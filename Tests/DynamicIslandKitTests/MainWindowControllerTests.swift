import AppKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class MainWindowControllerTests: XCTestCase {

    /// Accessory while the window is shut, regular while it is open.
    ///
    /// An app with a window and no Dock icon is one you cannot get back to once
    /// something covers it — no icon to click, no app to switch to. An accessory
    /// app carrying a permanent Dock icon is a menu-bar utility lying about what
    /// it is. The policy belongs to the window, so it moves with it.
    func testTheDockIconFollowsTheWindow() {
        XCTAssertEqual(MainWindowController.policy(windowOpen: false), .accessory)
        XCTAssertEqual(MainWindowController.policy(windowOpen: true), .regular)
    }

    /// The status item is a button now, and pressing it twice must not build a
    /// second window. The window survives its own close for the same reason —
    /// `isReleasedWhenClosed` off — so the second press has something to reopen.
    func testTheWindowIsBuiltOnceAndReused() throws {
        let controller = MainWindowController()
        controller.presentForTesting()
        let first = try XCTUnwrap(controller.windowForTesting)
        controller.presentForTesting()
        XCTAssertTrue(first === controller.windowForTesting, "a second press must reuse the window")
        XCTAssertFalse(first.isReleasedWhenClosed, "it has to survive being closed")
        XCTAssertEqual(first.title, ProductIdentity.displayName)
        XCTAssertTrue(first.styleMask.contains(.closable))
        XCTAssertTrue(first.styleMask.contains(.resizable))
    }

    /// Nothing the window does may drag the panel into the activation story: the
    /// panel is non-activating and must never become main, however key the window
    /// beside it is.
    func testThePanelStaysOutOfTheActivationStory() {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40))
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.canBecomeKey, "not until a tab asks for the keyboard")
    }

    /// Every function the status menu carried has somewhere to be. The version
    /// line and the privacy switches live in the window, Open Panel in both, and
    /// Quit in the app menu — which exists only because the app goes `.regular`.
    func testTheWindowKnowsHowToReachTheIsland() {
        var toggled = 0
        let controller = MainWindowController()
        controller.actions = MainWindowController.Actions(
            togglePanel: { toggled += 1 },
            privacy: { nil }
        )
        controller.actions.togglePanel()
        XCTAssertEqual(toggled, 1)
        XCTAssertNil(controller.actions.privacy())
        XCTAssertEqual(MainWindowView.Section.allCases.map(\.rawValue), ["island", "about"])
    }
}
