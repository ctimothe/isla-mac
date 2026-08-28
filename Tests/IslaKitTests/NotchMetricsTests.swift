import CoreGraphics
import XCTest
@testable import IslaKit

final class NotchMetricsTests: XCTestCase {
    func testApprovedGeometryAndTimingDriveTheShell() {
        XCTAssertEqual(NotchMetrics.standardBody, CGSize(width: 620, height: 208))
        XCTAssertEqual(NotchMetrics.teleprompterBody, CGSize(width: 620, height: 400))
        XCTAssertEqual(NotchMetrics.maximumWindow, CGSize(width: 700, height: 444))
        XCTAssertEqual(NotchMetrics.openDelay, 0.05)
        XCTAssertEqual(NotchMetrics.closeDelay, 0.32)
        XCTAssertEqual(NotchMetrics.tabDwell, 0.15)
        XCTAssertEqual(NotchMetrics.fastPointerInterval, 1.0 / 60.0)
        XCTAssertEqual(NotchMetrics.idlePointerInterval, 1.0 / 8.0)
        XCTAssertEqual(NotchMetrics.restThreshold, 3.0)
        XCTAssertEqual(NotchMetrics.warmZoneHeight, 260)
        XCTAssertEqual(NotchMetrics.coolMargin, 80)
        XCTAssertEqual(NotchMetrics.collapseRectShrinkDelay, 0.45)
        XCTAssertEqual(NotchMetrics.pointerAwayCollapseDelay, 0.6)
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
