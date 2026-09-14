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
}
