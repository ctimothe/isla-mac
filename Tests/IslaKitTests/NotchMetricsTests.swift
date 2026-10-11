import CoreGraphics
import XCTest
@testable import IslaKit

final class NotchMetricsTests: XCTestCase {
    func testApprovedGeometryAndTimingDriveTheShell() {
        XCTAssertEqual(NotchMetrics.standardBody, CGSize(width: 620, height: 208))
        XCTAssertEqual(NotchMetrics.tallestBody, CGSize(width: 620, height: 400))
        XCTAssertEqual(NotchMetrics.maximumWindow, CGSize(width: 700, height: 444))
        XCTAssertEqual(NotchMetrics.openDelay, 0.05)
        XCTAssertEqual(NotchMetrics.closeDelay, 0.32)
        XCTAssertEqual(NotchMetrics.fastPointerInterval, 1.0 / 60.0)
        XCTAssertEqual(NotchMetrics.idlePointerInterval, 1.0 / 8.0)
        XCTAssertEqual(NotchMetrics.restThreshold, 3.0)
        XCTAssertEqual(NotchMetrics.warmZoneHeight, 260)
        XCTAssertEqual(NotchMetrics.coolMargin, 80)
        XCTAssertEqual(NotchMetrics.collapseRectShrinkDelay, 0.45)
        XCTAssertEqual(NotchMetrics.pointerAwayCollapseDelay, 0.6)
    }

    /// `verifySyntheticNotch` ran only from `install()`, so a display change or
    /// a wake that rebuilt the panel while the built-in display was still
    /// settling drew the synthetic pill on a notched Mac for the rest of the
    /// session (F-047). Every synthetic build now asks again, twice; a build
    /// that a newer one superseded, or one that found the physical notch,
    /// asks nothing — which is also what bounds a rebuild storm to one pair of
    /// looks per live build.
    func testASyntheticBuildSchedulesItsOwnRecheck() {
        XCTAssertEqual(
            NotchController.syntheticRecheckDelays(isPhysical: false, generation: 2, current: 2),
            [1.5, 5.0]
        )
        XCTAssertEqual(
            NotchController.syntheticRecheckDelays(isPhysical: false, generation: 2, current: 3), []
        )
        XCTAssertEqual(
            NotchController.syntheticRecheckDelays(isPhysical: true, generation: 2, current: 2), []
        )
    }

    /// `NotchGeometry.windowSize` used to return a locally computed `size`
    /// that only matched `NotchMetrics.maximumWindow` because of an
    /// `assert()` — which vanishes in Release builds, so the contract held
    /// only in debug. It must return the constant unconditionally.
    @MainActor
    func testWindowSizeAlwaysReturnsTheMaximumWindowContract() {
        // Optional since the geometry has no screen to describe while the
        // system reports none — a real window during display reconfiguration.
        // A test host always has one.
        XCTAssertEqual(NotchGeometry.current()?.windowSize, NotchMetrics.maximumWindow)
    }
}
