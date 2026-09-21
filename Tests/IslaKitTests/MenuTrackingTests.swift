import XCTest
@testable import IslaKit

/// A menu hanging below the panel holds it open, and its closing hands the
/// pointer back.
@MainActor
final class MenuTrackingTests: XCTestCase {
    func testTheLastMenuClosingIsReportedOnceAndTheCountNeverOwes() {
        let tracking = MenuTracking()
        var closed = 0
        tracking.onAllClosed = { closed += 1 }

        tracking.ended()
        XCTAssertFalse(tracking.isOpen)
        XCTAssertEqual(closed, 0, "an end with no begin is not a menu closing")

        tracking.began()
        tracking.began()
        XCTAssertTrue(tracking.isOpen)
        tracking.ended()
        XCTAssertTrue(tracking.isOpen, "a submenu closing leaves its parent open")
        XCTAssertEqual(closed, 0)
        tracking.ended()
        XCTAssertFalse(tracking.isOpen)
        XCTAssertEqual(closed, 1)
    }

    /// The pointer watcher reads an open menu as it reads a drag: the panel
    /// stands while it tracks.
    func testAnOpenMenuCountsAsHoldingThePanel() {
        let watcher = PointerWatcher()
        var closes = 0
        watcher.isPanelOpen = { true }
        watcher.isDragging = { MenuTracking.shared.isOpen }
        watcher.onChange = { inside in if !inside { closes += 1 } }
        MenuTracking.shared.began()
        defer { MenuTracking.shared.ended() }
        XCTAssertTrue(watcher.isDragging())
    }
}
