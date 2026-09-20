import XCTest
@testable import IslaKit

final class LocalLyricsDocumentTests: XCTestCase {
    func testParsesMetadataAndEnhancedWordTiming() throws {
        let document = try LocalLyricsDocument.parse("""
        [ti:Weird Fishes]
        [ar:Radiohead]
        [al:In Rainbows]
        [length:05:18]
        [00:12.00]<00:12.00>In <00:12.45>the <00:12.82>deep
        """)

        XCTAssertEqual(document.metadata.title, "Weird Fishes")
        XCTAssertEqual(document.metadata.artist, "Radiohead")
        XCTAssertEqual(try XCTUnwrap(document.duration), 318, accuracy: 0.001)
        XCTAssertEqual(document.lines[0].words.map(\.text), ["In", "the", "deep"])
        XCTAssertEqual(document.granularity, .word)
    }

    func testRejectsOutOfOrderEnhancedWords() {
        XCTAssertThrowsError(try LocalLyricsDocument.parse(
            "[00:01.00]<00:01.80>late <00:01.20>early"
        ))
    }

    func testSerializeRoundTripsEditableLines() throws {
        let parsed = try LocalLyricsDocument.parse(
            "[ti:Song]\n[ar:Artist]\n[00:01.00]One"
        )

        XCTAssertEqual(try LocalLyricsDocument.parse(parsed.serialize()), parsed)
    }

    func testEnhancedFixtureIsValidLocalLRC() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/local-word-timed.lrc")
        let document = try LocalLyricsDocument.parse(String(contentsOf: fixture, encoding: .utf8))

        XCTAssertEqual(document.granularity, .word)
    }

    /// A stamp with no words is a gap between verses, not a broken file.
    ///
    /// LRC writers mark the pause between stanzas with a bare timestamp, and
    /// LRCLIB emits one in most files. This threw `emptyTimeline`, and because
    /// that error aborts the whole parse, a single blank line rejected an
    /// otherwise perfect lyric — an imported file was called invalid, and an
    /// online answer was cached as "this track has no lyrics".
    func testABareTimestampIsAGapAndNotABrokenFile() throws {
        let document = try LocalLyricsDocument.parse("""
        [00:10.58] Through your eyes I see
        [00:15.77] A smile you bring to me
        [00:21.05]
        [00:26.30] Not a lot, just forever
        """)
        XCTAssertEqual(document.lines.map(\.text), [
            "Through your eyes I see", "A smile you bring to me", "Not a lot, just forever",
        ])
        XCTAssertEqual(document.granularity, .line)
    }

    /// And a file that is nothing but gaps is still no lyric at all.
    func testAFileWithNoWordsAnywhereIsStillRejected() {
        XCTAssertThrowsError(try LocalLyricsDocument.parse("[00:01.00]\n[00:02.00]  "))
    }
}
