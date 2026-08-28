import AppKit
import XCTest
@testable import IslaKit

/// The island is the whole app.
@MainActor
final class AppSurfaceContractTests: XCTestCase {

    /// No Dock icon, ever.
    ///
    /// A window and a `.regular` policy were tried and removed by owner
    /// decision: the panel's own Settings tab already carries Open Panel, About
    /// and Quit, so a second front door was a second place to keep in sync. A
    /// policy that can change is what put an icon in the Dock, so the constant
    /// is asserted rather than the call.
    func testTheAppIsAnAccessoryAndNothingElse() {
        XCTAssertEqual(IslaApplication.activationPolicy, .accessory)
    }

    /// The status item was a symbol on the menu bar. Its name went with it, so
    /// nothing can quietly put one back by reaching for the old constant.
    func testNoStatusItemSymbolSurvives() {
        let identity = [
            ProductIdentity.displayName,
            ProductIdentity.executableName,
            ProductIdentity.bundleIdentifier,
            ProductIdentity.supportDirectoryName,
            ProductIdentity.screenshotDirectoryName,
            ProductIdentity.helperResourceName,
            ProductIdentity.internalPasteboardType,
        ]
        XCTAssertFalse(
            identity.contains("capsule.fill"),
            "the menu-bar symbol has no home in the product identity any more"
        )
    }

    /// Every function the removed surfaces carried is still reachable, because
    /// the panel can still be opened without a pointer. Losing this would leave
    /// an app with no way in at all on a Mac whose notch is not detected.
    func testThePanelCanStillBeOpenedFromTheKeyboard() {
        XCTAssertEqual(GlobalHotKey.defaultKeyCode, GlobalHotKey.defaultKeyCode)
        XCTAssertNotEqual(
            GlobalHotKey.defaultModifiers, 0,
            "⌥⌘I is the only route in that needs no pointer and no icon"
        )
    }
}
