import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Clipboard's numbers (spec §9, §13, §19.8), held as values at 480, 560 and 620
/// so a board that moves moves in `ClipboardLayout` and here. Frames are in the
/// content's coordinates — the board's y less the reference notch's 38, the x the
/// body's own now the rail is gone.
@MainActor
final class ClipboardLayoutTests: XCTestCase {
    // MARK: Rows

    /// Rows from y 84 on a 34 pitch, x 16 to `bw − 16`, radius 7: each 30 tall
    /// with 4 between.
    func testRowsAre30TallFourApartFromSixteenFortySix() {
        XCTAssertEqual(ClipboardLayout.rowHeight, 30)
        XCTAssertEqual(ClipboardLayout.rowGap, 4)
        XCTAssertEqual(ClipboardLayout.pitch, 34)
        XCTAssertEqual(ClipboardLayout.listOrigin, CGPoint(x: 16, y: 46), "the board's (16, 84) less the header row")
        XCTAssertEqual(ClipboardLayout.rowRadius, 7)
        XCTAssertEqual(ClipboardLayout.rowFrame(index: 2, bodyWidth: 560), CGRect(x: 0, y: 68, width: 528, height: 30))
    }

    func testRowsAreBodyWidthLessThirtyTwo() {
        XCTAssertEqual(ClipboardLayout.rowWidth(bodyWidth: 560), 528)
        XCTAssertEqual(ClipboardLayout.rowWidth(bodyWidth: 480), 448)
        XCTAssertEqual(ClipboardLayout.rowWidth(bodyWidth: 620), 588)
    }

    func testTheMarkAndContentSitWhereTheBoardPutsThem() {
        XCTAssertEqual(ClipboardLayout.rowInset, 8)
        XCTAssertEqual(ClipboardLayout.rowInset + ClipboardLayout.markSide, 28)
        XCTAssertEqual(ClipboardLayout.contentLeading, 36)
        XCTAssertEqual(ClipboardLayout.buttonSide, 22)
        // Two 22 pt buttons, 2 apart, end at the age's own edge: 46 from it.
        XCTAssertEqual(2 * ClipboardLayout.buttonSide + ClipboardLayout.buttonGap, 46)
        XCTAssertEqual(ClipboardLayout.copiedLifetime, 1.2)
    }

    func testTheListEndsTenAboveTheFootAndYieldsToTheAlertAndTheQuestion() {
        XCTAssertEqual(ClipboardLayout.contentHeight, 300 - 38)
        let standard = ClipboardLayout.viewport(bodyWidth: 560)
        XCTAssertEqual(standard, CGRect(x: 16, y: 46, width: 528, height: 206), "from the first row's top to 10 above the foot")
        XCTAssertEqual(standard.maxY, ClipboardLayout.contentHeight - 10)
        let alert = ClipboardLayout.viewport(bodyWidth: 560, showsAlert: true)
        XCTAssertEqual(alert.minY, 98, "the list sits 8 below the 44 pt alert")
        let asking = ClipboardLayout.viewport(bodyWidth: 560, confirming: true)
        XCTAssertEqual(asking.maxY, ClipboardLayout.confirmBar(bodyWidth: 560).minY)
        XCTAssertEqual(ClipboardLayout.overflowFade, 26)
        // Six rows are whole in the standard window: 5 gaps and a row.
        XCTAssertLessThanOrEqual(5 * ClipboardLayout.pitch + ClipboardLayout.rowHeight, standard.height)
    }

    func testTheQuestionBarIsTheBoards() {
        let bar = ClipboardLayout.confirmBar(bodyWidth: 560)
        XCTAssertEqual(bar, CGRect(x: 16, y: 220, width: 528, height: 34), "34 tall, ending 8 above the body's foot")
        XCTAssertEqual(bar.maxY, ClipboardLayout.contentHeight - 8)
    }

    func testTheDeniedAlertIsBodyLessThirtyTwoBy44WithTheWarningColours() {
        XCTAssertEqual(ClipboardLayout.alertHeight, 44)
        XCTAssertEqual(ClipboardLayout.alertRadius, 9)
        XCTAssertEqual(ClipboardLayout.alertFillOpacity, 0.12)
        XCTAssertEqual(ClipboardLayout.alertRingOpacity, 0.35)
        let warning = NSColor(Theme.warning).usingColorSpace(.sRGB)
        XCTAssertEqual(Double(warning?.redComponent ?? 0), 1, accuracy: 0.003)
        XCTAssertEqual(Double(warning?.greenComponent ?? 0), 159.0 / 255, accuracy: 0.003)
        XCTAssertEqual(Double(warning?.blueComponent ?? 0), 10.0 / 255, accuracy: 0.003)
    }

    // MARK: The Images grid

    func testTheImageGridIsFiveWideAtTheDefaultWidth() {
        XCTAssertEqual(ClipboardLayout.imageTile, CGSize(width: 88, height: 66))
        XCTAssertEqual(ClipboardLayout.imageGap, 12)
        XCTAssertEqual(ClipboardLayout.imageRadius, 8)
        XCTAssertEqual(ClipboardLayout.imageColumns(bodyWidth: 560), 5, "5 × 88 + 4 × 12 = 488 of 528")
        XCTAssertEqual(ClipboardLayout.imageColumns(bodyWidth: 480), 4, "4 × 88 + 3 × 12 = 388 of 448")
        XCTAssertEqual(ClipboardLayout.imageColumns(bodyWidth: 620), 6, "6 × 88 + 5 × 12 = 588 of 588: it just fits")
        // The board puts the tiles at 100 pt steps.
        XCTAssertEqual(ClipboardLayout.imageTileFrame(index: 3, columns: 5).minX, 300)
        XCTAssertEqual(ClipboardLayout.imageTileFrame(index: 0, columns: 5).size, CGSize(width: 88, height: 66))
        XCTAssertEqual(ClipboardLayout.imageTileFrame(index: 5, columns: 5).minX, 0, "the sixth starts a row")
        XCTAssertGreaterThan(ClipboardLayout.imageTileFrame(index: 5, columns: 5).minY, 66 + 14)
        XCTAssertEqual(ClipboardLayout.imageContentHeight(count: 0, columns: 5), 0)
        XCTAssertGreaterThan(
            ClipboardLayout.imageContentHeight(count: 6, columns: 5), ClipboardLayout.imageContentHeight(count: 5, columns: 5)
        )
    }

    // MARK: The search and the Kind filter

    /// The search field at (16, 46), 270 × 28, radius 8, white 0.10, and the
    /// Kind filter from (298, 48) to `bw − 16`, 24 tall (§19.8), both below
    /// the header strip: the first redesign put them in it and the notch sat
    /// on them.
    func testTheSearchFieldAndTheFilterAtTheDefaultWidth() {
        XCTAssertEqual(ClipboardHeader.searchField, CGRect(x: 16, y: 8, width: 270, height: 28))
        XCTAssertEqual(ClipboardHeader.filter(bodyWidth: 560), CGRect(x: 298, y: 10, width: 246, height: 24))
        XCTAssertEqual(ClipboardHeader.searchFieldRadius, 8)
        XCTAssertEqual(ClipboardHeader.searchFieldFillOpacity, 0.10)
        XCTAssertEqual(ClipboardHeader.searchRingWidth, 1.5)
        XCTAssertEqual(ClipboardHeader.searchRingOpacity, 0.70)
        XCTAssertEqual(ClipboardHeader.clearSide, 16)
    }

    func testTheFilterRidesTheTrailingMarginAtEveryWidth() {
        for width in [CGFloat(480), 540, 560, 620] {
            let filter = ClipboardHeader.filter(bodyWidth: width)
            XCTAssertEqual(filter.maxX, width - 16, "ends on the trailing margin at \(width)")
            XCTAssertEqual(filter.minX, 298)
            XCTAssertGreaterThan(filter.minX, ClipboardHeader.searchField.maxX, "right of the field at \(width)")
            XCTAssertEqual(ClipboardHeader.controlFrames(bodyWidth: width).map(\.name), ["Search field", "Kind filter"])
            XCTAssertEqual(ClipboardLayout.rowFrame(index: 0, bodyWidth: width).minX + ClipboardLayout.listOrigin.x, 16)
            XCTAssertLessThan(filter.maxY, ClipboardLayout.listOrigin.y, "the row ends above the list")
            XCTAssertLessThan(ClipboardHeader.searchField.maxY, ClipboardLayout.listOrigin.y)
        }
    }

    /// Where the four names do not fit the filter as words — 480 in English,
    /// every width in Russian — the segments are symbols with the names as
    /// tooltips and labels (§13: a control is never truncated). Below 540 the
    /// ages shorten.
    func testTheSegmentsAreSymbolsWhereTheWordsDoNotFit() {
        XCTAssertFalse(ClipboardHeader.usesSymbolSegments(bodyWidth: 560), "English fits at the default")
        XCTAssertFalse(ClipboardHeader.usesSymbolSegments(bodyWidth: 620))
        XCTAssertTrue(ClipboardHeader.usesSymbolSegments(bodyWidth: 480), "English does not fit 166 pt")
        // The rule itself, from a measure of the test's choosing: four segments
        // of the widest name and 8 of air, and the control's 4.
        XCTAssertTrue(ClipboardHeader.wordsFit(bodyWidth: 560, measure: { _ in 20 }))
        XCTAssertFalse(ClipboardHeader.wordsFit(bodyWidth: 560, measure: { _ in 100 }))
        XCTAssertEqual(ClipboardHeader.segmentWidth(measure: { _ in 40 }), 48)
        // 4 × (60 + 8) + 4 = 276: past the 246 pt filter at 560, inside 306 at 620.
        XCTAssertFalse(ClipboardHeader.wordsFit(bodyWidth: 560, measure: { _ in 60 }))
        XCTAssertTrue(ClipboardHeader.wordsFit(bodyWidth: 620, measure: { _ in 60 }))

        XCTAssertTrue(ClipboardHeader.usesNarrowAges(bodyWidth: 539))
        XCTAssertFalse(ClipboardHeader.usesNarrowAges(bodyWidth: 540))
        XCTAssertFalse(ClipboardHeader.usesNarrowAges(bodyWidth: 620))
    }

    func testTheKindControlIsFourNamedChoicesInBothModes() async {
        for width in [CGFloat(480), 560] {
            let control = ClipboardKindControl(selection: .constant(.links), bodyWidth: width)
            let root = await AXProbe.tree(of: control, size: ClipboardHeader.filter(bodyWidth: width).size)
            let groups = root.all(role: "AXRadioGroup")
            XCTAssertEqual(groups.map { $0.label.isEmpty ? $0.title : $0.label }, ["Kind"], "a radio group named Kind at \(width)\n\(root.dump)")
            let names = root.all(role: "AXRadioButton").map { $0.title.isEmpty ? $0.label : $0.title }
            XCTAssertEqual(names, ["All", "Text", "Links", "Images"], "named even as symbols\n\(root.dump)")
        }
    }

    // MARK: Marks and the text beside them

    func testEachKindHasItsMarkAndACoveredRowKeepsTheKindButNotTheContent() {
        XCTAssertEqual(ClipMark.mark(for: .text, hidden: false), .symbol("text.alignleft"))
        XCTAssertEqual(ClipMark.mark(for: .code, hidden: false), .symbol("curlybraces"))
        XCTAssertEqual(ClipMark.mark(for: .link, hidden: false), .symbol("link"))
        XCTAssertEqual(ClipMark.mark(for: .colour, hidden: false), .swatch)
        XCTAssertEqual(ClipMark.mark(for: .image, hidden: false), .thumbnail)
        XCTAssertEqual(ClipMark.mark(for: .file, hidden: false), .fileIcon)
        XCTAssertEqual(ClipMark.mark(for: .files, hidden: false), .fileStack)

        XCTAssertEqual(ClipMark.mark(for: .text, hidden: true), .symbol("text.alignleft"))
        XCTAssertEqual(ClipMark.mark(for: .code, hidden: true), .symbol("curlybraces"))
        XCTAssertEqual(ClipMark.mark(for: .link, hidden: true), .symbol("link"))
        XCTAssertEqual(ClipMark.mark(for: .colour, hidden: true), .neutralSwatch, "the swatch would be the colour")
        XCTAssertEqual(ClipMark.mark(for: .image, hidden: true), .symbol("photo"), "the thumbnail would be the picture")
        XCTAssertEqual(ClipMark.mark(for: .file, hidden: true), .symbol("doc"))
        XCTAssertEqual(ClipMark.mark(for: .files, hidden: true), .symbol("doc.on.doc"))
    }

    func testCoveredDotsAreProportionalToTheKind() {
        XCTAssertEqual(
            [ClipKind.text, .code, .link, .colour, .image, .files, .file].map(\.coverFraction),
            [0.9, 0.8, 0.75, 0.3, 0.55, 0.6, 0.45]
        )
    }

    func testFileRowsNameTheFileOrTheCount() {
        let one = ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/Q3 Report.pdf")), date: .distantPast)
        XCTAssertEqual(ClipFileText.title(for: one), "Q3 Report.pdf")
        let three = ClipItem(
            payload: .files(["Q3 Report.pdf", "Launch deck.key", "notes.txt"].map { URL(fileURLWithPath: "/tmp/\($0)") }),
            date: .distantPast
        )
        XCTAssertEqual(ClipFileText.title(for: three), "3 files")
        XCTAssertEqual(ClipFileText.detail(for: three), "Q3 Report.pdf, Launch deck.key and 1 more")
        let two = ClipItem(payload: .files(["a.key", "b.key"].map { URL(fileURLWithPath: "/tmp/\($0)") }), date: .distantPast)
        XCTAssertEqual(ClipFileText.detail(for: two), "a.key, b.key")
    }

    func testAFilesSizeIsReadOnceAtCapture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isla-clip-size-\(UUID().uuidString).bin")
        try Data(count: 2_400_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = ClipItem(payload: .file(url), date: .distantPast)
        XCTAssertEqual(item.fileSize, 2_400_000)
        XCTAssertEqual(ClipFileText.detail(for: item), ByteCountFormatter.string(fromByteCount: 2_400_000, countStyle: .file))
        XCTAssertNil(ClipItem(payload: .file(URL(fileURLWithPath: "/nonexistent/isla")), date: .distantPast).fileSize)
    }

    // MARK: Tokens

    func testTheFindHighlightIsTheSpecsYellowOnNearBlack() {
        func rgb(_ color: Color) -> [Int] {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            return [ns.redComponent, ns.greenComponent, ns.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        XCTAssertEqual(rgb(Theme.findHighlight), [0xFF, 0xD6, 0x0A])
        XCTAssertEqual(rgb(Theme.findHighlightText), [0x1D, 0x1D, 0x1F])
    }

    func testTheWellsStepUpUnderIncreaseContrast() {
        XCTAssertEqual(Theme.clipboardWellOpacity(increaseContrast: false), 0.08)
        XCTAssertGreaterThan(Theme.clipboardWellOpacity(increaseContrast: true), 0.08)
        XCTAssertEqual(Theme.searchFieldOpacity(increaseContrast: false), 0.10)
        XCTAssertGreaterThan(Theme.searchFieldOpacity(increaseContrast: true), 0.10)
    }
}
