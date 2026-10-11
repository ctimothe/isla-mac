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
    static var shared: SpotifyAccount { sharedOverride ?? live }
    private static let live = SpotifyAccount()

    /// A seam for the headless visual lab, never set by the app. Settings and
    /// the lock card read `shared` from deep inside the view tree, and the
    /// live account's first read goes to the person's own keychain and
    /// support folder. Set before anything asks for `shared`, an isolated
    /// account stands in and the live one is never even built — it is lazy.
    static var sharedOverride: SpotifyAccount?

    /// The registration made for this install — created in the user's own
    /// Spotify developer dashboard, at their request, so Connect is one
    /// click. A client id is public information by design in PKCE: there is
    /// no secret to protect, the id only names the app on the consent page.
    /// A different id pasted into defaults still overrides it.
    static let builtInClientID = "358067117334450d8cd1c09f689ffeec"
    static let clientIDKey = "spotifyClientID"
    static let redirectURI = "isla://spotify-callback"

    @Published private(set) var isConnected = false
    /// True once the API has refused a call for account reasons. The heart
    /// hides rather than lies.
    ///
    /// It clears on a successful call, on a disconnect, and on a new grant.
    /// It used to say only "on the next successful call", and none could
    /// happen: the hidden heart's own task was the only thing that asked, so
    /// one 403 blocked the account for the rest of the process — through a
    /// disconnect, and under a different account connected after it. Now a
    /// lookup asks again once `refusalCooldown` has passed, and the lock card
    /// keeps asking while the heart is hidden.
    @Published private(set) var apiBlocked = false {
        didSet {
            if !apiBlocked {
                refusal = nil
                blockedUntil = nil
            }
        }
    }
    /// When a refused account may be asked again. Nil while nothing is refused.
    private var blockedUntil: Date?
    /// Ten minutes: long enough that a refused account is not asked on every
    /// track change, short enough that one the developer has just listed in
    /// the dashboard starts working within a song or two.
    static let refusalCooldown: TimeInterval = 600
    /// Why, when Spotify said. Settings shows it so the missing heart has an
    /// explanation. Before, the heart vanished and nothing anywhere said why.
    @Published private(set) var refusal: Refusal?

    enum Refusal: Equatable {
        /// Spotify keeps an app in development mode until it is reviewed, and
        /// in that mode only accounts the developer listed by hand may use
        /// it. Every other account gets 403 "User not registered in the
        /// Developer Dashboard".
        case notRegistered
        /// Spotify named Premium. Since February 2026 that requirement sits on
        /// the developer who registered a Development Mode app — the built-in
        /// client is one — not on each person who signs in to it, so the
        /// explanation does not tell the listener to upgrade.
        case premiumRequired
        case other

        /// Read from the 403's own message, because the status alone cannot
        /// tell the two apart and the user can fix only one of them.
        static func from(_ body: Data?) -> Refusal {
            guard let body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let error = object["error"] as? [String: Any],
                  let message = (error["message"] as? String)?.lowercased()
            else { return .other }
            if message.contains("not registered") { return .notRegistered }
            if message.contains("premium") { return .premiumRequired }
            return .other
        }

        var explanation: String {
            switch self {
            case .notRegistered:
                return localized("Spotify refused this account. Until Spotify reviews Isla, it admits only accounts added by hand, so Liked Songs cannot work here yet.")
            case .premiumRequired:
                return localized("Spotify refused Liked Songs and named Premium. Spotify asks this of Isla's own registration, so your plan may not be the cause.")
            case .other:
                return localized("Spotify refused this account's library request.")
            }
        }
    }

    private func refuse(_ body: Data?) {
        refusal = Refusal.from(body)
        apiBlocked = true
        blockedUntil = now().addingTimeInterval(Self.refusalCooldown)
    }

    /// Whether a lookup may go to the network: always while nothing is
    /// refused, and again once a refusal's cooldown has run out, so a fixed
    /// account recovers without a relaunch.
    private func mayAsk() -> Bool {
        guard apiBlocked, let blockedUntil else { return true }
        return now() >= blockedUntil
    }

    /// Back to a clean slate for whatever account comes next. Called by a
    /// disconnect and by a completed grant — never by a token refresh, which
    /// is the same account and would lift a refusal about once an hour.
    private func forgetRefusal() {
        apiBlocked = false
        tokenUnavailable = false
    }
    /// Track id → saved?, so hearts answer instantly and survive re-renders.
    ///
    /// A missing entry means "not asked yet or not answered", which is not the
    /// same as "not saved" — the heart must not claim a song is unliked just
    /// because the lookup has not landed.
    @Published private(set) var saved: [String: Bool] = [:]

    /// True when there is an account on file but no usable token for it — the
    /// keychain prompt was dismissed, a refresh could not get through, or a
    /// freshly refreshed token was refused as well. The heart hides rather
    /// than sitting there doing nothing when a user presses it, which is what
    /// it used to do. A grant Spotify has revoked outright is not this: that
    /// disconnects, and says so through `needsReconnect`.
    @Published private(set) var tokenUnavailable = false

    /// True once Spotify has answered a refresh with `invalid_grant` — the
    /// user removed Isla at spotify.com/account/apps, or the grant otherwise
    /// died — and the account has let go of it. Settings used to go on saying
    /// Connected over a dead grant, while every track change sent another
    /// refresh that could never succeed. Cleared by the next grant and by a
    /// deliberate disconnect.
    @Published private(set) var needsReconnect = false

    /// How the last sign-in attempt ended, when it ended without an account.
    /// Every one of these used to return silently, leaving Settings offering
    /// Connect as if the button had never been pressed. Nil while an attempt
    /// is pending, after a success, and before anything was tried.
    @Published private(set) var signInOutcome: SignInOutcome?

    /// What went wrong on this Mac around a sign-in, as opposed to what Spotify
    /// answered (`signInOutcome`). One value, one inline note in Settings, no
    /// toast: the person acted on that row, so the row answers. Cleared on the
    /// next Connect press, and on a sign-in that completes.
    @Published private(set) var signInProblem: SignInProblem?

    enum SignInProblem: Equatable {
        /// `NSWorkspace.open` returned false: no browser took the consent URL.
        case browserDidNotOpen
        /// The import from the login keychain moved something, but not the
        /// refresh token, so no account came across. The Import row stays.
        case importIncomplete
        /// Spotify signed the person in and the tokens could be written
        /// nowhere — neither keychain nor file.
        case tokensNotSaved

        var explanation: String {
            switch self {
            case .browserDidNotOpen:
                return localized("Isla could not open your browser for Spotify sign-in.")
            case .importIncomplete:
                return localized("The account was not imported. Try again, or connect it anew.")
            case .tokensNotSaved:
                return localized("Spotify signed you in, but Isla could not save the account on this Mac.")
            }
        }
    }

    enum SignInOutcome: Equatable {
        /// Cancel was pressed on Spotify's consent page (`access_denied`).
        case cancelled
        /// The browser came back when no sign-in was pending — Isla was
        /// relaunched between Connect and approval, so the verifier that began
        /// the flow is gone and the code cannot be exchanged.
        case expired
        /// Spotify answered the callback with another error, or would not
        /// exchange the code it had just issued.
        case failed
    }

    /// Liked Songs writes, one runner per track. A tap records where the heart
    /// should end up; the runner sends PUT or DELETE, one at a time, until
    /// Spotify's last answer matches the latest tap. Each tap used to be its
    /// own unordered task, so a quick double tap could have the DELETE arrive
    /// before the slower PUT — the song liked on Spotify under a hollow heart.
    private var desiredSaved: [String: Bool] = [:]
    private var savedWriters: [String: Task<Void, Never>] = [:]

    private var verifier: String?
    /// Random value tying a callback to the request that started it. Without
    /// one, any process that claims the `isla` URL scheme — schemes
    /// are first-come and shared on macOS — could hand the app an
    /// authorization code it never asked for, and the app would exchange it:
    /// textbook OAuth CSRF, which PKCE does not defend against.
    private var authorizationState: String?
    /// When the pending verifier and state were made, so Connect pressed again
    /// can keep them while they are young and replace them once they are not.
    private var pendingSince: Date?
    /// The refresh in flight, if any. Spotify rotates refresh tokens on use,
    /// so two concurrent refreshes with the same token invalidate each other:
    /// a heart tapped in the same beat as a track change silently disconnected
    /// the account. Everyone waits on the same one instead.
    private var refreshTask: Task<String?, Never>?
    /// Serializes keychain mutations against each other and against reads.
    /// They used to be three unordered detached tasks per store, which could
    /// interleave with a concurrent disconnect and leave a connected-looking
    /// account over an empty keychain.
    private let credentials: CredentialStore

    /// The session every Web-API call goes through. `PrivateNetwork.session`
    /// in production — no disk cache, no cookie jar (audit G-016) —
    /// substituted in tests so the whole request path runs without a network.
    /// The two Liked Songs calls used to name the shared session directly, so
    /// no test could ever reach them.
    private let session: URLSession
    /// The clock the refusal cooldown reads. `Date.init` in production; a
    /// test moves it ten minutes without waiting ten minutes.
    private let now: () -> Date
    /// Where Connect sends the consent page: the user's browser in
    /// production, a capture in tests, so the whole grant — state, callback,
    /// exchange — can run without opening anything.
    private let openURL: (URL) -> Bool

    /// True when an older build left an account in the login keychain that
    /// this build cannot see. Offered in Settings as a one-press import —
    /// never done automatically, because that read is the one thing here that
    /// can raise the login-password prompt.
    @Published private(set) var canImportLegacyAccount = false
    /// Where credentials are being kept, stated in Settings rather than
    /// guessed at. See `TokenStore`.
    @Published private(set) var storage: TokenStore.Backing = .keychain

    /// Internal, not private, so tests can stand up an isolated account —
    /// throwaway service, temporary directory, stubbed session — instead of
    /// touching the real one. Production always arrives through `shared`.
    init(
        credentials: CredentialStore? = nil,
        session: URLSession = PrivateNetwork.session,
        now: @escaping () -> Date = Date.init,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let store = credentials ?? CredentialStore(service: "com.ctimothe.isla.spotify")
        self.credentials = store
        self.session = session
        self.now = now
        self.openURL = openURL
        // Read straight away, on every launch, with no flag guarding it —
        // because neither place this build can store a token asks the user
        // anything. The data-protection keychain answers the app that owns the
        // item, and a `0600` file answers its owner. The only store that ever
        // prompted was the legacy login keychain, and nothing reaches for that
        // unless somebody presses Import.
        Task { [store] in
            let connected = await store.read("refreshToken") != nil
            let backing = await store.backing()
            let legacy = connected ? false : await store.legacyAccountExists()
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
        signInProblem = nil
        Task { [credentials] in
            guard await credentials.importLegacy() else {
                // Said, and the row stays offered. It used to disappear on any
                // result, so an import that moved only an access token left the
                // person with no account and no way to try again.
                self.signInProblem = .importIncomplete
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

    /// How long a Connect that has not been answered keeps its verifier and
    /// state. Ten minutes: enough to find a password manager, short enough that
    /// a tab abandoned at lunch cannot approve into an account hours later.
    static let pendingSignInLifetime: TimeInterval = 600

    func beginAuthorization() {
        guard let clientID else { return }
        // A pending sign-in is reused, not replaced. Connect pressed twice used
        // to rotate the verifier and state on the second press, so approving the
        // first browser tab failed the state check and returned silently — the
        // person did everything right and nothing happened. Both tabs now carry
        // the one state; the first approval consumes it and the other tab's
        // callback is dropped, which is correct. Several pending pairs keyed by
        // state would be more to keep and more to attack for the same outcome.
        let pendingVerifier: String, state: String
        if let kept = self.verifier, let keptState = authorizationState,
           let since = pendingSince, now().timeIntervalSince(since) < Self.pendingSignInLifetime {
            pendingVerifier = kept
            state = keptState
        } else {
            let raw = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            pendingVerifier = raw.base64URLEncoded()
            state = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded()
            self.verifier = pendingVerifier
            authorizationState = state
            pendingSince = now()
        }
        let challenge = Data(SHA256.hash(data: Data(pendingVerifier.utf8))).base64URLEncoded()
        // A new attempt: whatever the last one ended in no longer describes
        // what is happening.
        signInOutcome = nil
        signInProblem = nil

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "user-library-read user-library-modify"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            // Documented in Spotify's authorization-code guide: the default,
            // false, lets a browser already signed in to Spotify skip the page
            // and reuse that account, so a reconnect after Disconnect could
            // never switch account. Connect is offered only while
            // disconnected, so the cost is one extra approval click, and in
            // exchange Spotify shows its "Not you?" switch.
            .init(name: "show_dialog", value: "true"),
        ]
        // `NSWorkspace.open` says whether it found a browser. That answer used
        // to be dropped, so a Mac with none made Connect do nothing and say
        // nothing.
        if !openURL(components.url!) { signInProblem = .browserDidNotOpen }
    }

    /// The browser lands back here through the app's URL scheme.
    func handleCallback(_ url: URL) {
        guard url.host == "spotify-callback" || url.path.contains("spotify-callback"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return }
        // A pair kept past its lifetime is gone, the same as after a relaunch:
        // Connect only reuses a young one, so an old one must not answer either.
        if let since = pendingSince, now().timeIntervalSince(since) >= Self.pendingSignInLifetime {
            self.verifier = nil
            authorizationState = nil
            pendingSince = nil
        }
        guard let verifier, let expected = authorizationState else {
            // Nothing is pending, so nothing can be exchanged: most likely Isla
            // was relaunched between Connect and approval and the verifier went
            // with the old process. Said, because the user has just approved
            // something and deserves to know it did not take. Not said over a
            // working account, where this is far more likely a callback opened
            // twice after it already succeeded than a sign-in that was lost.
            if !isConnected { signInOutcome = .expired }
            return
        }
        // The callback has to name the request it answers, and that request has
        // to be one this app made and has not already consumed. One that does
        // not is not ours to report on, so it is dropped without a word.
        guard let returned = items.first(where: { $0.name == "state" })?.value,
              constantTimeEquals(returned, expected) else { return }
        // Single-use, both of them: a verifier or state left lying around is a
        // second chance for a callback nobody asked for.
        authorizationState = nil
        self.verifier = nil
        pendingSince = nil
        guard let code = items.first(where: { $0.name == "code" })?.value, let clientID else {
            // No code means Spotify sent an error instead. `access_denied` is
            // the Cancel button on the consent page; anything else is a
            // failure the user did not choose.
            let error = items.first(where: { $0.name == "error" })?.value
            signInOutcome = error == "access_denied" ? .cancelled : .failed
            return
        }
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
        guard case .tokens(let tokens) = await tokenRequest(body: body) else {
            // Even `invalid_grant` here is only a failed sign-in — a code that
            // expired or was already spent — never a reason to touch the
            // account that may already be connected.
            signInOutcome = .failed
            return
        }
        let generation = credentialGeneration
        await store(tokens)
        // A new grant is Spotify's fresh answer about this account. Whatever
        // it refused before, under this account or the last one, no longer
        // stands; the next lookup finds out again. Skipped when a disconnect
        // overtook the write, which has cleared it already.
        if credentialGeneration == generation {
            forgetRefusal()
            signInOutcome = nil
        }
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

    /// What the token endpoint said, kept apart because the two failures mean
    /// opposite things. Every non-200 used to collapse into nil, so a grant
    /// the user had revoked looked exactly like a café with no Wi-Fi — and
    /// since only the first may disconnect, neither did.
    private enum TokenResult {
        case tokens(Tokens)
        /// OAuth's `invalid_grant`: the refresh token (or code) is dead and
        /// asking again cannot help.
        case invalidGrant
        /// Anything else — offline, a 5xx, a malformed body, any other 400.
        /// Never disconnects: the next attempt may well work.
        case failed
    }

    private func tokenRequest(body: String) async -> TokenResult {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (data, response) = try? await session.data(for: request) else { return .failed }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { return .failed }
            return .tokens(tokens)
        }
        // RFC 6749 §5.2: an error response is a 400 whose JSON body names the
        // error. Only that exact code counts, so a Spotify outage that happens
        // to answer 400 with some other body never signs anyone out.
        if status == 400,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["error"] as? String == "invalid_grant" {
            return .invalidGrant
        }
        return .failed
    }

    private func store(_ tokens: Tokens) async {
        let generation = credentialGeneration
        let expiry = String(Date().timeIntervalSince1970 + Double(tokens.expires_in) - 60)
        let backing = await credentials.storeTokens(
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
        // Keychain and file both refusing the write used to be dropped on the
        // floor, and the account went on claiming to be connected over tokens
        // that would be gone at the next launch. Not claimed now, and said.
        guard Self.connectedAfterStore(refreshBacking: backing) else {
            signInProblem = .tokensNotSaved
            return
        }
        signInProblem = nil
        isConnected = true
        canImportLegacyAccount = false
        // Tokens Spotify just issued are proof the account works.
        needsReconnect = false
    }

    /// Whether a sign-in may call itself connected, given where the write of
    /// the refresh token landed. Pure, so the rule is tested without a keychain.
    static func connectedAfterStore(refreshBacking: TokenStore.Backing) -> Bool {
        refreshBacking != .unavailable
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        dropAccountState()
        // A deliberate disconnect is its own explanation; the reconnect note
        // and the last attempt's outcome are about an account that is gone.
        needsReconnect = false
        signInOutcome = nil
        signInProblem = nil
        Task { [credentials] in await credentials.clear() }
    }

    /// Everything that belongs to the account being let go, shared by a
    /// disconnect and a revoked grant. The generation bump is what every
    /// in-flight lookup and write checks after its awaits: without it, a
    /// lookup already on the wire wrote the old account's answer back into
    /// `saved` after the disconnect had cleared it.
    private func dropAccountState() {
        credentialGeneration += 1
        saved = [:]
        desiredSaved = [:]
        savedWriters = [:]
        isConnected = false
        // The refusal belonged to the account just removed. Kept, it showed
        // in Settings under the next account and hid that one's heart too.
        forgetRefusal()
    }

    /// Spotify said `invalid_grant` to a refresh: the user removed Isla at
    /// spotify.com/account/apps, or the grant died some other way. Holding on
    /// to it meant Settings said Connected forever and every track change sent
    /// one more refresh that could never succeed. The tokens go — they will
    /// never work again — and Settings asks for a reconnect.
    private func letGoOfRevokedGrant() async {
        dropAccountState()
        needsReconnect = true
        await credentials.clear()
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
    /// Internal, not private: the media controller authenticates its catalogue
    /// lookup with this, and tests prove the cached-token path through it.
    ///
    /// `rejected` is an access token the Web API has just answered 401 to.
    /// The cached token is then skipped even though its stamp says it is
    /// still good — Spotify invalidated it early, or the stamp was written by
    /// a clock that was wrong — and a refresh is spent instead. Naming the
    /// token rather than passing a bare "force" flag lets two callers that
    /// were refused together share one refresh: the second finds a different
    /// token cached by the time it asks, and uses it. Spending the rotating
    /// refresh token twice would invalidate the account.
    func freshAccessToken(rejecting rejected: String? = nil) async -> String? {
        var joined: Task<String?, Never>?
        if let existing = refreshTask {
            let token = await existing.value
            guard let rejected, token == rejected else { return token }
            joined = existing
        }
        // Joined a lookup that only read back the token that was refused. If
        // someone else started a refresh while we waited, that is the one to
        // share; checked once, not looped, because the task just awaited may
        // still be registered until its owner resumes.
        if let current = refreshTask, current != joined { return await current.value }

        let generation = credentialGeneration
        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            let stored = await self.credentials.readTokens()
            if let expires = stored.expires,
               Date().timeIntervalSince1970 < expires,
               let token = stored.access,
               token != rejected {
                return token
            }
            guard let refresh = stored.refresh, let clientID = self.clientID else { return nil }
            let body = "grant_type=refresh_token"
                + "&refresh_token=\(Self.formEncoded(refresh))"
                + "&client_id=\(Self.formEncoded(clientID))"
            let result = await self.tokenRequest(body: body)
            // A disconnect that happened while this was in flight wins: storing
            // now would put the tokens the user just revoked back on disk, and
            // letting go of a grant would bump the generation a second time.
            guard self.credentialGeneration == generation else { return nil }
            switch result {
            case .tokens(let tokens):
                await self.store(tokens)
                return tokens.access_token
            case .invalidGrant:
                await self.letGoOfRevokedGrant()
                return nil
            case .failed:
                // Offline, or Spotify having a bad minute. The account stays:
                // clearing it on any failed refresh would sign out everybody
                // whose laptop woke up before its Wi-Fi did.
                return nil
            }
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

    /// Spotify retired the per-type saved-tracks endpoints for Development
    /// Mode apps on 2026-03-09 (its February 2026 migration guide) and
    /// replaced them with `/me/library` and `/me/library/contains`, which
    /// name what they touch by URI, comma-separated, at most 40 a call. The
    /// retired paths are why the heart never worked on the built-in client.
    ///
    /// The id arrives from AppleScript, so it is checked to be a catalogue id
    /// — 22 base62 characters — before it goes anywhere near a URL. A local
    /// file or anything stranger gets no request at all.
    static func libraryURL(_ path: String, trackID: String) -> URL? {
        guard trackID.count == 22,
              trackID.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        var components = URLComponents(string: "https://api.spotify.com/v1/me/\(path)")
        components?.queryItems = [URLQueryItem(name: "uris", value: "spotify:track:\(trackID)")]
        return components?.url
    }

    /// How one authorised Web-API call ended.
    private enum Reply {
        case answered(status: Int, body: Data)
        /// The request never got an HTTP answer: offline, or dropped.
        case unreachable
        /// No usable token, or a freshly refreshed one was refused as well.
        case noToken
        /// The account changed while the call was in flight — a disconnect,
        /// or a revoked grant let go. Whatever came back belongs to an
        /// account that is gone, and must not be written anywhere.
        case overtaken
    }

    /// One Web-API call with the account's token, and the one 401 retry.
    ///
    /// A 401 is Spotify saying the access token is no good: revoked early, or
    /// the wall-clock expiry stamp was written by a wrong clock. It used to be
    /// treated like a dropped connection and retried with the same dead token
    /// until the attempts ran out. Now it buys exactly one refresh, past the
    /// cached token, and the question is asked again; a second 401 means
    /// refreshing will not help, and the call stops there.
    ///
    /// The credential generation is checked after every await, because each is
    /// a point where a disconnect can land.
    private func send(_ request: (_ token: String) -> URLRequest) async -> Reply {
        let generation = credentialGeneration
        var rejected: String?
        for _ in 0..<2 {
            let token = await freshAccessToken(rejecting: rejected)
            guard credentialGeneration == generation else { return .overtaken }
            guard let token else { return .noToken }
            tokenUnavailable = false
            let reply = try? await session.data(for: request(token))
            guard credentialGeneration == generation else { return .overtaken }
            guard let (data, response) = reply else { return .unreachable }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 401 else { return .answered(status: status, body: data) }
            rejected = token
        }
        return .noToken
    }

    private static func bearer(_ url: URL, _ token: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Returns the lookup's task so a test can wait for the answer; the
    /// heart fires and forgets. Inside a refusal's cooldown it asks nothing.
    @discardableResult
    func refreshSavedState(trackID: String, attempt: Int = 0) -> Task<Void, Never>? {
        guard isConnected, saved[trackID] == nil, mayAsk(),
              let url = Self.libraryURL("library/contains", trackID: trackID) else { return nil }
        return Task {
            switch await send({ Self.bearer(url, $0) }) {
            case .overtaken:
                return
            case .noToken:
                // No usable token. Say so, so the heart can hide instead of
                // pretending: an unliked-looking heart that does nothing when
                // pressed is worse than no heart at all.
                tokenUnavailable = true
            case .unreachable:
                // Offline or refused mid-flight. Retried, because the entry
                // stays nil and nothing else would ever ask again — the heart
                // would show hollow for a liked song for the rest of the track.
                retrySavedState(trackID: trackID, attempt: attempt)
            case .answered(let status, let data):
                if status == 403 { return refuse(data) }
                guard status == 200,
                      let flags = try? JSONDecoder().decode([Bool].self, from: data),
                      let flag = flags.first else {
                    return retrySavedState(trackID: trackID, attempt: attempt)
                }
                apiBlocked = false
                // A tap that landed while this was on the wire has already put
                // the heart where the user wants it, and its write is on the
                // way; the answer to a question asked before it is stale.
                if saved[trackID] == nil { saved[trackID] = flag }
            }
        }
    }

    private func retrySavedState(trackID: String, attempt: Int) {
        guard attempt < 3 else { return }
        // Two, four, then eight seconds. A shift rather than `pow`: Xcode 26.6's
        // compiler (the CI runner's) fails with "failed to produce diagnostic"
        // on `pow(2.0, Double(attempt + 1))` here, which Xcode 27 accepts.
        let delay = TimeInterval(1 << (attempt + 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshSavedState(trackID: trackID, attempt: attempt + 1)
            }
        }
    }

    /// Returns the track's writer, so a test can wait until Spotify agrees
    /// with the last tap; the heart fires and forgets. A tap while a write is
    /// already running joins it rather than starting a second.
    @discardableResult
    func toggleSaved(trackID: String) -> Task<Void, Never>? {
        guard isConnected, let url = Self.libraryURL("library", trackID: trackID) else { return nil }
        let before = saved[trackID] ?? false
        let wants = !before
        // Optimistic: the heart answers the tap now; a failed request puts
        // it back rather than leaving the tap looking ignored.
        saved[trackID] = wants
        desiredSaved[trackID] = wants
        if let running = savedWriters[trackID] { return running }
        let generation = credentialGeneration
        let writer = Task {
            await writeSaved(trackID: trackID, url: url, confirmed: before, generation: generation)
        }
        savedWriters[trackID] = writer
        return writer
    }

    /// Sends PUT or DELETE, one at a time, until Spotify's last answer is
    /// where the latest tap pointed — so a third tap that lands while the
    /// first PUT is in flight costs nothing, and a second sends exactly one
    /// DELETE after it. `confirmed` is the last state Spotify is known to
    /// hold, which is what the heart falls back to when a write fails.
    private func writeSaved(trackID: String, url: URL, confirmed: Bool, generation: Int) async {
        var confirmed = confirmed
        // The loop condition is re-read after every await, and nothing awaits
        // between the last check and the cleanup below, so a tap can never
        // slip in after the writer has decided to stop and be left unsent.
        while let wants = desiredSaved[trackID], wants != confirmed {
            let reply = await send { Self.bearer(url, $0, method: wants ? "PUT" : "DELETE") }
            // A disconnect has cleared `saved` and these maps already, and a
            // new account may have a writer of its own for this track by now.
            guard credentialGeneration == generation else { return }
            switch reply {
            case .answered(let status, _) where (200..<300).contains(status):
                confirmed = wants
                apiBlocked = false
                continue
            case .answered(403, let data):
                refuse(data)
            case .noToken:
                tokenUnavailable = true
            default:
                break
            }
            // Failed: the heart goes back to what Spotify last agreed to, and
            // any taps queued behind the failure are dropped with it rather
            // than retried into the same wall.
            saved[trackID] = confirmed
            break
        }
        desiredSaved[trackID] = nil
        savedWriters[trackID] = nil
    }

    // MARK: - Track identity

    /// The catalogue's exact identity for one track: ISRC plus precise duration.
    ///
    /// Decoded straight from `GET /v1/tracks/{id}`, which needs no scope
    /// beyond the library ones the account already holds. `isrc` is nil when
    /// the entry carries no `external_ids` — unknown, not absent — so callers
    /// fall back to text matching rather than treating nil as "no ISRC".
    struct TrackMetadata: Decodable, Equatable {
        let isrc: String?
        /// Milliseconds, exactly as the catalogue reports them.
        let durationMs: Int

        private enum CodingKeys: String, CodingKey {
            case durationMs = "duration_ms"
            case externalIDs = "external_ids"
        }

        private struct ExternalIDs: Decodable {
            let isrc: String?
        }

        init(isrc: String?, durationMs: Int) {
            self.isrc = isrc
            self.durationMs = durationMs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            durationMs = try container.decode(Int.self, forKey: .durationMs)
            isrc = try container.decodeIfPresent(ExternalIDs.self, forKey: .externalIDs)?.isrc
        }
    }

    /// The catalogue's exact identity for a track, for lyric matching to join on.
    ///
    /// Gated like every other Web-API call: disconnected or blocked answers
    /// nil without touching the network, and a missing token hides the
    /// dependent features rather than raising anything. Never throws —
    /// network failure, a refused status, or an unrecognised payload all mean
    /// "unknown", and the caller falls back to title/artist matching.
    func trackMetadata(id: String) async -> TrackMetadata? {
        guard isConnected, mayAsk(),
              let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)") else { return nil }
        let data: Data, status: Int
        switch await send({ Self.bearer(url, $0) }) {
        case .overtaken, .unreachable:
            return nil
        case .noToken:
            // Same contract as the saved-state lookup: without a usable
            // token the features that need the id hide rather than sit dead.
            tokenUnavailable = true
            return nil
        case .answered(let answeredStatus, let body):
            status = answeredStatus
            data = body
        }
        if status == 403 {
            refuse(data)
            return nil
        }
        guard status == 200,
              let metadata = try? JSONDecoder().decode(TrackMetadata.self, from: data) else { return nil }
        apiBlocked = false
        return metadata
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

    init(service: String, paths: AppPaths = .live) {
        self.tokens = TokenStore(service: service, paths: paths)
    }

    /// Where this build can actually keep credentials — see `TokenStore`.
    func backing() -> TokenStore.Backing { tokens.backing }

    /// True when an older build left an account in the login keychain. Asks
    /// for attributes only, so it cannot raise the password prompt.
    func legacyAccountExists() -> Bool { tokens.legacyAccountExists("refreshToken") }

    /// Brings that account across. This one *can* prompt, which is why it only
    /// ever runs because somebody pressed a button asking it to.
    func importLegacy() -> Bool {
        var moved: [String] = []
        for account in ["accessToken", "refreshToken", "expiresAt"] {
            guard let value = tokens.readLegacy(account),
                  tokens.write(account, value) != .unavailable else { continue }
            moved.append(account)
        }
        if !moved.isEmpty { cache = nil; refused = false }
        return Self.importSucceeded(moved: moved)
    }

    /// An import is an account only if the refresh token came across: the
    /// access token expires within the hour and the stamp means nothing alone.
    /// Any one of the three moving used to count, after which the Import row
    /// was hidden over an account that could not sign in.
    nonisolated static func importSucceeded(moved: [String]) -> Bool {
        moved.contains("refreshToken")
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

    /// Returns where the refresh token landed — the write that decides whether
    /// the account survives a relaunch — or, when Spotify sent none because it
    /// is unchanged, where the access token landed. It used to return nothing,
    /// and a write that failed everywhere was invisible.
    @discardableResult
    func storeTokens(access: String, refresh: String?, expiresAt: String) -> TokenStore.Backing {
        let accessBacking = tokens.write("accessToken", access)
        // Spotify omits the refresh token when it is unchanged; writing nil
        // over the stored one would sign the user out at the next launch.
        let refreshBacking = refresh.map { tokens.write("refreshToken", $0) }
        tokens.write("expiresAt", expiresAt)
        // Write-through, so the next read is answered from memory rather than
        // by asking the keychain — and the user — all over again.
        refused = false
        cache = (Double(expiresAt), access, refresh ?? cache?.refresh)
        return refreshBacking ?? accessBacking
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
