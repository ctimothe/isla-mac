import AppKit
import XCTest
@testable import IslaKit

/// The island is the whole app.
@MainActor
final class AppSurfaceContractTests: XCTestCase {

    /// No Dock icon, ever.
    ///
    /// A window and a `.regular` policy were tried and removed by owner
    /// decision: the panel already carries About and Quit in Settings, and
    /// since R8 the island's right-click menu offers Settings… and Quit Isla
    /// from any state (spec §19.9), so a second front door was a second place
    /// to keep in sync. A policy that can change is what put an icon in the
    /// Dock, so the constant is asserted rather than the call.
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
        XCTAssertNotEqual(
            HotKeyAction.openPanel.defaultBinding.modifiers, 0,
            "the open shortcut is the only route in that needs no pointer and no icon"
        )
    }

    /// A Shelf card or a lyrics folder can live on an external disk or a
    /// network share, and macOS asks before Isla reads either. With no usage
    /// string declared, that prompt carried no reason at all (J-021); with one
    /// declared, `test-localizations.sh` holds the en and ru rows to it.
    func testInfoPlistDeclaresVolumeUsageStrings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundle = try String(
            contentsOf: root.appendingPathComponent("Scripts/bundle.sh"), encoding: .utf8
        )
        for key in ["NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription"] {
            XCTAssertTrue(bundle.contains("<key>\(key)</key>"), "Info.plist must declare \(key)")
        }
    }
}
