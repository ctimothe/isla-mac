import AppKit
import SwiftUI

/// The one icon spec for every page (owner, 2026-10-26: "the exact icon size
/// consistently across the pages ... literally every icon"; spec §19.8,
/// amended 2026-10-26). Before it, the header drew its glyphs at 14 medium,
/// the stage's foot at 13, Translate's Swap and Speak at 12, Copy at the
/// caption's 12 semibold, Paste and Clipboard's symbol segments at 11
/// regular, and the playing app's squircle at 16 beside symbols whose ink is
/// 14 to 15 — six sizes for one kind of thing.
///
/// - Every SF Symbol that is a control or names a page — the identity glyph,
///   the gear and its X, History, Remove All's trash, the stage's tools,
///   Swap, Speak, Copy, Paste, the Kind control's symbols — is `size` at
///   `weight`.
/// - The playing app's icon shows its squircle at `appSquircle`, the symbols'
///   own point size, centred on the same line. A filled squircle carries more
///   weight than a glyph's strokes, so equal extents read as one size.
/// - A glyph-only header tool is `well` square, radius `wellRadius`; one with
///   a word (Remove All, Paste) is the same well, `well` tall, the word at
///   `wordSize` medium (`IconWordButton`). No control's hit target is under
///   `minimumHitTarget` on either side.
///
/// Not icons by this spec, and left as they are: glyphs that stand inside a
/// line of text and take its size (the lock or globe before "On this Mac",
/// ⓘ before a footnote, a clipboard row's kind), a text field's own
/// adornments (Search's magnifier, the Clear ⓧ), the player's transport and
/// star (the page's content, sized by `PlayerLayout`), Settings' sidebar
/// tiles (System Settings' own), and the page dots, which are not glyphs.
enum HeaderIcon {
    static let size: CGFloat = 14
    static let weight: Font.Weight = .medium
    static var font: Font { .system(size: size, weight: weight) }
    static let appSquircle: CGFloat = size
    static let well: CGFloat = 26
    static let wellRadius: CGFloat = 8
    static let wordSize: CGFloat = 13
    static let minimumHitTarget: CGFloat = 24
}

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
    static let toolSide: CGFloat = HeaderIcon.well
    static func gear(bodyWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        centred(x: SurfaceLayout.gearX(bodyWidth: bodyWidth), size: CGSize(width: toolSide, height: toolSide), notchHeight: notchHeight)
    }

    /// What a header item to the gear's left keeps clear of its well.
    static let gearClearance: CGFloat = 8

    /// Translate's History, 26 × 26 at (`bw − 76`, 6), while Keep History is on.
    static func history(bodyWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        centred(x: bodyWidth - 76, size: CGSize(width: toolSide, height: toolSide), notchHeight: notchHeight)
    }

    /// Every page's title, the player's and the stage's included: what leads
    /// it in one 18 × 16 box — a filled symbol at 14 medium, white, or the
    /// playing app's own icon at 16 — and then its name, 13 semibold, from
    /// (20, 11). Its room ends `notchClearance` before the notch; the name
    /// shrinks a little before it is cut ("Буфер обмена" at 480 under a
    /// 220 pt notch).
    ///
    /// One box for every glyph since 2026-10-18. The Shelf's `tray.full.fill`
    /// was drawn 26 × 20 in white while Clipboard's and Translate's outline
    /// symbols were 14 regular in grey, and the owner read the Shelf's as the
    /// one native-looking icon of the three: "consider the whole app as one
    /// app rather than something separate for each section".
    static let titleLeading: CGFloat = 20
    static let titleGlyphBox = CGSize(width: 18, height: 16)
    static let titleGlyphSize: CGFloat = HeaderIcon.size
    /// The playing app's icon shows a 16 pt squircle, 20 in from the left as
    /// the gear's well is 20 in from the right. History: it was drawn 16 × 16,
    /// and an app icon's canvas is not its squircle — macOS 26 seats every
    /// icon's squircle in 824 of its 1024 points — so Spotify showed about
    /// 13 pt beside the gear's 26 pt well, half its height (owner,
    /// 2026-10-18: "whatever player icon is being shown it should be
    /// consistent"); it was then drawn the gear's full 26 pt squircle. On
    /// 2026-10-25 the owner found the Apple Music icon at that size "just too
    /// big ... making it look weird" beside the title, so the squircle came
    /// down to 16 pt, the size of an iPhone Live Activity's app glyph. On
    /// 2026-10-26 it came to 14 (`HeaderIcon.appSquircle`): beside the other
    /// pages' glyphs, whose ink measures 14 to 15 pt, the 16 pt squircle was
    /// still the biggest thing in any header. The image is `14 / share`
    /// (about 17.4 pt), never a 14 × 14 frame, which would show 11 pt. Every
    /// app still gets the same squircle on macOS 26 and later, so one scale
    /// makes every player the same height. The lock card's badge is
    /// unchanged. Header only.
    static let appIconSquircleShare: CGFloat = 824.0 / 1024.0
    static let appIconSquircleSide: CGFloat = HeaderIcon.appSquircle
    static let appIconSide: CGFloat = appIconSquircleSide / appIconSquircleShare
    /// The width a title's glyph takes before its name: the app's squircle
    /// (about 20 pt of image), or the box every symbol shares.
    static func glyphWidth(_ glyph: HeaderGlyph) -> CGFloat {
        if case .app = glyph { return appIconSide }
        return titleGlyphBox.width
    }
    /// The glyph in a header tool's well: the gear, History, Remove All.
    static let toolGlyphSize: CGFloat = HeaderIcon.size
    static let titleSize: CGFloat = 13
    static let titleGap: CGFloat = 6
    static let titleRowHeight: CGFloat = 16
    static func title(bodyWidth: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let width = max(0, (bodyWidth - notchWidth) / 2 - notchClearance - titleLeading)
        return centred(x: titleLeading, size: CGSize(width: width, height: titleRowHeight), notchHeight: notchHeight)
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

/// The gear on a page and the stage, and on Settings the way back out of it
/// (spec §19.16, amended 2026-10-18).
///
/// It used to stand lit on Settings and go back on a second click, which the
/// owner read as a gear that did nothing new: a lit gear says "you are in
/// Settings", not "press to leave". On Settings the well shows `xmark`, labelled
/// "Close Settings", and goes back to the page or stage Settings came from,
/// where the gear returns. The X is unlit and carries no update badge:
/// Settings shows the update itself.
struct HeaderGear: Equatable {
    var onSettings: Bool
    var hasUpdate: Bool

    var symbol: String { onSettings ? "xmark" : "gearshape" }
    var label: String { onSettings ? localized("Close Settings") : localized("Settings") }
    var badge: Bool { hasUpdate && !onSettings }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(HeaderIcon.font)
                .foregroundStyle(isOn ? Color.white : Theme.secondary)
                // The gear turning into Settings' close button, and back, is
                // one glyph replaced in its well rather than two buttons
                // crossfading.
                .symbolSwap(value: symbol, reduceMotion: reduceMotion)
                .frame(width: SurfaceHeaderLayout.toolSide, height: SurfaceHeaderLayout.toolSide)
                .background(
                    RoundedRectangle(cornerRadius: HeaderIcon.wellRadius, style: .continuous)
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
                .contentShape(RoundedRectangle(cornerRadius: HeaderIcon.wellRadius, style: .continuous))
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

/// What leads a header's title: a symbol, or the playing app's own icon.
enum HeaderGlyph: Equatable {
    case symbol(String)
    case app(NSImage)

    static func == (lhs: HeaderGlyph, rhs: HeaderGlyph) -> Bool {
        switch (lhs, rhs) {
        case (.symbol(let a), .symbol(let b)): return a == b
        case (.app(let a), .app(let b)): return a === b
        default: return false
        }
    }
}

/// A page's title (spec §19.8, amended 2026-10-18): its glyph and its name,
/// on every page — the player and the stage name the app the sound comes
/// from, the way Clipboard and Translate name themselves.
struct SurfaceHeaderTitle: View {
    let glyph: HeaderGlyph
    let title: String
    /// False where only the glyph fits (`PlayerSourceTitle.showsName`): the
    /// title is then the element's label and the glyph's tooltip.
    var showsName = true

    init(glyph: HeaderGlyph, title: String, showsName: Bool = true) {
        self.glyph = glyph
        self.title = title
        self.showsName = showsName
    }

    init(symbol: String, title: String) {
        self.init(glyph: .symbol(symbol), title: title)
    }

    var body: some View {
        HStack(spacing: SurfaceHeaderLayout.titleGap) {
            HeaderGlyphView(glyph: glyph)
            if showsName {
                Text(title)
                    .font(.system(size: SurfaceHeaderLayout.titleSize, weight: .semibold))
                    .tracking(Theme.tracking(forSize: SurfaceHeaderLayout.titleSize))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)
            }
        }
        .help(showsName ? "" : title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The player's and the stage's title: the app the sound comes from, by its
/// own icon and its name — Spotify, Music, Telegram, a browser playing a tab —
/// taken from the running process, so an app nobody listed is named all the
/// same. Under a note and "Music" while no app is known.
///
/// The player is the narrowest page, and under a wide notch the room left of
/// it is 40 points: the icon always, the name only where all of it fits —
/// never shrunk or cut to "Yandex M…". The stage is the panel's width and
/// names the app in full. The name is the title's accessibility label and
/// its tooltip either way.
struct PlayerSourceTitle: Equatable {
    let glyph: HeaderGlyph
    let title: String

    init(name: String?, icon: NSImage?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmed.isEmpty ? localized("Music") : trimmed
        glyph = icon.map(HeaderGlyph.app) ?? .symbol("music.note")
    }

    /// Whether the name is drawn beside the glyph in a title `room` wide.
    func showsName(room: CGFloat) -> Bool {
        let font = NSFont.systemFont(ofSize: SurfaceHeaderLayout.titleSize, weight: .semibold)
        let name = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return SurfaceHeaderLayout.glyphWidth(glyph) + SurfaceHeaderLayout.titleGap + name <= room
    }
}

/// A title's glyph: a filled symbol at 14 medium in white in the header's one
/// glyph box, so every page that names itself starts its name at the same x;
/// or an app's icon with its squircle 16 pt, whose roughly 20 pt image
/// overhangs the 16 pt row evenly above and below.
struct HeaderGlyphView: View {
    let glyph: HeaderGlyph

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .font(HeaderIcon.font)
                    .foregroundStyle(Color.white)
            case .app(let icon):
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: SurfaceHeaderLayout.appIconSide, height: SurfaceHeaderLayout.appIconSide)
            }
        }
        .frame(width: SurfaceHeaderLayout.glyphWidth(glyph), height: SurfaceHeaderLayout.titleGlyphBox.height)
        .accessibilityHidden(true)
    }
}

/// The tray's Remove All (spec §19.7, amended 2026-10-18): `trash` and "All"
/// in a well that is the gear's — 26 tall, radius 8, white 0.08 (0.14 under
/// the pointer), the glyph at the gear's 14 medium and the word at 13 medium,
/// both secondary. It was an 18 × 20 glyph stretched to fit and "All" in 15
/// regular on no plate, standing beside the gear's well as a different kind
/// of control (owner's review: "too big for its text, not matching the
/// settings icon next to it"). It asks first: the question stands in the
/// tray, in place of the row.
struct ShelfRemoveAllButton: View {
    let action: () -> Void

    static func width() -> CGFloat { ShelfLayout.removeAllWidth() }

    var body: some View {
        IconWordButton(symbol: "trash", word: localized("All"), action: action)
            .help(localized("Remove All"))
            .accessibilityLabel(localized("Remove All"))
            .accessibilityHint(localized("Asks for confirmation before acting."))
    }
}

/// A glyph and a word in a header tool's well (`HeaderIcon`): Remove All on
/// the Shelf's header and Paste on Translate's source card, one style since
/// 2026-10-26. Paste was a 22 pt push plate — white 0.14 with a lit top
/// edge, its glyph at 11 regular beside a 13 regular word in white — and so
/// a second kind of button with a hit target under 24 pt, where Remove All
/// was already the gear's well. The glyph is `HeaderIcon.size` in a column
/// `ShelfLayout.removeAllGlyphWidth` wide, the word `HeaderIcon.wordSize`
/// medium, both secondary and white under the pointer; 0.4 while disabled.
struct IconWordButton: View {
    let symbol: String
    let word: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: ShelfLayout.removeAllGap) {
                Image(systemName: symbol)
                    .font(HeaderIcon.font)
                    .frame(width: ShelfLayout.removeAllGlyphWidth)
                Text(word)
                    .font(.system(size: HeaderIcon.wordSize, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(hovering && isEnabled ? Color.white : Theme.secondary)
            .padding(.horizontal, ShelfLayout.removeAllPadding)
            .frame(height: HeaderIcon.well)
            .background(
                RoundedRectangle(cornerRadius: HeaderIcon.wellRadius, style: .continuous)
                    .fill(Color.white.opacity(hovering && isEnabled ? 0.14 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: HeaderIcon.wellRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(PanelButtonStyle())
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }
}
