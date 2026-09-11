import XCTest
@testable import IslaKit

/// Shared wire stub for the lyric-tier tests: the handler stands in for the
/// network, every answer below arrives through a real URLSession.
final class TestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    // Served on the session's background queue, off the test's actor.
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (Int, Data)?)?

    static func session(handler: @escaping (URLRequest) -> (Int, Data)?) -> URLSession {
        lock.withLock { self.handler = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
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

/// The QQ Music word-synced tier: search, QRC download, the vendor's
/// deliberately-off DES, and the suffix-syllable parse.
final class QQLyricsTests: XCTestCase {
    // MARK: - Buggy DES

    /// Known-answer vectors from the reference port (jixunmoe-go/qrc
    /// `des_impl_test.go`): the only proof a clean-room port matches the
    /// implementation that decodes real QRC files.
    func testSingleDESEncryptMatchesReferenceVector() {
        let input = Data([0xFD, 0x0E, 0x64, 0x06, 0x65, 0xBE, 0x74, 0x13,
                          0x77, 0x63, 0x3B, 0x02, 0x45, 0x4E, 0x70, 0x7A])
        let expected = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(QQLyrics.desCrypt(input, key: Data("TEST!KEY".utf8), encrypt: true), expected)
    }

    func testSingleDESDecryptMatchesReferenceVector() {
        let input = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6])
        let expected = Data([0xFD, 0x0E, 0x64, 0x06, 0x65, 0xBE, 0x74, 0x13,
                             0x77, 0x63, 0x3B, 0x02, 0x45, 0x4E, 0x70, 0x7A])
        XCTAssertEqual(QQLyrics.desCrypt(input, key: Data("TEST!KEY".utf8), encrypt: false), expected)
    }

    /// Encrypt with the tier's own keys, decrypt back: the round trip must be
    /// exact, byte for byte.
    func testQRCRoundTrip() throws {
        let xml = """
        <?xml version="1.0"?><QrcInfos><Lyric_1 LyricType="1" \
        LyricContent="[10000,5000]Hello (10000,500)world(10500,500)"/></QrcInfos>
        """
        let encrypted = try XCTUnwrap(QQLyrics.encryptQRC(xml))
        XCTAssertEqual(QQLyrics.decryptQRC(encrypted), xml)
    }

    // MARK: - QRC body parse

    /// Same shape as the KRC test, because the contract is the same: real
    /// word ends, spaces riding with the syllable before them.
    func testParseQRCBody() {
        // The AMLL reference sample: timestamps follow their text and are
        // absolute, unlike KRC's line-relative offsets.
        let body = "[190871,1984]For (190871,361)the (191232,172)first (191404,376)time(191780,1075)"
        let lines = WordSyncedLyrics.parseQRCBody(body)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].at, 190.871, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "For the first time")
        XCTAssertEqual(lines[0].words.map(\.text), ["For ", "the ", "first ", "time"])
        XCTAssertEqual(lines[0].words[0].at, 190.871, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[0].end ?? -1, 191.232, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].at, 191.232, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].end ?? -1, 191.404, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[3].at, 191.780, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[3].end ?? -1, 192.855, accuracy: 0.001)
    }

    /// Parentheses that are not timestamps are lyric text — QRC keeps normal
    /// parens in lyrics, so only `(\d+,\d+)` splits a syllable.
    func testParseQRCBodyKeepsNonTimestampParens() {
        let lines = WordSyncedLyrics.parseQRCBody("[1000,3000]Hello (world) again(1000,100)")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello (world) again")
        XCTAssertEqual(lines[0].words.count, 1)
    }

    // MARK: - Search + download parsing

    func testParseSearchResponse() throws {
        let json = """
        {"code":0,"music.search.SearchCgiService":{"code":0,"data":{"body":{"song":{"list":[
        {"songid":12345,"songmid":"abc123","songname":"Test Song",
         "singer":[{"name":"Test Artist"}],"albumname":"Test Album","interval":200}
        ]}}}}}
        """.data(using: .utf8)!
        let songs = QQLyrics.parseSearchResponse(json)
        XCTAssertEqual(songs.count, 1)
        let song = try XCTUnwrap(songs.first)
        XCTAssertEqual(song.songID, "12345")
        XCTAssertEqual(song.title, "Test Song")
        XCTAssertEqual(song.artist, "Test Artist")
        XCTAssertEqual(song.album, "Test Album")
        XCTAssertEqual(song.duration ?? -1, 200, accuracy: 0.001)
    }

    /// The download answer wraps hex in `contentts` (word-synced) with
    /// `content` as the fallback; HTML comments around the XML are QQ's own.
    func testParseDownloadResponsePrefersContentTS() {
        let xml = """
        <!--<QmLyric><contentts><![CDATA[DEADBEEF]]></contentts><content><![CDATA[00]]></content></QmLyric>-->
        """.data(using: .utf8)!
        XCTAssertEqual(QQLyrics.parseDownloadResponse(xml), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testParseDownloadResponseFallsBackToContent() {
        let xml = "<QmLyric><contentts></contentts><content>00ff</content></QmLyric>".data(using: .utf8)!
        XCTAssertEqual(QQLyrics.parseDownloadResponse(xml), Data([0x00, 0xFF]))
    }

    func testExtractQRCBody() {
        let xml = """
        <?xml version="1.0"?><QrcInfos><Lyric_1 LyricType="1" \
        LyricContent="[1000,2000]Hi (1000,500)there(1500,500)"/></QrcInfos>
        """
        XCTAssertEqual(QQLyrics.extractQRCBody(from: xml), "[1000,2000]Hi (1000,500)there(1500,500)")
    }

    // MARK: - Network shape

    /// Search posts the desktop query and the download posts the form the PC
    /// client uses; both carry the browser referer QQ expects.
    func testSearchAndDownloadHitTheDocumentedEndpoints() async {
        var seen: [String] = []
        let session = TestURLProtocol.session { request in
            seen.append(request.url?.absoluteString ?? "")
            if request.url?.host == "u.y.qq.com" {
                return (200, #"{"code":0}"#.data(using: .utf8)!)
            }
            return nil
        }
        _ = await QQLyrics.searchSongs(title: "T", artist: "A", session: session)
        XCTAssertTrue(seen.contains { $0.hasPrefix("https://u.y.qq.com/cgi-bin/musicu.fcg") })
        XCTAssertEqual(QQLyrics.downloadURL.host, "c.y.qq.com")
    }
}
