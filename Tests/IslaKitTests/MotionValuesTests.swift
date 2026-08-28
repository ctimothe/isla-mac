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
        for animation in [Theme.openAnimation, Theme.compactAnimation] {
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
}
