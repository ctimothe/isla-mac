import AppKit
import SwiftUI

/// Where everything on the tray sits (spec §19.7, board `R2-Shelf-Open`), as
/// values, in the content's coordinates: the board's shape coordinates less
/// the tray's 24 pt shoulder across, and less the reference notch's 38 down
/// (`SurfaceLayout.inContent`). A test that holds these numbers holds the
/// pixels without rendering anything.
///
/// The tray replaced §8.1's grid and §8.2's selection bar: one row of tiles,
/// four in view, scrolling sideways past four — the tray never widens.
enum ShelfLayout {
    // MARK: - The row (§19.7)

    /// The shoulder the board's x is measured outside of.
    static let shoulder: CGFloat = 24

    /// A tile: 80 × 94, radius 16, on a 90 pitch.
    static let tile = CGSize(width: 80, height: 94)
    static let tileRadius: CGFloat = 16
    static let pitch: CGFloat = 90

    /// The first tile's corner: (41.9, 47.5) on the board.
    static let firstTile = CGPoint(x: 41.9 - shoulder, y: 47.5 - SurfaceLayout.referenceNotchHeight)

    /// How many tiles the tray shows before it scrolls.
    static let visibleTiles = 4

    /// The 16 pt fades at a clipped end of the row.
    static let edgeFade: CGFloat = 16

    /// A tile's frame inside the row's scrolled content.
    static func tileFrame(index: Int) -> CGRect {
        CGRect(
            x: firstTile.x + CGFloat(index) * pitch, y: firstTile.y,
            width: tile.width, height: tile.height
        )
    }

    /// The row's scrolled content: the tiles and the same margin after the
    /// last as before the first.
    static func contentWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return 2 * firstTile.x + CGFloat(count - 1) * pitch + tile.width
    }

    /// The viewport the row scrolls in: the board's 385.3 across, centred in
    /// the body — which is that width unless a wide notch widened the tray
    /// (`bodyWidth(notchWidth:)`) — and the content's whole height below the
    /// header strip. Four tiles keep the board's margins either way.
    static func viewport(bodyWidth: CGFloat) -> CGRect {
        let width = min(bodyWidth, referenceBodyWidth)
        return CGRect(
            x: ((bodyWidth - width) / 2).rounded(), y: 0,
            width: width, height: SurfaceLayout.trayReference.height - SurfaceLayout.referenceNotchHeight
        )
    }

    // MARK: - The tray's width (§19.7, amended 2026-10-18)

    /// The board's tray body: 433.3 less its two 24 pt shoulders.
    static let referenceBodyWidth: CGFloat = SurfaceLayout.trayReference.width - 2 * shoulder

    /// The tray's body under a notch `notchWidth` wide. The board's 385.3
    /// leaves the header about 100 pt either side of a 185 pt notch; under a
    /// 220 or 240 pt one (§19.12) the count had 17 pt for "60" and Remove All
    /// ran into the notch (R8 review). So the body is at least the notch plus
    /// what the header needs on its wider side, on both sides, since the tray
    /// is centred on the notch. The tiles stay four, centred.
    static func bodyWidth(notchWidth: CGFloat) -> CGFloat {
        max(referenceBodyWidth, notchWidth + 2 * headerSideRoom())
    }

    /// What the header needs on one side of the notch: the glyph and the
    /// count at its widest ("60", the Shelf's limit) on the left, Remove All
    /// in the language on screen on the right — each with the clearance every
    /// header item keeps from the notch.
    static func headerSideRoom() -> CGFloat {
        let left = headerCountX + maximumCountWidth() + SurfaceHeaderLayout.notchClearance
        let right = (44 - shoulder) + removeAllWidth() + SurfaceHeaderLayout.notchClearance
        return ceil(max(left, right))
    }

    /// "60" in the count's 15 pt with tabular digits.
    static func maximumCountWidth() -> CGFloat {
        ceil(("60" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: headerCountSize, weight: .regular),
        ]).width)
    }

    /// Remove All as drawn (`ShelfRemoveAllButton`): `trash` 18, 5 apart,
    /// "All" in 15 regular, and 6 of padding either side.
    static func removeAllWidth() -> CGFloat {
        let text = ceil((localized("All") as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        ]).width)
        return 18 + 5 + text + 12
    }

    /// Whether the row scrolls at all: more than four tiles.
    static func scrolls(count: Int) -> Bool { count > visibleTiles }

    /// The tile under `point`, in the row's scrolled content, or nil between
    /// tiles. Decided from the layout, not from each tile's own hover: a tile
    /// that slides under a pointer that has not moved gets no hover event (the
    /// reason the grid this replaced worked this way).
    static func tileIndex(at point: CGPoint, count: Int) -> Int? {
        guard point.x >= firstTile.x else { return nil }
        let index = Int((point.x - firstTile.x) / pitch)
        guard index < count, tileFrame(index: index).contains(point) else { return nil }
        return index
    }

    // MARK: - A tile (§19.7)

    /// The file's thumbnail or icon: 42 × 42 at (19, 9).
    static let icon = CGRect(x: 19, y: 9, width: 42, height: 42)
    /// The name: 11.5 semibold, white 0.86, centred, two lines, cut in the
    /// middle, at (4, 60.4), 72 wide.
    static let nameOrigin = CGPoint(x: 4, y: 60.4)
    static let nameWidth: CGFloat = 72
    static let nameSize: CGFloat = 11.5
    static let nameLineHeight: CGFloat = 14
    static let maximumNameLines = 2
    /// The remove badge: `xmark.circle.fill` 17 over a 14 pt disc, at (57.75, 5.5).
    static let badge = CGRect(x: 57.75, y: 5.5, width: 17, height: 17)
    static let badgeDisc: CGFloat = 14

    /// A picture's box: a thumbnail at its own shape, long side `box`.
    static func fittedSize(of image: CGSize, in box: CGFloat = icon.width) -> CGSize {
        guard image.width > 0, image.height > 0 else { return CGSize(width: box, height: box) }
        let scale = box / max(image.width, image.height)
        return CGSize(width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
    }

    // MARK: - The header (§19.7)

    /// `tray.full.fill`, 26 × 20, at the board's x 52.6; the count, SF Pro
    /// Rounded 15, tabular, at its x 82. Centred in the header strip.
    static let headerGlyph = CGSize(width: 26, height: 20)
    static let headerGlyphX: CGFloat = 52.6 - shoulder
    static let headerCountX: CGFloat = 82 - shoulder
    static let headerCountSize: CGFloat = 15
    /// Remove All ends 44 from the board's right edge, which is the shape's.
    static func removeAllTrailing(bodyWidth: CGFloat) -> CGFloat { bodyWidth - (44 - shoulder) }

    /// The empty tray's line: "Drag files to the notch to keep them here."
    static let emptyLineSize: CGFloat = 13
}

// MARK: - A tile's plate (§19.7)

/// What a tile's plate says beyond white 0.10, if anything: a drop that
/// matched without adding first, then a pick, then hover. The flash wins
/// because it is the one the person did not cause by pointing, and the one
/// that has to be seen in the second it lasts.
enum ShelfWell: Equatable {
    case hover
    case selected
    /// The tile a drop matched without adding (§8.4, `Shelf-Already`): lit in
    /// the accent inside a 2 pt accent ring — the drop targets' own lit look,
    /// so "this is where it went" is one visual word.
    case alreadyKept

    static func state(isSelected: Bool, isHovered: Bool, isAlreadyKept: Bool) -> ShelfWell? {
        if isAlreadyKept { return .alreadyKept }
        if isSelected { return .selected }
        if isHovered { return .hover }
        return nil
    }

    /// Whether the tile wears its remove badge: hovered or selected
    /// (decision 9).
    static func showsBadge(isSelected: Bool, isHovered: Bool) -> Bool { isSelected || isHovered }
}

// MARK: - The header (§19.7)

enum ShelfHeader {
    /// What the count says to VoiceOver: "%d items", or "1 item" — the board
    /// draws the bare number beside the glyph.
    static func countText(_ count: Int) -> String {
        count == 1 ? localized("1 item") : localized("%d items", count)
    }

    /// The count and Remove All are drawn with items on the Shelf, and never
    /// over the empty line.
    static func showsCount(itemCount: Int) -> Bool { itemCount > 0 }
    static func showsRemoveAll(itemCount: Int) -> Bool { itemCount > 0 }
}

// MARK: - A tile's name (§8.1)

/// The name under a tile: two lines at most, the second cut in the middle so
/// the extension survives.
///
/// Finder wraps a long name onto a second line and, when that is not enough,
/// truncates the middle of it — "Screenshot 2026-1…09.12.44.png" — because the
/// ends of a filename are what tell two of them apart: the start says what
/// family, the end says which one and what kind. The old card cut to the *last
/// word* and dropped the start entirely (H-025); the redesign gives names a
/// second line and takes Finder's rule instead (spec §8.1, board
/// `Shelf-Icons`).
///
/// Lines are computed here and drawn one `Text` each, rather than one `Text`
/// with a line limit and a truncation mode: SwiftUI's middle truncation over
/// two lines is not specified well enough to test, and drawing each line is
/// what lets the selection highlight them one by one, as Finder does.
enum ShelfTileName {
    /// The lines `name` takes in `width`, as many as fit and at most two.
    static func lines(
        _ name: String, width: CGFloat = ShelfLayout.nameWidth,
        measure: (String) -> CGFloat
    ) -> [String] {
        guard measure(name) > width else { return [name] }
        let (first, rest) = firstLine(of: name, width: width, measure: measure)
        guard !rest.isEmpty else { return [first] }
        if measure(rest) <= width { return [first, rest] }
        return [first, middleTruncated(rest, width: width, measure: measure)]
    }

    /// `lines` for the name as a tile draws it, remembered. A pick redraws every
    /// tile on the shelf and breaking a name measures it once per character it
    /// gives up — sixty captures were some fifteen hundred measurements on a
    /// click, which is why the card this replaces cached its cut names too. A
    /// shelf holds sixty names, so the cache is emptied rather than ordered when
    /// it outgrows a few shelves' worth.
    @MainActor
    static func drawnLines(_ name: String, selected: Bool) -> [String] {
        let key = (selected ? "1" : "0") + name
        if let known = cache[key] { return known }
        if cache.count >= 4 * ShelfStore.limit { cache.removeAll() }
        let lines = lines(name) { measure($0, selected: selected) }
        cache[key] = lines
        return lines
    }

    @MainActor private static var cache: [String: [String]] = [:]

    /// The first line: the longest run that fits, ended at a space when there
    /// is one in reach (Finder breaks between words) and at the character that
    /// no longer fits when there is not (a long name with no spaces — a
    /// camera's IMG_…, a hash — wraps mid-word).
    static func firstLine(
        of name: String, width: CGFloat, measure: (String) -> CGFloat
    ) -> (line: String, rest: String) {
        let characters = Array(name)
        var fit = characters.count
        while fit > 1, measure(String(characters[0..<fit])) > width { fit -= 1 }
        if fit >= characters.count { return (name, "") }
        // A space at or before the cut: the run ends there.
        var breakIndex = fit
        while breakIndex > 0, !characters[breakIndex].isWhitespace { breakIndex -= 1 }
        if breakIndex > 0 {
            let line = String(characters[0..<breakIndex])
            let rest = String(characters[breakIndex...]).trimmingCharacters(in: .whitespaces)
            return (line, rest)
        }
        // No space to break at: wrap mid-word. A name only a hair too long for
        // a line would wrap its last character or two onto the second — "…150444.jp"
        // over "g" — and split the extension across lines, which is the one thing
        // the second line exists to avoid. So the second line gets at least the
        // extension and three characters before it, whatever the first gives up.
        var cut = fit
        let extensionLength = (name as NSString).pathExtension.isEmpty ? 0 : (name as NSString).pathExtension.count + 1
        let wantedTail = min(extensionLength + 3, fit)
        if characters.count - cut < wantedTail { cut = max(1, characters.count - wantedTail) }
        return (String(characters[0..<cut]), String(characters[cut...]))
    }

    /// `text` shortened in the middle until it fits, the extension and the end
    /// of the stem kept. The head and the tail share what room there is, the
    /// head getting the odd character; when not even an ellipsis and the
    /// extension fit — a pathological extension — the end is cut instead and
    /// the result still fits.
    static func middleTruncated(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(text) > width else { return text }
        let ellipsis = "…"
        var stem = text
        var ext = ""
        let pathExtension = (text as NSString).pathExtension
        // A real extension, not a sentence's last dot ("Version 1.5 final").
        if !pathExtension.isEmpty, pathExtension.count <= 8, !pathExtension.contains(where: \.isWhitespace) {
            ext = "." + pathExtension
            stem = String(text.dropLast(ext.count))
        }
        let characters = Array(stem)
        var keep = characters.count - 1
        while keep >= 0 {
            let head = (keep + 1) / 2
            let tail = keep / 2
            let candidate = String(characters.prefix(head)) + ellipsis + String(characters.suffix(tail)) + ext
            if measure(candidate) <= width { return candidate }
            keep -= 1
        }
        // Not even "…" + the extension fits: cut the end.
        var cut = Array(text)
        while cut.count > 1, measure(String(cut) + ellipsis) > width { cut.removeLast() }
        return String(cut) + ellipsis
    }

    /// The name as it is drawn: 11.5 semibold (§19.7), with its size's
    /// tracking. A count of characters is no measure of a proportional line,
    /// which is the lesson of `ShelfItem.measureCardName` this replaces.
    /// `selected` is kept for the callers that still say it; the tray sets a
    /// picked name in the same weight.
    static func measure(_ text: String, selected: Bool = false) -> CGFloat {
        let size = ShelfLayout.nameSize
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .kern: Theme.tracking(forSize: size),
        ]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }
}

// MARK: - The bar (§8.2, §13)

/// What a Shelf verb or well draws as its picture: an SF Symbol, or — for
/// AirDrop alone — the genuine image macOS shows for it.
///
/// There is no public SF Symbol for AirDrop (Apple's `airdrop` glyph is
/// private), and `dot.radiowaves.up.forward`, the lookalike the Shelf used,
/// read as a generic broadcast mark (owner, 2026-10-16). The icon every macOS
/// share menu shows is `NSSharingService(named: .sendViaAirDrop)?.image`: a
/// full-colour picture, not a template, so a caller that draws it must not tint
/// it. A Mac with no such service falls back to the old symbol.
enum ShelfIcon {
    case symbol(String)
    case image(NSImage)

    /// The symbol the Shelf used before the real icon, and still the fallback.
    static let airDropFallbackSymbol = "dot.radiowaves.up.forward"

    /// AirDrop's icon from `service` (injected, so a test names the service it
    /// means), or the fallback symbol when there is none or it has no image.
    /// The image is copied and marked non-template: the service hands back a
    /// shared instance, which is not ours to change.
    static func airDrop(service: NSSharingService?) -> ShelfIcon {
        guard let shared = service?.image, let image = shared.copy() as? NSImage else {
            return .symbol(airDropFallbackSymbol)
        }
        image.isTemplate = false
        return .image(image)
    }

    /// AirDrop's icon on this Mac, resolved once: the well redraws as it lights
    /// and the service is the same every time, so there is no reason to build
    /// one and copy its picture on every pass.
    static let airDropOnThisMac: ShelfIcon = airDrop(service: NSSharingService(named: .sendViaAirDrop))

    /// What a menu item shows beside a verb: the symbol, or a 16 × 16 copy of
    /// the image — the service's picture is larger than a menu row's, and
    /// unsized it made AirDrop's row taller than the symbol rows around it.
    var nsImage: NSImage? {
        switch self {
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .image(let image):
            let sized = (image.copy() as? NSImage) ?? image
            sized.size = NSSize(width: 16, height: 16)
            return sized
        }
    }
}

/// Draws a `ShelfIcon` at `size`: a symbol in the font a symbol is drawn in,
/// an image as it is — original colours, never tinted.
struct ShelfIconView: View {
    let icon: ShelfIcon
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size, weight: weight))
        case .image(let image):
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Dropping in (§8.3)

/// Which of the two wells a drag would land on.
enum ShelfDropTarget: Equatable {
    case keep
    case airDrop

    /// The target's second line (§19.7): what letting go does.
    var caption: String {
        switch self {
        case .keep: return localized("Release to add to the Shelf")
        case .airDrop: return localized("Send to a nearby device")
        }
    }

    var title: String {
        switch self {
        case .keep: return localized("Keep on Shelf")
        case .airDrop: return localized("AirDrop")
        }
    }

    var symbol: String {
        switch self {
        case .keep: return "tray.full"
        case .airDrop: return ShelfIcon.airDropFallbackSymbol
        }
    }

    /// What the well draws: AirDrop's well wears the real icon.
    var icon: ShelfIcon {
        self == .airDrop ? ShelfIcon.airDropOnThisMac : .symbol(symbol)
    }

    // MARK: Geometry

    /// The two targets (spec §19.7), in body coordinates: at the board's y 46
    /// — 46 − 38 below the header strip, whatever the notch's height — each
    /// `(bw − 48) / 2` × 114, 16 apart from x 16, radius 14.
    static let top: CGFloat = 46
    static let height: CGFloat = 114
    static let gap: CGFloat = 16
    static let leading: CGFloat = 16
    static let radius: CGFloat = 14
    /// The glyph: 22 pt.
    static let glyphSize: CGFloat = 22

    static func well(
        _ target: ShelfDropTarget, bodyWidth: CGFloat,
        notchHeight: CGFloat = SurfaceLayout.referenceNotchHeight
    ) -> CGRect {
        let width = (bodyWidth - 48) / 2
        let x = leading + (target == .keep ? 0 : width + gap)
        return CGRect(x: x, y: SurfaceLayout.y(top, notchHeight: notchHeight), width: width, height: height)
    }

    /// The target a drop at `point` (body coordinates) takes.
    ///
    /// AirDrop is chosen only by being *over* its target — its frame, with
    /// the gap between the two counted as AirDrop's half so the choice does not
    /// flicker through a dead strip. Everywhere else — the other target, the
    /// header, the margins — is Keep: the window accepts a drop all over the
    /// panel (`NotchRootView.dropRect`), keeping has always been what a drop
    /// does, and a stray release must never send someone's file to a
    /// stranger's phone.
    static func target(
        atBodyPoint point: CGPoint, bodyWidth: CGFloat,
        notchHeight: CGFloat = SurfaceLayout.referenceNotchHeight
    ) -> ShelfDropTarget {
        let airDrop = well(.airDrop, bodyWidth: bodyWidth, notchHeight: notchHeight)
        let zone = CGRect(
            x: airDrop.minX - gap / 2, y: airDrop.minY,
            width: airDrop.width + gap / 2, height: airDrop.height
        )
        return zone.contains(point) ? .airDrop : .keep
    }

    /// A point in the window (AppKit's, origin at the bottom-left) in body
    /// coordinates (origin at the body's top-left): `contentRect` is where the
    /// body sits in the window (`NotchGeometry.contentRect(for:)`).
    static func bodyPoint(windowPoint: CGPoint, contentRect: CGRect) -> CGPoint {
        CGPoint(x: windowPoint.x - contentRect.minX, y: contentRect.maxY - windowPoint.y)
    }
}
