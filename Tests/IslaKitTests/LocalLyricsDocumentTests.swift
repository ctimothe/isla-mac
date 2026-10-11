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
        XCTAssertEqual(document.lines[0].words.map(\.text), ["In ", "the ", "deep"])
        XCTAssertEqual(document.lines[0].text, "In the deep")
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

    /// A stamp with no words is where the line before it ends — not a broken
    /// file, and not a row.
    ///
    /// LRC writers mark the pause between stanzas with a bare timestamp, and
    /// LRCLIB emits one in most files. This threw `emptyTimeline`, and because
    /// that error aborts the whole parse, a single blank line rejected an
    /// otherwise perfect lyric — an imported file was called invalid, and an
    /// online answer was cached as "this track has no lyrics". It was then
    /// dropped, which threw the answer away: the lyric lab (L6, 540 tracks)
    /// found finished lines lit through instrumentals for a median 28.9 s a
    /// track, and 1,694 of these stamps saying exactly when each voice ended.
    func testABareTimestampEndsTheLineBeforeIt() throws {
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
        XCTAssertNil(document.lines[0].end, "a line with no stamp after it runs to the next")
        XCTAssertEqual(try XCTUnwrap(document.lines[1].end), 21.05, accuracy: 0.000_001)
        XCTAssertNil(document.lines[2].end)
        XCTAssertEqual(try LocalLyricsDocument.parse(document.serialize()), document)
    }

    /// Which line an empty stamp ends, in the cases a real file throws at it:
    /// the outro stamp after the last line ends that line; a stamp before the
    /// first sung line ends nothing; a second stamp in one gap does not move
    /// the first; a stamp at the very moment of the line before it is not an
    /// end; and the offset applies to an end exactly as to a start.
    func testWhichLineAnEmptyStampEnds() throws {
        let document = try LocalLyricsDocument.parse("""
        [offset:500]
        [00:01.00]
        [00:05.00]a
        [00:05.00]
        [00:09.00]b
        [00:12.00]
        [00:14.00]
        [00:20.00]c
        [00:31.50]
        """)
        XCTAssertEqual(document.lines.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(document.lines.map(\.at), [4.5, 8.5, 19.5])
        XCTAssertNil(document.lines[0].end, "a stamp at the line's own start ends nothing")
        XCTAssertEqual(try XCTUnwrap(document.lines[1].end), 11.5, accuracy: 0.000_001, "the first stamp of a gap")
        XCTAssertEqual(try XCTUnwrap(document.lines[2].end), 31, accuracy: 0.000_001, "the outro stamp ends the last line")
        XCTAssertEqual(try LocalLyricsDocument.parse(document.serialize()), document)
    }

    /// `serialize` writes an end back only where `parse` would read it as the
    /// same line's end. The editor can move a line past its own end, or past
    /// the next line; written out blindly, that end would come back as the
    /// end of some other line.
    func testAnEndIsWrittenOnlyWhereItReadsBackAsTheSameLinesEnd() throws {
        let document = LocalLyricsDocument(
            metadata: LocalLyricsMetadata(),
            lines: [
                LyricsStore.Line(at: 10, text: "moved past its end", end: 8),
                LyricsStore.Line(at: 12, text: "end beyond the next", end: 30),
                LyricsStore.Line(at: 20, text: "kept", end: 24),
            ],
            offset: 0
        )
        XCTAssertEqual(
            document.serialize(),
            "[00:10.00]moved past its end\n[00:12.00]end beyond the next\n[00:20.00]kept\n[00:24.00]"
        )
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

        XCTAssertEqual(document.lines[0].words.map(\.text), ["I <3 ", "you"])
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
        XCTAssertEqual(
            LocalLyricsDocument.parserRevision, 5,
            "5: a first word may start a centisecond before its line stamp"
        )
    }

    // MARK: - Word timing is honest (J-010, G-018, L-11)

    /// `[offset:]` moves a word with its line (J-010).
    ///
    /// Only line stamps took the offset, and `serialize` added it to both, so
    /// a +500 file swept every word half a second behind the line it sat in,
    /// each Save Copy pushed the words another half second, and a −300 file
    /// wrote words before their own line, which the editor's re-parse refused
    /// as "This LRC file is invalid." for a file that had imported fine.
    func testAnOffsetMovesWordsWithTheirLine() throws {
        let late = try LocalLyricsDocument.parse("[offset:+500]\n[00:10.00]<00:10.00>a <00:10.50>b")
        XCTAssertEqual(late.lines[0].at, 9.5, accuracy: 0.000_001)
        XCTAssertEqual(late.lines[0].words.map(\.at), [9.5, 10.0])
        XCTAssertEqual(try LocalLyricsDocument.parse(late.serialize()), late)

        let early = try LocalLyricsDocument.parse("[offset:-300]\n[00:10.00]<00:10.00>a <00:10.50>b<00:11.00>")
        XCTAssertEqual(early.lines[0].at, 10.3, accuracy: 0.000_001)
        XCTAssertEqual(early.lines[0].words[0].at, 10.3, accuracy: 0.000_001)
        XCTAssertEqual(early.lines[0].words[1].at, 10.8, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(early.lines[0].words[1].end), 11.3, accuracy: 0.000_001, "an end moves too")
        XCTAssertEqual(try LocalLyricsDocument.parse(early.serialize()), early)
    }

    /// The text between two markers is the word, exactly (G-018).
    ///
    /// Words were trimmed and the line rebuilt with a space between each, so
    /// per-character Chinese karaoke read '我 爱 你' and a syllable split
    /// 'Hel<…>lo' read 'Hel lo', on screen and on the clipboard.
    func testWordTextIsKeptVerbatim() throws {
        let chinese = try LocalLyricsDocument.parse("[00:01.00]<00:01.00>我<00:01.20>爱<00:01.40>你")
        XCTAssertEqual(chinese.lines[0].text, "我爱你")
        XCTAssertEqual(chinese.lines[0].words.map(\.text), ["我", "爱", "你"])
        XCTAssertEqual(try LocalLyricsDocument.parse(chinese.serialize()), chinese)

        let syllables = try LocalLyricsDocument.parse("[00:01.00]<00:01.00>Hel<00:01.20>lo world")
        XCTAssertEqual(syllables.lines[0].text, "Hello world")
        XCTAssertEqual(syllables.lines[0].words.map(\.text), ["Hel", "lo world"])
        XCTAssertEqual(try LocalLyricsDocument.parse(syllables.serialize()), syllables)
    }

    /// A marker with no text after it is where the word before it ends (L-11).
    /// The A2 dialect closes a line this way, and the empty word threw, so
    /// the whole file was refused.
    func testATrailingMarkerEndsTheLastWord() throws {
        let document = try LocalLyricsDocument.parse("[00:01.00]<00:01.00>one <00:01.50>two<00:02.10>")
        XCTAssertEqual(document.lines[0].text, "one two")
        XCTAssertEqual(document.lines[0].words.map(\.text), ["one ", "two"])
        XCTAssertNil(document.lines[0].words[0].end, "the next marker already says where 'one ' ends")
        XCTAssertEqual(try XCTUnwrap(document.lines[0].words[1].end), 2.10, accuracy: 0.000_001)
        XCTAssertEqual(try LocalLyricsDocument.parse(document.serialize()), document)

        // A space before the closing marker is the line's trailing space,
        // which every other line has trimmed; it is not kept on the last word.
        let spaced = try LocalLyricsDocument.parse("[00:01.00]<00:01.00>one <00:01.50>two <00:02.10>")
        XCTAssertEqual(spaced.lines[0].text, "one two")
        XCTAssertEqual(spaced.lines[0].words.map(\.text), ["one ", "two"])
    }

    /// The same inside a line: two markers with nothing between them end the
    /// word before the first, and the silence up to the second is nobody's.
    func testAnEmptyMarkerInsideALineEndsTheWordBeforeIt() throws {
        let document = try LocalLyricsDocument.parse("[00:01.00]<00:01.00>one<00:01.30><00:02.00> two")
        XCTAssertEqual(document.lines[0].text, "one two")
        XCTAssertEqual(document.lines[0].words.map(\.at), [1, 2])
        XCTAssertEqual(try XCTUnwrap(document.lines[0].words[0].end), 1.3, accuracy: 0.000_001)
        XCTAssertEqual(try LocalLyricsDocument.parse(document.serialize()), document)
        // An end before its own word is still out of order, and an empty
        // marker with no word before it is still not a word.
        XCTAssertThrowsError(try LocalLyricsDocument.parse("[00:01.00]<00:01.00>one<00:00.50>"))
        XCTAssertThrowsError(try LocalLyricsDocument.parse("[00:01.00]<00:01.00><00:01.50>one"))
    }

    /// LRCLIB's word-timed files (36877652 in the lab corpus) write the line
    /// stamp in centiseconds, rounded, and the words in milliseconds, so the
    /// first word starts 5 ms before the line it belongs to: `[00:21.98]` over
    /// `<00:21.975>`. That read as a word before its own line and refused the
    /// file with `invalidTimestamp`, though it is the one kind of file that
    /// carries real word timing. The fixture is invented; it has that shape,
    /// three-digit fractions and two markers back to back.
    func testAFirstWordAFewMillisecondsBeforeItsRoundedLineStampKeepsItsRealTiming() throws {
        let document = try LocalLyricsDocument.parse(
            "[00:21.98]<00:21.975>alpha <00:22.207>beta <00:22.423>gamma<00:23.071><00:23.247>delta<00:24.119>"
        )
        let line = document.lines[0]
        XCTAssertEqual(line.at, 21.98, accuracy: 0.000_001)
        XCTAssertEqual(line.words.map(\.text), ["alpha ", "beta ", "gamma", "delta"])
        XCTAssertEqual(line.words.map(\.at), [21.975, 22.207, 22.423, 23.247])
        XCTAssertEqual(try XCTUnwrap(line.words[2].end), 23.071, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(line.words[3].end), 24.119, accuracy: 0.000_001)
        XCTAssertEqual(document.granularity, .word)
    }

    /// The allowance is one centisecond, the rounding of the line stamp, and
    /// only for the first word: a word a tenth of a second before its line is
    /// still a mistyped file, and a later word cannot step back past the one
    /// before it.
    func testAWordWellBeforeItsLineStampIsStillRefused() {
        XCTAssertThrowsError(try LocalLyricsDocument.parse("[00:21.98]<00:21.880>alpha <00:22.100>beta")) { error in
            XCTAssertEqual(error as? LocalLyricsDocument.Error, .invalidTimestamp(line: 1))
        }
        XCTAssertThrowsError(try LocalLyricsDocument.parse("[00:21.98]<00:21.975>alpha <00:21.972>beta")) { error in
            XCTAssertEqual(error as? LocalLyricsDocument.Error, .invalidWordOrder(line: 1))
        }
    }
}
