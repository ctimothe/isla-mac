import SwiftUI
import XCTest
@testable import IslaKit

/// The display accessibility settings this app is obliged to answer.
@MainActor
final class AccessibilityDisplayTests: XCTestCase {

    private func style(samplesBackdrop: Bool = true) -> GlassSurfaceStyle {
        GlassSurfaceStyle(
            cornerRadius: 30, elevation: .card, tint: nil, light: nil,
            samplesBackdrop: samplesBackdrop, preferDrawn: false
        )
    }

    /// Reduce Transparency ends the glass, whatever else is true.
    ///
    /// The system's own surfaces go opaque when it is on, and a panel that
    /// stayed translucent would be the only frosted thing left on screen. For
    /// some people the setting is not taste — translucency is unreadable.
    func testReduceTransparencyTurnsOffTheGlass() {
        let appearance = SystemAppearance.shared
        if appearance.reduceTransparency {
            XCTAssertFalse(style().usesSystemGlass, "no glass while the setting is on")
            XCTAssertTrue(style().isOpaque)
        } else {
            // The machine running the tests has it off, so the inverse is what
            // can be asserted here without lying about what was checked.
            XCTAssertTrue(style().isOpaque == false)
            let expected: Bool
            if #available(macOS 26.0, *) { expected = true } else { expected = false }
            XCTAssertEqual(style().usesSystemGlass, expected)
        }
    }

    /// The three settings are read from `NSWorkspace`, which is the only place
    /// two of them exist on macOS — SwiftUI's environment carries Reduce Motion
    /// and nothing else.
    func testTheSettingsAreReadFromTheSystem() {
        let workspace = NSWorkspace.shared
        let appearance = SystemAppearance.shared
        XCTAssertEqual(appearance.reduceTransparency, workspace.accessibilityDisplayShouldReduceTransparency)
        XCTAssertEqual(appearance.increaseContrast, workspace.accessibilityDisplayShouldIncreaseContrast)
        XCTAssertEqual(appearance.reduceMotion, workspace.accessibilityDisplayShouldReduceMotion)
    }

    /// A surface with nothing behind it never used the material anyway, and
    /// that stays true whatever the settings say.
    func testASurfaceWithNoBackdropIsUnaffected() {
        XCTAssertFalse(style(samplesBackdrop: false).usesSystemGlass)
    }
}
