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

    private func stubSession(_ handler: @escaping (URLRequest) -> (Int, Data)?) -> URLSession {
        StubURLProtocol.serve(handler)
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

    static func serve(_ handler: @escaping (URLRequest) -> (Int, Data)?) {
        lock.withLock { self.handler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
