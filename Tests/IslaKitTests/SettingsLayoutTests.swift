import SwiftUI
import XCTest
@testable import IslaKit

/// Where Settings' sidebar and form sit (redesign 2026-10-15, spec §10, moved
/// by §19.8 now the rail is gone): the numbers the board is drawn with, held at
/// 480, 540, 560 and 620. Every leading coordinate §10 placed at 58 for the rail
/// moved to 16, and every width running from it to a `bw − n` edge grew by 42.
@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testTheSidebarIsOneTwentyTwoWideAtSixteenByFortySixWithRowsTwentySixApart() {
        XCTAssertEqual(SettingsLayout.sidebarFrame(), CGRect(x: 16, y: 46, width: 122, height: 260))
        for index in 0..<10 {
            XCTAssertEqual(
                SettingsLayout.sidebarRow(index),
                CGRect(x: 16, y: 46 + CGFloat(index) * 26, width: 122, height: 24), "row \(index)"
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
        XCTAssertEqual(SettingsLayout.dividerLeading, 143, "5 pt past the sidebar: 185 − 42")
    }

    /// The form is 396 at the default 560 (`bw − 164`) and 316 below 540, where
    /// the labels wrap before the controls give way (§19.8: 354 and 274 grown
    /// by the rail's 42).
    func testTheFormIsThreeNinetySixAtFiveSixtyAndThreeSixteenBelowFiveForty() {
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 560), 396)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 560), 560 - 164)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 620), 456)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 540), 376, "540 is the first wide width")
        for width: CGFloat in [480, 500, 520, 539] {
            XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: width), 316, "below 540 at \(width)")
            XCTAssertTrue(SettingsLayout.isNarrow(bodyWidth: width))
        }
        XCTAssertFalse(SettingsLayout.isNarrow(bodyWidth: 540))
        XCTAssertFalse(SettingsLayout.isNarrow(bodyWidth: 560))
    }

    func testTheFormStartsAtOneFiftyByFortySixAndEndsInsideTheBody() {
        for width: CGFloat in [480, 539, 540, 560, 620] {
            let form = SettingsLayout.formFrame(bodyWidth: width)
            XCTAssertEqual(form.minX, 150)
            XCTAssertEqual(form.minY, 46)
            XCTAssertEqual(form.width, SettingsLayout.formWidth(bodyWidth: width))
            XCTAssertEqual(form.maxY, 386, "the body's 400 less its 14 pt of padding")
            XCTAssertGreaterThan(form.minX, SettingsLayout.sidebarFrame().maxX, "clear of the sidebar")
            XCTAssertLessThanOrEqual(form.maxX, width - 14, "inside the body's padding at \(width)")
        }
        let wide = SettingsLayout.formFrame(bodyWidth: 560)
        XCTAssertEqual(wide, CGRect(x: 150, y: 46, width: 396, height: 340))
    }

    /// Body coordinates, as the spec writes them, and the content's own, through
    /// the one conversion every surface uses: the content starts at the body's
    /// own x, under the header row, so only y moves (46 − 38).
    func testTheContentCoordinatesAreTheBodysLessTheHeaderRow() {
        let form = SettingsLayout.formFrame(bodyWidth: 560)
        XCTAssertEqual(SettingsLayout.inContent(form), CGRect(x: 150, y: 8, width: 396, height: 340))
        XCTAssertEqual(SettingsLayout.inContent(SettingsLayout.sidebarFrame()).origin, CGPoint(x: 16, y: 8))
        // The form ends 14 short of the body's right edge at the widths it is
        // designed for.
        XCTAssertEqual(SettingsLayout.inContent(form).maxX, 560 - 14)
        XCTAssertEqual(SettingsLayout.inContent(SettingsLayout.formFrame(bodyWidth: 620)).maxX, 620 - 14)
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

    /// Four previews across the form, 80 × 52 at 396, shrinking with it so the
    /// four never run past the edge. At the narrow 316 they are 72 × 46: the
    /// room is 316 less 8 and three 6 pt gaps, a quarter of 290 rounded down.
    func testTheStylePreviewsFitTheFormAtEveryWidth() {
        XCTAssertEqual(SettingsLayout.previewSize(formWidth: 396), CGSize(width: 80, height: 52))
        XCTAssertEqual(SettingsLayout.previewSize(formWidth: 456), CGSize(width: 80, height: 52))
        let narrow = SettingsLayout.previewSize(formWidth: 316)
        XCTAssertEqual(narrow.width, 72)
        XCTAssertEqual(narrow.height, 46)
        for form: CGFloat in [316, 376, 396, 456] {
            let size = SettingsLayout.previewSize(formWidth: form)
            let used = size.width * 4 + SettingsLayout.previewMinimumGap * 3 + 8
            XCTAssertLessThanOrEqual(used, form, "four previews and their gaps fit \(form)")
            XCTAssertEqual(size.width / size.height, 80.0 / 52.0, accuracy: 0.05, "the card's own proportions")
        }
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
