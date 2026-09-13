import XCTest
@testable import IslaKit

@MainActor
final class LyricsBrokerTests: XCTestCase {
    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        func set(_ request: URLRequest) {
            lock.withLock { stored.append(request) }
        }

        var requests: [URLRequest] { lock.withLock { stored } }

        var resolveBody: [String: Any] {
            let request = requests.last { $0.url?.path == "/v1/lyrics/resolve" }
            return request.flatMap { request in
                request.httpBody.flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
            } ?? [:]
        }
    }

    private let identity = LyricIdentity(
        playerID: "music",
        title: "Song",
        artist: "Artist",
        album: "Album",
        duration: 180,
        isrc: "USXXX1234567",
        locale: "en"
    )

    func testResolvePostsOnlyTheBrokerIdentityContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenStore = TokenStore(
            service: "com.ctimothe.isla.tests.lyrics.\(UUID().uuidString)",
            paths: AppPaths(
                supportDirectory: root.appendingPathComponent("support"),
                screenshotDirectory: root.appendingPathComponent("pictures")
            )
        )
        defer { tokenStore.delete("anonymous-installation") }
        let capture = RequestCapture()
        let session = TestURLProtocol.session { request in
            capture.set(request)
            if request.url?.path == "/v1/installations" {
                return (201, try! JSONSerialization.data(withJSONObject: ["token": "broker-token"]))
            }
            let payload: [String: Any] = [
                "status": "available",
                "territory": "allowed",
                "canonicalMatch": ["title": "Song", "artist": "Artist"],
                "timeline": [
                    "granularity": "line",
                    "attribution": "Provider",
                    "source": "licensed",
                    "matchConfidence": 0.99,
                    "cacheExpiresAt": Date().addingTimeInterval(60).timeIntervalSince1970,
                    "lines": [["at": 1.0, "text": "One line", "words": []]],
                ],
            ]
            return (200, try! JSONSerialization.data(withJSONObject: payload))
        }
        let resolver = BrokerLyricsResolver(
            endpoint: URL(string: "https://lyrics.example/v1/lyrics/resolve")!,
            session: session,
            tokenStore: tokenStore
        )

        let resolution = await resolver.resolve(identity)

        guard case .available(let timeline) = resolution else {
            return XCTFail("the successful broker response should become a timeline")
        }
        XCTAssertEqual(timeline.lines.map(\.text), ["One line"])
        XCTAssertEqual(
            capture.requests.map { $0.url?.path },
            ["/v1/installations", "/v1/lyrics/resolve"],
            "a broker-issued token must be enrolled once before resolution"
        )
        XCTAssertEqual(
            capture.requests.last?.value(forHTTPHeaderField: "X-Isla-Installation-Token"),
            "broker-token"
        )
        XCTAssertEqual(tokenStore.read("anonymous-installation"), "broker-token")
        XCTAssertEqual(
            Set(capture.resolveBody.keys),
            ["playerID", "title", "artist", "album", "duration", "isrc", "appLocale"],
            "the broker must never receive playback, library, audio, or account fields"
        )
        XCTAssertEqual(capture.resolveBody["isrc"] as? String, "USXXX1234567")
    }

    func testDeniedTerritoryIsUnavailable() async {
        let tokenStore = TokenStore(service: "com.ctimothe.isla.tests.lyrics.\(UUID().uuidString)")
        let session = TestURLProtocol.session { _ in
            let payload = ["status": "unavailable", "territory": "denied"]
            return (200, try! JSONSerialization.data(withJSONObject: payload))
        }
        let resolver = BrokerLyricsResolver(
            endpoint: URL(string: "https://lyrics.example/v1/lyrics/resolve")!,
            session: session,
            tokenStore: tokenStore
        )

        let resolution = await resolver.resolve(identity)
        XCTAssertEqual(resolution, .unavailable)
    }

    func testBrokerFailurePreservesTheVendorRetryability() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenStore = TokenStore(
            service: "com.ctimothe.isla.tests.lyrics.\(UUID().uuidString)",
            paths: AppPaths(
                supportDirectory: root.appendingPathComponent("support"),
                screenshotDirectory: root.appendingPathComponent("pictures")
            )
        )
        defer { tokenStore.delete("anonymous-installation") }
        let session = TestURLProtocol.session { request in
            if request.url?.path == "/v1/installations" {
                return (201, try! JSONSerialization.data(withJSONObject: ["token": "broker-token"]))
            }
            return (503, try! JSONSerialization.data(withJSONObject: [
                "status": "failed", "errorClass": "service", "retryable": false,
            ]))
        }
        let resolver = BrokerLyricsResolver(
            endpoint: URL(string: "https://lyrics.example/v1/lyrics/resolve")!,
            session: session,
            tokenStore: tokenStore
        )

        let resolution = await resolver.resolve(identity)

        XCTAssertEqual(
            resolution, .failed(LyricsFailure(kind: .service, retryable: false)),
            "a provider's non-retryable failure must not advertise a retry"
        )
    }

    func testBrokerRejectsAnAvailableTimelineWithoutAttributionOrCacheRights() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenStore = TokenStore(
            service: "com.ctimothe.isla.tests.lyrics.\(UUID().uuidString)",
            paths: AppPaths(
                supportDirectory: root.appendingPathComponent("support"),
                screenshotDirectory: root.appendingPathComponent("pictures")
            )
        )
        defer { tokenStore.delete("anonymous-installation") }
        let session = TestURLProtocol.session { request in
            if request.url?.path == "/v1/installations" {
                return (201, try! JSONSerialization.data(withJSONObject: ["token": "broker-token"]))
            }
            let payload: [String: Any] = [
                "status": "available",
                "territory": "allowed",
                "timeline": [
                    "granularity": "line",
                    "attribution": "",
                    "source": "licensed",
                    "matchConfidence": 0.99,
                    "cacheExpiresAt": Date().addingTimeInterval(-1).timeIntervalSince1970,
                    "lines": [["at": 1.0, "text": "Uncredited", "words": []]],
                ],
            ]
            return (200, try! JSONSerialization.data(withJSONObject: payload))
        }
        let resolver = BrokerLyricsResolver(
            endpoint: URL(string: "https://lyrics.example/v1/lyrics/resolve")!,
            session: session,
            tokenStore: tokenStore
        )

        let resolution = await resolver.resolve(identity)

        XCTAssertEqual(
            resolution, .failed(LyricsFailure(kind: .service, retryable: true)),
            "an uncredited or expired timeline must never be displayed or cached"
        )
    }
}
