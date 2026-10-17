import AppKit
import XCTest
@testable import IslaKit

/// ⌘, opens Settings while a surface has the keyboard (spec §19.1). The panel
/// is key only on Clipboard and Translate, and an `.accessory` app has no menu
/// bar to carry the shortcut, so the panel reads the press itself.
@MainActor
final class SettingsKeyTests: XCTestCase {
    func testCommandCommaIsTheSettingsKey() {
        XCTAssertTrue(NotchPanel.isSettingsKey(keyCode: 43, characters: ",", flags: .command))
        // Caps Lock is not a modifier anyone meant.
        XCTAssertTrue(NotchPanel.isSettingsKey(keyCode: 43, characters: ",", flags: [.command, .capsLock]))
    }

    func testOtherModifiersAreNotTheSettingsKey() {
        for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertFalse(NotchPanel.isSettingsKey(keyCode: 43, characters: ",", flags: flags), "\(flags)")
        }
    }

    func testTheCommaFollowsTheLabelNotThePosition() {
        // A layout whose comma sits elsewhere: the printed comma wins, and
        // the US comma's key printing something else is not Settings.
        XCTAssertTrue(NotchPanel.isSettingsKey(keyCode: 46, characters: ",", flags: .command))
        XCTAssertFalse(NotchPanel.isSettingsKey(keyCode: 43, characters: "m", flags: .command))
    }

    func testANonLatinLayoutFallsBackToThePosition() {
        // Russian prints б on the US comma's key.
        XCTAssertTrue(NotchPanel.isSettingsKey(keyCode: 43, characters: "б", flags: .command))
        XCTAssertFalse(NotchPanel.isSettingsKey(keyCode: 47, characters: "ю", flags: .command))
    }

    func testARealEventReachesTheSeamAndNotTheField() throws {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        var asked = 0
        panel.settingsKeyHandled = { asked += 1; return true }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43
        ))
        panel.sendEvent(event)
        XCTAssertEqual(asked, 1)
    }
}
