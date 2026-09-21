import AppKit
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

    /// Every rail glyph resolves, in both the outline the rail draws and the
    /// fill it draws for the chosen tab — a name macOS does not know draws
    /// nothing at all — and none of them is one of the set the rail wore until
    /// 2026-09-21, which was the upstream project's own.
    func testTheRailGlyphsResolveAndAreTheIslandsOwn() {
        for tab in NotchViewModel.Tab.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil),
                            "\(tab.symbol) does not resolve")
            XCTAssertFalse(NotchViewModel.Tab.retiredSymbols.contains(tab.symbol),
                           "\(tab) is wearing a retired glyph again: \(tab.symbol)")
        }
        XCTAssertEqual(Set(NotchViewModel.Tab.allCases.map(\.symbol)).count,
                       NotchViewModel.Tab.allCases.count, "two tabs share a glyph")
        XCTAssertFalse(NotchViewModel.Tab.retiredSymbols.contains(SettingsIcon.clipboard))
        XCTAssertFalse(NotchViewModel.Tab.retiredSymbols.contains(SettingsIcon.translate))
    }
}
