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
                WordSyncedLyrics.Word(at: 0, text: "one", end: 1),
                WordSyncedLyrics.Word(at: 1, text: "two", end: 2),
            ]
        )
        XCTAssertEqual(
            LyricSweep.fraction(line: timed, at: 1, end: 2),
            WordSyncedLyrics.wordFraction(words: timed.words, at: 1, lineEnd: 2),
            accuracy: 0.0001
        )
    }
}
