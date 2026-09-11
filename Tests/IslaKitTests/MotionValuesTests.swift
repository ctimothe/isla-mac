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
}
