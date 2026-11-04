import AppKit
import XCTest
@testable import IslaKit

/// A setting a test pins stays pinned until the test hands it back.
///
/// On 2026-11-04 the release build on CI's macOS 26 runner, which runs with
/// Reduce Motion on, failed `IslandOutlineIntegrationTests` with the outline
/// asking for the 0.24 ease, Reduce Motion's curve, although the test had
/// pinned full motion in its `setUp`. The system posts
/// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` for display
/// options none of these track as well, and the refresh it triggered read the
/// runner's own setting back over the pin, so any test could lose its pin
/// halfway through on a Mac whose settings differ from the pin.
@MainActor
final class SystemAppearanceTests: XCTestCase {
    private let workspace = NSWorkspace.shared
    private let appearance = SystemAppearance.shared

    override func tearDown() {
        SystemAppearance.shared.resetForTests()
        super.tearDown()
    }

    private func postDisplayOptionsChange() {
        workspace.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testAPinnedSettingSurvivesTheSystemsNotification() {
        // The opposite of this Mac's own, so a re-read would show.
        let motion = !workspace.accessibilityDisplayShouldReduceMotion
        let transparency = !workspace.accessibilityDisplayShouldReduceTransparency
        let contrast = !workspace.accessibilityDisplayShouldIncreaseContrast
        appearance.overrideForTests(reduceTransparency: transparency, increaseContrast: contrast, reduceMotion: motion)
        postDisplayOptionsChange()
        XCTAssertEqual(appearance.reduceMotion, motion, "Reduce Motion went back to the Mac's own")
        XCTAssertEqual(appearance.reduceTransparency, transparency, "Reduce Transparency went back to the Mac's own")
        XCTAssertEqual(appearance.increaseContrast, contrast, "Increase Contrast went back to the Mac's own")
    }

    /// A pin holds the setting it names; the others go on following the Mac.
    func testOnlyThePinnedSettingIsHeld() {
        let motion = !workspace.accessibilityDisplayShouldReduceMotion
        appearance.overrideForTests(reduceMotion: motion)
        postDisplayOptionsChange()
        XCTAssertEqual(appearance.reduceMotion, motion)
        XCTAssertEqual(appearance.reduceTransparency, workspace.accessibilityDisplayShouldReduceTransparency)
        XCTAssertEqual(appearance.increaseContrast, workspace.accessibilityDisplayShouldIncreaseContrast)
    }

    /// Handing the pins back reads the Mac again, and later notifications
    /// keep following it.
    func testResetHandsTheSettingsBackToTheMac() {
        let own = workspace.accessibilityDisplayShouldReduceMotion
        appearance.overrideForTests(reduceMotion: !own)
        appearance.resetForTests()
        XCTAssertEqual(appearance.reduceMotion, own)
        postDisplayOptionsChange()
        XCTAssertEqual(appearance.reduceMotion, own)
    }
}
