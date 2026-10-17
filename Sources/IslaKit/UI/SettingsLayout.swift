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
    /// Rows are 26 apart: a 24 pt row and a 2 pt gap, so the selected row's well
    /// never touches the next one's.
    static let sidebarRowPitch: CGFloat = 26
    static let sidebarRowHeight: CGFloat = 24
    static let sidebarIconSide: CGFloat = 18
    /// The tile's corner and the selected row's. The tile is a rounded square,
    /// not a circle: it is the shape every System Settings icon is.
    static let sidebarIconRadius: CGFloat = 5
    static let sidebarSelectionRadius: CGFloat = 6
    /// The tile's inset from the row's left edge, and the label's from it:
    /// 6 + 18 + 8.
    static let sidebarIconInset: CGFloat = 6
    static let sidebarLabelInset: CGFloat = 32
    /// What the label is cut to, so a long name (Russian's
    /// «Конфиденциальность») truncates at its tail instead of running under the
    /// form.
    static var sidebarLabelWidth: CGFloat { sidebarWidth - 36 }
    /// The hairline between the sidebar and the form, 5 pt past the sidebar.
    static let dividerLeading: CGFloat = sidebarLeading + sidebarWidth + 5

    // MARK: Form

    static let formLeading: CGFloat = 150
    /// Below this body width the form is the narrow 316 and the controls give
    /// way in a fixed order (`Stress-Settings-RU-480`): sliders shrink first,
    /// then labels wrap, and a control never does.
    static let narrowBelow: CGFloat = 540
    static let narrowFormWidth: CGFloat = 316

    /// The form's width: `bw − 164` — 396 at the default 560 — and the narrow
    /// 316 below 540, where the sidebar keeps its 122 and the form takes the one
    /// width the boards design for. At 620 it is 456. Either way it ends 14 short
    /// of the body's right edge at the widths it is designed for.
    static func formWidth(bodyWidth: CGFloat) -> CGFloat {
        bodyWidth < narrowBelow ? narrowFormWidth : bodyWidth - 164
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

    static let groupRadius: CGFloat = 9
    static let rowHeight: CGFloat = 28
    /// An app's icon at the head of a row (Players on This Mac, the Automation
    /// status): the sidebar tile's side, so the two columns of icons agree.
    static let rowAppIconSide: CGFloat = sidebarIconSide
    /// The row's inset either side, and the hairline's: it stops short of the
    /// group's edge so the card reads as one object with lines in it.
    static let rowInset: CGFloat = 10
    static let hairlineInset: CGFloat = 10
    static let hairlineHeight: CGFloat = 0.5

    // MARK: Lock Screen style previews (spec §10)

    /// Four previews across the form, 80 × 52 at 396. Narrower, they shrink with
    /// the form — 73 × 47 at 316 — so the four always fit with 6 pt between them
    /// at the least, rather than the last one running under the edge.
    static let previewNominalSize = CGSize(width: 80, height: 52)
    static let previewRadius: CGFloat = 7
    static let previewLabelGap: CGFloat = 6
    static let previewMinimumGap: CGFloat = 6

    static func previewSize(formWidth width: CGFloat, count: Int = 4) -> CGSize {
        let room = width - 8 - CGFloat(count - 1) * previewMinimumGap
        let side = min(previewNominalSize.width, (room / CGFloat(count)).rounded(.down))
        return CGSize(
            width: side,
            height: (side * previewNominalSize.height / previewNominalSize.width).rounded(.down)
        )
    }

    // MARK: Content coordinates

    /// A frame in body coordinates, in the content's: Settings is a surface
    /// like any other and starts under the header row.
    static func inContent(_ body: CGRect) -> CGRect {
        SurfaceLayout.inContent(body)
    }
}
