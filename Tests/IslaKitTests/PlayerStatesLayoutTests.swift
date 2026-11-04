import SwiftUI
import XCTest
@testable import IslaKit

/// What is left of the old state table (spec §5.1) after §19: the player `P`
/// is `PlayerLayoutTests`'s, and the lyric column `C` and the tall page `T`
/// were withdrawn (§19.6, §19.11) — the stage is the one lyric surface, with
/// its own frame (`StageLayout`). What outlives them is the lines' ramp, which
/// the stage draws from the same board values and the same contrast floor, and
/// the spring the update card still expands on.
final class PlayerStatesLayoutTests: XCTestCase {

    // MARK: - The lines' ramp

    /// §19.6: lines already sung 0.34 and 0.20 by distance, lines to come 0.50,
    /// 0.32 and 0.18, and the faintest past the board's last row.
    func testTheBoardsOpacities() {
        XCTAssertEqual((-2...3).map { PlayerLayout.boardLyricOpacity(offset: $0) }, [0.20, 0.34, 1, 0.50, 0.32, 0.18])
        XCTAssertEqual(PlayerLayout.boardLyricOpacity(offset: -5), 0.20, "past the board, above")
        XCTAssertEqual(PlayerLayout.boardLyricOpacity(offset: 6), 0.18, "past the board, below")
    }

    /// Under Increase Contrast the contrast floor still wins over the boards
    /// (spec §2.1): no context line is ever drawn under the ramp's floor, the
    /// neighbours under its neighbour step, and the order the board gives —
    /// the next line brighter than the previous — survives where the board
    /// clears the floor. The default setting's dimmer ramp is the next test.
    func testNoContextLineIsDrawnUnderTheContrastFloorUnderIncreaseContrast() {
        for increaseContrast in [true] {
            let ramp = LyricRow.Ramp.panel(increaseContrast: increaseContrast)
            for offset in -6...6 where offset != 0 {
                let drawn = PlayerLayout.lyricOpacity(
                    offset: offset, ramp: ramp, reading: false, increaseContrast: increaseContrast
                )
                let floor = abs(offset) == 1 ? ramp.neighbour : ramp.floor
                XCTAssertGreaterThanOrEqual(drawn, floor, "offset \(offset), contrast \(increaseContrast)")
                XCTAssertLessThan(drawn, 1, "only the sung line is full white")
            }
            XCTAssertEqual(
                PlayerLayout.lyricOpacity(offset: 0, ramp: ramp, reading: false, increaseContrast: increaseContrast), 1
            )
            XCTAssertGreaterThan(
                PlayerLayout.lyricOpacity(offset: 1, ramp: ramp, reading: false, increaseContrast: increaseContrast),
                PlayerLayout.lyricOpacity(offset: -1, ramp: ramp, reading: false, increaseContrast: increaseContrast),
                "the next line is the brightest context line, as the board draws it"
            )
        }
    }

    /// The stage's ramp since 2026-10-25 (owner): the sung line 1.0, the next
    /// 0.45, every line further to come 0.30, every line already sung 0.20.
    func testTheDefaultRampIsOneNinetyFiveThirtyTwenty() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        func drawn(_ offset: Int) -> Double { PlayerLayout.lyricOpacity(offset: offset, ramp: ramp, reading: false) }
        XCTAssertEqual(drawn(0), 1)
        XCTAssertEqual(drawn(1), 0.45)
        XCTAssertEqual([2, 3, 4, 9].map(drawn), [0.30, 0.30, 0.30, 0.30])
        XCTAssertEqual([-1, -2, -3, -9].map(drawn), [0.20, 0.20, 0.20, 0.20])
    }

    /// Increase Contrast keeps the contrast-floor ramp `ContrastRampTests`
    /// guards: the board's values raised to the ramp's floor (0.42) and
    /// neighbour (0.46) steps, the next line still the brightest.
    func testIncreaseContrastKeepsTheContrastFloorRamp() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: true)
        func drawn(_ offset: Int) -> Double {
            PlayerLayout.lyricOpacity(offset: offset, ramp: ramp, reading: false, increaseContrast: true)
        }
        XCTAssertEqual(drawn(-2), 0.42)
        XCTAssertEqual(drawn(-1), 0.46)
        XCTAssertEqual(drawn(1), 0.5)
        XCTAssertEqual(drawn(2), 0.42)
        XCTAssertEqual(drawn(3), 0.42)
        XCTAssertEqual(drawn(4), 0.42)
    }

    /// With nothing lit — an intro, an outro — every line is a context line at
    /// the far step, never the sung line's own full white.
    func testWithNothingLitEveryLineIsAtTheFarStep() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        let drawn = PlayerLayout.lyricOpacity(offset: LyricsStage.unlitOffset, ramp: ramp, reading: false)
        XCTAssertEqual(drawn, 0.30)
        let contrast = LyricRow.Ramp.panel(increaseContrast: true)
        XCTAssertEqual(
            PlayerLayout.lyricOpacity(
                offset: LyricsStage.unlitOffset, ramp: contrast, reading: false, increaseContrast: true
            ),
            contrast.floor
        )
    }

    func testReadingByHandLiftsEveryContextLineToTheReadingStep() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        for offset in [-3, -1, 1, 4] {
            XCTAssertEqual(PlayerLayout.lyricOpacity(offset: offset, ramp: ramp, reading: true), ramp.reading)
        }
    }

    // MARK: - Animation (spec §2.4)

    /// The update card's own expansion keeps the 0.40 critically damped spring
    /// (`Theme.expand`); the body's Expand it was named for is gone, the curve
    /// is not.
    func testTheExpandSpringIsPointFourCriticallyDamped() {
        XCTAssertEqual(Theme.expandResponse, 0.40)
        XCTAssertEqual(Theme.expandAnimation, Animation.spring(response: 0.40, dampingFraction: 1.0))
        XCTAssertTrue(Theme.criticallyDampedSprings.contains(Theme.expandAnimation))
        XCTAssertEqual(Theme.expand(reduceMotion: true), Theme.reducedMotion)
        XCTAssertEqual(Theme.expand(reduceMotion: false), Theme.expandAnimation)
    }
}
