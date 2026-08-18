import XCTest
@testable import DynamicIslandKit

@MainActor
final class TabContractTests: XCTestCase {
    func testRailsExposeAllParityFeaturesInStableOrder() {
        XCTAssertEqual(
            NotchViewModel.Tab.leftRail,
            [.media, .shelf, .clipboard, .snippets, .calendar, .translate]
        )
        XCTAssertEqual(
            NotchViewModel.Tab.rightRail,
            [.notes, .teleprompter, .settings]
        )
        XCTAssertEqual(
            NotchViewModel.Tab.allCases.filter(\.needsKeyboard),
            [.snippets, .translate, .notes]
        )
    }
}
