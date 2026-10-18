import AppKit
import SwiftUI

/// Where everything on the tray sits (spec §19.7, board `R2-Shelf-Open`), as
/// values, in the content's coordinates: the body under the header strip, the
/// board's y less the reference notch's 38 (`SurfaceLayout.inContent`). A test
/// that holds these numbers holds the pixels without rendering anything.
///
/// The tray replaced §8.1's grid and §8.2's selection bar with the board's
/// tiles. Until 2026-10-18 they stood in one row, four in view, scrolling
/// sideways — and a quick sideways swipe on a full Shelf scrolled that row
/// instead of turning the page (owner, on hardware). They now fill the three
/// tools' shared page in rows and scroll down, so sideways is always the
/// pages' (§19.7 and §19.16, amended 2026-10-18).
enum ShelfLayout {
    // MARK: - The grid (§19.7)

    /// The shoulder the board's x was measured outside of.
    static let shoulder: CGFloat = 24

    /// A tile: 80 × 94, radius 16, on the board's 90 pitch across; rows are
    /// the same 10 pt apart, so 104 down.
    static let tile = CGSize(width: 80, height: 94)
    static let tileRadius: CGFloat = 16
    static let pitch: CGFloat = 90
    static var gap: CGFloat { pitch - tile.width }
    static var rowPitch: CGFloat { tile.height + gap }

    /// The first row's top: the board's 47.5, under the 38 pt header strip.
    static let firstRowTop: CGFloat = 47.5 - SurfaceLayout.referenceNotchHeight

    /// The least room the grid leaves either side. Six tiles fit 560 with 15
    /// either side; the board's 17.9 would have left five and a 50 pt margin.
    static let minimumSideMargin: CGFloat = 14

    /// The 16 pt fades at a clipped top or bottom of the grid.
    static let edgeFade: CGFloat = 16

    /// How many tiles a row holds at `bodyWidth`: five at 480, six at 560
    /// and 620.
    static func columns(bodyWidth: CGFloat) -> Int {
        max(1, Int((bodyWidth - 2 * minimumSideMargin + gap) / pitch))
    }

    /// The grid's leading edge: centred in the body, on a whole point.
    static func gridLeading(bodyWidth: CGFloat) -> CGFloat {
        let width = CGFloat(columns(bodyWidth: bodyWidth)) * pitch - gap
        return ((bodyWidth - width) / 2).rounded()
    }

    /// A tile's frame inside the grid's scrolled content.
    static func tileFrame(index: Int, bodyWidth: CGFloat) -> CGRect {
        let columns = columns(bodyWidth: bodyWidth)
        return CGRect(
            x: gridLeading(bodyWidth: bodyWidth) + CGFloat(index % columns) * pitch,
            y: firstRowTop + CGFloat(index / columns) * rowPitch,
            width: tile.width, height: tile.height
        )
    }

    static func rows(count: Int, bodyWidth: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let columns = columns(bodyWidth: bodyWidth)
        return (count + columns - 1) / columns
    }

    /// The grid's scrolled content: the rows, and the same margin under the
    /// last as over the first.
    static func contentHeight(count: Int, bodyWidth: CGFloat) -> CGFloat {
        let rows = rows(count: count, bodyWidth: bodyWidth)
        guard rows > 0 else { return 0 }
        return 2 * firstRowTop + CGFloat(rows - 1) * rowPitch + tile.height
    }

    /// The viewport the grid scrolls in: the body's whole width and its
    /// content between the header strip and the dots — 262 on any notch,
    /// since both move with it. Two rows and part of a third show, so a cut
    /// row says there is more.
    static func viewport(bodyWidth: CGFloat) -> CGRect {
        CGRect(
            x: 0, y: 0, width: bodyWidth,
            height: SurfaceLayout.toolPageHeight - SurfaceLayout.referenceNotchHeight
        )
    }

    /// Whether the grid scrolls at all: more rows than the viewport holds.
    static func scrolls(count: Int, bodyWidth: CGFloat) -> Bool {
        contentHeight(count: count, bodyWidth: bodyWidth) > viewport(bodyWidth: bodyWidth).height
    }

    /// The tile under `point`, in the grid's scrolled content, or nil between
    /// tiles. Decided from the layout, not from each tile's own hover: a tile
    /// that slides under a pointer that has not moved gets no hover event (the
    /// reason the grid this replaced worked this way).
    static func tileIndex(at point: CGPoint, count: Int, bodyWidth: CGFloat) -> Int? {
        let leading = gridLeading(bodyWidth: bodyWidth)
        guard point.x >= leading, point.y >= firstRowTop else { return nil }
        let column = Int((point.x - leading) / pitch)
        guard column < columns(bodyWidth: bodyWidth) else { return nil }
        let index = Int((point.y - firstRowTop) / rowPitch) * columns(bodyWidth: bodyWidth) + column
        guard index < count, tileFrame(index: index, bodyWidth: bodyWidth).contains(point) else { return nil }
        return index
    }

    /// The notice line's height and top: under the last row while the grid
    /// fits, and at the viewport's foot, over the fade, once it scrolls — so a
    /// notice never covers a tile in full view.
    static let noticeHeight: CGFloat = 14
    static func noticeTop(count: Int, bodyWidth: CGFloat) -> CGFloat {
        let lastRow = firstRowTop + CGFloat(max(rows(count: count, bodyWidth: bodyWidth) - 1, 0)) * rowPitch
        return min(lastRow + tile.height + 1, viewport(bodyWidth: bodyWidth).height - noticeHeight - 1)
    }

    // MARK: - The tray's width (§19.7, amended 2026-10-18)

    /// The board's tray body: 433.3 less its two 24 pt shoulders.
    static let referenceBodyWidth: CGFloat = SurfaceLayout.trayReference.width - 2 * shoulder

    /// The narrowest tray the header fits under a notch `notchWidth` wide.
    /// The board's 385.3 left the header about 100 pt either side of a 185 pt
    /// notch; under a 220 or 240 pt one (§19.12) the count had 17 pt for "60"
    /// and Remove All ran into the notch (R8 review). So the body is at least
    /// the notch plus what the header needs on its wider side, on both sides,
    /// since the tray is centred on the notch. Since the tray took the panel's
    /// width this is a floor the narrowest panel already clears; it stays so
    /// that a wider notch than any §19.12 names still cannot crowd the header.
    static func bodyWidth(notchWidth: CGFloat) -> CGFloat {
        max(referenceBodyWidth, notchWidth + 2 * headerSideRoom())
    }

    /// What the header needs on one side of the notch: the glyph and the
    /// count at its widest ("60", the Shelf's limit) on the left, Remove All
    /// in the language on screen on the right — each with the clearance every
    /// header item keeps from the notch.
    ///
    /// Kept for the language it was measured in. The tray's size is read many
    /// times on every frame of a swipe, and each read measured two strings
    /// afresh (R8b review P2); what it depends on is the localized "All".
    static func headerSideRoom() -> CGFloat {
        let all = localized("All")
        if let kept = keptSideRoom, kept.all == all { return kept.room }
        let room = measuredHeaderSideRoom()
        keptSideRoom = (all, room)
        return room
    }

    /// `headerSideRoom()` measured now.
    static func measuredHeaderSideRoom() -> CGFloat {
        let left = headerCountX + maximumCountWidth() + SurfaceHeaderLayout.notchClearance
        let right = removeAllRightRoom + removeAllWidth() + SurfaceHeaderLayout.notchClearance
        return ceil(max(left, right))
    }

    /// Read and written on the main thread only, where every layout is asked.
    nonisolated(unsafe) private static var keptSideRoom: (all: String, room: CGFloat)?

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

    /// `tray.full.fill`, 26 × 20, starting at 20 — where every summoned
    /// surface's title starts, now that the tray is their size — and the
    /// count, SF Pro Rounded 15, tabular, the board's 29.4 after it (52.6 and
    /// 82 on the board). Centred in the header strip.
    static let headerGlyph = CGSize(width: 26, height: 20)
    static let headerGlyphX: CGFloat = SurfaceHeaderLayout.titleLeading
    static let headerCountX: CGFloat = headerGlyphX + (82 - 52.6)
    static let headerCountSize: CGFloat = 15
    /// Remove All ends `gearClearance` before the gear's well (§19.16). The
    /// board ended it 44 from the shape's right edge, which is where the gear
    /// now stands.
    static let removeAllRightRoom: CGFloat = 46 + SurfaceHeaderLayout.gearClearance
    static func removeAllTrailing(bodyWidth: CGFloat) -> CGFloat { bodyWidth - removeAllRightRoom }

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
