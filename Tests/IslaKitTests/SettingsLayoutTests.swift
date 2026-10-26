import SwiftUI
import XCTest
@testable import IslaKit

/// Where Settings' sidebar and form sit (redesign 2026-10-15, spec §10, moved
/// by §19.8 now the rail is gone): the numbers the board is drawn with, held at
/// 480, 540, 560 and 620. Every leading coordinate §10 placed at 58 for the rail
/// moved to 16, and every width running from it to a `bw − n` edge grew by 42.
@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// Native pass (2026-10-25): the native sidebar list's 32 pt pitch, a 28 pt
    /// row and a 20 pt visible tile. Ten rows end at 46 + 320 = 366, inside the
    /// 386 the body allows.
    func testTheSidebarIsOneTwentyTwoWideAtSixteenByFortySixWithRowsThirtyTwoApart() {
        XCTAssertEqual(SettingsLayout.sidebarFrame(), CGRect(x: 16, y: 46, width: 122, height: 320))
        for index in 0..<10 {
            XCTAssertEqual(
                SettingsLayout.sidebarRow(index),
                CGRect(x: 16, y: 46 + CGFloat(index) * 32, width: 122, height: 28), "row \(index)"
            )
        }
        XCTAssertLessThanOrEqual(SettingsLayout.sidebarFrame().maxY, 386)
        XCTAssertEqual(SettingsSection.allCases.count, 10)
        XCTAssertEqual(SettingsLayout.sidebarIconSide, 20)
        XCTAssertEqual(SettingsLayout.sidebarSelectionRadius, 6)
        XCTAssertEqual(SettingsLayout.sidebarIconRadius, 4.5, "System Settings' tile corner at 20 pt")
        // 6 + 20 + 8: the icon's inset, the tile and the gap the label starts at.
        XCTAssertEqual(SettingsLayout.sidebarLabelInset, 34)
        XCTAssertEqual(SettingsLayout.sidebarLabelWidth, 84, "a long name is cut to this and truncates at its tail")
        XCTAssertEqual(SettingsLayout.sidebarLabelInset + SettingsLayout.sidebarLabelWidth, 118, "4 pt short of the row's edge")
        XCTAssertEqual(SettingsLayout.dividerLeading, 143, "5 pt past the sidebar: 185 − 42")
    }

    /// The form is 390 at the default 560 (`bw − 170`) and 310 below 540: the
    /// groups end 20 pt short of the body's edge, the grouped form's own
    /// margin (native pass 2026-10-25; it was 14).
    func testTheFormIsThreeNinetyAtFiveSixtyAndThreeTenBelowFiveForty() {
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 560), 390)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 560), 560 - 170)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 620), 450)
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 540), 370, "540 is the first wide width")
        for width: CGFloat in [480, 500, 520, 539] {
            XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: width), 310, "below 540 at \(width)")
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
            XCTAssertLessThanOrEqual(form.maxX, width - 20, "20 pt inside the body's edge at \(width)")
        }
        let wide = SettingsLayout.formFrame(bodyWidth: 560)
        XCTAssertEqual(wide, CGRect(x: 150, y: 46, width: 390, height: 340))
    }

    /// Body coordinates, as the spec writes them, and the content's own, through
    /// the one conversion every surface uses: the content starts at the body's
    /// own x, under the header row, so only y moves (46 − 38).
    func testTheContentCoordinatesAreTheBodysLessTheHeaderRow() {
        let form = SettingsLayout.formFrame(bodyWidth: 560)
        XCTAssertEqual(SettingsLayout.inContent(form), CGRect(x: 150, y: 8, width: 390, height: 340))
        XCTAssertEqual(SettingsLayout.inContent(SettingsLayout.sidebarFrame()).origin, CGPoint(x: 16, y: 8))
        // The form ends 20 short of the body's right edge at every width.
        XCTAssertEqual(SettingsLayout.inContent(form).maxX, 560 - 20)
        XCTAssertEqual(SettingsLayout.inContent(SettingsLayout.formFrame(bodyWidth: 620)).maxX, 620 - 20)
        XCTAssertEqual(SettingsLayout.inContent(SettingsLayout.formFrame(bodyWidth: 480)).maxX, 480 - 20)
    }

    /// Native row heights on macOS 27 (probe): a switch row 37.5, a slider 37,
    /// a pop-up 38.5 (38 here, the floor every row keeps), a segmented control 41.
    func testGroupsAndRowsAreTheSpecs() {
        XCTAssertEqual(SettingsLayout.groupRadius, 10)
        XCTAssertEqual(SettingsLayout.rowHeight, 38)
        XCTAssertEqual(SettingsLayout.segmentedRowHeight, 41)
        XCTAssertEqual(SettingsLayout.rowInset, 10)
        XCTAssertEqual(SettingsLayout.hairlineInset, 10)
        XCTAssertEqual(SettingsLayout.hairlineHeight, 0.5)
        XCTAssertEqual(ShortcutRecorderRow.wellWidth, 96, "the three shortcut recorders are 96 pt fields")
        XCTAssertEqual(ToolbarPushButtonStyle.height, 22, "a push button fits the 28 pt row with 3 pt either side")
    }

    /// Four previews across the form, 80 × 52 at 390, shrinking with it so the
    /// four never run past the edge. At the narrow 310 they are 71 × 46: the
    /// room is 310 less 8 and three 6 pt gaps, a quarter of 284 rounded down.
    func testTheStylePreviewsFitTheFormAtEveryWidth() {
        XCTAssertEqual(SettingsLayout.previewSize(formWidth: 390), CGSize(width: 80, height: 52))
        XCTAssertEqual(SettingsLayout.previewSize(formWidth: 450), CGSize(width: 80, height: 52))
        let narrow = SettingsLayout.previewSize(formWidth: 310)
        XCTAssertEqual(narrow.width, 71)
        XCTAssertEqual(narrow.height, 46)
        for form: CGFloat in [310, 370, 390, 450] {
            let size = SettingsLayout.previewSize(formWidth: form)
            let used = size.width * 4 + SettingsLayout.previewMinimumGap * 3 + 8
            XCTAssertLessThanOrEqual(used, form, "four previews and their gaps fit \(form)")
            XCTAssertEqual(size.width / size.height, 80.0 / 52.0, accuracy: 0.05, "the card's own proportions")
        }
    }

    /// The tokens (native pass 2026-10-25): group fill white 0.065, labels at
    /// `labelColor`'s 0.85, each stepped up by Increase Contrast; the switch
    /// is the grouped form's own 36 × 16.
    func testTheTokensAreTheSpecs() {
        XCTAssertEqual(Theme.settingsGroupOpacity(increaseContrast: false), 0.065)
        XCTAssertEqual(Theme.settingsHeaderOpacity(increaseContrast: false), 0.85)
        XCTAssertGreaterThan(Theme.settingsGroupOpacity(increaseContrast: true), 0.065)
        XCTAssertGreaterThan(Theme.settingsHeaderOpacity(increaseContrast: true), 0.85)
        XCTAssertEqual(Theme.settingsPreviewRingWidth, 2, "the chosen preview is ringed at 2 pt")
        XCTAssertEqual(Theme.switchTrackSize, CGSize(width: 36, height: 16))
        XCTAssertEqual(Theme.SettingsTint.allCases.count, 5)
        XCTAssertEqual(SettingsLayout.labelRole.size, 13, "System Settings' 13 pt row label")
        XCTAssertEqual(SettingsLayout.footnoteRole.size, 11, "the grouped form's 11 pt footer")
    }
}
