import CoreGraphics
import XCTest
@testable import DynamicIslandKit

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
    }
}
