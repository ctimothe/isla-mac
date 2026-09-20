import SwiftUI
import XCTest
@testable import IslaKit

/// Motion values, held to Apple's own rule.
final class MotionValuesTests: XCTestCase {

    /// From *Designing Fluid Interfaces*: damping starts at 1.0, and overshoot
    /// is added **only** when the gesture carried momentum. Nothing the island
    /// does is thrown — it opens from a click and the pill resizes because a
    /// track changed — so nothing here should bounce.
    ///
    /// Asserted as the description string because `Animation` exposes no
    /// parameters to read back. Crude, and still the only thing standing
    /// between this file and a bounce creeping back in.
    func testNothingWithoutMomentumOvershoots() {
        for animation in Theme.criticallyDampedSprings {
            let described = String(describing: animation)
            XCTAssertTrue(
                described.contains("dampingFraction: 1.0"),
                "critically damped, per Apple's default: \(described)"
            )
        }
    }

    /// Reduce Motion still means no spring at all, which no damping value fixes.
    func testReduceMotionReplacesTheSpringEntirely() {
        let reduced = String(describing: Theme.open(reduceMotion: true))
        XCTAssertFalse(reduced.contains("spring"), "a spring is travel, and that is what was refused")
    }

    /// The page is carried by the song, so this is the one animation in the app
    /// entitled to overshoot: the words have momentum the way a flick does. It
    /// also has to be slower than the sweep it carries — borrowing the generic
    /// 0.16s content ease made the page arrive before the voice did.
    func testTheLyricScrollIsSlowerThanTheWordSweepAndMayOvershoot() {
        XCTAssertGreaterThan(Theme.lyricScrollResponse, 0.25,
                             "the page must not outrun the word sweep it carries")
        XCTAssertLessThan(Theme.lyricScrollDamping, 1.0,
                          "carried by momentum, so a small overshoot is correct here")
        XCTAssertGreaterThan(Theme.lyricScrollDamping, 0.75,
                             "a small overshoot, not a wobble")
    }

    /// The caption's line turn stays inside its slot. The travel is clipped at
    /// the slot's edge, so a travel past half the slot would have the arriving
    /// line cut off mid-glyph before it settled; and it is a real travel, not a
    /// crossfade wearing an offset — under 3 pt reads as a shiver.
    func testTheLineTurnTravelsWithinTheCaptionSlot() {
        XCTAssertLessThan(LyricLineTurn.travel, MediaPane.captionHeight / 2,
                          "the turn must settle before the clip takes it")
        XCTAssertGreaterThanOrEqual(LyricLineTurn.travel, 3, "a turn, not a shiver")
        // Both ends of the modifier: gone and arrived.
        XCTAssertEqual(LyricLineTurn(progress: 1, direction: 1).progress, 1)
        XCTAssertEqual(LyricLineTurn(progress: 0, direction: -1).progress, 0)
    }

    /// The published position is what a lyric reads, so the tick interval *is*
    /// how stale the words on screen can be — not merely how smoothly the
    /// scrubber advances.
    ///
    /// Measured, not reasoned: at the old quarter-second the live Spotify probe
    /// put the lyric surface's 95th-percentile error at 0.167 s against a
    /// 0.150 s gate, with a bias near zero — the whole failure was the spread
    /// this interval creates. At a tenth of a second the same run measured
    /// 0.074 s and 0.083 s. The lead can only centre the error; only this can
    /// narrow it, so the two together must stay under the gate.
    @MainActor
    func testThePositionTickIsFineEnoughForTheWordTimingGate() {
        XCTAssertLessThanOrEqual(
            MediaController.positionTickInterval, 0.1,
            "a coarser tick puts the lyric surface's p95 back over the 150ms gate"
        )
        // And the lead is what centres the residual. The probe measured the
        // clock a median 0.188 s behind; the lead must stay within a tick of
        // cancelling that, or the bias re-opens what the interval just closed.
        XCTAssertEqual(
            LyricSweep.standardLead, 0.20, accuracy: 0.05,
            "the lead centres the measured lag; re-run Scripts/measure-sync.sh before moving it"
        )
    }
}
