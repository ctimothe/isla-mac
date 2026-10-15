import CoreGraphics
import SwiftUI

/// Where everything in the tall Settings body sits (redesign 2026-10-15, spec §10).
///
/// Stated the way the board states it — in *body coordinates*, the origin at the
/// open body's top-left corner at the top of the screen (spec §1) — and converted
/// to the pane's own through `PlayerLayout.inPane`, the one conversion every
/// pane uses, so a test that holds the spec's numbers holds the pixels.
///
/// Pure: the sidebar and the form are laid by these numbers, and
/// `SettingsLayoutTests` reads them at 480, 540, 560 and 620.
enum SettingsLayout {
    /// Settings always opens 400 tall (spec §10), whatever any tab was expanded
    /// to: no Expand button reaches it, because the sidebar is the structure
    /// that earns the height and a body that folded to 208 would be a sidebar of
    /// ten rows in a window of seven.
    static let bodyHeight: CGFloat = NotchMetrics.tallestBody.height

    /// Where the sidebar and the form begin, under the 38 pt header and a gap.
    static let contentTop: CGFloat = 46

    // MARK: Sidebar

    static let sidebarLeading: CGFloat = 58
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

    static let formLeading: CGFloat = 192
    /// Below this body width the form is the narrow 274 and the controls give
    /// way in a fixed order (`Stress-Settings-RU-480`): sliders shrink first,
    /// then labels wrap, and a control never does.
    static let narrowBelow: CGFloat = 540
    static let narrowFormWidth: CGFloat = 274

    /// The form's width: `bw − 206` — 354 at the default 560 — and the narrow
    /// 274 below 540, where the sidebar keeps its 122 and the form takes the one
    /// width the boards design for. At 620 it is 414.
    static func formWidth(bodyWidth: CGFloat) -> CGFloat {
        bodyWidth < narrowBelow ? narrowFormWidth : bodyWidth - 206
    }

    static func isNarrow(bodyWidth: CGFloat) -> Bool { bodyWidth < narrowBelow }

    /// The form's own scrolling area: from `contentTop` to the body's 14 pt
    /// bottom padding. A section taller than this scrolls inside it.
    static func formFrame(bodyWidth: CGFloat) -> CGRect {
        CGRect(
            x: formLeading, y: contentTop,
            width: formWidth(bodyWidth: bodyWidth),
            height: bodyHeight - NotchGeometry.bodyBottomPadding - contentTop
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

    /// The header strip carries no control on this tab: no Expand (Settings is
    /// always tall), no tools. What `HeaderNotchBandTests` holds for every other
    /// tab holds here trivially, and a control added later has to be listed.
    static let headerControlFrames: [CGRect] = []

    // MARK: Lock Screen style previews (spec §10)

    /// Four previews across the form, 80 × 52 at 354. Narrower, they shrink with
    /// the form — 62 × 40 at 274 — so the four always fit with 6 pt between them
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

    // MARK: Pane coordinates

    /// A frame in body coordinates, in the pane's: Settings is a pane like any
    /// other and starts where the rail ends and the header does.
    static func inPane(_ body: CGRect, headerHeight: CGFloat) -> CGRect {
        PlayerLayout.inPane(body, headerHeight: headerHeight)
    }
}
