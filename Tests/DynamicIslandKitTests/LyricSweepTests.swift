import XCTest
@testable import DynamicIslandKit

/// One clock for every lyric surface.
@MainActor
final class LyricSweepTests: XCTestCase {

    /// The caption used to read the lead without the listener's own correction
    /// and the lock card hardcoded `+ 0.25`, consulting neither the correction
    /// nor the precision flag. So nudging Sync on the stage moved the stage and
    /// left the other two pointing at the line before.
    func testTheListenerCorrectionAndThePrecisionFlagReachEverySurface() {
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), 0.45, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: -0.4), -0.15, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 1.2), 1.65, accuracy: 0.0001)
        XCTAssertEqual(
            LyricSweep.position(10, precisionSync: true, userOffset: 0.5), 10.75, accuracy: 0.0001
        )
    }

    /// Word timing wins wherever a source carried it; the singing-speed estimate
    /// is only for lines that never got any.
    func testWordTimingWinsOverTheEstimate() {
        let timed = LyricsStore.Line(
            at: 0,
            text: "one two",
            words: [
                WordSyncedLyrics.Word(at: 0, text: "one", end: 1),
                WordSyncedLyrics.Word(at: 1, text: "two", end: 2),
            ]
        )
        XCTAssertEqual(
            LyricSweep.fraction(line: timed, at: 1, end: 2),
            WordSyncedLyrics.wordFraction(words: timed.words, at: 1, lineEnd: 2),
            accuracy: 0.0001
        )

        let untimed = LyricsStore.Line(at: 0, text: "one two")
        let span = LyricsStore.sweepSpan(text: untimed.text, slot: 2)
        XCTAssertEqual(LyricSweep.fraction(line: untimed, at: 1, end: 2), 1 / span, accuracy: 0.0001)
    }

    func testTheFractionNeverLeavesZeroToOne() {
        let line = LyricsStore.Line(at: 10, text: "a line of words")
        XCTAssertEqual(LyricSweep.fraction(line: line, at: 0, end: 20), 0, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.fraction(line: line, at: 9_999, end: 20), 1, accuracy: 0.0001)
    }

    /// The frozen-position case, which is what "pause it and the words go" was.
    func testAPositionBeforeTheFirstLineStillHasSomethingToShow() throws {
        let lines = [
            LyricsStore.Line(at: 1.58, text: "first"),
            LyricsStore.Line(at: 18.2, text: "second"),
        ]
        let early = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 0.4))
        XCTAssertEqual(early.line.text, "first")
        XCTAssertFalse(early.swept)
        XCTAssertEqual(early.end, 18.2, accuracy: 0.0001)
    }
}
