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

    // MARK: - Every standard LRC reads (G-002, F-009, G-007, G-019, F-010)

    /// A byte-order mark is not part of the first stamp.
    ///
    /// The line was trimmed with `.whitespaces`, which keeps U+FEFF, so a file
    /// saved by Notepad lost its first sung line: `\u{FEFF}[00:00.00]` was not
    /// a stamp, and the line was skipped. The lab found one in 540 tracks.
    func testALeadingByteOrderMarkKeepsTheFirstLine() throws {
        let document = try LocalLyricsDocument.parse("\u{FEFF}[00:00.00]First\n[00:05.00]Second")

        XCTAssertEqual(document.lines.count, 2)
        XCTAssertEqual(document.lines.first?.text, "First")
        XCTAssertEqual(document.lines.map(\.at), [0, 5])
    }

    /// A compressed LRC writes a chorus once, under every stamp it is sung
    /// at, so its stamps step backwards across lines by design. That threw
    /// `invalidTimestamp` and rejected the whole file (F-009).
    func testStackedTimestampsAreSortedNotRejected() throws {
        let document = try LocalLyricsDocument.parse("[00:10.00][01:30.00]Chorus\n[00:20.00]Verse")

        XCTAssertEqual(document.lines.map(\.at), [10, 20, 90])
        XCTAssertEqual(document.lines.map(\.text), ["Chorus", "Verse", "Chorus"])
    }

    /// Tags Isla does not know, comment lines and section labels are not
    /// stamps, and a heart in the words is not a word marker (G-002). Any one
    /// of them threw and, from LRCLIB, cached the song as a 14-day miss.
    func testUnknownTagsAndSectionLabelsAreNotTimestamps() throws {
        let document = try LocalLyricsDocument.parse("""
        [by:x]
        [re:y]
        [#:c]
        [id:z]
        [tool:t]
        [Verse 1: Drake]
        [00:12.00][Verse 1: Drake] Started
        [00:15.00]I <3 you
        """)

        XCTAssertEqual(document.lines.map(\.text), ["[Verse 1: Drake] Started", "I <3 you"])
        XCTAssertEqual(document.lines.map(\.at), [12, 15])
        XCTAssertTrue(document.lines.allSatisfy(\.words.isEmpty))
        XCTAssertEqual(document.granularity, .line)
    }

    /// A '<' inside word-timed content that does not open a marker is text.
    func testALiteralAngleBracketInsideWordTimingIsText() throws {
        let document = try LocalLyricsDocument.parse("[00:01.00]<00:01.00>I <3 <00:02.00>you")

        XCTAssertEqual(document.lines[0].words.map(\.text), ["I <3", "you"])
        XCTAssertEqual(document.lines[0].words.map(\.at), [1, 2])
    }

    /// Comma and colon fractions, and three-digit milliseconds, are the
    /// dialects real editors write (G-007); the lab found a Mandarin file in
    /// `mm:ss:ff` refused whole.
    func testCommonTimestampDialects() throws {
        let document = try LocalLyricsDocument.parse("[00:12,34]a\n[00:13:34]b\n[00:14.345]c\n[00:15]d\n[00:16.5]e")

        XCTAssertEqual(document.lines.map(\.text), ["a", "b", "c", "d", "e"])
        let expected: [TimeInterval] = [12.34, 13.34, 14.345, 15, 16.5]
        for (line, at) in zip(document.lines, expected) {
            XCTAssertEqual(line.at, at, accuracy: 0.000_001, line.text)
        }
        XCTAssertEqual(
            try LocalLyricsDocument.parse("[00:12,34]a").lines[0].at,
            try LocalLyricsDocument.parse("[00:12:34]b").lines[0].at
        )
    }

    /// `TimeInterval(String)` reads "nan", "inf" and 1e300, and `serialize`
    /// then trapped in `Int(...)` when the editor saved a copy (G-019).
    func testNonFiniteValuesAreRejectedAndSerializeNeverTraps() throws {
        for raw in [
            "[offset:nan]\n[00:01.00]x",
            "[offset:inf]\n[00:01.00]x",
            "[offset:1e300]\n[00:01.00]x",
            "[inf:00.00]x",
            "[1e300:00.00]x",
            "[00:01.00]ok\n[1e300:00.00]x",
            "[00:01.00]ok\n[1000:00.00]x",
        ] {
            XCTAssertThrowsError(try LocalLyricsDocument.parse(raw), raw)
        }

        let huge = LocalLyricsDocument(
            metadata: LocalLyricsMetadata(duration: .infinity),
            lines: [
                LyricsStore.Line(at: 1e17, text: "far"),
                LyricsStore.Line(at: .nan, text: "nowhere"),
            ],
            offset: 1e300
        )
        let written = huge.serialize()
        XCTAssertTrue(written.contains("far"))
        // Whatever it wrote, Isla can read back.
        XCTAssertNoThrow(try LocalLyricsDocument.parse(written))
    }

    /// Two rows at one stamp — a bilingual file, original then translation —
    /// are one line of two rows. Kept apart, the first was unreachable: every
    /// search answered the second (F-010, lab L2).
    func testEqualStampsBecomeOneTwoRowLine() throws {
        let document = try LocalLyricsDocument.parse("[00:10.00]Hello\n[00:10.00]Привет\n[00:12.00]Next")

        XCTAssertEqual(document.lines.map(\.text), ["Hello\nПривет", "Next"])
        XCTAssertEqual(document.lines.map(\.at), [10, 12])

        let written = document.serialize()
        XCTAssertEqual(written, "[00:10.00]Hello\n[00:10.00]Привет\n[00:12.00]Next")
        XCTAssertEqual(try LocalLyricsDocument.parse(written), document)
    }

    /// A refusal says where: the error carries the 1-based source line.
    func testAParseFailureNamesItsLine() {
        XCTAssertThrowsError(try LocalLyricsDocument.parse("[00:01.00]a\n[00:7x.00]b")) { error in
            XCTAssertEqual(error as? LocalLyricsDocument.Error, .invalidTimestamp(line: 2))
        }
        XCTAssertThrowsError(try LocalLyricsDocument.parse(
            "[ti:x]\r\n\r\n[00:01.00]<00:01.80>late <00:01.20>early"
        )) { error in
            XCTAssertEqual(error as? LocalLyricsDocument.Error, .invalidWordOrder(line: 3))
        }
    }

    /// CR, LF and CRLF all end a line.
    func testEveryNewlineConventionEndsALine() throws {
        let document = try LocalLyricsDocument.parse("[00:01.00]a\r\n[00:02.00]b\r[00:03.00]c\n[00:04.00]d")

        XCTAssertEqual(document.lines.map(\.text), ["a", "b", "c", "d"])
    }

    func testTheParserRevisionMovesWhenTheGrammarDoes() {
        XCTAssertEqual(LocalLyricsDocument.parserRevision, 2)
    }
}
