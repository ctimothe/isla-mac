import AppKit
import SwiftUI

/// Where everything on Tools sits (spec §19.8, board `R2-Tools`), in the
/// content's coordinates: the board's body coordinates less the reference
/// notch's 38 (`SurfaceLayout.inContent`). Settings, at (434, 6), is the
/// shell's: it is drawn in the header strip.
enum ToolsLayout {
    /// Three cards, 142 × 140 at y 46 from x 16 on a 153 pitch, radius 16.
    static let card = CGSize(width: 142, height: 140)
    static let cardRadius: CGFloat = 16
    static let pitch: CGFloat = 153

    static func cardFrame(_ tool: ToolsCard.Tool) -> CGRect {
        let index = CGFloat(ToolsCard.Tool.allCases.firstIndex(of: tool) ?? 0)
        return SurfaceLayout.inContent(CGRect(x: 16 + index * pitch, y: 46, width: card.width, height: card.height))
    }

    /// Inside a card: the glyph's 30 pt circle at (12, 12); the name, 13
    /// semibold, at (12, 52); the preview, 12 regular, under it; the hint at
    /// the card's foot, 11 regular.
    static let circle = CGRect(x: 12, y: 12, width: 30, height: 30)
    static let nameOrigin = CGPoint(x: 12, y: 52)
    static let previewTop: CGFloat = 72
    static let hintBottomInset: CGFloat = 12
    static let textWidth: CGFloat = card.width - 24
}

/// What one Tools card says (spec §19.8), apart from any drawing, so each
/// preview is a test.
struct ToolsCard: Equatable {
    enum Tool: CaseIterable {
        case shelf, clipboard, translate

        var surface: NotchViewModel.Surface {
            switch self {
            case .shelf: return .tray
            case .clipboard: return .clipboard
            case .translate: return .translate
            }
        }

        var name: String {
            switch self {
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .translate: return localized("Translate")
            }
        }

        /// The glyph in the card's circle: Shelf `tray.full`, Clipboard
        /// `doc.on.clipboard`, Translate `translate`.
        var symbol: String {
            switch self {
            case .shelf: return "tray.full"
            case .clipboard: return "doc.on.clipboard"
            case .translate: return "translate"
            }
        }
    }

    /// What the preview line holds.
    enum Preview: Equatable {
        /// Words to draw, one line, cut at the tail.
        case text(String)
        /// The newest clip under `PrivacyMode`'s cover: drawn as the drifting
        /// dots, and read as "Hidden".
        case covered
    }

    var tool: Tool
    var preview: Preview
    /// The foot line: "or drag files here", or the tool's shortcut as
    /// `HotKeyCenter` holds it — nil when there is none to show.
    var hint: String?

    /// Shelf: "%d items" or "Empty"; the hint is how files arrive.
    static func shelf(itemCount: Int) -> ToolsCard {
        ToolsCard(
            tool: .shelf,
            preview: .text(itemCount == 0 ? localized("Empty") : ShelfHeader.countText(itemCount)),
            hint: localized("or drag files here")
        )
    }

    /// Clipboard: the newest clip, behind the cover when Privacy covers the
    /// Clipboard; "Empty" with none.
    static func clipboard(newest: ClipItem?, covered: Bool, shortcut: String?) -> ToolsCard {
        let preview: Preview
        if let newest {
            preview = covered ? .covered : .text(newest.preview)
        } else {
            preview = .text(localized("Empty"))
        }
        return ToolsCard(tool: .clipboard, preview: preview, hint: shortcut)
    }

    /// Translate: the last language pair, "Detect Language → English" before
    /// a source was chosen.
    static func translate(source: String?, target: String, shortcut: String?) -> ToolsCard {
        ToolsCard(
            tool: .translate,
            // Two language names and an arrow: nothing in it to translate.
            preview: .text("\(source ?? localized("Detect Language")) → \(target)"),
            hint: shortcut
        )
    }
}

/// Tools (spec §19.8): what a click on the island opens when nothing is
/// live, and what the Tools button on every summoned surface turns it into.
/// Three cards, each a button that opens its surface.
struct ToolsSurface: View {
    var cards: [ToolsCard]
    var open: (NotchViewModel.Surface) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(cards, id: \.tool) { card in
                ToolsCardButton(card: card) { open(card.tool.surface) }
                    .placedAt(ToolsLayout.cardFrame(card.tool))
            }
        }
    }
}

private struct ToolsCardButton: View {
    let card: ToolsCard
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Color.clear
                Circle()
                    .fill(Theme.toolsCircle(card.tool))
                    .overlay(
                        Image(systemName: card.tool.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                    )
                    .placedAt(ToolsLayout.circle)
                Text(card.tool.name)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(Theme.tracking(forSize: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: ToolsLayout.textWidth, alignment: .leading)
                    .offset(x: ToolsLayout.nameOrigin.x, y: ToolsLayout.nameOrigin.y)
                preview
                    .frame(width: ToolsLayout.textWidth, height: 16, alignment: .leading)
                    .offset(x: ToolsLayout.nameOrigin.x, y: ToolsLayout.previewTop)
                if let hint = card.hint {
                    Text(hint)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(Theme.toolsHintOpacity))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: ToolsLayout.textWidth, height: 14, alignment: .leading)
                        .offset(
                            x: ToolsLayout.nameOrigin.x,
                            y: ToolsLayout.card.height - ToolsLayout.hintBottomInset - 14
                        )
                }
            }
            .frame(width: ToolsLayout.card.width, height: ToolsLayout.card.height)
            .contentShape(RoundedRectangle(cornerRadius: ToolsLayout.cardRadius, style: .continuous))
        }
        .buttonStyle(ToolsCardStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help(card.tool.name)
        .accessibilityLabel(card.tool.name)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var preview: some View {
        switch card.preview {
        case .text(let text):
            Text(text)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(Theme.toolsPreviewOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
        case .covered:
            SpoilerField(seed: 0x7001)
                .frame(width: ToolsLayout.textWidth * 0.7, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    private var accessibilityValue: String {
        switch card.preview {
        case .text(let text): return text
        case .covered: return localized("Hidden")
        }
    }
}

/// A card's plate: white 0.07, 0.10 under the pointer, 0.14 pressed.
private struct ToolsCardStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: ToolsLayout.cardRadius, style: .continuous)
                    .fill(Color.white.opacity(
                        configuration.isPressed ? 0.14 : (hovering ? 0.10 : 0.07)
                    ))
            )
            .animation(Theme.contentAnimation, value: hovering)
    }
}
