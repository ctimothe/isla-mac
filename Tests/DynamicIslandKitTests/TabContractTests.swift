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
        XCTAssertEqual(
            PrivacyMode.Section.allCases.map(\.rawValue).sorted(),
            ["clipboard", "notes"]
        )
    }
}
