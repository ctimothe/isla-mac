import AppKit
import SwiftUI

/// Where everything on Clipboard sits (spec §19.8, board `R2-Clipboard`), as
/// values, in the content's coordinates: the board's body coordinates less the
/// reference notch's 38 (`SurfaceLayout.inContent`). A test that holds the
/// spec's numbers holds the pixels at 480, 560 and 620 and in Russian without
/// rendering anything. The header — the glyph, "Clipboard" and Tools — is the
/// shell's.
enum ClipboardLayout {
    // MARK: - Rows (§19.8)

    /// Rows from y 84 on a 34 pitch, x 16 to `bw − 16`, radius 7: each 30
    /// tall, so a selected row's white 0.10 never touches the next.
    static let rowHeight: CGFloat = 30
    static let rowGap: CGFloat = 4
    static var pitch: CGFloat { rowHeight + rowGap }
    static let listOrigin = CGPoint(x: 16, y: 84 - SurfaceLayout.referenceNotchHeight)
    static let rowRadius: CGFloat = 7

    static func rowWidth(bodyWidth: CGFloat) -> CGFloat { bodyWidth - 32 }

    /// A row's frame inside the scrolled list, before any separator.
    static func rowFrame(index: Int, bodyWidth: CGFloat) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * pitch, width: rowWidth(bodyWidth: bodyWidth), height: rowHeight)
    }

    /// Inside a row, from its left edge: the kind's mark in a 20 pt box at 8,
    /// and the text at 36.
    static let rowInset: CGFloat = 8
    static let markSide: CGFloat = 20
    static let contentLeading: CGFloat = 36
    /// The hover buttons: 22 pt, 2 apart, ending where the age does.
    static let buttonSide: CGFloat = 22
    static let buttonGap: CGFloat = 2

    /// The hairline under the pinned rows: 7 pt of list with the line in its
    /// middle, 8 in from each side.
    static let separatorHeight: CGFloat = 7
    static let separatorInset: CGFloat = 8

    /// How long a row confirms a copy in place (spec §9.2). 1.2 s: the same beat
    /// the Shelf's "already kept" flash holds, so one gesture is one duration.
    static let copiedLifetime: TimeInterval = 1.2

    /// Where the list ends: 10 above the body's foot. The 26 pt fade softens
    /// the row it cuts.
    static let bottomInset: CGFloat = 10
    static let overflowFade: CGFloat = 26

    /// The content's height on the 300 pt body.
    static var contentHeight: CGFloat { SurfaceLayout.clipboardHeight - SurfaceLayout.referenceNotchHeight }

    /// The window the list scrolls in: the first row's top to the foot. With a
    /// denied-access alert above it the list starts below the alert, and while
    /// Clear History is being asked the question's bar takes the foot.
    static func viewport(bodyWidth: CGFloat, showsAlert: Bool = false, confirming: Bool = false) -> CGRect {
        let top = listOrigin.y + (showsAlert ? alertHeight + alertGap : 0)
        let bottom = confirming ? confirmBar(bodyWidth: bodyWidth).minY : contentHeight - bottomInset
        return CGRect(x: listOrigin.x, y: top, width: rowWidth(bodyWidth: bodyWidth), height: max(0, bottom - top))
    }

    // MARK: - Clear everything, asked once (§9.4)

    /// The bar at the foot: 34 tall, ending 8 above the body's bottom, with its
    /// own hairline along the top.
    static let confirmHeight: CGFloat = 34
    static let confirmFootInset: CGFloat = 8

    static func confirmBar(bodyWidth: CGFloat) -> CGRect {
        CGRect(
            x: listOrigin.x, y: contentHeight - confirmFootInset - confirmHeight,
            width: rowWidth(bodyWidth: bodyWidth), height: confirmHeight
        )
    }

    // MARK: - Denied (§9.4)

    /// The inline alert: `bw − 32` × 44 at the list's origin, radius 9, the list 8 below it.
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

    /// Tiles per row across the list's width.
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

    /// The grid's scrolled height, tiles and ages.
    static func imageContentHeight(count: Int, columns: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        let row = imageTile.height + imageAgeGap + imageAgeHeight
        return CGFloat(rows) * row + CGFloat(rows - 1) * imageRowGap
    }
}

// MARK: - The search and the Kind filter (§19.8)

/// The row under the header strip: the search field at (16, 46), 270 × 28,
/// radius 8, and the Kind filter — All, Text, Links, Images — from (298, 46)
/// to `bw − 16`, the same 28 tall, so the two read as one row of controls.
/// Both sit below the strip, so the notch, which occupies its middle, covers
/// neither (`HeaderNotchBandTests`).
///
/// One height since 2026-10-18. The filter was 24 at y 48, and the field's
/// fill hugged its text rather than its 28-point frame, so the field drew
/// shorter than the filter beside it — "too stuck", in the owner's words.
enum ClipboardHeader {
    static let controlHeight: CGFloat = 28
    static let searchField = SurfaceLayout.inContent(CGRect(x: 16, y: 46, width: 270, height: controlHeight))
    static let searchFieldRadius: CGFloat = 8
    static let searchFieldFillOpacity: Double = 0.10
    /// The field's ring while it has the keyboard: 1.5 pt of blue at 0.70.
    static let searchRingWidth: CGFloat = 1.5
    static let searchRingOpacity: Double = 0.70
    /// The ⓧ inside the field's trailing end: 16 pt.
    static let clearSide: CGFloat = 16

    /// The filter's frame: from x 298 to `bw − 16`, the field's 28 at its y.
    static let filterHeight: CGFloat = controlHeight
    static func filter(bodyWidth: CGFloat) -> CGRect {
        SurfaceLayout.inContent(CGRect(x: 298, y: 46, width: max(0, bodyWidth - 16 - 298), height: filterHeight))
    }

    /// The widest kind's name at the size it is drawn, plus 8 of air.
    static func segmentWidth(measure: (String) -> CGFloat = Self.measure) -> CGFloat {
        (ClipboardBrowser.filters.map { measure($0.title) + 8 }.max() ?? 0)
    }

    /// Whether the four names fit the filter's width as words. Where they do
    /// not — 480 in English, every width in Russian — the segments are symbols
    /// with the names as tooltips and labels: §13's rule that a control is
    /// never truncated.
    static func wordsFit(bodyWidth: CGFloat, measure: (String) -> CGFloat = Self.measure) -> Bool {
        CGFloat(ClipboardBrowser.filters.count) * segmentWidth(measure: measure) + 4 <= filter(bodyWidth: bodyWidth).width
    }

    static func usesSymbolSegments(bodyWidth: CGFloat) -> Bool { !wordsFit(bodyWidth: bodyWidth) }

    /// Below 540 the ages shorten (spec §9.3, §13).
    static let narrowAgeWidth: CGFloat = 540
    static func usesNarrowAges(bodyWidth: CGFloat) -> Bool { bodyWidth < narrowAgeWidth }

    /// A segment's name, 12 medium as the selected one is drawn.
    static func measure(_ text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    /// Every control under the strip, in content coordinates, for the notch
    /// test and anyone else who needs to ask what is where.
    static func controlFrames(bodyWidth: CGFloat) -> [(name: String, frame: CGRect)] {
        [("Search field", searchField), ("Kind filter", filter(bodyWidth: bodyWidth))]
    }
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
