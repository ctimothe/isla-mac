import AppKit

/// Finds out whether a newer Isla has been released.
///
/// Before this there was no way to learn of one. The app had no updater, no
/// feed and no version check, so everyone who installed 0.1.0 would stay on
/// it until a macOS release broke it. Sparkle is the eventual answer, but it
/// needs a Developer ID to be safe, so this is the part that works without
/// one: it asks GitHub for the latest release and, if it is newer, links to
/// its page.
///
/// It reaches the network, so the automatic check is **off by default**, per
/// the rule in `CLAUDE.md`, and recorded in `checklist.md` and the README's
/// privacy table. Pressing Check for Updates is itself the consent for that
/// one request. What leaves the Mac is the request: GitHub sees an IP address
/// and a User-Agent naming the Isla version, and nothing else.
@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, page: URL)
        case failed(Reason)
    }

    /// Why a check failed, so Settings can say something true. A rate limit
    /// used to read "Could not reach GitHub", which sent people to debug a
    /// connection that was fine.
    enum Reason: Equatable {
        case offline
        case rateLimited
        case server
    }

    @Published private(set) var state: State = .idle

    /// The newest release a check has found that is later than this one.
    /// `state` is only the latest outcome, and `check()` sets `.checking` first
    /// and then whatever came back, so a Tuesday offline failure used to erase
    /// Monday's "Update available": the rail dot and the Download row went with
    /// it. This is kept across `.checking` and `.failed` and cleared only by an
    /// answer that says the running version is current.
    @Published private(set) var lastAvailable: (version: String, page: URL)?

    static let automaticKey = "updates.checkAutomatically"

    static var automaticEnabled: Bool {
        UserDefaults.standard.bool(forKey: automaticKey)
    }

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/ctimothe/isla-mac/releases/latest")!

    /// Once a day is enough for an app that releases every few weeks, and the
    /// tolerance lets the system fold it into another wake-up.
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let fetch: Fetch
    private let currentVersion: () -> String
    private var timer: Timer?

    init(
        fetch: @escaping Fetch = { try await PrivateNetwork.session.data(for: $0) },
        currentVersion: @escaping () -> String = { ProductIdentity.version }
    ) {
        self.fetch = fetch
        self.currentVersion = currentVersion
    }

    // MARK: - Checking

    func check() {
        guard state != .checking else { return }
        state = .checking
        let local = currentVersion()
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Isla/\(local)", forHTTPHeaderField: "User-Agent")
        let fetch = fetch
        Task { [weak self] in
            let outcome: State
            do {
                let (data, response) = try await fetch(request)
                if let reason = Self.failure(for: response) {
                    Log.updates.error("update check failed: \(String(describing: reason), privacy: .public)")
                    outcome = .failed(reason)
                } else {
                    outcome = Self.state(forRelease: data, localVersion: local)
                }
            } catch {
                Log.updates.error("update check failed: \(error.localizedDescription, privacy: .public)")
                outcome = .failed(.offline)
            }
            self?.apply(outcome)
        }
    }

    private func apply(_ outcome: State) {
        switch outcome {
        case .available(let version, let page): lastAvailable = (version, page)
        case .upToDate: lastAvailable = nil
        case .idle, .checking, .failed: break
        }
        state = outcome
    }

    /// What a non-200 answer means. GitHub answers an exhausted unauthenticated
    /// quota with 403 and `x-ratelimit-remaining: 0`, or with 429; any other
    /// failing status is the server's, not the network's.
    nonisolated static func failure(for response: URLResponse) -> Reason? {
        guard let http = response as? HTTPURLResponse else { return .server }
        switch http.statusCode {
        case 200: return nil
        case 429: return .rateLimited
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0": return .rateLimited
        default: return .server
        }
    }

    /// What a `releases/latest` answer means for the running version.
    nonisolated static func state(forRelease data: Data, localVersion: String) -> State {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true
        else { return .failed(.server) }
        let remote = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isNewer(remote, than: localVersion) else { return .upToDate(version: localVersion) }
        // The page is what "Download Isla x" opens. An answer that points
        // anywhere but Isla's own releases is a failed check, not a download
        // button (G-027).
        guard isTrustedReleasePage(release.html_url) else {
            Log.updates.error("update check refused a release page off Isla's GitHub releases")
            return .failed(.server)
        }
        return .available(version: remote, page: release.html_url)
    }

    /// Whether `url` is a page under Isla's own GitHub releases: https, exactly
    /// github.com, no credentials or port, and a path under
    /// `/ctimothe/isla-mac/releases/`. The repository is read from
    /// `latestReleaseURL` so the two cannot drift apart. A renamed repository
    /// shows as a failed check until that constant changes, which the API
    /// request itself already depends on.
    nonisolated static func isTrustedReleasePage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil
        else { return false }
        let apiPath = latestReleaseURL.path            // /repos/<owner>/<name>/releases/latest
        guard apiPath.hasPrefix("/repos/"), let releases = apiPath.range(of: "/releases/") else { return false }
        let repository = apiPath[apiPath.index(apiPath.startIndex, offsetBy: "/repos".count)..<releases.lowerBound]
        return url.path.hasPrefix("\(repository)/releases/")
    }

    /// Whether `remote` is a later release than `local`, by dotted numbers.
    /// A local pre-release ("0.3.0-beta.1") is older than the same numbers
    /// released. A version that is not dotted numbers is never newer, so a
    /// malformed tag cannot offer a download.
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parse(_ version: String) -> (numbers: [Int], prerelease: Bool)? {
            let parts = version.split(separator: "-", maxSplits: 1)
            guard let core = parts.first else { return nil }
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            return (numbers.compactMap { $0 }, parts.count > 1)
        }
        guard let r = parse(remote), !r.prerelease else { return false }
        guard let l = parse(local) else { return true }
        let count = max(r.numbers.count, l.numbers.count)
        for index in 0..<count {
            let a = index < r.numbers.count ? r.numbers[index] : 0
            let b = index < l.numbers.count ? l.numbers[index] : 0
            if a != b { return a > b }
        }
        return l.prerelease
    }

    // MARK: - Automatic

    /// Starts the daily check when the user has turned it on. Called at launch
    /// and from the Settings switch.
    func startAutomaticIfEnabled() {
        stopAutomatic()
        guard Self.automaticEnabled else { return }
        // Not at the launch instant, which is busy enough, and not every
        // launch-at-login morning in the same second as everything else.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard Self.automaticEnabled else { return }
            self?.check()
        }
        let timer = Timer(timeInterval: Self.automaticInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setAutomatic(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticKey)
        startAutomaticIfEnabled()
    }

    private func stopAutomatic() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether the Settings tab should wear a mark: an update was found.
    var hasUpdate: Bool { lastAvailable != nil }
}
