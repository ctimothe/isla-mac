import AppKit
import CryptoKit

/// The one Spotify feature that has no local API: Liked Songs.
///
/// Every scriptable route was probed and is dead — the AppleScript `starred`
/// property errors on read and write both, a corpse left in the dictionary —
/// so saving a track goes the way Spotify actually sanctions: the Web API,
/// authorized once by the user in their browser with PKCE. No client secret
/// exists anywhere; the tokens live in the keychain, never in defaults; and
/// the only scopes requested are the library ones the heart needs.
@MainActor
final class SpotifyAccount: ObservableObject {
    static let shared = SpotifyAccount()

    /// The registration made for this install — created in the user's own
    /// Spotify developer dashboard, at their request, so Connect is one
    /// click. A client id is public information by design in PKCE: there is
    /// no secret to protect, the id only names the app on the consent page.
    /// A different id pasted into defaults still overrides it.
    static let builtInClientID = "358067117334450d8cd1c09f689ffeec"
    static let clientIDKey = "spotifyClientID"
    static let redirectURI = "isla://spotify-callback"

    @Published private(set) var isConnected = false
    /// True once the API has refused a library call for account reasons —
    /// Spotify gates the whole Web API behind Premium as of 2026. The heart
    /// hides rather than lies; this clears on the next successful call.
    @Published private(set) var apiBlocked = false
    /// Track id → saved?, so hearts answer instantly and survive re-renders.
    ///
    /// A missing entry means "not asked yet or not answered", which is not the
    /// same as "not saved" — the heart must not claim a song is unliked just
    /// because the lookup has not landed.
    @Published private(set) var saved: [String: Bool] = [:]

    /// True when there is an account on file but its tokens cannot be read —
    /// the keychain prompt was dismissed, or the stored refresh token has been
    /// revoked. The heart hides rather than sitting there doing nothing when a
    /// user presses it, which is what it used to do.
    @Published private(set) var tokenUnavailable = false

    private var verifier: String?
    /// Random value tying a callback to the request that started it. Without
    /// one, any process that claims the `isla` URL scheme — schemes
    /// are first-come and shared on macOS — could hand the app an
    /// authorization code it never asked for, and the app would exchange it:
    /// textbook OAuth CSRF, which PKCE does not defend against.
    private var authorizationState: String?
    /// The refresh in flight, if any. Spotify rotates refresh tokens on use,
    /// so two concurrent refreshes with the same token invalidate each other:
    /// a heart tapped in the same beat as a track change silently disconnected
    /// the account. Everyone waits on the same one instead.
    private var refreshTask: Task<String?, Never>?
    /// Serializes keychain mutations against each other and against reads.
    /// They used to be three unordered detached tasks per store, which could
    /// interleave with a concurrent disconnect and leave a connected-looking
    /// account over an empty keychain.
    private let credentials = CredentialStore(service: "com.ctimothe.isla.spotify")

    /// True when an older build left an account in the login keychain that
    /// this build cannot see. Offered in Settings as a one-press import —
    /// never done automatically, because that read is the one thing here that
    /// can raise the login-password prompt.
    @Published private(set) var canImportLegacyAccount = false
    /// Where credentials are being kept, stated in Settings rather than
    /// guessed at. See `TokenStore`.
    @Published private(set) var storage: TokenStore.Backing = .keychain

    private init() {
        // Read straight away, on every launch, with no flag guarding it —
        // because neither place this build can store a token asks the user
        // anything. The data-protection keychain answers the app that owns the
        // item, and a `0600` file answers its owner. The only store that ever
        // prompted was the legacy login keychain, and nothing reaches for that
        // unless somebody presses Import.
        Task { [credentials] in
            let connected = await credentials.read("refreshToken") != nil
            let backing = await credentials.backing()
            let legacy = connected ? false : await credentials.legacyAccountExists()
            self.isConnected = connected
            self.storage = backing
            self.canImportLegacyAccount = legacy
        }
    }

    /// Brings an account across from the login keychain, at the user's request.
    /// This is the one path that can ask for the login password, and it does so
    /// exactly once, because what it finds is rewritten where this build can
    /// read it without asking again.
    func importLegacyAccount() {
        Task { [credentials] in
            guard await credentials.importLegacy() else {
                self.canImportLegacyAccount = false
                return
            }
            self.isConnected = await credentials.read("refreshToken") != nil
            self.canImportLegacyAccount = false
            self.tokenUnavailable = false
        }
    }

    var clientID: String? {
        let value = UserDefaults.standard.string(forKey: Self.clientIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? Self.builtInClientID : value
    }

    // MARK: - Authorization (PKCE)

    func beginAuthorization() {
        guard let clientID else { return }
        let raw = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let verifier = raw.base64URLEncoded()
        self.verifier = verifier
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded()
        authorizationState = state

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "user-library-read user-library-modify"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)
    }

    /// The browser lands back here through the app's URL scheme.
    func handleCallback(_ url: URL) {
        guard url.host == "spotify-callback" || url.path.contains("spotify-callback"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              let verifier, let clientID else { return }
        // The callback has to name the request it answers, and that request has
        // to be one this app made and has not already consumed.
        guard let expected = authorizationState,
              let returned = items.first(where: { $0.name == "state" })?.value,
              constantTimeEquals(returned, expected) else { return }
        // Single-use, both of them: a verifier or state left lying around is a
        // second chance for a callback nobody asked for.
        authorizationState = nil
        self.verifier = nil
        Task {
            await exchange(code: code, verifier: verifier, clientID: clientID)
        }
    }

    /// Compares without leaking how far the match got through timing.
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    private func exchange(code: String, verifier: String, clientID: String) async {
        // Percent-encoded, every one. These are interpolated into a
        // form-encoded body, and a value carrying `&`, `+` or `=` — legal in
        // an authorization code — would otherwise split the body into fields
        // that mean something else.
        let body = [
            "grant_type=authorization_code",
            "code=\(Self.formEncoded(code))",
            "redirect_uri=\(Self.formEncoded(Self.redirectURI))",
            "client_id=\(Self.formEncoded(clientID))",
            "code_verifier=\(Self.formEncoded(verifier))",
        ].joined(separator: "&")
        guard let tokens = await tokenRequest(body: body) else { return }
        await store(tokens)
    }

    /// `application/x-www-form-urlencoded` escaping: everything outside the
    /// unreserved set, and a space as `%20` rather than `+`.
    static func formEncoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private func tokenRequest(body: String) async -> Tokens? {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private func store(_ tokens: Tokens) async {
        let generation = credentialGeneration
        let expiry = String(Date().timeIntervalSince1970 + Double(tokens.expires_in) - 60)
        await credentials.storeTokens(
            access: tokens.access_token,
            refresh: tokens.refresh_token,
            expiresAt: expiry
        )
        // Re-checked after the hop, not only before it. A disconnect landing
        // while the write was in flight would otherwise leave the account
        // showing as connected on top of a keychain it had just cleared.
        //
        // Overtaken means only "do not claim to be connected". Clearing here
        // instead would be worse than the bug it fixes: by the time this
        // resumes the user may have reconnected, and the disconnect's own
        // `clear()` is already queued behind this write on the same actor — so
        // wiping again would delete the *new* session's tokens.
        guard credentialGeneration == generation else { return }
        isConnected = true
        canImportLegacyAccount = false
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        credentialGeneration += 1
        saved = [:]
        isConnected = false
        Task { [credentials] in await credentials.clear() }
    }

    /// One refresh at a time, shared by every caller that arrives while it is
    /// in flight.
    ///
    /// The whole body is one task, created and registered without an `await`
    /// between the check and the assignment. Reading the keychain first and
    /// registering afterwards left a suspension point in the middle, so two
    /// callers arriving together — a heart tap in the same beat as a track
    /// change — both saw no task in flight and both spent the same rotating
    /// refresh token, which invalidates the account.
    private func freshAccessToken() async -> String? {
        if let existing = refreshTask { return await existing.value }

        let generation = credentialGeneration
        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            let stored = await self.credentials.readTokens()
            if let expires = stored.expires,
               Date().timeIntervalSince1970 < expires,
               let token = stored.access {
                return token
            }
            guard let refresh = stored.refresh, let clientID = self.clientID else { return nil }
            let body = "grant_type=refresh_token"
                + "&refresh_token=\(Self.formEncoded(refresh))"
                + "&client_id=\(Self.formEncoded(clientID))"
            guard let tokens = await self.tokenRequest(body: body) else { return nil }
            // A disconnect that happened while this was in flight wins: storing
            // now would put the tokens the user just revoked back on disk.
            guard self.credentialGeneration == generation else { return nil }
            await self.store(tokens)
            return tokens.access_token
        }
        refreshTask = task
        let token = await task.value
        // Only clear our own registration — a successor may already have
        // replaced it.
        if refreshTask == task { refreshTask = nil }
        return token
    }

    /// Bumped by every deliberate credential change, so an exchange that was
    /// already in flight can tell it has been overtaken.
    private var credentialGeneration = 0

    // MARK: - Liked Songs

    func refreshSavedState(trackID: String, attempt: Int = 0) {
        guard isConnected, saved[trackID] == nil else { return }
        Task {
            guard let token = await freshAccessToken() else {
                // No usable token. Say so, so the heart can hide instead of
                // pretending: an unliked-looking heart that does nothing when
                // pressed is worse than no heart at all.
                tokenUnavailable = true
                return
            }
            tokenUnavailable = false
            guard let url = URL(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackID)") else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                // Offline or refused mid-flight. Retried, because the entry
                // stays nil and nothing else would ever ask again — the heart
                // would show hollow for a liked song for the rest of the track.
                return retrySavedState(trackID: trackID, attempt: attempt)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 {
                apiBlocked = true
                return
            }
            guard status == 200,
                  let flags = try? JSONDecoder().decode([Bool].self, from: data),
                  let flag = flags.first else {
                return retrySavedState(trackID: trackID, attempt: attempt)
            }
            apiBlocked = false
            saved[trackID] = flag
        }
    }

    private func retrySavedState(trackID: String, attempt: Int) {
        guard attempt < 3 else { return }
        let delay = pow(2.0, Double(attempt + 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshSavedState(trackID: trackID, attempt: attempt + 1)
            }
        }
    }

    func toggleSaved(trackID: String) {
        guard isConnected else { return }
        let wants = !(saved[trackID] ?? false)
        // Optimistic: the heart answers the tap now; a failed request puts
        // it back rather than leaving the tap looking ignored.
        saved[trackID] = wants
        Task {
            guard let token = await freshAccessToken() else {
                saved[trackID] = !wants
                tokenUnavailable = true
                return
            }
            tokenUnavailable = false
            guard let url = URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackID)") else {
                saved[trackID] = !wants
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = wants ? "PUT" : "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let status = (try? await URLSession.shared.data(for: request))
                .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            if status == 403 { apiBlocked = true }
            if !(status.map { (200..<300).contains($0) } ?? false) {
                saved[trackID] = !wants
            } else {
                apiBlocked = false
            }
        }
    }
}

/// Serializes every keychain touch onto one actor, off the main thread.
///
/// Two reasons, and both were live bugs. Ordering: the writes used to be
/// fire-and-forget detached tasks, so a read could miss tokens that had just
/// been stored, and a disconnect's deletes could land after a reconnect's
/// writes — leaving `isConnected` true over an empty keychain, an account that
/// silently died at the next launch. Blocking: `SecItemCopyMatching` can stop
/// on the system's own ACL prompt, and an actor with one serial executor parks
/// at most one thread on that dialog instead of one per concurrent caller.
actor CredentialStore {
    private let tokens: TokenStore

    /// What the keychain last told us, kept for the life of the process.
    ///
    /// This is what stops the password prompt repeating. Every keychain read is
    /// a chance for macOS to ask — a rebuilt or re-signed app looks like a
    /// stranger to the item's ACL — and the token used to be re-read on *every
    /// track change*, because that is when the heart re-checks whether the song
    /// is saved. Locking and unlocking a Mac with music playing therefore
    /// produced prompt after prompt for the same item. Read once, remember,
    /// and the answer is given at most once per launch.
    private var cache: (expires: Double?, access: String?, refresh: String?)?
    /// Raised when the user dismissed the prompt. Asking again after somebody
    /// has said no is the behaviour being complained about; the feature simply
    /// stays off until they connect it again by hand.
    private var refused = false

    init(service: String) {
        self.tokens = TokenStore(service: service)
    }

    /// Where this build can actually keep credentials — see `TokenStore`.
    func backing() -> TokenStore.Backing { tokens.backing }

    /// True when an older build left an account in the login keychain. Asks
    /// for attributes only, so it cannot raise the password prompt.
    func legacyAccountExists() -> Bool { tokens.legacyAccountExists("refreshToken") }

    /// Brings that account across. This one *can* prompt, which is why it only
    /// ever runs because somebody pressed a button asking it to.
    func importLegacy() -> Bool {
        var moved = false
        for account in ["accessToken", "refreshToken", "expiresAt"] {
            guard let value = tokens.readLegacy(account) else { continue }
            tokens.write(account, value)
            moved = true
        }
        if moved { cache = nil; refused = false }
        return moved
    }

    func read(_ account: String) -> String? {
        guard !refused else { return nil }
        return tokens.read(account)
    }

    func readTokens() -> (expires: Double?, access: String?, refresh: String?) {
        if let cache { return cache }
        guard !refused else { return (nil, nil, nil) }
        let fresh = (tokens.read("expiresAt").flatMap(Double.init),
                     tokens.read("accessToken"),
                     tokens.read("refreshToken"))
        // Nothing came back at all where something was expected: either there
        // is no account, or the prompt was dismissed. Either way, stop asking.
        if fresh.1 == nil && fresh.2 == nil {
            refused = true
            return (nil, nil, nil)
        }
        cache = fresh
        return fresh
    }

    func storeTokens(access: String, refresh: String?, expiresAt: String) {
        tokens.write("accessToken", access)
        // Spotify omits the refresh token when it is unchanged; writing nil
        // over the stored one would sign the user out at the next launch.
        if let refresh { tokens.write("refreshToken", refresh) }
        tokens.write("expiresAt", expiresAt)
        // Write-through, so the next read is answered from memory rather than
        // by asking the keychain — and the user — all over again.
        refused = false
        cache = (Double(expiresAt), access, refresh ?? cache?.refresh)
    }

    func clear() {
        cache = nil
        refused = false
        tokens.delete("accessToken")
        tokens.delete("refreshToken")
        tokens.delete("expiresAt")
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
