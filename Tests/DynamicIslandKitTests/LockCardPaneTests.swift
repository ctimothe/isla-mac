import XCTest
@testable import DynamicIslandKit

/// The card is one size in every state, and the lyric window slides rather
/// than clips.
@MainActor
final class LockCardPaneTests: XCTestCase {

    /// The window above the login shield is cut to exactly this and never
    /// resized. A state that needed a different size would have to resize it,
    /// and resizing it across a lock is what stretched the window-server
    /// snapshot into a half-scale card off to one side.
    func testEveryPaneSharesOneSize() {
        XCTAssertEqual(LockScreenCard.size, CGSize(width: 460, height: 300))
        XCTAssertEqual(LockScreenCard.Pane.allCases.count, 3)
    }

    /// A five-line window slid inside the song, not clipped at its ends. At the
    /// first line a clipped window would show three lines and two gaps.
    func testTheLyricWindowStaysFullAtBothEnds() {
        let size = LockScreenCard.visibleLyricLines
        XCTAssertEqual(size, 5)

        XCTAssertEqual(LockScreenCard.window(around: 0, count: 20, size: size), [0, 1, 2, 3, 4])
        XCTAssertEqual(LockScreenCard.window(around: 10, count: 20, size: size), [8, 9, 10, 11, 12])
        XCTAssertEqual(LockScreenCard.window(around: 19, count: 20, size: size), [15, 16, 17, 18, 19])
    }

    /// A song shorter than the window shows all of it and nothing invented.
    func testAShortSongShowsEveryLineItHas() {
        XCTAssertEqual(LockScreenCard.window(around: 1, count: 3, size: 5), [0, 1, 2])
        XCTAssertEqual(LockScreenCard.window(around: 0, count: 1, size: 5), [0])
        XCTAssertEqual(LockScreenCard.window(around: 0, count: 0, size: 5), [])
    }

    /// The centre follows the one rule every lyric surface follows — the same
    /// function the stage calls — including the fallback that keeps a paused
    /// track before its first timestamp from showing nothing.
    func testTheCentreIsTheLineBeingSungOrTheFirstOne() {
        let lines = [
            LyricsStore.Line(at: 1.58, text: "first"),
            LyricsStore.Line(at: 18.2, text: "second"),
            LyricsStore.Line(at: 30, text: "third"),
        ]
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 0), 0, "before the first line")
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 20), 1)
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 999), 2)
        XCTAssertEqual(LyricSweep.centreIndex(in: [], at: 5), 0)
    }
}
