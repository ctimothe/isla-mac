import CoreGraphics
import SwiftUI

/// Where everything on the Settings surface sits (spec §10, moved by §19.8).
///
/// Stated the way the board states it — in *body coordinates*, the origin at the
/// open body's top-left corner at the top of the screen (spec §1) — and converted
/// to the content's own, under the header row, through `SurfaceLayout.inContent`,
/// so a test that holds the spec's numbers holds the pixels. §10 placed the
/// sidebar at 58, beside the rail; with the rail gone every leading edge moved
/// 42 left and every width running to a `bw − n` edge grew by 42.
///
/// Pure: the sidebar and the form are laid by these numbers, and
/// `SettingsLayoutTests` reads them at 480, 540, 560 and 620.
enum SettingsLayout {
    /// Settings is 400 tall (§19.8): the sidebar is the structure that earns
    /// the height, and a shorter body would be a sidebar of ten rows in a
    /// window of seven.
    static let bodyHeight: CGFloat = SurfaceLayout.settingsHeight
    /// What the form leaves under itself at the body's foot.
    static let bottomInset: CGFloat = 14

    /// Where the sidebar and the form begin, under the 38 pt header and a gap.
    static let contentTop: CGFloat = 46

    // MARK: Sidebar

    static let sidebarLeading: CGFloat = 16
    static let sidebarWidth: CGFloat = 122
    /// Rows are 32 apart, the native sidebar list's pitch on macOS 27: a 28 pt
    /// row and a 4 pt gap (native pass 2026-10-25; it was 26 and 24).
    static let sidebarRowPitch: CGFloat = 32
    static let sidebarRowHeight: CGFloat = 28
    /// The visible tile, 20 pt: a system pane icon is drawn larger so its own
    /// tile fills this (`Theme.systemPaneIconOpticalScale`), a drawn one is
    /// this size.
    static let sidebarIconSide: CGFloat = 20
    /// The drawn tile's corner — System Settings' at 20 pt — and the selected
    /// row's.
    static let sidebarIconRadius: CGFloat = 4.5
    static let sidebarSelectionRadius: CGFloat = 6
    /// The tile's inset from the row's left edge, and the label's from it:
    /// 6 + 20 + 8.
    static let sidebarIconInset: CGFloat = 6
    static let sidebarLabelInset: CGFloat = 34
    /// What the label is cut to, so a long name truncates at its tail instead
    /// of running under the form. Russian's three long titles were shortened
    /// on 2026-10-25 so they fit at 13 pt («Приватность», «Клавиши»,
    /// «Блокировка»).
    static var sidebarLabelWidth: CGFloat { sidebarWidth - 38 }

    /// System Settings' type: 13 pt row labels and headers, 11 pt footers
    /// (probe, macOS 27). They are the panel's `subhead` and `body` roles.
    static let labelRole: Theme.TypeRole = .subhead
    static let footnoteRole: Theme.TypeRole = .body
    /// The hairline between the sidebar and the form, 5 pt past the sidebar.
    static let dividerLeading: CGFloat = sidebarLeading + sidebarWidth + 5

    // MARK: Form

    static let formLeading: CGFloat = 150
    /// Below this body width the form is the narrow 310 and the controls give
    /// way in a fixed order (`Stress-Settings-RU-480`): sliders shrink first,
    /// then labels wrap, and a control never does.
    static let narrowBelow: CGFloat = 540
    static let narrowFormWidth: CGFloat = 310
    /// The grouped form's own margin between its groups and the edge (probe:
    /// `Form(.grouped)` keeps 20 pt whatever its content margins say).
    static let formTrailingMargin: CGFloat = 20

    /// The form's width: `bw − 170` — 390 at the default 560 — and the narrow
    /// 310 below 540. Either way the groups end 20 short of the body's right
    /// edge, as a grouped form's do (native pass 2026-10-25; it was `bw − 164`
    /// and 316, 14 short).
    static func formWidth(bodyWidth: CGFloat) -> CGFloat {
        bodyWidth < narrowBelow ? narrowFormWidth : bodyWidth - formLeading - formTrailingMargin
    }

    static func isNarrow(bodyWidth: CGFloat) -> Bool { bodyWidth < narrowBelow }

    /// The form's own scrolling area: from `contentTop` to the body's 14 pt
    /// bottom padding. A section taller than this scrolls inside it.
    static func formFrame(bodyWidth: CGFloat) -> CGRect {
        CGRect(
            x: formLeading, y: contentTop,
            width: formWidth(bodyWidth: bodyWidth),
            height: bodyHeight - bottomInset - contentTop
        )
    }

    static func sidebarFrame() -> CGRect {
        CGRect(
            x: sidebarLeading, y: contentTop,
            width: sidebarWidth, height: CGFloat(SettingsSection.allCases.count) * sidebarRowPitch
        )
    }

    /// The `index`th sidebar row's frame, body coordinates.
    static func sidebarRow(_ index: Int) -> CGRect {
        CGRect(
            x: sidebarLeading, y: contentTop + CGFloat(index) * sidebarRowPitch,
            width: sidebarWidth, height: sidebarRowHeight
        )
    }

    // MARK: Groups and rows

    /// Continuous, the grouped form's corner run of 10.5 pt (probe).
    static let groupRadius: CGFloat = 10
    /// Native row heights on macOS 27 (probe): a switch row 37.5, a slider
    /// 37, a pop-up 38.5, a bordered push button 40 — 38 here for all of
    /// them, a minimum the bordered button's own height grows past by itself.
    /// They were 28: the type, the colours and the missing margin read "not
    /// native" more than the height did, but the height was off too.
    static let rowHeight: CGFloat = 38
    /// A row holding a segmented control: 41 on macOS 27 (probe).
    static let segmentedRowHeight: CGFloat = 41
    /// An app's icon at the head of a row (Players on This Mac, the Automation
    /// status): the sidebar tile's side, so the two columns of icons agree.
    static let rowAppIconSide: CGFloat = sidebarIconSide
    /// A Connections row: a 26 pt icon beside two lines, the height System
    /// Settings' Internet Accounts rows have for the same shape.
    static let connectionIconSide: CGFloat = 26
    static let connectionRowHeight: CGFloat = 48
    /// The row's inset either side, and the hairline's: it stops short of the
    /// group's edge so the card reads as one object with lines in it.
    static let rowInset: CGFloat = 10
    static let hairlineInset: CGFloat = 10
    static let hairlineHeight: CGFloat = 0.5

    // MARK: Lock Screen style previews (spec §10)

    /// Four previews across the form, 80 × 52 wherever the form is 352 or
    /// wider. Narrower, they shrink with it — 69 × 44 in the 310 pt form of a
    /// panel under 540 — so the four options always fit with 6 pt between the
    /// previews at the least, rather than the row running past the edge.
    ///
    /// An option is its preview and the label under it, and the label is
    /// framed `previewLabelOverhang` wider than the preview on either side, so
    /// a word longer than the preview has room. The sizes used to leave room
    /// for the previews alone: at 310 the four options were 332 pt in a 310 pt
    /// form, and the row was cut 15 pt either side (Batch 10, 2026-10-29). So
    /// an option takes a quarter of the row at the most
    /// (`previewOptionWidth`), and the preview leaves the minimum gap inside it.
    static let previewNominalSize = CGSize(width: 80, height: 52)
    static let previewRadius: CGFloat = 7
    static let previewLabelGap: CGFloat = 6
    static let previewMinimumGap: CGFloat = 6
    static let previewLabelOverhang: CGFloat = 6
    /// The picker's row stands this far inside the form on either side: the
    /// selected ring is drawn 3 pt outside its preview, and the form's scroll
    /// view clips at its own edge.
    static let previewRowInset: CGFloat = 4

    static func previewSize(formWidth width: CGFloat, count: Int = 4) -> CGSize {
        let side = min(previewNominalSize.width, (previewSlot(formWidth: width, count: count) - previewMinimumGap).rounded(.down))
        return CGSize(
            width: side,
            height: (side * previewNominalSize.height / previewNominalSize.width).rounded(.down)
        )
    }

    /// One option's width: its preview and the label's overhang, or a quarter
    /// of the row where that is less.
    static func previewOptionWidth(formWidth width: CGFloat, count: Int = 4) -> CGFloat {
        min(previewSize(formWidth: width, count: count).width + previewLabelOverhang * 2,
            previewSlot(formWidth: width, count: count))
    }

    private static func previewSlot(formWidth width: CGFloat, count: Int) -> CGFloat {
        (width - previewRowInset * 2) / CGFloat(count)
    }

    // MARK: Content coordinates

    /// A frame in body coordinates, in the content's: Settings is a surface
    /// like any other and starts under the header row.
    static func inContent(_ body: CGRect) -> CGRect {
        SurfaceLayout.inContent(body)
    }
}
