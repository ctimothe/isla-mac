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
    static var shared: UpdateCheck { sharedOverride ?? live }
    /// Stands in front of the real one, for the visual lab, which draws every
    /// state of the About card without a request leaving the Mac.
    static var sharedOverride: UpdateCheck?
    private static let live = UpdateCheck()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(Release)
        case failed(Reason)
    }

    /// A release newer than the running one, with what Update Now needs to
    /// install it. `dmg` and `signature` are nil unless the answer named them
    /// the way Isla's own releases do (`trustedAsset`): a release that lacks
    /// either is still offered, through its page.
    struct Release: Equatable, Sendable {
        struct Asset: Equatable, Sendable {
            let name: String
            let url: URL
            let size: Int64
        }

        let version: String
        let page: URL
        /// The release's own notes, plain Markdown, at most `notesLimit` bytes,
        /// cut at a line boundary.
        var notes: String = ""
        var dmg: Asset? = nil
        var signature: Asset? = nil

        /// Both files are there, so Update Now has something it may install.
        var isInstallable: Bool { dmg != nil && signature != nil }
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
    @Published private(set) var lastAvailable: Release?

    static let automaticKey = "updates.checkAutomatically"

    static var automaticEnabled: Bool {
        UserDefaults.standard.bool(forKey: automaticKey)
    }

    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/ctimothe/isla-mac/releases/latest")!

    /// Once a day is enough for an app that releases every few weeks, and the
    /// tolerance lets the system fold it into another wake-up.
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let fetch: Fetch
    private let currentVersion: () -> String
    /// The rehearsal folder (`DI_UPDATE_REHEARSAL`), or nil, which is every
    /// normal run. Given, never read from the environment here.
    private let rehearsal: URL?
    private var timer: Timer?

    init(
        fetch: @escaping Fetch = { try await PrivateNetwork.session.data(for: $0) },
        currentVersion: @escaping () -> String = { ProductIdentity.version },
        rehearsal: URL? = DebugTrail.updateRehearsal
    ) {
        self.fetch = fetch
        self.currentVersion = currentVersion
        self.rehearsal = rehearsal
    }

    /// Whether this is a rehearsal: the release comes from a local folder, and
    /// the card says so.
    var isRehearsal: Bool { rehearsal != nil }

    // MARK: - Checking

    func check() {
        guard state != .checking else { return }
        state = .checking
        let local = currentVersion()
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Isla/\(local)", forHTTPHeaderField: "User-Agent")
        let rehearsal = rehearsal
        // In a rehearsal the answer is a file in the folder, shaped like
        // GitHub's, and nothing is requested from anywhere.
        let fetch: Fetch = rehearsal.map { folder in
            { request in
                let data = try Data(contentsOf: folder.appendingPathComponent("release.json"))
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        } ?? self.fetch
        Task { [weak self] in
            let outcome: State
            do {
                let (data, response) = try await fetch(request)
                if let reason = Self.failure(for: response) {
                    Log.updates.error("update check failed: \(String(describing: reason), privacy: .public)")
                    outcome = .failed(reason)
                } else {
                    outcome = Self.state(forRelease: data, localVersion: local, rehearsal: rehearsal)
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
        case .available(let release): lastAvailable = release
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
    nonisolated static func state(forRelease data: Data, localVersion: String, rehearsal: URL? = nil) -> State {
        // Assets are decoded one by one and every field is optional, so a
        // malformed asset costs only itself and never the release around it.
        struct RawAsset: Decodable {
            let name: String?
            let browser_download_url: String?
            let size: Int64?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                name = try? container.decode(String.self, forKey: .name)
                browser_download_url = try? container.decode(String.self, forKey: .browser_download_url)
                size = try? container.decode(Int64.self, forKey: .size)
            }

            enum Keys: String, CodingKey { case name, browser_download_url, size }
        }
        struct Answer: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let body: String?
            let assets: [RawAsset]?
        }
        guard let release = try? JSONDecoder().decode(Answer.self, from: data),
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
        func asset(_ kind: AssetKind) -> Release.Asset? {
            for raw in release.assets ?? [] {
                guard let name = raw.name, let url = raw.browser_download_url.flatMap(URL.init(string:)), let size = raw.size,
                      let trusted = trustedAsset(name: name, url: url, size: size, version: remote, kind: kind, rehearsal: rehearsal)
                else { continue }
                return trusted
            }
            return nil
        }
        return .available(Release(
            version: remote,
            page: release.html_url,
            notes: cappedNotes(release.body ?? ""),
            dmg: asset(.dmg),
            signature: asset(.signature)
        ))
    }

    // MARK: - Assets

    enum AssetKind {
        case dmg, signature

        /// The most the file may be. A disk image of Isla is about five
        /// megabytes; the cap only has to refuse the absurd, because it is
        /// also what the free-space check multiplies and what the signature
        /// check reads into memory.
        var sizeLimit: Int64 {
            switch self {
            case .dmg: return 100 * 1024 * 1024
            case .signature: return 1024
            }
        }

        func fileName(version: String) -> String {
            switch self {
            case .dmg: return "Isla-\(version).dmg"
            case .signature: return "Isla-\(version).dmg.sig"
            }
        }
    }

    /// The asset, when every rule holds, else nil — which makes the release
    /// offer only its page. The URL must be exactly
    /// `https://github.com/<owner>/<repo>/releases/download/v<version>/Isla-<version>.dmg`
    /// (or `.dmg.sig`), compared as the encoded path so nothing can hide in an
    /// escape, a dot segment or a doubled slash, with no credentials, port,
    /// query or fragment (an empty `?` or `#` counts); the asset's own name must
    /// be that file name; and its size must be positive and within the kind's
    /// limit.
    ///
    /// The host is not the protection. Downloads are redirected to GitHub's
    /// asset network and the signature is checked against the key in the app,
    /// which is what keeps a wrong file out. These rules keep a tampered answer
    /// from choosing what is *fetched* at all, and keep the first request on
    /// Isla's own repository.
    ///
    /// **In a rehearsal** (`rehearsal` is the folder) the rule changes in one
    /// way: the URL must be exactly `file://<folder>/<file name>`, with no `..`
    /// in it, no link anywhere along it that leads out, and nothing but the
    /// folder's own file; an https URL is then refused, as is any other file.
    nonisolated static func trustedAsset(
        name: String, url: URL, size: Int64, version: String, kind: AssetKind, rehearsal: URL? = nil
    ) -> Release.Asset? {
        let fileName = kind.fileName(version: version)
        if let rehearsal {
            guard name == fileName, size > 0, size <= kind.sizeLimit, isRehearsalFile(url, named: fileName, in: rehearsal)
            else { return nil }
            return Release.Asset(name: name, url: url, size: size)
        }
        guard name == fileName, size > 0, size <= kind.sizeLimit,
              let repository = repositoryPath,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == "\(repository)/releases/download/v\(version)/\(fileName)"
        else { return nil }
        return Release.Asset(name: name, url: url, size: size)
    }

    /// Whether `url` is `file://<folder>/<fileName>`, exactly: a file URL with no
    /// host, query or fragment and no `..`, whose path with every link resolved
    /// is the folder's own resolved path and that file name. A link named
    /// `<fileName>` that points out of the folder resolves elsewhere and fails.
    nonisolated static func isRehearsalFile(_ url: URL, named fileName: String, in folder: URL) -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.fragment == nil, parts.user == nil, parts.port == nil,
              !url.pathComponents.contains("..")
        else { return false }
        let expected = folder.resolvingSymlinksInPath().appendingPathComponent(fileName).path
        return url.resolvingSymlinksInPath().path == expected
    }

    /// `/<owner>/<repo>`, read from `latestReleaseURL` so the API request, the
    /// release page check and the asset check cannot name different
    /// repositories.
    nonisolated static var repositoryPath: String? {
        let apiPath = latestReleaseURL.path            // /repos/<owner>/<name>/releases/latest
        guard apiPath.hasPrefix("/repos/"), let releases = apiPath.range(of: "/releases/") else { return nil }
        return String(apiPath[apiPath.index(apiPath.startIndex, offsetBy: "/repos".count)..<releases.lowerBound])
    }

    // MARK: - Notes

    nonisolated static let notesLimit = 4096

    /// The release's notes as the panel shows them: line ends normalised, at
    /// most `notesLimit` bytes, cut where a line ends so a sentence is never
    /// left in half. A single line longer than the limit has no boundary to
    /// cut at and is cut on a character instead.
    nonisolated static func cappedNotes(_ body: String) -> String {
        let text = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count > notesLimit else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: notesLimit)
        // Back off to a character boundary, then to the last line end.
        while end > text.utf8.startIndex, end.samePosition(in: text) == nil {
            end = text.utf8.index(before: end)
        }
        let head = text[..<end]
        if let newline = head.lastIndex(of: "\n") {
            return String(head[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(head)
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
        guard let repository = repositoryPath else { return false }
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

    /// The version this check compares against: the running one. Settings says
    /// it under the card, so the card and the check cannot disagree about it.
    var runningVersion: String { currentVersion() }

    /// Whether the Settings tab should wear a mark: an update was found.
    var hasUpdate: Bool { lastAvailable != nil }
}
