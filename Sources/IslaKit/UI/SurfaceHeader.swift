import AppKit
import SwiftUI

/// The header strip's frames (spec §19.6–§19.8), in body coordinates: the strip
/// is the notch's own height at the top of the body, and the notch sits in the
/// middle of it — 185 to 220 pt wide, and drawn on a Mac that has none — so
/// nothing that is a control goes there. Every item is centred on the strip's
/// height, which is the board's y 6 (a 26 pt button) and y 11 (a 16 pt row)
/// on the reference's 38.
enum SurfaceHeaderLayout {
    /// What a header item keeps clear of the notch on each side.
    static let notchClearance: CGFloat = 8

    /// The gear, 26 × 26 at (`bw − 46`, 6) on every page, the stage and
    /// Settings (§19.16) — where the Tools button stood.
    static let toolSide: CGFloat = 26
    static func gear(bodyWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        centred(x: SurfaceLayout.gearX(bodyWidth: bodyWidth), size: CGSize(width: toolSide, height: toolSide), notchHeight: notchHeight)
    }

    /// What a header item to the gear's left keeps clear of its well.
    static let gearClearance: CGFloat = 8

    /// Translate's History, 26 × 26 at (`bw − 76`, 6), while Keep History is on.
    static func history(bodyWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        centred(x: bodyWidth - 76, size: CGSize(width: toolSide, height: toolSide), notchHeight: notchHeight)
    }

    /// A summoned surface's title: its glyph at 14 and its name, 13 semibold,
    /// from (20, 11). Its room ends `notchClearance` before the notch; the
    /// name shrinks a little before it is cut ("Буфер обмена" at 480 under a
    /// 220 pt notch).
    static let titleLeading: CGFloat = 20
    static let titleGlyphSize: CGFloat = 14
    static let titleSize: CGFloat = 13
    static let titleGap: CGFloat = 6
    static let titleRowHeight: CGFloat = 16
    static func title(bodyWidth: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let width = max(0, (bodyWidth - notchWidth) / 2 - notchClearance - titleLeading)
        return centred(x: titleLeading, size: CGSize(width: width, height: titleRowHeight), notchHeight: notchHeight)
    }

    /// The stage's leading icon: the playing app's, 16 × 16 at (20, 11).
    static func stageIcon(notchHeight: CGFloat) -> CGRect {
        centred(x: 20, size: CGSize(width: 16, height: 16), notchHeight: notchHeight)
    }

    /// The tray's glyph, 26 × 20, and its count (`ShelfLayout.headerGlyphX`,
    /// `headerCountX`).
    static func trayGlyph(notchHeight: CGFloat) -> CGRect {
        centred(x: ShelfLayout.headerGlyphX, size: ShelfLayout.headerGlyph, notchHeight: notchHeight)
    }

    static func trayCount(bodyWidth: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let width = max(0, (bodyWidth - notchWidth) / 2 - notchClearance - ShelfLayout.headerCountX)
        return centred(x: ShelfLayout.headerCountX, size: CGSize(width: width, height: 20), notchHeight: notchHeight)
    }

    /// Remove All — `trash` and "All" — ending at `ShelfLayout.removeAllTrailing`,
    /// `width` wide as it measures.
    static func removeAll(bodyWidth: CGFloat, width: CGFloat, notchHeight: CGFloat) -> CGRect {
        centred(
            x: ShelfLayout.removeAllTrailing(bodyWidth: bodyWidth) - width,
            size: CGSize(width: width, height: toolSide), notchHeight: notchHeight
        )
    }

    /// The notch's own span of the strip: the one part of it that closes the
    /// panel, and where the island's accessibility element lives while open.
    static func closeSpan(bodyWidth: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        CGRect(x: (bodyWidth - notchWidth) / 2, y: 0, width: notchWidth, height: notchHeight)
    }

    private static func centred(x: CGFloat, size: CGSize, notchHeight: CGFloat) -> CGRect {
        CGRect(x: x, y: SurfaceLayout.headerCentreY(notchHeight: notchHeight) - size.height / 2,
               width: size.width, height: size.height)
    }
}

/// A header tool (spec §19.8): a glyph at 14 in a 26 × 26 well, white 0.08
/// (0.14 under the pointer, white 0.18 behind the filled glyph while it is
/// on). The gear and Translate's History.
struct HeaderToolButton: View {
    let symbol: String
    let label: String
    var isOn = false
    /// A 5 pt dot at the top-trailing corner: Settings with an update waiting.
    var badge = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: SurfaceHeaderLayout.titleGlyphSize, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Theme.secondary)
                .frame(width: SurfaceHeaderLayout.toolSide, height: SurfaceHeaderLayout.toolSide)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isOn ? 0.18 : (hovering ? 0.14 : 0.08)))
                )
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 5, height: 5)
                            .offset(x: -3, y: 3)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(badge ? localized("Update available") : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A summoned surface's title (spec §19.8): its glyph and its name.
struct SurfaceHeaderTitle: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: SurfaceHeaderLayout.titleGap) {
            Image(systemName: symbol)
                .font(.system(size: SurfaceHeaderLayout.titleGlyphSize, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: SurfaceHeaderLayout.titleSize, weight: .semibold))
                .tracking(Theme.tracking(forSize: SurfaceHeaderLayout.titleSize))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The tray's Remove All (spec §19.7): `trash` 18 × 20 and "All", 5 apart, 15
/// regular. It asks first: the question stands in the tray, in place of the row.
struct ShelfRemoveAllButton: View {
    let action: () -> Void
    @State private var hovering = false

    static func width() -> CGFloat { ShelfLayout.removeAllWidth() }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 20)
                Text(localized("All"))
                    .font(.system(size: 15, weight: .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(hovering ? Color.white : Theme.secondary)
            .padding(.horizontal, 6)
            .frame(height: SurfaceHeaderLayout.toolSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .onHover { hovering = $0 }
        .help(localized("Remove All"))
        .accessibilityLabel(localized("Remove All"))
        .accessibilityHint(localized("Asks for confirmation before acting."))
    }
}
