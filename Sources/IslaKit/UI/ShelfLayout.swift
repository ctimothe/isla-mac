import AppKit
import SwiftUI

/// Where everything on the Shelf sits (spec §8), as values.
///
/// The board is drawn in body coordinates, like the player's (`PlayerLayout`):
/// the origin is the open body's top-left corner and the first `headerHeight`
/// points are the header row. Every frame here is stated in those terms, as the
/// spec writes it, and the view converts through `PlayerLayout.inPane` — the
/// one conversion the app has — so a test that holds the spec's numbers holds
/// the pixels, at 480, 560 and 620 and in Russian, without rendering anything.
///
/// It replaces the horizontal strip of 86 × 92 card plates, whose geometry was
/// spread over `ShelfItem.cardWidth`, the card's own paddings and a scroll view
/// that never knew how wide the panel had been set.
enum ShelfLayout {
    // MARK: - The grid (§8.1)

    /// A tile: 78 × 100, 4 apart across and 8 apart down.
    static let tile = CGSize(width: 78, height: 100)
    static let columnGap: CGFloat = 4
    static let rowGap: CGFloat = 8
    /// The first tile's top-left, in body coordinates. Its x is the pane's own
    /// leading edge (`PlayerLayout.paneLeading`), so the grid starts flush with
    /// the rail's right gap as the player's cover does.
    static let gridOrigin = CGPoint(x: PlayerLayout.paneLeading, y: 44)
    static let minimumColumns = 5

    static var pitch: CGSize {
        CGSize(width: tile.width + columnGap, height: tile.height + rowGap)
    }

    /// How many tiles fill a row at this body width: `bw − 72` is the pane,
    /// and a row of `n` tiles is `82 n − 4` wide (the last has no gap after
    /// it), so `n = ⌊(bw − 72 + 4) / 82⌋`. Six fill the 560 body to the point —
    /// 6 × 78 + 5 × 4 = 488 — and five fill 480 with 2 to spare.
    ///
    /// The spec's prose writes `(bw − 72) / 82`, which is 5.95 at 560 and so
    /// drops a column the same paragraph says is there; the gap after the last
    /// tile is not a tile's worth of room, and the boards draw six. Never below
    /// five, which is also what 480 gives.
    static func columns(bodyWidth: CGFloat) -> Int {
        let pane = PlayerLayout.paneWidth(bodyWidth: bodyWidth)
        return max(minimumColumns, Int(((pane + columnGap) / pitch.width).rounded(.down)))
    }

    static func rows(count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        return (count + columns - 1) / columns
    }

    /// Tile `index`'s frame, in the grid's own coordinates (the scrolled
    /// content's, origin at the first tile's top-left). Newest first, row by
    /// row.
    static func tileFrame(index: Int, columns: Int) -> CGRect {
        let row = index / columns
        let column = index % columns
        return CGRect(
            x: CGFloat(column) * pitch.width, y: CGFloat(row) * pitch.height,
            width: tile.width, height: tile.height
        )
    }

    /// The tile under a point in the grid's coordinates, or nil between tiles
    /// and past the last one.
    ///
    /// Pure so hover is a *decision* rather than a side effect of tracking
    /// areas moving with their views: the pane re-asks it whenever the pointer
    /// moves, the shelf changes or the content scrolls, which is what keeps a
    /// ✕ under a pointer that has not moved after the card above it was
    /// removed (the bug `ShelfPane`'s old comment describes).
    static func tileIndex(at point: CGPoint, count: Int, columns: Int) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / pitch.width)
        let row = Int(point.y / pitch.height)
        guard column < columns else { return nil }
        let index = row * columns + column
        guard index < count, tileFrame(index: index, columns: columns).contains(point) else { return nil }
        return index
    }

    /// The scrolled content's height: the rows, plus the 7 pt the last row's
    /// age spills under its 100 pt tile when a name takes two lines (the
    /// board's name block is 65 + 28 + 2 + 12 tall).
    static func contentHeight(count: Int, columns: Int) -> CGFloat {
        let rows = rows(count: count, columns: columns)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * pitch.height - rowGap + nameOverhang
    }

    static let nameOverhang: CGFloat = 8

    // MARK: - A tile (§8.1, §8.2)

    /// The icon or thumbnail: 52 × 52 at (13, 5) in the tile.
    static let icon = CGRect(x: 13, y: 5, width: 52, height: 52)
    /// The selection and hover well behind the icon: 60 × 60 at (9, 1), radius
    /// 8 (spec §2.3).
    static let well = CGRect(x: 9, y: 1, width: 60, height: 60)
    static let wellRadius: CGFloat = 8
    /// The ⓧ remove badge: 18 pt at the tile's (4, −3), so it overhangs the
    /// tile's top edge by 3.
    static let badge = CGRect(x: 4, y: -3, width: 18, height: 18)
    /// The name block: starts 65 below the tile's top, 6 wider than the tile on
    /// each side so a full-width highlight is not clipped, centred.
    static let nameTop: CGFloat = 65
    static let nameBleed: CGFloat = 6
    /// The column a name is broken and cut to. The board's text block is 76
    /// wide (the tile less 2); two points less again are held back so the
    /// measure and the drawing can differ by a hair without a third line.
    static let nameWidth: CGFloat = 74
    static let nameLineHeight: CGFloat = 14
    static let ageLineHeight: CGFloat = 12
    static let maximumNameLines = 2

    /// A thumbnail's size, fitted in the 52 pt box the way Finder fits one: the
    /// picture's own shape, its long side 52, never enlarged past it. The
    /// white border and the shadow are drawn on *this* rect, not on the box —
    /// a landscape screenshot has no border round the empty band above it.
    static func fittedSize(of image: CGSize, in box: CGFloat = icon.width) -> CGSize {
        guard image.width > 0, image.height > 0 else { return CGSize(width: box, height: box) }
        let scale = box / max(image.width, image.height)
        return CGSize(width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
    }

    // MARK: - The pane's regions (body coordinates)

    /// The bar's top: 37 above the body's foot, which is 22 tall and 15 clear
    /// of the edge. The board draws 171 on the 208 body.
    static func barTop(bodyHeight: CGFloat) -> CGFloat { bodyHeight - 37 }
    static let barHeight: CGFloat = 22
    /// The air kept between the grid's viewport and the bar.
    static let barClearance: CGFloat = 6

    /// The window the grid scrolls in: from the first row's top to just above
    /// the bar, the pane's full width.
    ///
    /// On the 208 body that is 121 points — one row and 21 of the next, which
    /// the 26 pt mask fades out so the second row is a hint of more, not a
    /// row cut by the bar. (The spec's prose says two rows show; its own
    /// coordinates, and every board, leave room for one and a quarter.)
    /// Expanded, 313 points is three rows.
    static func viewport(bodySize: CGSize) -> CGRect {
        let top = gridOrigin.y
        return CGRect(
            x: gridOrigin.x, y: top,
            width: PlayerLayout.paneWidth(bodyWidth: bodySize.width),
            height: max(0, barTop(bodyHeight: bodySize.height) - barClearance - top)
        )
    }

    /// The fade at the viewport's foot while a row is cut by it (spec §8.1).
    static let overflowFade: CGFloat = 26

    /// Where the bar sits: from the pane's leading edge to its trailing one.
    static func bar(bodySize: CGSize) -> CGRect {
        CGRect(
            x: gridOrigin.x, y: barTop(bodyHeight: bodySize.height),
            width: PlayerLayout.paneWidth(bodyWidth: bodySize.width), height: barHeight
        )
    }

    /// The body size a pane of this size belongs to, on a notch whose header is
    /// `headerHeight` tall: the inverse of what the shell cuts the pane from
    /// (`NotchGeometry.contentHeight(forBodyHeight:)`).
    static func bodySize(paneSize: CGSize, headerHeight: CGFloat) -> CGSize {
        CGSize(
            width: PlayerLayout.bodyWidth(paneWidth: paneSize.width),
            height: paneSize.height + headerHeight + NotchGeometry.bodyBottomPadding
        )
    }
}

// MARK: - A tile's well (§8.2, §8.4)

/// The rounded square drawn behind a tile's icon, if any, and in what dress.
///
/// One value for the three things that light it, so the order they win in is a
/// test: an "already kept" flash over a click's selection over the pointer's
/// hover. The flash wins because it is the one the person did not cause by
/// pointing, and the one that has to be seen in the second it lasts.
enum ShelfWell: Equatable {
    /// White 0.07, with the ⓧ badge (§8.2).
    case hover
    /// White 0.14, with the name highlighted in the accent (§8.2).
    case selected
    /// The tile a drop matched without adding (§8.4, `Shelf-Already`): the
    /// 60 × 60 well, lit in the accent at 0.18 inside a 2 pt accent ring — the
    /// drop wells' own lit look, so "this is where it went" is one visual word.
    /// The spec's prose says only "its selection well"; the board lights it in
    /// the accent, because a plain 0.14 well is indistinguishable from a click
    /// and the flash exists to be told apart from one.
    case alreadyKept

    static func state(isSelected: Bool, isHovered: Bool, isAlreadyKept: Bool) -> ShelfWell? {
        if isAlreadyKept { return .alreadyKept }
        if isSelected { return .selected }
        if isHovered { return .hover }
        return nil
    }
}

// MARK: - The header (§8.1)

/// What the Shelf's header says at its trailing edge.
enum ShelfHeader {
    /// "%d items", or "1 item" — the spec's one string is plural-only, and a
    /// shelf of one is common enough (a screenshot just taken) that "1 items"
    /// would be read on most days. Russian takes the same shape for every
    /// number ("Всего: %d", which replaced "Объектов: %d" in review 2026-10-15 for the width).
    static func countText(_ count: Int) -> String {
        count == 1 ? localized("1 item") : localized("%d items", count)
    }

    /// What the count keeps clear of the header's own 16 pt trailing padding:
    /// the 22 pt Expand button and the 8 pt gap before it, less the 1 pt the
    /// source tag's padding adds — 31 puts the count's right edge at `bw − 47`,
    /// where the board has it.
    static let countClearance: CGFloat = 31

    /// Where the count sits in the header, in body coordinates, for a text
    /// `textWidth` wide: right-aligned to `bw − 47` (see `countClearance`),
    /// 22 tall at the tools' own 8 from the top. Stated so the notch-band test
    /// can hold that the notch (centred on the body, 185 to 220 pt wide) never
    /// covers it — a longer Russian count reaches furthest toward it.
    static func countFrame(bodyWidth: CGFloat, textWidth: CGFloat) -> CGRect {
        CGRect(
            x: bodyWidth - 47 - textWidth, y: HeaderToolFrames.top,
            width: textWidth, height: HeaderToolFrames.side
        )
    }

    /// The count is drawn with items on the Shelf, and never over the empty
    /// well (`Shelf-Empty` has none).
    static func showsCount(itemCount: Int) -> Bool { itemCount > 0 }

    /// Expand is there while there is something to grow for — and while the
    /// body is already tall, even if the last item has just left it. Clear on
    /// the tall Shelf empties it; hiding Collapse then would strand the
    /// person in a 400 pt well with no way back to 208.
    static func showsExpand(itemCount: Int, isExpanded: Bool) -> Bool {
        itemCount > 0 || isExpanded
    }
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

    /// The name as it is drawn: the body role, regular — medium while picked,
    /// as Finder sets a selected name — with the role's tracking. A count of
    /// characters is no measure of a proportional line, which is the lesson of
    /// `ShelfItem.measureCardName` this replaces.
    static func measure(_ text: String, selected: Bool = false) -> CGFloat {
        let size = Theme.TypeRole.body.size
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: selected ? .medium : .regular),
            .kern: Theme.tracking(forSize: size),
        ]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }
}

// MARK: - The bar (§8.2, §13)

/// Whether a verb belongs to the bar's selection group.
enum ShelfVerb: CaseIterable, Equatable {
    case quickLook, airDrop, copy, showInFinder, remove

    var title: String {
        switch self {
        case .quickLook: return localized("Quick Look")
        case .airDrop: return localized("AirDrop")
        case .copy: return localized("Copy")
        case .showInFinder: return localized("Show in Finder")
        case .remove: return localized("Remove")
        }
    }

    var symbol: String {
        switch self {
        case .quickLook: return "eye"
        case .airDrop: return "dot.radiowaves.up.forward"
        case .copy: return "doc.on.doc"
        case .showInFinder: return "folder"
        case .remove: return "trash"
        }
    }
}

/// What the bar at the foot of the Shelf shows, decided from the shelf's state
/// alone so each of the spec's states is a test and not a screenshot.
///
/// - Selection: "%d selected", the Deselect All ⓧ, and the five verbs.
/// - Nothing selected: the drag hint and Clear.
/// - A notice replaces the leading text — the eviction sentence, "Already on
///   the Shelf", an AirDrop refusal — as before (`ShelfStore.Notice`).
/// - Clearing: the question and its two answers replace everything.
/// - Below `ShelfBar.moreWidth` the bar keeps Quick Look and Remove and moves
///   the rest into a "…" menu (`Stress-Shelf-RU-480`).
struct ShelfBar: Equatable {
    enum Leading: Equatable {
        case selection(count: Int)
        case notice(ShelfStore.Notice)
        case hint
        /// "Remove all %d items? Files are untouched."
        case clearQuestion(count: Int)
    }

    enum Trailing: Equatable {
        /// The five verbs, in order, with the ones that did not fit moved
        /// under "…" when `overflow` is not empty.
        case verbs(inline: [ShelfVerb], overflow: [ShelfVerb])
        case clear
        case confirmClear
        case nothing
    }

    var leading: Leading
    var trailing: Trailing

    /// Below this body width the bar folds (spec §8.2, §13).
    static let moreWidth: CGFloat = 540

    /// The verbs kept inline when the bar folds.
    static let foldedInline: [ShelfVerb] = [.quickLook, .remove]

    static func verbs(bodyWidth: CGFloat) -> (inline: [ShelfVerb], overflow: [ShelfVerb]) {
        guard bodyWidth < moreWidth else { return (ShelfVerb.allCases, []) }
        return (foldedInline, ShelfVerb.allCases.filter { !foldedInline.contains($0) })
    }

    /// This bar with the verbs folded, whatever the width: what the view falls
    /// back to when the full row does not fit its pane — Russian's "Быстрый
    /// просмотр" and "Показать в Finder" overrun 488 pt well above 540, which
    /// is where the spec folds.
    var folded: ShelfBar {
        guard case .verbs = trailing else { return self }
        return ShelfBar(
            leading: leading,
            trailing: .verbs(
                inline: Self.foldedInline,
                overflow: ShelfVerb.allCases.filter { !Self.foldedInline.contains($0) }
            )
        )
    }

    static func make(
        itemCount: Int, selectionCount: Int, notice: ShelfStore.Notice?,
        isConfirmingClear: Bool, bodyWidth: CGFloat
    ) -> ShelfBar {
        if isConfirmingClear && itemCount > 0 {
            return ShelfBar(leading: .clearQuestion(count: itemCount), trailing: .confirmClear)
        }
        // A notice owns the leading slot while nothing is selected, or when it
        // answers a press of a verb in this very bar (`showsOverSelection`).
        let noticeWins = notice.map { selectionCount == 0 || $0.showsOverSelection } ?? false
        if selectionCount > 0 {
            let folded = verbs(bodyWidth: bodyWidth)
            return ShelfBar(
                leading: noticeWins ? .notice(notice!) : .selection(count: selectionCount),
                trailing: .verbs(inline: folded.inline, overflow: folded.overflow)
            )
        }
        return ShelfBar(leading: noticeWins ? .notice(notice!) : .hint, trailing: itemCount > 0 ? .clear : .nothing)
    }
}

// MARK: - Dropping in (§8.3)

/// Which of the two wells a drag would land on.
enum ShelfDropTarget: Equatable {
    case keep
    case airDrop

    /// The well's own caption at rest, and lit.
    var restingCaption: String {
        switch self {
        case .keep: return localized("Drop to keep on the Shelf")
        case .airDrop: return localized("Send to a nearby device")
        }
    }

    var litCaption: String {
        switch self {
        case .keep: return localized("Release to add to the Shelf")
        case .airDrop: return localized("Release to send with AirDrop")
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
        case .keep: return "tray.and.arrow.down"
        case .airDrop: return "dot.radiowaves.up.forward"
        }
    }

    // MARK: Geometry

    /// The two wells, in body coordinates: side by side across the pane, 8
    /// apart, from y 46 down to 22 above the body's foot — 140 tall on the
    /// standard body, as the board draws, and filling the tall one.
    static let wellTop: CGFloat = 46
    static let wellGap: CGFloat = 8
    static let wellFootInset: CGFloat = 22

    static func well(_ target: ShelfDropTarget, bodySize: CGSize) -> CGRect {
        let pane = PlayerLayout.paneWidth(bodyWidth: bodySize.width)
        let width = (pane - wellGap) / 2
        let x = PlayerLayout.paneLeading + (target == .keep ? 0 : width + wellGap)
        return CGRect(
            x: x, y: wellTop, width: width,
            height: max(0, bodySize.height - wellFootInset - wellTop)
        )
    }

    /// The target a drop at `point` (body coordinates) takes.
    ///
    /// AirDrop is chosen only by being *over* its well — the well's frame, with
    /// the gap between the two counted as AirDrop's half so the choice does not
    /// flicker through a dead strip. Everywhere else — the other well, the
    /// header, the rail, the margins — is Keep: the window accepts a drop all
    /// over the panel (`NotchRootView.dropRect`), keeping has always been what a
    /// drop does, and a stray release must never send someone's file to a
    /// stranger's phone.
    static func target(atBodyPoint point: CGPoint, bodySize: CGSize) -> ShelfDropTarget {
        let airDrop = well(.airDrop, bodySize: bodySize)
        let zone = CGRect(
            x: airDrop.minX - wellGap / 2, y: airDrop.minY,
            width: airDrop.width + wellGap / 2, height: airDrop.height
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
