import CoreGraphics
import SwiftUI

/// Where everything on the Clipboard tab sits (spec §9), as values.
///
/// Stated in the board's body coordinates, like `ShelfLayout` and `PlayerLayout`
/// before it, and converted to the pane's by `PlayerLayout.inPane`, so a test
/// that holds the spec's numbers holds the pixels at 480, 560 and 620 and in
/// Russian without rendering anything.
enum ClipboardLayout {
    // MARK: - Rows (§9.2)

    /// Rows 28 tall, 2 apart, from (58, 44): the pane's own leading edge and the
    /// first row below the header.
    static let rowHeight: CGFloat = 28
    static let rowGap: CGFloat = 2
    static let listOrigin = CGPoint(x: PlayerLayout.paneLeading, y: 44)
    static let rowRadius: CGFloat = 7

    /// `bw − 72`: 488 at 560.
    static func rowWidth(bodyWidth: CGFloat) -> CGFloat {
        PlayerLayout.paneWidth(bodyWidth: bodyWidth)
    }

    /// Inside a row, from its left edge: the leading mark's 20 pt box at 8
    /// (the board's 66 to 86 against a row that starts at 58), and the content
    /// at 36 (the board's 94).
    static let rowInset: CGFloat = 8
    static let markSide: CGFloat = 20
    static let contentLeading: CGFloat = 36
    /// The two hover buttons are 22 pt, 2 apart, and end where the age does —
    /// 8 from the row's trailing edge.
    static let buttonSide: CGFloat = 22
    static let buttonGap: CGFloat = 2

    /// The hairline under the pinned rows: it takes 7 pt of the list, the line
    /// itself 3 below the last pinned row's foot and 8 in from each side
    /// (472 wide at 560).
    static let separatorHeight: CGFloat = 7
    static let separatorInset: CGFloat = 8

    /// How long a row confirms a copy in place (spec §9.2). 1.2 s: the same beat
    /// the Shelf's "already kept" flash holds, so one gesture is one duration.
    static let copiedLifetime: TimeInterval = 1.2

    /// Where the list ends: 10 above the body's foot — 198 on the standard body,
    /// as the boards cut it. The pane clips there, and the 26 pt fade
    /// (`overflowFade`) is what softens the cut row.
    static let bottomInset: CGFloat = 10
    static let overflowFade: CGFloat = 26

    /// The window the list scrolls in: the first row's top to the foot. With a
    /// denied-access alert above it the list starts below the alert, and while
    /// Clear History is being asked the question's bar takes the foot.
    static func viewport(bodySize: CGSize, showsAlert: Bool = false, confirming: Bool = false) -> CGRect {
        let top = listOrigin.y + (showsAlert ? alertHeight + alertGap : 0)
        let bottom = confirming
            ? confirmBar(bodySize: bodySize).minY
            : bodySize.height - bottomInset
        return CGRect(
            x: listOrigin.x, y: top,
            width: rowWidth(bodyWidth: bodySize.width), height: max(0, bottom - top)
        )
    }

    /// The pane's size's body size: the inverse the shell cuts the pane from.
    static func bodySize(paneSize: CGSize, headerHeight: CGFloat) -> CGSize {
        ShelfLayout.bodySize(paneSize: paneSize, headerHeight: headerHeight)
    }

    // MARK: - Clear everything, asked once (§9.4)

    /// The bar at the foot: 34 tall, ending 8 above the body's bottom, with its
    /// own hairline along the top — `Clip-Clear-Everything`'s 166 on the 208 body.
    static let confirmHeight: CGFloat = 34
    static let confirmFootInset: CGFloat = 8

    static func confirmBar(bodySize: CGSize) -> CGRect {
        CGRect(
            x: listOrigin.x, y: bodySize.height - confirmFootInset - confirmHeight,
            width: rowWidth(bodyWidth: bodySize.width), height: confirmHeight
        )
    }

    // MARK: - Denied (§9.4)

    /// The inline alert: 488 × 44 at (58, 44), radius 9, the list 8 below it.
    static let alertHeight: CGFloat = 44
    static let alertGap: CGFloat = 8
    static let alertRadius: CGFloat = 9
    static let alertFillOpacity: Double = 0.12
    static let alertRingOpacity: Double = 0.35

    // MARK: - The Images grid (§9.2)

    static let imageTile = CGSize(width: 88, height: 66)
    static let imageGap: CGFloat = 12
    static let imageRadius: CGFloat = 8
    /// The age centred under a tile: its line, and the air before the next row.
    static let imageAgeHeight: CGFloat = 14
    static let imageAgeGap: CGFloat = 3
    static let imageRowGap: CGFloat = 10

    /// Tiles per row: five at 560 (5 × 88 + 4 × 12 = 488, the board's), four at
    /// 480, five at 620 where the last 48 points are the margin the fifth
    /// leaves rather than a sixth tile.
    static func imageColumns(bodyWidth: CGFloat) -> Int {
        let pane = rowWidth(bodyWidth: bodyWidth)
        return max(1, Int(((pane + imageGap) / (imageTile.width + imageGap)).rounded(.down)))
    }

    static func imageTileFrame(index: Int, columns: Int) -> CGRect {
        let row = index / columns
        let column = index % columns
        return CGRect(
            x: CGFloat(column) * (imageTile.width + imageGap),
            y: CGFloat(row) * (imageTile.height + imageAgeGap + imageAgeHeight + imageRowGap),
            width: imageTile.width, height: imageTile.height
        )
    }

    /// The grid's scrolled height, tiles and ages and the footnote under them.
    static func imageContentHeight(count: Int, columns: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        let row = imageTile.height + imageAgeGap + imageAgeHeight
        return CGFloat(rows) * row + CGFloat(rows - 1) * imageRowGap
    }
}

// MARK: - The header (§9.3)

/// The Clipboard header's tools, in header coordinates (the body's own, 8 below
/// the top for a 22 pt tool): the segmented filter, Search and Expand.
enum ClipboardHeader {
    /// Below this body width the segments become symbols and ages shorten
    /// (spec §9.3, §13, `Stress-Clip-RU-480`).
    static let symbolWidth: CGFloat = 540

    static func usesSymbols(bodyWidth: CGFloat) -> Bool { bodyWidth < symbolWidth }

    /// Whether the five names fit their 53 pt segments at the size they are
    /// drawn. "Изображения" is 76 pt wide, so the Russian control cannot be
    /// words at any width the panel has; the spec's rule is "below 540" and
    /// says nothing of a language, but a control that truncated its own labels
    /// would break the one rule §13 gives every layout — controls are never
    /// truncated — so the words fall back to symbols (with the names as their
    /// tooltips and labels) exactly where they would not fit. Measured, as the
    /// Shelf bar's fold is, rather than listed by language.
    static func wordsFit(measure: (String) -> CGFloat = { ShelfTileName.measure($0, selected: true) }) -> Bool {
        let segment = (wordsWidth - 4) / CGFloat(ClipFilter.allCases.count)
        return ClipFilter.allCases.allSatisfy { measure($0.title) + 8 <= segment }
    }

    /// The control as drawn: symbols below 540, and wherever the words do not fit.
    static func usesSymbolSegments(bodyWidth: CGFloat, wordsFit: Bool = ClipboardHeader.wordsFit()) -> Bool {
        usesSymbols(bodyWidth: bodyWidth) || !wordsFit
    }

    static let wordsWidth: CGFloat = 270
    static let symbolsWidth: CGFloat = 150

    /// The control's size: 270 × 20 with words, 150 × 20 with symbols.
    static func filterSize(bodyWidth: CGFloat, wordsFit: Bool = ClipboardHeader.wordsFit()) -> CGSize {
        CGSize(
            width: usesSymbolSegments(bodyWidth: bodyWidth, wordsFit: wordsFit) ? symbolsWidth : wordsWidth,
            height: 20
        )
    }

    static let filterTop: CGFloat = 9

    /// Search sits at `bw − 67` and Expand at `bw − 39`: 22 pt each, 6 apart.
    static func search(bodyWidth: CGFloat) -> CGRect {
        CGRect(x: bodyWidth - 67, y: HeaderToolFrames.top, width: HeaderToolFrames.side, height: HeaderToolFrames.side)
    }

    /// The filter rides the trailing edge with the two buttons: 11 clear of
    /// Search with words — where the spec's `212` comes from at 560, and why it
    /// is `bw − 348` here, so a wider body keeps the cluster together instead
    /// of leaving a gap — and 3 with symbols (`Stress-Clip-RU-480`'s 260 at
    /// 480).
    static func filter(bodyWidth: CGFloat, wordsFit: Bool = ClipboardHeader.wordsFit()) -> CGRect {
        let size = filterSize(bodyWidth: bodyWidth, wordsFit: wordsFit)
        let gap: CGFloat = usesSymbolSegments(bodyWidth: bodyWidth, wordsFit: wordsFit) ? 3 : 11
        return CGRect(
            x: search(bodyWidth: bodyWidth).minX - gap - size.width, y: filterTop,
            width: size.width, height: size.height
        )
    }

    /// The open search field: 294 × 22 at (250, 8) on 560, riding the same edge
    /// (its right edge is 544, inside Expand's) — it *replaces* the filter and
    /// Search, and Expand stays.
    static func searchField(bodyWidth: CGFloat) -> CGRect {
        CGRect(x: bodyWidth - 310, y: HeaderToolFrames.top, width: 294, height: 22)
    }

    static let searchFieldRadius: CGFloat = 7
    static let searchFieldFillOpacity: Double = 0.10
    /// The ⓧ inside the field's trailing end: 16 pt at 6 from the edge.
    static let clearSide: CGFloat = 16

    /// Search stays reachable while there is a history to look through, and
    /// only then. Expand follows the Shelf's rule: there while there is
    /// something to grow for, and while the body is already tall.
    static func showsTools(itemCount: Int, isExpanded: Bool, isSearching: Bool) -> Bool {
        itemCount > 0 || isExpanded || isSearching
    }

    static func showsSearch(itemCount: Int) -> Bool { itemCount > 0 }
}

// MARK: - A row's mark and content

/// What a row draws at its leading edge, decided from the kind and the cover so
/// each is a test.
enum ClipMark: Equatable {
    case symbol(String)
    /// The colour itself, 14 pt, radius 4.
    case swatch
    /// A covered colour's swatch: neutral, so the mark still says "a colour"
    /// and the value does not leak.
    case neutralSwatch
    /// The picture, 20 × 20, radius 4.
    case thumbnail
    /// The file's real icon at 20 pt.
    case fileIcon
    /// Three stacked icons, for several files.
    case fileStack

    /// The mark for an entry. Covered, the kind stays readable (spec §9.4) and
    /// the content never shows: a colour's swatch, a picture's thumbnail and a
    /// file's real icon would each give away the thing under the dots, so those
    /// draw their kind's glyph instead.
    static func mark(for kind: ClipKind, hidden: Bool) -> ClipMark {
        switch kind {
        case .text: return .symbol("text.alignleft")
        case .code: return .symbol("curlybraces")
        case .link: return .symbol("link")
        case .colour: return hidden ? .neutralSwatch : .swatch
        case .image: return hidden ? .symbol("photo") : .thumbnail
        case .file: return hidden ? .symbol("doc") : .fileIcon
        case .files: return hidden ? .symbol("doc.on.doc") : .fileStack
        }
    }
}

/// The two lines a file row shows after its name (spec §9.1).
enum ClipFileText {
    /// "Q3 Report.pdf" and "2.4 MB"; "3 files" and "A, B and 1 more".
    static func title(for item: ClipItem) -> String {
        if case .files(let urls) = item.payload { return localized("%d files", urls.count) }
        return item.preview
    }

    static func detail(for item: ClipItem) -> String? {
        switch item.payload {
        case .file:
            return item.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        case .files(let urls):
            let names = urls.map(\.lastPathComponent)
            switch names.count {
            case ..<2: return names.first
            case 2: return names.joined(separator: ", ")
            default: return localized("%@, %@ and %d more", names[0], names[1], names.count - 2)
            }
        default:
            return nil
        }
    }
}

/// An image row's second part: "1200 × 1200 · Photos".
enum ClipImageText {
    static func detail(_ image: ClipImage) -> String {
        [image.dimensionsText, image.sourceApp].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Clear History, asked once (§9.4)

/// "Clear %d entries? Pinned items stay." — in place, at the foot of the list,
/// with Cancel and Clear History. The Shelf's Clear asks the same way
/// (`ShelfClearConfirmation`), for the same reasons: the question says what
/// will happen, Escape answers it ("no") before Escape folds the panel, and it
/// does not lapse by itself.
///
/// The count is of what the clear would remove — the entries that are not
/// pinned — so the number on the button's question is the number that goes.
@MainActor
final class ClipboardClearConfirmation: ObservableObject {
    @Published private(set) var isAsking = false
    @Published private(set) var count = 0
    private var token: UUID?

    func ask(count: Int) {
        guard !isAsking, count > 0 else { return }
        self.count = count
        isAsking = true
        token = ArmedConfirmations.shared.register { [weak self] in self?.cancel() }
        Announcer.shared.announce(localized("Clear %d entries? Pinned items stay.", count))
    }

    func cancel() {
        if let token { ArmedConfirmations.shared.withdraw(token) }
        token = nil
        isAsking = false
    }

    /// Answers yes: puts the question away first, then acts.
    func confirm(_ action: () -> Void) {
        guard isAsking else { return }
        cancel()
        action()
    }
}
