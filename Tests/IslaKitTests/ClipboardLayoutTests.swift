import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Clipboard's numbers (redesign spec §9, §13), held as values at 480, 560
/// and 620 so a board that moves moves in `ClipboardLayout` and here.
@MainActor
final class ClipboardLayoutTests: XCTestCase {
    private func body(_ width: CGFloat, _ height: CGFloat = 208) -> CGSize { CGSize(width: width, height: height) }

    // MARK: Rows

    func testRowsAre28TallTwoApartFromFiftyEightFortyFour() {
        XCTAssertEqual(ClipboardLayout.rowHeight, 28)
        XCTAssertEqual(ClipboardLayout.rowGap, 2)
        XCTAssertEqual(ClipboardLayout.listOrigin, CGPoint(x: 58, y: 44))
        XCTAssertEqual(ClipboardLayout.rowRadius, 7)
    }

    func testRowsAreBodyWidthLessSeventyTwo() {
        XCTAssertEqual(ClipboardLayout.rowWidth(bodyWidth: 560), 488)
        XCTAssertEqual(ClipboardLayout.rowWidth(bodyWidth: 480), 408)
        XCTAssertEqual(ClipboardLayout.rowWidth(bodyWidth: 620), 548)
    }

    func testTheMarkAndContentSitWhereTheBoardPutsThem() {
        // Board x 66 to 86 and 94, against a row that starts at 58.
        XCTAssertEqual(ClipboardLayout.rowInset, 8)
        XCTAssertEqual(ClipboardLayout.rowInset + ClipboardLayout.markSide, 28)
        XCTAssertEqual(ClipboardLayout.contentLeading, 36)
        XCTAssertEqual(ClipboardLayout.buttonSide, 22)
        // Two 22 pt buttons, 2 apart, end at the age's own edge: 46 from it.
        XCTAssertEqual(2 * ClipboardLayout.buttonSide + ClipboardLayout.buttonGap, 46)
        XCTAssertEqual(ClipboardLayout.copiedLifetime, 1.2)
    }

    func testTheListEndsTenAboveTheFootAndYieldsToTheAlertAndTheQuestion() {
        let standard = ClipboardLayout.viewport(bodySize: body(560))
        XCTAssertEqual(standard, CGRect(x: 58, y: 44, width: 488, height: 154), "the board's 198 foot")
        let tall = ClipboardLayout.viewport(bodySize: body(560, 400))
        XCTAssertEqual(tall.maxY, 390)
        XCTAssertEqual(tall.minY, 44)
        let alert = ClipboardLayout.viewport(bodySize: body(560), showsAlert: true)
        XCTAssertEqual(alert.minY, 96, "the list sits 8 below the 44 pt alert")
        let asking = ClipboardLayout.viewport(bodySize: body(560), confirming: true)
        XCTAssertEqual(asking.maxY, ClipboardLayout.confirmBar(bodySize: body(560)).minY)
        XCTAssertEqual(ClipboardLayout.overflowFade, 26)
    }

    func testTheQuestionBarIsTheBoards() {
        let bar = ClipboardLayout.confirmBar(bodySize: body(560))
        XCTAssertEqual(bar, CGRect(x: 58, y: 166, width: 488, height: 34))
        XCTAssertEqual(ClipboardLayout.confirmBar(bodySize: body(560, 400)).minY, 358)
    }

    func testTheDeniedAlertIs488By44WithTheWarningColours() {
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
        XCTAssertEqual(ClipboardLayout.imageColumns(bodyWidth: 560), 5, "5 × 88 + 4 × 12 = 488")
        XCTAssertEqual(ClipboardLayout.imageColumns(bodyWidth: 480), 4)
        XCTAssertEqual(ClipboardLayout.imageColumns(bodyWidth: 620), 5)
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

    // MARK: The header

    func testTheHeaderToolsAtTheDefaultWidth() {
        let filter = ClipboardHeader.filter(bodyWidth: 560)
        XCTAssertEqual(filter, CGRect(x: 212, y: 9, width: 270, height: 20), "the spec's (212, 9), 270 × 20")
        XCTAssertEqual(ClipboardHeader.search(bodyWidth: 560), CGRect(x: 493, y: 8, width: 22, height: 22))
        XCTAssertEqual(HeaderToolFrames.expand(bodyWidth: 560), CGRect(x: 521, y: 8, width: 22, height: 22))
        XCTAssertEqual(ClipboardHeader.searchField(bodyWidth: 560), CGRect(x: 250, y: 8, width: 294, height: 22))
    }

    func testTheClusterRidesTheTrailingEdgeAtEveryWidth() {
        for width in [CGFloat(540), 560, 620] {
            XCTAssertEqual(ClipboardHeader.search(bodyWidth: width).minX, width - 67)
            XCTAssertEqual(ClipboardHeader.filter(bodyWidth: width).maxX, width - 78, "11 clear of Search")
            XCTAssertEqual(ClipboardHeader.searchField(bodyWidth: width).maxX, width - 16)
        }
    }

    func testBelow540TheSegmentsAreSymbolsAndAgesNarrow() {
        XCTAssertFalse(ClipboardHeader.usesSymbols(bodyWidth: 540))
        XCTAssertFalse(ClipboardHeader.usesSymbols(bodyWidth: 620))
        XCTAssertTrue(ClipboardHeader.usesSymbols(bodyWidth: 539))
        XCTAssertTrue(ClipboardHeader.usesSymbols(bodyWidth: 480))
        XCTAssertEqual(ClipboardHeader.filterSize(bodyWidth: 480), CGSize(width: 150, height: 20))
        XCTAssertEqual(ClipboardHeader.filterSize(bodyWidth: 560), CGSize(width: 270, height: 20))
        // Stress-Clip-RU-480: the symbols end 3 before Search, at x 260.
        let narrow = ClipboardHeader.filter(bodyWidth: 480)
        XCTAssertEqual(narrow.minX, 260)
        XCTAssertEqual(narrow.maxX, ClipboardHeader.search(bodyWidth: 480).minX - 3)
    }

    func testTheKindControlIsFiveNamedChoicesInBothModes() async {
        for width in [CGFloat(480), 560] {
            let control = ClipboardKindControl(selection: .constant(.links), bodyWidth: width)
            let root = await AXProbe.tree(of: control, size: ClipboardHeader.filterSize(bodyWidth: width))
            let groups = root.all(role: "AXRadioGroup")
            XCTAssertEqual(groups.map { $0.label.isEmpty ? $0.title : $0.label }, ["Kind"], "a radio group named Kind at \(width)\n\(root.dump)")
            let names = root.all(role: "AXRadioButton").map { $0.title.isEmpty ? $0.label : $0.title }
            XCTAssertEqual(names, ["All", "Text", "Links", "Images", "Files"], "named even as symbols\n\(root.dump)")
        }
    }

    func testToolsAppearWhereTheyAreOfUse() {
        XCTAssertFalse(ClipboardHeader.showsSearch(itemCount: 0), "nothing to search")
        XCTAssertTrue(ClipboardHeader.showsSearch(itemCount: 1))
        XCTAssertFalse(ClipboardHeader.showsTools(itemCount: 0, isExpanded: false, isSearching: false))
        XCTAssertTrue(ClipboardHeader.showsTools(itemCount: 0, isExpanded: true, isSearching: false), "Collapse is never stranded")
        XCTAssertTrue(ClipboardHeader.showsTools(itemCount: 3, isExpanded: false, isSearching: false))
        XCTAssertEqual(ClipboardHeader.searchFieldRadius, 7)
        XCTAssertEqual(ClipboardHeader.searchFieldFillOpacity, 0.10)
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
