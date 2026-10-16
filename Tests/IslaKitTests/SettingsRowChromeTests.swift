import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// A Settings row never breaks a word (2026-10-17, owner): at 480 pt the group
/// label "Accessibility" was cut as "Accessibilit / y" beside "Open Privacy &
/// Security…". A label wraps between words; when its longest word and the
/// control cannot share a line, the row stacks.
@MainActor
final class SettingsRowChromeTests: XCTestCase {
    // MARK: The decision, from widths alone

    func testItStacksWhenTheLongestWordAndTheControlDoNotShareALine() {
        // "Accessibility" at 11.5 pt is about 78 wide, the button about 158, in
        // the 254 inside the 274 form.
        XCTAssertEqual(
            SettingsRowArrangement.choose(available: 254, leading: 0, longestWord: 78, trailing: 158),
            .stacked, "78 + 24 + 158 = 260 > 254"
        )
        XCTAssertEqual(
            SettingsRowArrangement.choose(available: 334, leading: 0, longestWord: 78, trailing: 158),
            .sideBySide
        )
    }

    func testALongLabelOfShortWordsStaysBesideItsControlAndWraps() {
        // Ninety points of "Volume and Brightness replaces …" words: only the
        // longest word counts, never the whole label.
        XCTAssertEqual(
            SettingsRowArrangement.choose(available: 254, leading: 0, longestWord: 60, trailing: 40),
            .sideBySide
        )
    }

    /// Measured widths are rounded up and there is no tolerance: a label that is
    /// proposed even a hair less than its longest word breaks inside it.
    func testTheBoundaryIsExactAndMeasuredWidthsRoundUp() {
        // 50.2 rounds up to 51: 51 + 24 + 30 = 105.
        XCTAssertEqual(SettingsRowArrangement.choose(available: 105, leading: 0, longestWord: 50.2, trailing: 30), .sideBySide)
        XCTAssertEqual(SettingsRowArrangement.choose(available: 104.9, leading: 0, longestWord: 50.2, trailing: 30), .stacked)
        // The control's 29.2 rounds up to 30: 50 + 24 + 30 = 104.
        XCTAssertEqual(SettingsRowArrangement.choose(available: 104, leading: 0, longestWord: 50, trailing: 29.2), .sideBySide)
        XCTAssertEqual(SettingsRowArrangement.choose(available: 103.9, leading: 0, longestWord: 50, trailing: 29.2), .stacked)
    }

    func testTheLeadingIconCountsWithItsGap() {
        XCTAssertEqual(
            SettingsRowArrangement.choose(available: 130, leading: 18, longestWord: 50, trailing: 30),
            .sideBySide, "18 + 8 + 50 + 24 + 30 = 130"
        )
        XCTAssertEqual(
            SettingsRowArrangement.choose(available: 129, leading: 18, longestWord: 50, trailing: 30),
            .stacked
        )
    }

    func testARowWithNothingOnTheRightOnlyNeedsItsWord() {
        XCTAssertEqual(SettingsRowArrangement.gap(trailing: 0), 16)
        XCTAssertEqual(SettingsRowArrangement.gap(trailing: 20), 24)
        XCTAssertEqual(SettingsRowArrangement.choose(available: 100, leading: 0, longestWord: 80, trailing: 0), .sideBySide)
    }

    // MARK: The real layout

    private func height(of view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        return host.fittingSize.height
    }

    private static func button(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).frame(height: 22)
    }

    func testAnAccessibilityRowAtTheNarrowFormStacksInsteadOfBreakingTheWord() {
        let row = SettingsRowChrome(label: "Accessibility") { Self.button("Open Privacy & Security…") }
        let narrow = height(of: row, width: 274)
        let wide = height(of: row, width: 600)
        XCTAssertEqual(wide, SettingsLayout.rowHeight, "it fits at 600: one line, as before")
        XCTAssertGreaterThan(narrow, SettingsLayout.rowHeight + 10, "at 274 it is two lines, label above control")
        XCTAssertLessThan(narrow, 80, "two lines, not a letter per line")
    }

    func testARowThatFitsIsExactlyAsTallAsBefore() {
        let row = SettingsRowChrome(label: "Launch at Login") { Toggle("", isOn: .constant(true)).labelsHidden() }
        XCTAssertEqual(height(of: row, width: 274), SettingsLayout.rowHeight)
        let withIcon = SettingsRowChrome(label: "Charging", icon: "bolt") { Toggle("", isOn: .constant(true)).labelsHidden() }
        XCTAssertEqual(height(of: withIcon, width: 274), SettingsLayout.rowHeight)
    }

    func testARowWithNoLabelStaysTheOldHStack() {
        let row = SettingsRowChrome(label: nil) { Self.button("Open Privacy & Security…") }
        XCTAssertEqual(height(of: row, width: 274), SettingsLayout.rowHeight)
    }

    func testAnEmptyTrailingControlDoesNotChangeTheChildCount() {
        let row = SettingsRowChrome(label: "Some Player") { EmptyView() }
        XCTAssertEqual(height(of: row, width: 274), SettingsLayout.rowHeight)
    }
}
