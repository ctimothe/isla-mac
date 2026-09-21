import AppKit
import XCTest
@testable import IslaKit

/// A menu hanging below the panel holds it open, its closing hands the pointer
/// back, and nothing can make the hold outlive the menu.
@MainActor
final class MenuTrackingTests: XCTestCase {
    // Held for the life of the test: an identifier is an address, and two
    // menus freed at once can come back at the same one.
    private let menus = [NSMenu(title: "first"), NSMenu(title: "second")]
    private var first: ObjectIdentifier { ObjectIdentifier(menus[0]) }
    private var second: ObjectIdentifier { ObjectIdentifier(menus[1]) }

    func testTheLastMenuClosingIsReportedOnceAndStrangersChangeNothing() {
        let tracking = MenuTracking()
        var closed = 0
        tracking.onAllClosed = { closed += 1 }

        tracking.ended(first)
        XCTAssertFalse(tracking.hasOpenMenus)
        XCTAssertEqual(closed, 0, "a close for a menu never seen opening is not a menu closing")

        tracking.began(first)
        tracking.began(second)
        tracking.ended(second)
        XCTAssertTrue(tracking.hasOpenMenus, "a submenu closing leaves its parent open")
        XCTAssertEqual(closed, 0)
        tracking.ended(second)
        XCTAssertEqual(closed, 0, "the same close twice counts once")
        tracking.ended(first)
        XCTAssertFalse(tracking.hasOpenMenus)
        XCTAssertEqual(closed, 1)
    }

    /// A lost "closed" notice must not hold the panel forever: outside the
    /// run loop's tracking mode a counted menu holds nothing, and folding the
    /// panel forgets it.
    func testALeakedOpeningHoldsNothingOnceTrackingIsOver() {
        let tracking = MenuTracking()
        tracking.began(first)
        XCTAssertTrue(tracking.hasOpenMenus)
        XCTAssertNotEqual(RunLoop.main.currentMode, .eventTracking)
        XCTAssertFalse(tracking.isOpen, "no menu is tracking, whatever the count says")
        tracking.reset()
        XCTAssertFalse(tracking.hasOpenMenus)
    }
}
