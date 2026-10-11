import XCTest
@testable import IslaKit

/// Exact track identity over the existing Spotify auth: ISRC plus the
/// catalogue's precise duration, so lyric tiers can join on identity instead
/// of guessing from title text. Every network answer below arrives through a
/// real URLSession — the stub only stands in for the wire — and every
/// credential lives under a throwaway service in a temporary directory, never
/// near the real account.
@MainActor
final class SpotifyAccountTests: XCTestCase {
    private var tempDir: URL!
    private var stores: [CredentialStore] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        stores = []
    }

    override func tearDown() async throws {
        // Best-effort scrub: on a signed build the seeds below reach the
        // data-protection keychain, and must not outlive the test.
        for store in stores { await store.clear() }
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeStore() -> CredentialStore {
        let store = CredentialStore(
            service: "com.ctimothe.isla.tests.\(UUID().uuidString)",
            paths: AppPaths(
                supportDirectory: tempDir.appendingPathComponent("support"),
                screenshotDirectory: tempDir.appendingPathComponent("pictures")
            )
        )
        stores.append(store)
        return store
    }

    private func stubSession(
        _ handler: @escaping (URLRequest) -> (Int, Data)?,
        delay: (@Sendable (URLRequest) -> TimeInterval)? = nil
    ) -> URLSession {
        StubURLProtocol.serve(handler, delay: delay)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The launch read that decides `isConnected` runs inside init, so a test
    /// needing a connected account seeds first and waits for it to land.
    private func waitForConnected(_ account: SpotifyAccount) async {
        for _ in 0..<100 {
            if account.isConnected { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// `GET /v1/tracks/{id}` carries both halves of the identity.
    func testTrackMetadataDecodesDurationAndISRC() throws {
        let json = """
        {"id":"4uLU6hMCjMI75M1A2tKUQ","duration_ms":213456,"external_ids":{"isrc":"USRC12345678"}}
        """.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(SpotifyAccount.TrackMetadata.self, from: json)
        XCTAssertEqual(metadata.durationMs, 213456)
        XCTAssertEqual(metadata.isrc, "USRC12345678")
    }

    /// Not every catalogue entry carries `external_ids` — that is unknown, not
    /// absent, and must decode rather than throw.
    func testTrackMetadataDecodesMissingExternalIDsAsNilISRC() throws {
        let json = """
        {"id":"4uLU6hMCjMI75M1A2tKUQ","duration_ms":180000}
        """.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(SpotifyAccount.TrackMetadata.self, from: json)
        XCTAssertEqual(metadata.durationMs, 180000)
        XCTAssertNil(metadata.isrc)
    }

    /// An explicit null is still unknown, not a failure: the caller's fallback
    /// is text matching, which a throw would skip.
    func testTrackMetadataDecodesExplicitNullExternalIDsAsNilISRC() throws {
        let json = """
        {"id":"4uLU6hMCjMI75M1A2tKUQ","duration_ms":180000,"external_ids":{"isrc":null}}
        """.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(SpotifyAccount.TrackMetadata.self, from: json)
        XCTAssertEqual(metadata.durationMs, 180000)
        XCTAssertNil(metadata.isrc)
    }

    /// Disconnected answers nil before any token or network is touched.
    func testTrackMetadataReturnsNilWhenDisconnected() async {
        let account = SpotifyAccount(credentials: makeStore())
        XCTAssertFalse(account.isConnected)
        let metadata = await account.trackMetadata(id: "4uLU6hMCjMI75M1A2tKUQ")
        XCTAssertNil(metadata)
        XCTAssertFalse(account.apiBlocked, "answering while disconnected must not flag the API")
    }

    /// A 403 is Spotify's account gate (Premium-only Web API as of 2026): nil,
    /// and the block flag set so dependent hearts hide rather than lie.
    func testTrackMetadataReturnsNilAndFlagsBlockedOn403() async {
        let store = makeStore()
        await store.storeTokens(
            access: "test-access",
            refresh: "test-refresh",
            expiresAt: String(Date().timeIntervalSince1970 + 3600)
        )
        let session = stubSession { _ in (403, Data()) }
        let account = SpotifyAccount(credentials: store, session: session)
        await waitForConnected(account)
        XCTAssertTrue(account.isConnected)

        let metadata = await account.trackMetadata(id: "4uLU6hMCjMI75M1A2tKUQ")

        XCTAssertNil(metadata)
        XCTAssertTrue(account.apiBlocked, "a 403 for account reasons must flag the API blocked")
    }

    /// A connected account whose tokens are spent answers nil and says so via
    /// `tokenUnavailable` — without mistaking a dead token for a blocked API.
    func testTrackMetadataReturnsNilWhenTokenUnavailable() async {
        let store = makeStore()
        await store.storeTokens(access: "spent", refresh: "test-refresh", expiresAt: "1")
        let session = stubSession { request in
            guard request.url?.host == "accounts.spotify.com" else { return nil }
            return (400, Data())
        }
        let account = SpotifyAccount(credentials: store, session: session)
        await waitForConnected(account)
        XCTAssertTrue(account.isConnected)

        let metadata = await account.trackMetadata(id: "4uLU6hMCjMI75M1A2tKUQ")

        XCTAssertNil(metadata)
        XCTAssertTrue(account.tokenUnavailable, "a spent token must surface, not silently hide")
        XCTAssertFalse(account.apiBlocked, "a dead token is not a blocked account")
    }

    /// The whole path at once: cached access token, Bearer on the wire, exact
    /// identity back, block flag untouched.
    func testTrackMetadataReturnsISRCAndDurationOnSuccess() async {
        let store = makeStore()
        await store.storeTokens(
            access: "test-access",
            refresh: "test-refresh",
            expiresAt: String(Date().timeIntervalSince1970 + 3600)
        )
        let payload = """
        {"id":"4uLU6hMCjMI75M1A2tKUQ","duration_ms":200100,"external_ids":{"isrc":"GBAYE6800011"}}
        """.data(using: .utf8)!
        // The 200 is served only when the cached token rides as a Bearer —
        // anything else reads as 401, so a non-nil result proves the header.
        let session = stubSession { request in
            guard request.url?.host == "api.spotify.com",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access" else {
                return (401, Data())
            }
            return (200, payload)
        }
        let account = SpotifyAccount(credentials: store, session: session)
        await waitForConnected(account)

        let metadata = await account.trackMetadata(id: "4uLU6hMCjMI75M1A2tKUQ")

        XCTAssertEqual(metadata?.isrc, "GBAYE6800011")
        XCTAssertEqual(metadata?.durationMs, 200100)
        XCTAssertFalse(account.apiBlocked)
    }

    /// The token the metadata call authenticates with, exposed for the
    /// controller's Bearer — a cached one costs no network.
    func testFreshAccessTokenReturnsCachedTokenWithoutNetwork() async {
        let store = makeStore()
        await store.storeTokens(
            access: "test-access",
            refresh: "test-refresh",
            expiresAt: String(Date().timeIntervalSince1970 + 3600)
        )
        let account = SpotifyAccount(credentials: store)
        let token = await account.freshAccessToken()
        XCTAssertEqual(token, "test-access")
    }

    // MARK: - Liked Songs on the library endpoints, and a refusal that recovers

    /// A real-shaped catalogue id: 22 base62 characters, the only shape the
    /// account will build a library URL around.
    private let likedID = "4uLU6hMCjMI75M1A2tKUQb"

    /// A connected account over a seeded, unexpired token, so every request
    /// below goes straight to the stub with no refresh in front of it.
    private func connectedAccount(
        session: URLSession,
        now: @escaping () -> Date = Date.init,
        openURL: @escaping (URL) -> Bool = { _ in true }
    ) async -> SpotifyAccount {
        let store = makeStore()
        await store.storeTokens(
            access: "test-access",
            refresh: "test-refresh",
            expiresAt: String(Date().timeIntervalSince1970 + 3600)
        )
        let account = SpotifyAccount(credentials: store, session: session, now: now, openURL: openURL)
        await waitForConnected(account)
        return account
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The `uris` value a request carried, decoded.
    nonisolated private static func uris(_ request: URLRequest) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == "uris" })?.value
    }

    /// Spotify moved Development Mode apps off `/me/tracks/contains` on
    /// 2026-03-09: the library is asked with a track URI now. The stub answers
    /// only that question, so a saved flag proves both the path and the URI —
    /// and that the lookup went through the injected session at all, which it
    /// did not while it was hard-wired to `URLSession.shared`.
    func testSavedStateAsksTheLibraryWithATrackURI() async {
        let id = likedID
        let session = stubSession { request in
            guard request.httpMethod == "GET",
                  request.url?.host == "api.spotify.com",
                  request.url?.path == "/v1/me/library/contains",
                  Self.uris(request) == "spotify:track:\(id)" else { return (404, Data()) }
            return (200, Data("[true]".utf8))
        }
        let account = await connectedAccount(session: session)

        await account.refreshSavedState(trackID: id)?.value

        XCTAssertEqual(account.saved[id], true)
        XCTAssertFalse(account.apiBlocked)
    }

    /// The heart saves with PUT and removes with DELETE on `/me/library`, each
    /// naming the track by URI, and a 200 keeps the optimistic answer.
    func testToggleSavedPutsThenDeletesTheTrackURI() async {
        let id = likedID
        let wire = Wire { request in
            request.url?.path == "/v1/me/library" ? (200, Data()) : (404, Data())
        }
        let session = stubSession(wire.answer)
        let account = await connectedAccount(session: session)

        await account.toggleSaved(trackID: id)?.value
        XCTAssertEqual(account.saved[id], true, "a 200 must keep the heart filled")
        await account.toggleSaved(trackID: id)?.value
        XCTAssertEqual(account.saved[id], false, "a 200 must keep the heart hollow")

        XCTAssertEqual(wire.seen, [
            "PUT /v1/me/library spotify:track:\(id)",
            "DELETE /v1/me/library spotify:track:\(id)",
        ])
    }

    /// One 403 used to block the Web API for the life of the process: the
    /// only resets were in success branches that the block itself closed.
    /// Ten minutes on, the next lookup asks again, and a 200 lifts it.
    func testARefusedAccountRecoversAfterTheCooldown() async {
        let id = likedID
        let wire = Wire(queue: [
            (403, Data(#"{"error":{"status":403,"message":"Premium required"}}"#.utf8)),
            (200, Data("[true]".utf8)),
        ])
        let session = stubSession(wire.answer)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let account = await connectedAccount(session: session, now: { clock })

        await account.refreshSavedState(trackID: id)?.value
        XCTAssertTrue(account.apiBlocked)
        XCTAssertEqual(account.refusal, .premiumRequired)

        clock += 601
        await account.refreshSavedState(trackID: id)?.value

        XCTAssertFalse(account.apiBlocked, "a refused account must be asked again after the cooldown")
        XCTAssertNil(account.refusal)
        XCTAssertEqual(account.saved[id], true)
    }

    /// The cooldown is a cooldown: a refused account is not asked again on
    /// every track change inside it.
    func testNothingIsAskedInsideTheCooldown() async {
        let id = likedID
        let wire = Wire { _ in (403, Data()) }
        let session = stubSession(wire.answer)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let account = await connectedAccount(session: session, now: { clock })

        await account.refreshSavedState(trackID: id)?.value
        XCTAssertTrue(account.apiBlocked)

        clock += 599
        await account.refreshSavedState(trackID: id)?.value
        _ = await account.trackMetadata(id: id)

        XCTAssertEqual(wire.seen.count, 1, "nothing may be asked inside the cooldown")
        XCTAssertTrue(account.apiBlocked)
    }

    /// Disconnecting ends the account the refusal was about. Settings used to
    /// keep showing the first account's refusal under the next one.
    func testDisconnectClearsTheRefusal() async {
        let session = stubSession { _ in (403, Data()) }
        let account = await connectedAccount(session: session)
        await account.refreshSavedState(trackID: likedID)?.value
        XCTAssertTrue(account.apiBlocked)

        account.disconnect()

        XCTAssertFalse(account.apiBlocked)
        XCTAssertNil(account.refusal)
        XCTAssertFalse(account.tokenUnavailable)
    }

    /// A new grant is a new answer from Spotify about this account, so the
    /// old refusal goes with it.
    func testANewGrantClearsTheRefusal() async throws {
        let tokens = Data(#"{"access_token":"granted","refresh_token":"granted-refresh","expires_in":3600}"#.utf8)
        let session = stubSession { request in
            request.url?.host == "accounts.spotify.com" ? (200, tokens) : (403, Data())
        }
        var opened: URL?
        let account = await connectedAccount(session: session, openURL: { opened = $0; return true })
        await account.refreshSavedState(trackID: likedID)?.value
        XCTAssertTrue(account.apiBlocked)

        account.beginAuthorization()
        let authorize = try XCTUnwrap(opened, "Connect must open the consent page through the seam")
        let state = try XCTUnwrap(
            URLComponents(url: authorize, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
        var callback = URLComponents(string: "isla://spotify-callback")!
        callback.queryItems = [.init(name: "code", value: "granted-code"), .init(name: "state", value: state)]
        account.handleCallback(callback.url!)
        await waitUntil { !account.apiBlocked }

        XCTAssertFalse(account.apiBlocked, "a completed grant must lift the old refusal")
        XCTAssertNil(account.refusal)
        XCTAssertFalse(account.tokenUnavailable)
        XCTAssertTrue(account.isConnected)
    }

    // MARK: - A dead grant, a 401, and writes that cannot cross

    private let renewedTokens = Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8)

    /// A 401 is Spotify saying the access token is no good — revoked early,
    /// or the wall-clock expiry stamp was wrong. It used to go down the same
    /// retry path as a dropped connection, with the same dead token, three
    /// times. Now it buys exactly one refresh and the question is asked again
    /// with the new token.
    func testA401RefreshesOnceAndAsksAgain() async {
        let id = likedID
        let renewed = renewedTokens
        let wire = Wire { request in
            if request.url?.host == "accounts.spotify.com" { return (200, renewed) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed"
                ? (200, Data("[true]".utf8))
                : (401, Data())
        }
        let account = await connectedAccount(session: stubSession(wire.answer))

        await account.refreshSavedState(trackID: id)?.value

        XCTAssertEqual(account.saved[id], true, "the retried lookup must land under the new token")
        XCTAssertEqual(wire.seen.filter { $0.hasPrefix("POST /api/token") }.count, 1,
                       "a 401 is worth exactly one refresh")
        XCTAssertFalse(account.tokenUnavailable)
    }

    /// A fresh token that is refused too means refreshing will not help: stop
    /// after one refresh and hide the heart, rather than loop.
    func testASecond401StopsAndSaysTheTokenIsUnavailable() async {
        let id = likedID
        let renewed = renewedTokens
        let wire = Wire { request in
            request.url?.host == "accounts.spotify.com" ? (200, renewed) : (401, Data())
        }
        let account = await connectedAccount(session: stubSession(wire.answer))

        await account.refreshSavedState(trackID: id)?.value

        XCTAssertNil(account.saved[id])
        XCTAssertTrue(account.tokenUnavailable)
        XCTAssertTrue(account.isConnected, "a 401 alone is not a revoked grant")
        XCTAssertEqual(wire.seen.filter { $0.hasPrefix("POST /api/token") }.count, 1)
        XCTAssertEqual(wire.seen.filter { $0.hasPrefix("GET /v1/me/library/contains") }.count, 2)
    }

    /// Two taps in quick succession used to be two unordered tasks: the DELETE
    /// could reach Spotify before the slower PUT, leaving the song liked under
    /// a hollow heart. Writes for one track now go one at a time, and the last
    /// tap decides where they stop.
    func testAQuickDoubleTapEndsWhereTheLastTapPointed() async {
        let id = likedID
        let wire = Wire { request in
            request.url?.path == "/v1/me/library" ? (200, Data()) : (404, Data())
        }
        let session = stubSession(wire.answer, delay: { request in
            wire.note("sent \(request.httpMethod ?? "?")")
            return request.httpMethod == "PUT" ? 0.2 : 0
        })
        let account = await connectedAccount(session: session)

        let first = account.toggleSaved(trackID: id)
        XCTAssertEqual(account.saved[id], true)
        // A finger is slower than the main actor: by the second tap the PUT
        // is already on the wire.
        await waitUntil { wire.seen.contains("sent PUT") }
        let second = account.toggleSaved(trackID: id)
        XCTAssertEqual(account.saved[id], false, "the heart follows the latest tap at once")
        await first?.value
        await second?.value

        XCTAssertEqual(wire.seen, [
            "sent PUT",
            "PUT /v1/me/library spotify:track:\(id)",
            "sent DELETE",
            "DELETE /v1/me/library spotify:track:\(id)",
        ], "the DELETE must leave only after the PUT has been answered")
        XCTAssertEqual(account.saved[id], false)
    }

    /// Removing Isla at spotify.com/account/apps used to leave Settings saying
    /// Connected while every track change sent another refresh that could
    /// never succeed. Spotify's `invalid_grant` is the one answer that means
    /// the grant itself is gone: the account lets go of it and asks for a
    /// reconnect.
    func testARevokedGrantDisconnectsAndAsksToReconnect() async {
        let store = makeStore()
        await store.storeTokens(access: "spent", refresh: "revoked-refresh", expiresAt: "1")
        let wire = Wire { request in
            request.url?.host == "accounts.spotify.com"
                ? (400, Data(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8))
                : (500, Data())
        }
        let account = SpotifyAccount(credentials: store, session: stubSession(wire.answer))
        await waitForConnected(account)
        XCTAssertTrue(account.isConnected)

        let token = await account.freshAccessToken()

        XCTAssertNil(token)
        XCTAssertFalse(account.isConnected, "a revoked grant must not keep claiming Connected")
        XCTAssertTrue(account.needsReconnect)
        let left = await store.readTokens()
        XCTAssertNil(left.refresh, "the dead refresh token must not be offered again")
        XCTAssertNil(left.access)

        _ = await account.freshAccessToken()
        account.refreshSavedState(trackID: likedID)
        XCTAssertEqual(wire.seen.count, 1, "a revoked account sends no further token requests")
    }

    /// Offline, or Spotify having a bad minute, is not a revoked grant. Only
    /// `invalid_grant` lets go of the account; anything else keeps it, or a
    /// laptop that woke without Wi-Fi would sign its user out.
    func testAFailedRefreshKeepsTheAccount() async {
        let store = makeStore()
        await store.storeTokens(access: "spent", refresh: "test-refresh", expiresAt: "1")
        let session = stubSession { request in
            request.url?.host == "accounts.spotify.com"
                ? (400, Data(#"{"error":"invalid_request"}"#.utf8))
                : (500, Data())
        }
        let account = SpotifyAccount(credentials: store, session: session)
        await waitForConnected(account)

        let token = await account.freshAccessToken()

        XCTAssertNil(token)
        XCTAssertTrue(account.isConnected)
        XCTAssertFalse(account.needsReconnect)
        let left = await store.readTokens()
        XCTAssertEqual(left.refresh, "test-refresh")
    }

    /// Connect with a consent page captured instead of opened, returning the
    /// `state` the callback must carry.
    private func beginSignIn(_ account: SpotifyAccount, opened: () -> URL?) throws -> String {
        account.beginAuthorization()
        let authorize = try XCTUnwrap(opened(), "Connect must open the consent page through the seam")
        return try XCTUnwrap(
            URLComponents(url: authorize, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
    }

    /// Pressing Cancel on Spotify's consent page comes back as
    /// `error=access_denied` with no code, and used to be dropped without a
    /// word: Settings went on offering Connect as if nothing had happened.
    func testACancelledSignInIsReported() async throws {
        var opened: URL?
        let account = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (500, Data()) }, openURL: { opened = $0; return true }
        )
        let state = try beginSignIn(account) { opened }

        var callback = URLComponents(string: "isla://spotify-callback")!
        callback.queryItems = [.init(name: "error", value: "access_denied"), .init(name: "state", value: state)]
        account.handleCallback(callback.url!)

        XCTAssertEqual(account.signInOutcome, .cancelled)
        XCTAssertFalse(account.isConnected)
    }

    /// The browser can come back after Isla has been relaunched, when the
    /// verifier that began the flow is gone. That cannot complete, and it is
    /// said rather than swallowed.
    func testACallbackWithNoSignInPendingIsReportedAsExpired() async {
        let account = SpotifyAccount(credentials: makeStore(), session: stubSession { _ in (500, Data()) })

        account.handleCallback(URL(string: "isla://spotify-callback?code=late&state=gone")!)

        XCTAssertEqual(account.signInOutcome, .expired)
    }

    /// The code came back but Spotify would not exchange it.
    func testAFailedExchangeIsReported() async throws {
        var opened: URL?
        let account = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (500, Data()) }, openURL: { opened = $0; return true }
        )
        let state = try beginSignIn(account) { opened }

        var callback = URLComponents(string: "isla://spotify-callback")!
        callback.queryItems = [.init(name: "code", value: "granted-code"), .init(name: "state", value: state)]
        account.handleCallback(callback.url!)
        await waitUntil { account.signInOutcome != nil }

        XCTAssertEqual(account.signInOutcome, .failed)
        XCTAssertFalse(account.isConnected)
    }

    // MARK: - Sign-in edge cases (K-015)

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }

    /// Connect pressed twice used to rotate the verifier and state on the
    /// second press, so approving the first browser tab failed the state
    /// check and returned without a word. Both tabs now carry one state.
    func testASecondConnectKeepsTheFirstTabValid() async throws {
        let tokens = Data(#"{"access_token":"granted","refresh_token":"granted-refresh","expires_in":3600}"#.utf8)
        var opened: [URL] = []
        let account = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (200, tokens) },
            openURL: { opened.append($0); return true }
        )
        account.beginAuthorization()
        account.beginAuthorization()
        XCTAssertEqual(opened.count, 2)
        let first = try XCTUnwrap(queryValue(opened[0], "state"))
        XCTAssertEqual(queryValue(opened[1], "state"), first)
        XCTAssertEqual(queryValue(opened[1], "code_challenge"), queryValue(opened[0], "code_challenge"))

        // Let init's launch read of the empty keychain land first; it writes
        // isConnected = false, and a grant finishing before it would be undone
        // by it. A person cannot approve in a browser inside that window.
        try await Task.sleep(for: .milliseconds(150))
        var callback = URLComponents(string: "isla://spotify-callback")!
        callback.queryItems = [.init(name: "code", value: "granted-code"), .init(name: "state", value: first)]
        account.handleCallback(callback.url!)
        await waitUntil { account.isConnected }

        XCTAssertTrue(account.isConnected)
        XCTAssertNil(account.signInProblem)
    }

    /// A completed callback consumes the pair, so the next Connect after a
    /// disconnect gets a new one rather than a state already spent.
    func testAFinishedSignInGetsANewStateNextTime() async throws {
        var opened: [URL] = []
        let account = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (500, Data()) },
            openURL: { opened.append($0); return true }
        )
        account.beginAuthorization()
        let first = try XCTUnwrap(queryValue(opened[0], "state"))
        var callback = URLComponents(string: "isla://spotify-callback")!
        callback.queryItems = [.init(name: "error", value: "access_denied"), .init(name: "state", value: first)]
        account.handleCallback(callback.url!)
        account.beginAuthorization()

        XCTAssertNotEqual(queryValue(opened[1], "state"), first)
    }

    /// A pending pair older than ten minutes is not kept: the person walked
    /// away from that tab, and a state that old is only attack surface.
    func testAnExpiredPendingSignInIsReplaced() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var opened: [URL] = []
        let account = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (500, Data()) }, now: { clock },
            openURL: { opened.append($0); return true }
        )
        account.beginAuthorization()
        clock = clock.addingTimeInterval(SpotifyAccount.pendingSignInLifetime + 1)
        account.beginAuthorization()

        XCTAssertNotEqual(queryValue(opened[0], "state"), queryValue(opened[1], "state"))
    }

    /// Without `show_dialog`, Spotify silently reuses whichever account the
    /// browser is signed in to, so a reconnect after Disconnect could never
    /// switch account.
    func testTheConsentPageAlwaysOffersAnotherAccount() async throws {
        var opened: URL?
        let account = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (500, Data()) }, openURL: { opened = $0; return true }
        )
        account.beginAuthorization()

        XCTAssertEqual(queryValue(try XCTUnwrap(opened), "show_dialog"), "true")
    }

    /// `NSWorkspace.open`'s answer used to be thrown away, so a Mac with no
    /// default browser made Connect do nothing and say nothing.
    func testABrowserThatDoesNotOpenIsSaid() async {
        let account = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (500, Data()) }, openURL: { _ in false }
        )
        account.beginAuthorization()

        XCTAssertEqual(account.signInProblem, .browserDidNotOpen)
        // The next press starts over, and a browser that does open clears it.
        let working = SpotifyAccount(
            credentials: makeStore(), session: stubSession { _ in (500, Data()) }, openURL: { _ in true }
        )
        working.beginAuthorization()
        XCTAssertNil(working.signInProblem)
    }

    /// Any one of three items moving used to count as an import, after which
    /// the Import row was hidden over an account with no refresh token.
    func testAPartialImportIsNotASuccess() {
        XCTAssertFalse(CredentialStore.importSucceeded(moved: ["accessToken", "expiresAt"]))
        XCTAssertFalse(CredentialStore.importSucceeded(moved: []))
        XCTAssertTrue(CredentialStore.importSucceeded(moved: ["refreshToken"]))
        XCTAssertTrue(CredentialStore.importSucceeded(moved: ["accessToken", "refreshToken", "expiresAt"]))
    }

    /// `TokenStore.write` returns where it landed, and `.unavailable` was
    /// dropped: the account claimed to be connected over tokens that vanish
    /// at the next launch.
    func testUnsavedTokensDoNotClaimAConnection() {
        XCTAssertFalse(SpotifyAccount.connectedAfterStore(refreshBacking: .unavailable))
        XCTAssertTrue(SpotifyAccount.connectedAfterStore(refreshBacking: .keychain))
        XCTAssertTrue(SpotifyAccount.connectedAfterStore(refreshBacking: .file))
    }

    /// A completed grant clears what the last attempt, or a revoked grant,
    /// left on screen.
    func testASuccessfulSignInClearsTheReconnectNote() async throws {
        let tokens = Data(#"{"access_token":"granted","refresh_token":"granted-refresh","expires_in":3600}"#.utf8)
        let store = makeStore()
        await store.storeTokens(access: "spent", refresh: "revoked-refresh", expiresAt: "1")
        // The refresh is refused as revoked, then the new grant's exchange is
        // answered — in that order, the only two requests this test makes.
        let wire = Wire(queue: [
            (400, Data(#"{"error":"invalid_grant"}"#.utf8)),
            (200, tokens),
        ])
        let session = stubSession(wire.answer)
        var opened: URL?
        let account = SpotifyAccount(credentials: store, session: session, openURL: { opened = $0; return true })
        await waitForConnected(account)
        _ = await account.freshAccessToken()
        XCTAssertTrue(account.needsReconnect)

        let state = try beginSignIn(account) { opened }
        var callback = URLComponents(string: "isla://spotify-callback")!
        callback.queryItems = [.init(name: "code", value: "granted-code"), .init(name: "state", value: state)]
        account.handleCallback(callback.url!)
        await waitUntil { account.isConnected }

        XCTAssertTrue(account.isConnected)
        XCTAssertFalse(account.needsReconnect)
        XCTAssertNil(account.signInOutcome)
    }

    /// Last tap wins, all the way: two taps that land before anything has
    /// left cancel out and send nothing, and three taps while a PUT is in
    /// flight end on that PUT without a further request.
    func testTapsThatCancelOutSendNothingMore() async {
        let id = likedID
        let wire = Wire { request in
            request.url?.path == "/v1/me/library" ? (200, Data()) : (404, Data())
        }
        let session = stubSession(wire.answer, delay: { request in
            request.httpMethod == "PUT" ? 0.2 : 0
        })
        let account = await connectedAccount(session: session)

        account.toggleSaved(trackID: id)
        await account.toggleSaved(trackID: id)?.value
        XCTAssertEqual(wire.seen, [], "a tap undone in the same beat is nothing to tell Spotify")
        XCTAssertEqual(account.saved[id], false)

        account.toggleSaved(trackID: id)
        await waitUntil { account.saved[id] == true }
        try? await Task.sleep(for: .milliseconds(50))
        account.toggleSaved(trackID: id)
        await account.toggleSaved(trackID: id)?.value

        XCTAssertEqual(wire.seen, ["PUT /v1/me/library spotify:track:\(id)"])
        XCTAssertEqual(account.saved[id], true)
    }

    /// A write Spotify refuses puts the heart back where Spotify last agreed,
    /// not merely one step back from the latest tap.
    func testAFailedWriteFallsBackToWhatSpotifyLastAgreed() async {
        let id = likedID
        let session = stubSession({ _ in (500, Data()) }, delay: { _ in 0.1 })
        let account = await connectedAccount(session: session)

        account.toggleSaved(trackID: id)
        try? await Task.sleep(for: .milliseconds(30))
        account.toggleSaved(trackID: id)
        await account.toggleSaved(trackID: id)?.value

        XCTAssertEqual(account.saved[id], false,
                       "the last tap pointed at saved, but nothing was ever saved, so the heart ends hollow")
    }

    /// A disconnect clears `saved`, and a lookup that was already on the wire
    /// used to write the old account's answer straight back into it.
    func testADisconnectDuringALookupLeavesNothingBehind() async {
        let session = stubSession({ _ in (200, Data("[true]".utf8)) }, delay: { _ in 0.2 })
        let account = await connectedAccount(session: session)

        let lookup = account.refreshSavedState(trackID: likedID)
        try? await Task.sleep(for: .milliseconds(50))
        account.disconnect()
        await lookup?.value

        XCTAssertTrue(account.saved.isEmpty, "a disconnected account must not keep the old answer")
        XCTAssertFalse(account.isConnected)
    }
}

/// Records every request the stub is asked and answers it, from the
/// session's background queue. Tests capture this one reference instead of a
/// local `var`: a closure formed on the main actor that captures mutable
/// state is isolated to it, and calling it off the main thread traps.
private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var queue: [(Int, Data)]
    private let respond: @Sendable (URLRequest) -> (Int, Data)?

    /// Answers `queue` in order, then 500 for anything after it.
    init(queue: [(Int, Data)]) {
        self.queue = queue
        self.respond = { _ in (500, Data()) }
    }

    init(_ respond: @escaping @Sendable (URLRequest) -> (Int, Data)?) {
        self.queue = []
        self.respond = respond
    }

    var seen: [String] { lock.withLock { lines } }

    /// Puts a line of the test's own into the same log, so an event that is
    /// not an answer — a request leaving — can be ordered against answers.
    func note(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func answer(_ request: URLRequest) -> (Int, Data)? {
        let uris = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == "uris" })?.value
        return lock.withLock {
            lines.append("\(request.httpMethod ?? "?") \(request.url?.path ?? "?") \(uris ?? "-")")
            return queue.isEmpty ? respond(request) : queue.removeFirst()
        }
    }
}

/// Serves canned HTTP answers through a real URLSession, so the account's
/// whole request path — URL, Bearer header, status handling — is exercised
/// without touching the network. Handler swap is locked because answers are
/// served on the session's background queue, off the test's actor.
private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    // Lock-guarded: answers are served on the session's background queue, off
    // the test's actor, so every access goes through `lock`.
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (Int, Data)?)?
    nonisolated(unsafe) private static var delay: (@Sendable (URLRequest) -> TimeInterval)?

    /// `delay` holds a request on the wire before it is answered — and before
    /// the handler sees it, so a handler that logs records answers in the
    /// order they came back, which is what tells sequential writes from
    /// overlapping ones.
    static func serve(
        _ handler: @escaping (URLRequest) -> (Int, Data)?,
        delay: (@Sendable (URLRequest) -> TimeInterval)? = nil
    ) {
        lock.withLock {
            self.handler = handler
            self.delay = delay
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let wait = Self.lock.withLock { Self.delay?(request) } ?? 0
        guard wait > 0 else { return answer() }
        // Asynchronously, never by sleeping here: the session may start every
        // protocol on one thread, and a sleep would serialise requests the
        // code under test sent concurrently — hiding the very race asserted.
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [self] in answer() }
    }

    private func answer() {
        let answer = Self.lock.withLock { Self.handler?(request) }
        guard let (status, body) = answer,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
