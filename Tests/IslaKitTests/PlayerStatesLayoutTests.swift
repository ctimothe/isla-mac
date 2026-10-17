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

    /// The contrast floor wins over the boards (spec §2.1): no context line is
    /// ever drawn under the ramp's floor, the neighbours under its neighbour
    /// step, and the order the board gives — the next line brighter than the
    /// previous — survives where the board clears the floor.
    func testNoContextLineIsDrawnUnderTheContrastFloor() {
        for increaseContrast in [false, true] {
            let ramp = LyricRow.Ramp.panel(increaseContrast: increaseContrast)
            for offset in -6...6 where offset != 0 {
                let drawn = PlayerLayout.lyricOpacity(offset: offset, ramp: ramp, reading: false)
                let floor = abs(offset) == 1 ? ramp.neighbour : ramp.floor
                XCTAssertGreaterThanOrEqual(drawn, floor, "offset \(offset), contrast \(increaseContrast)")
                XCTAssertLessThan(drawn, 1, "only the sung line is full white")
            }
            XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 0, ramp: ramp, reading: false), 1)
            XCTAssertGreaterThan(
                PlayerLayout.lyricOpacity(offset: 1, ramp: ramp, reading: false),
                PlayerLayout.lyricOpacity(offset: -1, ramp: ramp, reading: false),
                "the next line is the brightest context line, as the board draws it"
            )
        }
    }

    /// Where the contrast floor raised the board — the values the spec asked
    /// to be named: −2 (0.20 → 0.36), −1 (0.34 → 0.42), +2 (0.32 → 0.36) and
    /// +3 (0.18 → 0.36) are raised; +1 (0.50) clears.
    func testTheValuesTheFloorRaisedAreTheOnesBelowIt() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: -2, ramp: ramp, reading: false), 0.36)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: -1, ramp: ramp, reading: false), 0.42)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 1, ramp: ramp, reading: false), 0.5)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 2, ramp: ramp, reading: false), 0.36)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 3, ramp: ramp, reading: false), 0.36)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 4, ramp: ramp, reading: false), 0.36)
    }

    /// With nothing lit — an intro, an outro — every line is a context line at
    /// the far floor, never the sung line's own full white.
    func testWithNothingLitEveryLineIsAtTheFarFloor() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        let drawn = PlayerLayout.lyricOpacity(offset: LyricsStage.unlitOffset, ramp: ramp, reading: false)
        XCTAssertEqual(drawn, ramp.floor)
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
