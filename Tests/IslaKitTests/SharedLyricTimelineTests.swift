import Foundation
import XCTest
@testable import IslaKit

/// One timeline, one highlighter, every surface.
@MainActor
final class SharedLyricTimelineTests: XCTestCase {

    private let lines = [
        LyricsStore.Line(at: 1.58, text: "first"),
        LyricsStore.Line(at: 18.2, text: "second"),
        LyricsStore.Line(at: 30, text: "third"),
    ]

    /// There were three binary searches over the same array: `LyricsStore`'s,
    /// the stage's private copy, and the card going through `displayed`. The
    /// copies had drifted on the case that shows most — before the first
    /// timestamp the stage highlighted nothing and the card highlighted the
    /// opening line. Both call this now.
    func testOneSearchAnswersForEverySurface() {
        XCTAssertNil(LyricSweep.index(in: lines, at: 0), "nothing is being sung yet")
        XCTAssertEqual(LyricSweep.index(in: lines, at: 2), 0)
        XCTAssertEqual(LyricSweep.index(in: lines, at: 20), 1)
        XCTAssertEqual(LyricSweep.index(in: lines, at: 9_999), 2)
        XCTAssertNil(LyricSweep.index(in: [], at: 5))
    }

    /// And the "always show something" rule sits on top of it, in one place,
    /// rather than being re-derived per surface.
    func testTheCentreNeverLeavesASurfaceEmpty() {
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 0), 0, "before the first line")
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 20), 1)
        XCTAssertEqual(LyricSweep.centreIndex(in: [], at: 5), 0)
    }

    /// A line ends where the next begins, and the last borrows a spoken length.
    /// Both surfaces used to compute this inline, identically, twice.
    func testALineEndsWhereTheNextBegins() {
        XCTAssertEqual(LyricSweep.end(of: 0, in: lines), 18.2, accuracy: 0.001)
        XCTAssertEqual(LyricSweep.end(of: 1, in: lines), 30, accuracy: 0.001)
        XCTAssertEqual(LyricSweep.end(of: 2, in: lines), 36, accuracy: 0.001)
        XCTAssertEqual(LyricSweep.end(of: 99, in: lines), 0, "out of range answers rather than crashes")
    }

    /// The sweep the highlighter draws comes from the same function on both
    /// surfaces, so a change to word timing lands on both at once.
    func testTheSweepIsOneFunction() {
        let timed = LyricsStore.Line(
            at: 0, text: "one two",
            words: [
                LyricWord(at: 0, text: "one", end: 1),
                LyricWord(at: 1, text: "two", end: 2),
            ]
        )
        XCTAssertEqual(
            LyricSweep.fraction(line: timed, at: 1, end: 2),
            LyricSweep.wordFraction(words: timed.words, at: 1, lineEnd: 2),
            accuracy: 0.0001
        )
    }

    /// The intro, on all three surfaces at once. Before the first timestamp
    /// the stage drew no sung line, the caption drew line 1 unswept, and the
    /// lock card drew line 1 *as sung* — `isCurrent` was the centre, and
    /// `LyricRow` fills a current line-timed row to 1 — for a median 12.9 s of
    /// every track in the lab's 540 (L8: 52,013 disagreements, every one of
    /// them before the first line). One moment answers for all three now:
    /// nothing is current, line 1 is the one shown, and it is not swept.
    func testEverySurfaceAgreesBeforeTheFirstLine() throws {
        let lines = [
            LyricsStore.Line(at: 5, text: "a"),
            LyricsStore.Line(at: 9, text: "b"),
        ]
        // Standard sync, no corrections: the lead is 0.2, so the lyric reads 2.2.
        let inputs = LyricInputs(
            position: 2, precisionSync: false, userOffset: 0, trackOffset: 0, wordTiming: false
        )
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), 0.2, accuracy: 0.0001)

        let stage = LyricsStage.resolve(lines: lines, inputs: inputs)
        XCTAssertNil(stage.current, "the stage lights nothing during the intro")
        XCTAssertEqual(stage.centre, 0, "and waits on the opening line")
        XCTAssertEqual(stage.fraction, 0)

        let card = LockScreenCard.resolve(lines: lines, inputs: inputs)
        XCTAssertNil(card.current, "the card used to call the centre current and fill it")
        XCTAssertEqual(card.centre, 0)
        XCTAssertEqual(card.fraction, 0, "line 1 is not sung yet, so it is not swept")

        let caption = try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs))
        XCTAssertNil(caption.current)
        XCTAssertEqual(caption.centre, 0, "the caption shows the opening line")
        XCTAssertEqual(caption.fraction, 0, "unswept")

        XCTAssertEqual(stage, card)
        XCTAssertEqual(card, caption)
    }

    /// And once the voice is inside a line, all three still say the same:
    /// that line, filled to 1 for line timing, by its word sweep otherwise.
    func testEverySurfaceAgreesInsideALine() throws {
        let lines = [
            LyricsStore.Line(at: 5, text: "a"),
            LyricsStore.Line(
                at: 9, text: "one two",
                words: [LyricWord(at: 9, text: "one", end: 10), LyricWord(at: 10, text: "two", end: 11)]
            ),
        ]
        for wordTiming in [false, true] {
            let inputs = LyricInputs(
                position: 9.8, precisionSync: false, userOffset: 0, trackOffset: 0, wordTiming: wordTiming
            )
            let stage = LyricsStage.resolve(lines: lines, inputs: inputs)
            let card = LockScreenCard.resolve(lines: lines, inputs: inputs)
            let caption = try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs))
            XCTAssertEqual(stage.current, 1)
            XCTAssertEqual(stage.centre, 1)
            XCTAssertEqual(
                stage.fraction,
                wordTiming ? LyricSweep.fraction(line: lines[1], at: 10, end: 15) : 1,
                accuracy: 0.0001
            )
            XCTAssertEqual(stage, card)
            XCTAssertEqual(card, caption)
        }
    }

    /// A credit is never swept, on any surface: a filled sweep across
    /// "Produced by" claims somebody is singing it.
    func testACurrentCreditIsDrawnUnswept() {
        let credit = LyricsStore.Line(at: 0, text: "Produced by Somebody", isCredit: true)
        XCTAssertEqual(LyricSweep.drawnFraction(line: credit, isCurrent: true, at: 3, end: 6, wordTiming: false), 0)
        let sung = LyricsStore.Line(at: 0, text: "la la")
        XCTAssertEqual(LyricSweep.drawnFraction(line: sung, isCurrent: true, at: 3, end: 6, wordTiming: false), 1)
        XCTAssertEqual(LyricSweep.drawnFraction(line: sung, isCurrent: false, at: 3, end: 6, wordTiming: false), 0)
    }

    /// The moment itself: what is current, what a surface centres on, and what
    /// the voice reaches next.
    func testTheMomentNamesCurrentCentreAndUpcoming() {
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 0), LyricMoment(current: nil, centre: 0, upcoming: 0))
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 20), LyricMoment(current: 1, centre: 1, upcoming: 2))
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 999), LyricMoment(current: 2, centre: 2, upcoming: nil))
        XCTAssertEqual(LyricSweep.moment(in: [], at: 5), LyricMoment(current: nil, centre: 0, upcoming: nil))
        // Depth is measured from the sung line; with none sung, every line
        // sits at the far floor rather than the opening line being the
        // dimmest thing beside a brighter neighbour.
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 20).distance(of: 2), 1)
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 0).distance(of: 0), 2)
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 0).distance(of: 1), 2)
    }

    // MARK: - A line ends when its voice does (L-01)

    /// A finished line used to stay lit until the next line's stamp, through
    /// every instrumental: the lab measured a median 28.9 s a track, and 447
    /// mid-song lines lit through more than 8 s of silence. From its end the
    /// line is not current, and the surfaces centre on the line coming.
    func testALineGoesDarkAtItsEnd() {
        let lines = [
            LyricsStore.Line(at: 10, text: "a", end: 15),
            LyricsStore.Line(at: 26.3, text: "b"),
        ]
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 14.9), LyricMoment(current: 0, centre: 0, upcoming: 1))
        XCTAssertEqual(
            LyricSweep.moment(in: lines, at: 15), LyricMoment(current: nil, centre: 1, upcoming: 1),
            "dark on the frame the voice stops"
        )
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 20), LyricMoment(current: nil, centre: 1, upcoming: 1))
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 26.3), LyricMoment(current: 1, centre: 1, upcoming: nil))
        XCTAssertEqual(LyricSweep.effectiveEnd(of: 0, in: lines), 15)
        XCTAssertEqual(LyricSweep.end(of: 0, in: lines), 15, accuracy: 0.0001, "the sweep ends with the voice")
    }

    /// A breath is not a gap. An empty stamp 0.8 s before the next line would
    /// blink the line off and on again, so a gap under `minimumHonouredGap`
    /// keeps the line lit to the next stamp, as before.
    func testAShortBreathKeepsTheLineLit() {
        let lines = [
            LyricsStore.Line(at: 10, text: "a", end: 25.5),
            LyricsStore.Line(at: 26.3, text: "b"),
        ]
        XCTAssertEqual(LyricSweep.minimumHonouredGap, 1.5)
        XCTAssertNil(LyricSweep.effectiveEnd(of: 0, in: lines))
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 25.9).current, 0)
        XCTAssertEqual(LyricSweep.end(of: 0, in: lines), 26.3, accuracy: 0.0001)
        // An end at or before the line's own start, or past the next start,
        // is not an end: a document built in code can hold either.
        XCTAssertNil(LyricSweep.effectiveEnd(of: 0, in: [LyricsStore.Line(at: 10, text: "a", end: 10)]))
        XCTAssertNil(LyricSweep.effectiveEnd(of: 0, in: [
            LyricsStore.Line(at: 10, text: "a", end: 40), LyricsStore.Line(at: 20, text: "b"),
        ]))
    }

    /// The outro: the last line's stamp ends it, and then nothing is sung —
    /// but the caption keeps the last line, unswept, rather than falling back
    /// to a status line ("Finding lyrics…") for the rest of the track.
    func testTheOutroLeavesTheLastLineShownUnswept() throws {
        let lines = [
            LyricsStore.Line(at: 10, text: "a"),
            LyricsStore.Line(at: 20, text: "b", end: 24),
        ]
        XCTAssertEqual(LyricSweep.moment(in: lines, at: 30), LyricMoment(current: nil, centre: 1, upcoming: nil))
        let inputs = LyricInputs(
            position: 30, precisionSync: false, userOffset: 0, trackOffset: 0, wordTiming: false
        )
        let caption = try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs))
        XCTAssertNil(caption.current)
        XCTAssertEqual(caption.centre, 1)
        XCTAssertEqual(caption.fraction, 0)
        XCTAssertEqual(caption, LyricsStage.resolve(lines: lines, inputs: inputs))
        XCTAssertEqual(caption, LockScreenCard.resolve(lines: lines, inputs: inputs))

        // And the Shortcuts action, which reads `displayed`, no longer calls
        // a finished line the one playing.
        let shown = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 30))
        XCTAssertEqual(shown.line.text, "b")
        XCTAssertFalse(shown.swept)
        XCTAssertEqual(shown.end, 24, accuracy: 0.0001)
    }

    /// A bilingual LRC stamps the original and its translation at one time,
    /// and the parser keeps both. Keyed by timestamp, the two rows shared one
    /// id — drawn twice or skipped, and the scroll anchor could not tell them
    /// apart. Keyed by index, every row is its own.
    func testRowsAreKeyedByIndexNotTime() {
        let bilingual = [
            LyricsStore.Line(at: 4, text: "hello"),
            LyricsStore.Line(at: 4, text: "privet"),
            LyricsStore.Line(at: 8, text: "goodbye"),
        ]
        let ids = LyricsStage.rowIDs(bilingual)
        XCTAssertEqual(ids.count, bilingual.count)
        XCTAssertEqual(Set(ids).count, bilingual.count, "two lines at one stamp are two rows")
    }

    func testEveryLocalAvailabilityHasCaptionAndLocalRecoveryAction() {
        let timeline = LyricTimeline(
            lines: [LyricsStore.Line(at: 1, text: "One")],
            granularity: .line
        )
        let states: [LyricsAvailability] = [
            .disabled,
            .findingLocalLyrics,
            .ready(timeline),
            .noLocalLyrics,
            .invalidLocalFile(.malformed),
            .cannotLookUp(.noLength),
            .cannotLookUp(.noTitle),
        ]

        for state in states {
            XCTAssertFalse(LyricsPresentation.compactCaption(for: state, currentLine: nil).isEmpty, "\(state)")
        }
        XCTAssertTrue(LyricsPresentation.canOpenLocalActions(.noLocalLyrics))
        XCTAssertTrue(LyricsPresentation.canOpenLocalActions(.invalidLocalFile(.malformed)))
        // A track that cannot be looked up has no identity to bind a file to.
        XCTAssertFalse(LyricsPresentation.canOpenLocalActions(.cannotLookUp(.noLength)))
        XCTAssertFalse(LyricsPresentation.canOpenLocalActions(.cannotLookUp(.noTitle)))
    }

    func testWordKaraokeDefaultsOffAndPersistsAnExplicitSelection() {
        UserDefaults.standard.removeObject(forKey: LyricsStore.wordKaraokeEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: LyricsStore.wordKaraokeEnabledKey) }

        let lyrics = LyricsStore()
        XCTAssertFalse(lyrics.wordKaraokeEnabled)
        lyrics.wordKaraokeEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: LyricsStore.wordKaraokeEnabledKey))
    }

    /// A word shorter than a frame fills as the clock crosses it (L-11).
    ///
    /// Every word's span was floored at 50 ms, so a 10 ms word had reached
    /// only a fifth of itself when its successor started, and the edge then
    /// leapt the rest in one frame: the lab's L5 measured 0.099 → 0.5 across
    /// 0.1 ms. The true span is used now; it cannot be zero inside that
    /// branch, because the clock is strictly between the word's two edges.
    func testAShortWordFillsContinuously() {
        let blink = [LyricWord(at: 0, text: "ab", end: 0.01), LyricWord(at: 0.01, text: "cd", end: 0.5)]
        let justBefore = LyricSweep.wordFraction(words: blink, at: 0.0099, lineEnd: 0.5)
        XCTAssertGreaterThanOrEqual(justBefore, 0.98 * 0.5, "the short word is 99% sung, half the line's letters")
        XCTAssertLessThanOrEqual(justBefore, 0.5)
        XCTAssertEqual(LyricSweep.wordFraction(words: blink, at: 0.01, lineEnd: 0.5), 0.5, accuracy: 0.0001)
        // Two words stamped at one moment have no span at all: the first is
        // sung the instant the second starts, and nothing divides by zero.
        let stacked = [LyricWord(at: 1, text: "a", end: nil), LyricWord(at: 1, text: "b", end: nil)]
        XCTAssertEqual(LyricSweep.wordFraction(words: stacked, at: 1, lineEnd: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.wordFraction(words: stacked, at: 1.5, lineEnd: 2), 0.75, accuracy: 0.0001)
    }

    /// One line without word timing no longer turns karaoke off for the song
    /// (J-014). Granularity was `.word` only when every line had words, and
    /// the editor drops a line's words when its text is edited, so fixing
    /// one typo made every line light whole. Now the lines that carry words
    /// sweep by them, and a line without any lights whole: the singing-speed
    /// estimate would be timing nobody wrote, so it is never drawn.
    func testOneEditedLineKeepsKaraokeForTheRest() throws {
        let document = try LocalLyricsDocument.parse("""
        [00:01.00]<00:01.00>one <00:01.50>two
        [00:03.00]typo fixed here
        [00:05.00]<00:05.00>three <00:05.50>four
        """)
        XCTAssertEqual(document.granularity, .word)
        XCTAssertTrue(LyricsPresentation.usesWordTiming(
            document.granularity, precisionMeasured: true, wordKaraokeEnabled: true
        ))

        let wordless = document.lines[1]
        XCTAssertTrue(wordless.words.isEmpty)
        XCTAssertEqual(
            LyricSweep.drawnFraction(line: wordless, isCurrent: true, at: 3.1, end: 5, wordTiming: true), 1,
            "a line with no word timing lights whole, never by an estimate"
        )
        let timed = LyricSweep.drawnFraction(
            line: document.lines[0], isCurrent: true, at: 1.25, end: 3, wordTiming: true
        )
        XCTAssertGreaterThan(timed, 0)
        XCTAssertLessThan(timed, 1)
    }

    func testWordKaraokeRequiresPreferenceWordTimelineAndMeasuredClock() {
        XCTAssertFalse(LyricsPresentation.usesWordTiming(.word, precisionMeasured: true, wordKaraokeEnabled: false))
        XCTAssertFalse(LyricsPresentation.usesWordTiming(.line, precisionMeasured: true, wordKaraokeEnabled: true))
        XCTAssertFalse(LyricsPresentation.usesWordTiming(.word, precisionMeasured: false, wordKaraokeEnabled: true))
        XCTAssertTrue(LyricsPresentation.usesWordTiming(.word, precisionMeasured: true, wordKaraokeEnabled: true))
    }
}
