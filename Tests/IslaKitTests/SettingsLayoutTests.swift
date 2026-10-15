import SwiftUI
import XCTest
@testable import IslaKit

/// Where Settings' sidebar and form sit (redesign 2026-10-15, spec §10): the
/// numbers the board is drawn with, held at 480, 540, 560 and 620.
@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testTheSidebarIsOneTwentyTwoWideAtFiftyEightByFortySixWithRowsTwentySixApart() {
        XCTAssertEqual(SettingsLayout.sidebarFrame(), CGRect(x: 58, y: 46, width: 122, height: 260))
        for index in 0..<10 {
            XCTAssertEqual(
                SettingsLayout.sidebarRow(index),
                CGRect(x: 58, y: 46 + CGFloat(index) * 26, width: 122, height: 24), "row \(index)"
            )
        }
        XCTAssertEqual(SettingsSection.allCases.count, 10)
        XCTAssertEqual(SettingsLayout.sidebarIconSide, 18)
        XCTAssertEqual(SettingsLayout.sidebarSelectionRadius, 6)
        XCTAssertEqual(SettingsLayout.sidebarIconRadius, 5)
        // 6 + 18 + 8: the icon's inset, the tile and the gap the label starts at.
        XCTAssertEqual(SettingsLayout.sidebarLabelInset, 32)
        XCTAssertEqual(SettingsLayout.sidebarLabelWidth, 86, "a long name is cut to this and truncates at its tail")
        XCTAssertEqual(SettingsLayout.sidebarLabelInset + SettingsLayout.sidebarLabelWidth, 118, "4 pt short of the row's edge")
        XCTAssertEqual(SettingsLayout.dividerLeading, 185)
    }

    /// The form is 354 at the default 560 (`bw − 206`) and 274 below 540, where
    /// the labels wrap before the controls give way.
    func testTheFormIsThreeFiftyFourAtFiveSixtyAndTwoSeventyFourBelowFiveForty() {
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 560), 354)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 560), 560 - 206)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 620), 414)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 540), 334, "540 is the first wide width")
        for width: CGFloat in [480, 500, 520, 539] {
            XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: width), 274, "below 540 at \(width)")
            XCTAssertTrue(SettingsLayout.isNarrow(bodyWidth: width))
        }
        XCTAssertFalse(SettingsLayout.isNarrow(bodyWidth: 540))
        XCTAssertFalse(SettingsLayout.isNarrow(bodyWidth: 560))
    }

    func testTheFormStartsAtOneNinetyTwoByFortySixAndEndsInsideTheBody() {
        for width: CGFloat in [480, 539, 540, 560, 620] {
            let form = SettingsLayout.formFrame(bodyWidth: width)
            XCTAssertEqual(form.minX, 192)
            XCTAssertEqual(form.minY, 46)
            XCTAssertEqual(form.width, SettingsLayout.formWidth(bodyWidth: width))
            XCTAssertEqual(form.maxY, 386, "the body's 400 less its 14 pt of padding")
            XCTAssertGreaterThan(form.minX, SettingsLayout.sidebarFrame().maxX, "clear of the sidebar")
            XCTAssertLessThanOrEqual(form.maxX, width - 14, "inside the body's padding at \(width)")
        }
        let wide = SettingsLayout.formFrame(bodyWidth: 560)
        XCTAssertEqual(wide, CGRect(x: 192, y: 46, width: 354, height: 340))
    }

    /// Body coordinates, as the spec writes them, and the pane's own, through
    /// the one conversion every pane uses: the pane starts at (58, header).
    func testThePaneCoordinatesFollowTheHeader() {
        let form = SettingsLayout.formFrame(bodyWidth: 560)
        XCTAssertEqual(SettingsLayout.inPane(form, headerHeight: 38), CGRect(x: 134, y: 8, width: 354, height: 340))
        XCTAssertEqual(
            SettingsLayout.inPane(form, headerHeight: 32).minY, 14,
            "a shorter notch has a taller pane and the same screen position"
        )
        // The form's right edge is the pane's right edge: bw − 72 wide.
        XCTAssertEqual(PlayerLayout.paneWidth(bodyWidth: 560), 488)
        XCTAssertEqual(SettingsLayout.inPane(form, headerHeight: 38).maxX, 488)
    }

    func testGroupsAndRowsAreTheSpecs() {
        XCTAssertEqual(SettingsLayout.groupRadius, 9)
        XCTAssertEqual(SettingsLayout.rowHeight, 28)
        XCTAssertEqual(SettingsLayout.rowInset, 10)
        XCTAssertEqual(SettingsLayout.hairlineInset, 10)
        XCTAssertEqual(SettingsLayout.hairlineHeight, 0.5)
        XCTAssertEqual(ShortcutRecorderRow.wellWidth, 96, "the three shortcut recorders are 96 pt fields")
        XCTAssertEqual(ToolbarPushButtonStyle.height, 22, "a push button fits the 28 pt row with 3 pt either side")
    }

    /// Four previews across the form, 80 × 52 at 354, shrinking with it so the
    /// four never run past the edge.
    func testTheStylePreviewsFitTheFormAtEveryWidth() {
        XCTAssertEqual(SettingsLayout.previewSize(formWidth: 354), CGSize(width: 80, height: 52))
        XCTAssertEqual(SettingsLayout.previewSize(formWidth: 414), CGSize(width: 80, height: 52))
        let narrow = SettingsLayout.previewSize(formWidth: 274)
        XCTAssertEqual(narrow.width, 62)
        XCTAssertEqual(narrow.height, 40)
        for form: CGFloat in [274, 334, 354, 414] {
            let size = SettingsLayout.previewSize(formWidth: form)
            let used = size.width * 4 + SettingsLayout.previewMinimumGap * 3 + 8
            XCTAssertLessThanOrEqual(used, form, "four previews and their gaps fit \(form)")
            XCTAssertEqual(size.width / size.height, 80.0 / 52.0, accuracy: 0.05, "the card's own proportions")
        }
    }

    /// The header strip carries no control on this tab, so there is nothing to put
    /// under the notch (`HeaderNotchBandTests` holds it for every other tab).
    func testSettingsHasNoHeaderControls() {
        XCTAssertTrue(SettingsLayout.headerControlFrames.isEmpty)
    }

    /// The tokens: group fill white 0.055, the selected row 0.12, the header
    /// 0.85, each stepped up by Increase Contrast, and Connected in the charging
    /// green.
    func testTheTokensAreTheSpecs() {
        XCTAssertEqual(Theme.settingsGroupOpacity(increaseContrast: false), 0.055)
        XCTAssertEqual(Theme.settingsSidebarSelectionOpacity(increaseContrast: false), 0.12)
        XCTAssertEqual(Theme.settingsHeaderOpacity(increaseContrast: false), 0.85)
        XCTAssertGreaterThan(Theme.settingsGroupOpacity(increaseContrast: true), 0.055)
        XCTAssertGreaterThan(Theme.settingsSidebarSelectionOpacity(increaseContrast: true), 0.12)
        XCTAssertGreaterThan(Theme.settingsHeaderOpacity(increaseContrast: true), 0.85)
        XCTAssertEqual(Theme.settingsConnected, Theme.chargingGreen, "spec §2.1: green is charging and Connected")
        XCTAssertEqual(Theme.settingsPreviewRingWidth, 2, "the chosen preview is ringed at 2 pt")
        for tint in Theme.SettingsTint.allCases {
            let hex = tint.hex
            XCTAssertLessThanOrEqual(hex, 0xFFFFFF)
        }
        XCTAssertEqual(Theme.SettingsTint.allCases.count, 5)
    }
}
