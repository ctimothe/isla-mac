import XCTest
@testable import IslaKit

@MainActor
final class TabContractTests: XCTestCase {
    func testTheRailCarriesTheContentTabsThenSettings() {
        XCTAssertEqual(
            NotchViewModel.Tab.contentTabs,
            [.media, .shelf, .clipboard, .translate]
        )
        XCTAssertEqual(NotchViewModel.Tab.utilityTabs, [.settings])
        // Settings last, and below a gap: it is not somewhere to land on the
        // way to a track.
        XCTAssertEqual(
            NotchViewModel.Tab.leftRail,
            [.media, .shelf, .clipboard, .translate, .settings]
        )
        // One rail now. The second column existed to hold the overflow, and
        // the overflow is gone.
        XCTAssertTrue(NotchViewModel.Tab.rightRail.isEmpty)
        XCTAssertEqual(
            NotchViewModel.Tab.allCases.filter(\.needsKeyboard),
            [.translate]
        )
    }

    /// Snippets, Calendar, Notes and the Teleprompter were dropped from the
    /// product deliberately, not hidden: no tab, no privacy section, no store,
    /// no strings. A tab reappearing would be a regression, so the absence is
    /// asserted rather than assumed.
    func testDroppedFeaturesAreAbsentEntirely() {
        XCTAssertEqual(
            NotchViewModel.Tab.allCases.map(\.rawValue).sorted(),
            ["clipboard", "media", "settings", "shelf", "translate"]
        )
        XCTAssertEqual(
            PrivacyMode.Section.allCases.map(\.rawValue).sorted(),
            ["clipboard", "translate"]
        )
    }
}
