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
    @MainActor
    func testTheLineTurnTravelsWithinTheCaptionSlot() {
        XCTAssertLessThan(LyricLineTurn.travel, MediaPane.captionHeight / 2,
                          "the turn must settle before the clip takes it")
        XCTAssertGreaterThanOrEqual(LyricLineTurn.travel, 3, "a turn, not a shiver")
        // Both ends of the modifier: gone and arrived.
        XCTAssertEqual(LyricLineTurn(progress: 1, direction: 1).progress, 1)
        XCTAssertEqual(LyricLineTurn(progress: 0, direction: -1).progress, 0)
    }

    /// The caption's line turn never prints two legible lines on top of each
    /// other (H-014).
    ///
    /// Both lines used to ride the one lyric spring (0.42 s, ζ 0.86), so the
    /// line leaving and the line arriving crossed at the same moment: from 62
    /// to 158 ms both were at least a quarter opaque, under up to 3 pt of
    /// blur, and the visual lab's keyframes t083–t200 showed the smear on
    /// every line. Now the outgoing line leaves on a quick spring of its own
    /// and the incoming one follows behind a short delay, the same out-fast,
    /// in-behind rule the pill's content uses.
    ///
    /// Read from the closed form of a critically damped spring started at
    /// rest — what is left of the travel at t is `e^(−ωt)(1 + ωt)`, ω =
    /// 2π/response — scanned in 1 ms steps over the whole turn. The opacity
    /// of `LyricLineTurn` is `1 − progress`, so the outgoing line's opacity
    /// *is* that remainder and the incoming line's is its complement.
    func testTheCaptionTurnNeverOverprints() {
        func remaining(_ t: Double, response: Double) -> Double {
            guard t > 0 else { return 1 }
            let omega = 2 * Double.pi / response
            return exp(-omega * t) * (1 + omega * t)
        }
        func outgoing(_ t: Double) -> Double { remaining(t, response: Theme.captionTurnOutResponse) }
        func incoming(_ t: Double) -> Double {
            1 - remaining(t - Theme.captionTurnInDelay, response: Theme.captionTurnInResponse)
        }

        let overprinted = (0...600).map { Double($0) / 1000 }.filter { t in
            outgoing(t) >= 0.25 && incoming(t) >= 0.25
        }
        XCTAssertTrue(overprinted.isEmpty,
                      "both lines at least a quarter opaque for \(overprinted.count) ms, from \(overprinted.first ?? 0) s")
        XCTAssertGreaterThanOrEqual(incoming(0.120), 0.5, "the new line is legible by 120 ms")
        XCTAssertLessThan(outgoing(0.120), 0.1, "and the old one is all but gone by then")
        XCTAssertLessThanOrEqual(LyricLineTurn.maxBlur, 2,
                                 "a turn softens the line; 3 pt smeared it")
        // Out faster than in, or the old line is still there when the new
        // one lands on it.
        XCTAssertLessThan(Theme.captionTurnOutResponse, Theme.captionTurnInResponse)
        XCTAssertGreaterThan(Theme.captionTurnInDelay, 0)
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
