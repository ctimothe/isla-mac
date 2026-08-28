import XCTest
import Compression
@testable import IslaKit

final class WordSyncedLyricsTests: XCTestCase {
    // MARK: - TTML

    func testParsesAmllShapedTTML() {
        let ttml = """
        <tt><body><div>
        <p begin="10.5s" end="14.0s"><span begin="10.5s" end="11.0s">Blinding</span> <span begin="11.2s" end="12.0s">lights</span></p>
        <p begin="1:02.25" end="1:05"><span begin="1:02.25">Sky</span></p>
        </div></body></tt>
        """
        let lines = WordSyncedLyrics.parseTTML(Data(ttml.utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].at, 10.5, accuracy: 0.001)
        // The inter-span space rides with the word before it, the same
        // convention KRC uses — spacing carries sweep weight.
        XCTAssertEqual(lines[0].words.map(\.text), ["Blinding ", "lights"])
        XCTAssertEqual(lines[0].words[1].at, 11.2, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "Blinding lights")
        XCTAssertEqual(lines[1].at, 62.25, accuracy: 0.001)
    }

    func testClockFormats() {
        XCTAssertEqual(WordSyncedLyrics.clock("12.34s")!, 12.34, accuracy: 0.001)
        XCTAssertEqual(WordSyncedLyrics.clock("1:23.45")!, 83.45, accuracy: 0.001)
        XCTAssertEqual(WordSyncedLyrics.clock("0:01:23.5")!, 83.5, accuracy: 0.001)
        XCTAssertNil(WordSyncedLyrics.clock("nonsense"))
    }

    // MARK: - KRC

    func testParsesKRCBody() {
        let body = """
        [id:$00000000]
        [9380,4690]<0,142,0>Com<142,158,0>posed <300,200,0>here
        [15000,3000]<0,500,0>Second
        """
        let lines = WordSyncedLyrics.parseKRCBody(body)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].at, 9.38, accuracy: 0.001)
        XCTAssertEqual(lines[0].words.count, 3)
        XCTAssertEqual(lines[0].words[1].at, 9.38 + 0.142, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "Composed here")
        XCTAssertEqual(lines[1].words[0].text, "Second")
    }

    func testKRCDecryptRoundTrip() throws {
        // Build a synthetic KRC: deflate the body, prepend a zlib header,
        // XOR with the known key, add the magic — then decrypt it back.
        let body = "[1000,2000]<0,100,0>Hello<100,100,0> world"
        let source = [UInt8](body.utf8)
        var deflated = [UInt8](repeating: 0, count: source.count * 2 + 64)
        let written = source.withUnsafeBufferPointer { src in
            compression_encode_buffer(&deflated, deflated.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        XCTAssertGreaterThan(written, 0)
        // 0x78 0x9C — the standard zlib header Compression strips.
        var payload: [UInt8] = [0x78, 0x9C] + deflated[0..<written]
        let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
                            0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]
        for index in payload.indices { payload[index] ^= key[index % key.count] }
        let encrypted = Data("krc1".utf8) + Data(payload)

        let decrypted = try XCTUnwrap(WordSyncedLyrics.decryptKRC(encrypted))
        XCTAssertTrue(decrypted.contains("Hello"))
        let lines = WordSyncedLyrics.parseKRCBody(decrypted)
        XCTAssertEqual(lines.first?.words.map(\.text), ["Hello", " world"])
    }

    // MARK: - Word-accurate sweep

    private let line = WordSyncedLyrics.Line(
        at: 10,
        text: "Hello brave world",
        words: [
            .init(at: 10, text: "Hello "),   // 6 chars
            .init(at: 11, text: "brave "),   // 6 chars
            .init(at: 12.5, text: "world"),  // 5 chars
        ]
    )

    func testFractionBeforeFirstWordIsZero() {
        XCTAssertEqual(WordSyncedLyrics.wordFraction(words: line.words, at: 9.5, lineEnd: 14), 0)
    }

    func testFractionLandsOnTheWordBeingSung() {
        // Mid-second word: the whole first word plus half the second.
        let f = WordSyncedLyrics.wordFraction(words: line.words, at: 11.75, lineEnd: 14)
        XCTAssertEqual(f, (6 + 3) / 17.0, accuracy: 0.01)
    }

    func testFractionCompletesAtLineEnd() {
        XCTAssertEqual(WordSyncedLyrics.wordFraction(words: line.words, at: 14, lineEnd: 14), 1.0, accuracy: 0.001)
    }

    func testAWordHeldLongSweepsAtItsOwnPace() {
        // Third word spans 12.5...14 (1.5s): a quarter in, only a quarter of
        // its characters are sung.
        let f = WordSyncedLyrics.wordFraction(words: line.words, at: 12.875, lineEnd: 14)
        XCTAssertEqual(f, (12 + 5 * 0.25) / 17.0, accuracy: 0.01)
    }

    /// The bug that read as "wrong timeline" on long lines: both formats carry
    /// each word's real end, it was parsed and discarded, and every word was
    /// stretched to the next word's start — so the sweep crawled through
    /// breaths and rests instead of holding.
    func testSweepHoldsThroughPausesBetweenWords() {
        let words: [WordSyncedLyrics.Word] = [
            .init(at: 10.0, text: "Hold", end: 10.5),
            // A 2.5s gap before the next word — a breath, a rest, a riff.
            .init(at: 13.0, text: "on", end: 13.4),
        ]
        // Mid-first-word: partway through its own span, not the gap's.
        let mid = WordSyncedLyrics.wordFraction(words: words, at: 10.25, lineEnd: 14)
        XCTAssertEqual(mid, 0.5 * (4.0 / 6.0), accuracy: 0.01)
        // Deep in the pause: the first word is done, the second not begun —
        // the edge must hold exactly there, not drift onward.
        let pause1 = WordSyncedLyrics.wordFraction(words: words, at: 11.0, lineEnd: 14)
        let pause2 = WordSyncedLyrics.wordFraction(words: words, at: 12.9, lineEnd: 14)
        XCTAssertEqual(pause1, 4.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(pause2, pause1, accuracy: 0.0001, "the sweep moved during a pause")
    }

    func testKRCKeepsWordDurations() {
        let body = "[10000,4000]<0,500,0>Hold <3000,400,0>on"
        let lines = WordSyncedLyrics.parseKRCBody(body)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.count, 2)
        XCTAssertEqual(lines[0].words[0].end ?? -1, 10.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].end ?? -1, 13.4, accuracy: 0.001)
    }

    func testTTMLKeepsSpanEnds() {
        let ttml = """
        <p begin="10.0s" end="14.0s"><span begin="10.0s" end="10.5s">Hold</span> <span begin="13.0s" end="13.4s">on</span></p>
        """
        let lines = WordSyncedLyrics.parseTTML(Data(ttml.utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.first?.end ?? -1, 10.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].words.last?.end ?? -1, 13.4, accuracy: 0.001)
    }
}
