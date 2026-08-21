import XCTest
@testable import DynamicIslandKit

@MainActor
final class TabContractTests: XCTestCase {
    func testRailsExposeAllParityFeaturesInStableOrder() {
        XCTAssertEqual(
            NotchViewModel.Tab.leftRail,
            [.media, .shelf, .clipboard, .translate]
        )
        XCTAssertEqual(
            NotchViewModel.Tab.rightRail,
            [.notes, .teleprompter, .settings]
        )
        XCTAssertEqual(
            NotchViewModel.Tab.allCases.filter(\.needsKeyboard),
            [.translate, .notes]
        )
    }

    /// Snippets and Calendar were dropped from the product deliberately, not
    /// hidden: no tab, no privacy section, and — the part with teeth — no
    /// calendar entitlement to justify. A tab reappearing would be a
    /// regression, so the absence is asserted rather than assumed.
    func testDroppedFeaturesAreAbsentEntirely() {
        XCTAssertEqual(
            NotchViewModel.Tab.allCases.map(\.rawValue).sorted(),
            ["clipboard", "media", "notes", "settings", "shelf", "teleprompter", "translate"]
        )
        // Translate joined the covers because ⌥⌘T puts the clipboard's
        // contents into its field verbatim — covering the clipboard tab while
        // that pane showed the same text in full was a hole in the promise.
        XCTAssertEqual(
            PrivacyMode.Section.allCases.map(\.rawValue).sorted(),
            ["clipboard", "notes", "translate"]
        )
    }
}
