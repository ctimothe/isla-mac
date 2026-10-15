import Foundation
import XCTest
@testable import IslaKit

/// The replay cache's one non-obvious rule, held without a corpus: an answer
/// the Python resolver paid for serves Isla's identical request although the
/// two spell the URL differently, and never serves a request that only looks
/// the same. Runs in every `swift test`; it touches a temporary directory and
/// never the network (`record: false`).
final class LyricMatchLabReplayTests: XCTestCase {
    private func identity(_ title: String, _ artist: String, album: String = "", duration: TimeInterval = 0)
        -> LocalTrackIdentity
    {
        LocalTrackIdentity(playerID: "lab", title: title, artist: artist, album: album,
                           duration: duration, recordingID: nil)
    }

    func testResolverFormSpellsIslasRequestAsThePythonResolverDoes() throws {
        // URLComponents leaves the apostrophe and the brackets bare; Python's
        // quote(safe="") does not. The strings on the right are what
        // common.build_url printed for the same parameters.
        let get = try XCTUnwrap(OnlineLyrics.request(for: identity(
            "Don't Stop Me Now (2011 Remaster)", "Queen", album: "Jazz", duration: 209.5
        ))?.url)
        XCTAssertFalse(get.absoluteString.contains("%27"))
        XCTAssertEqual(
            MatchLab.resolverForm(of: get),
            "https://lrclib.net/api/get?track_name=Don%27t%20Stop%20Me%20Now%20%282011%20Remaster%29"
                + "&artist_name=Queen&album_name=Jazz&duration=210"
        )
        let search = try XCTUnwrap(OnlineLyrics.searchRequest(title: "Выхода нет", artist: "Сплин")?.url)
        XCTAssertEqual(
            MatchLab.resolverForm(of: search),
            "https://lrclib.net/api/search?track_name=%D0%92%D1%8B%D1%85%D0%BE%D0%B4%D0%B0%20%D0%BD%D0%B5%D1%82"
                + "&artist_name=%D0%A1%D0%BF%D0%BB%D0%B8%D0%BD"
        )
    }

    func testABarePlusIsASpaceAndNeverTheResolversPlus() throws {
        // URLComponents sends "Dan + Shay" with the plus bare, which the
        // server reads as a space; the resolver sent %2B. Different requests.
        let search = try XCTUnwrap(OnlineLyrics.searchRequest(title: "Tequila", artist: "Dan + Shay")?.url)
        XCTAssertTrue(search.absoluteString.contains("Dan%20+%20Shay"))
        XCTAssertEqual(
            MatchLab.resolverForm(of: search),
            "https://lrclib.net/api/search?track_name=Tequila&artist_name=Dan%20%20%20Shay"
        )
        XCTAssertNotEqual(
            MatchLab.resolverForm(of: search),
            "https://lrclib.net/api/search?track_name=Tequila&artist_name=Dan%20%2B%20Shay"
        )
    }

    func testReplayAnswersFromTheResolversSpellingAndKeepsACopyUnderIslas() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("match-lab-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try XCTUnwrap(OnlineLyrics.request(for: identity(
            "Don't Stop Me Now (2011 Remaster)", "Queen", album: "Jazz", duration: 209.5
        )))
        let url = try XCTUnwrap(request.url)
        let resolverURL = try XCTUnwrap(MatchLab.resolverForm(of: url))
        let body = Data(#"{"id":7}"#.utf8)
        // Written where the resolver writes: cache/py, keyed on its spelling.
        let file = MatchLab.cacheFile(root, key: MatchLab.sha256Hex(resolverURL), store: "py")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry: [String: Any] = ["url": resolverURL, "status": 200, "body_b64": body.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: entry).write(to: file)

        let transport = ReplayTransport(root: root, record: false)
        let (data, response) = try await transport.fetch(request)
        XCTAssertEqual(data, body)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(transport.liveRequests, 0)
        // The exchange names the key of Isla's own URL, and that file exists.
        let key = MatchLab.sha256Hex(url.absoluteString)
        XCTAssertEqual(transport.takeExchanges().first?.key, key)
        XCTAssertEqual(MatchLab.cacheEntry(root, key: key)?.url, url.absoluteString)
    }

    func testAFileRecordedForAnotherURLIsNotAnAnswer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("match-lab-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try XCTUnwrap(OnlineLyrics.searchRequest(title: "Song", artist: "It's Me"))
        let resolverURL = try XCTUnwrap(MatchLab.resolverForm(of: try XCTUnwrap(request.url)))
        // The right file name holding some other URL: a hand-copied file.
        let file = MatchLab.cacheFile(root, key: MatchLab.sha256Hex(resolverURL), store: "py")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry: [String: Any] = ["url": "https://lrclib.net/api/search?q=other", "status": 200,
                                    "body_b64": Data("[]".utf8).base64EncodedString()]
        try JSONSerialization.data(withJSONObject: entry).write(to: file)

        let transport = ReplayTransport(root: root, record: false)
        do {
            _ = try await transport.fetch(request)
            XCTFail("a file recorded for another URL answered the request")
        } catch is ReplayTransport.Miss {}
    }

    func testTheReplayCacheKeepsTheStatusesThePythonResolverKeeps() {
        // The Python side is `common.CACHEABLE_STATUSES` (400, 404) and every 2xx. A live fetch
        // needs a server, which this test does not have, so the rule is held as the predicate
        // `fetch` calls.
        for status in [200, 201, 204, 299, 400, 404] {
            XCTAssertTrue(ReplayTransport.cachesStatus(status), "\(status)")
        }
        for status in [301, 401, 403, 410, 429, 500, 503] {
            XCTAssertFalse(ReplayTransport.cachesStatus(status), "\(status)")
        }
        // Anything that is neither kept nor transient is a miss, never an answer: the Python
        // `common.refuses_status`, which this test holds the same set of (third review, m3).
        for status in [100, 301, 401, 402, 403, 405, 410, 418, 451] {
            XCTAssertTrue(ReplayTransport.refusesStatus(status), "\(status)")
        }
        for status in [200, 204, 299, 400, 404, 429, 500, 503, 599] {
            XCTAssertFalse(ReplayTransport.refusesStatus(status), "\(status)")
        }
        for status in 100...599 {
            XCTAssertFalse(ReplayTransport.cachesStatus(status) && ReplayTransport.refusesStatus(status), "\(status)")
        }
    }

    /// A host that keeps refusing is closed like one that keeps throttling: the fourth request
    /// never leaves the machine (third review, m12; Python's twin is
    /// `test_a_host_that_keeps_refusing_trips_like_one_that_keeps_throttling`). `send` stands in
    /// for curl, and `example.test` has no gap to wait out.
    func testRefusedStatusesTripAHostLikeThrottlingDoes() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("match-lab-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let replies = Replies([403, 401, 410, 200])
        let transport = ReplayTransport(root: scratch, record: true, stopAtFirst429: false) { _ in
            (Data(), replies.next())
        }
        for n in 0..<4 {
            transport.beginLookup()
            do {
                _ = try await transport.fetch(URLRequest(url: URL(string: "https://example.test/api/get?n=\(n)")!))
                XCTFail("a refused status is never an answer, and a tripped host is not asked")
            } catch is ReplayTransport.Miss {
                // expected
            }
            let exchanges = transport.takeExchanges()
            XCTAssertEqual(exchanges.map(\.kind), [.miss])
            XCTAssertNil(MatchLab.cacheEntry(scratch, key: exchanges[0].key))
        }
        XCTAssertEqual(transport.liveRequests, 3)
        XCTAssertTrue(transport.isTripped(URL(string: "https://example.test/api/search")!))
        XCTAssertFalse(transport.isTripped(URL(string: "https://other.test/api/search")!))
    }

    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [Int]
        init(_ statuses: [Int]) { self.statuses = statuses }
        func next() -> Int { lock.withLock { statuses.isEmpty ? 200 : statuses.removeFirst() } }
    }

    func testTheLRCLIBGapCanOnlyBeSlowerThanTheTable() {
        XCTAssertEqual(ReplayTransport.gap(for: "lrclib.net"), ReplayTransport.minimumGap["lrclib.net"])
        XCTAssertEqual(ReplayTransport.gap(for: "itunes.apple.com"), 3.2)
        XCTAssertNil(ReplayTransport.gap(for: "example.test"))
    }
}
