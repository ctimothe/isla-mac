import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Clipboard tab as it is drawn (redesign spec §9), probed through the
/// accessibility tree like the rest of the pane's tests: one button per row,
/// named by what it would copy.
@MainActor
final class ClipboardPaneTests: XCTestCase {
    private var spoken: [String] = []
    private var savedSink: ((String) -> Void)?

    override func setUp() {
        super.setUp()
        spoken = []
        savedSink = Announcer.shared.sink
        Announcer.shared.sink = { [unowned self] in spoken.append($0) }
        Announcer.shared.forget()
        LabLocalization.use("en")
    }

    override func tearDown() {
        LabLocalization.use("en")
        if let savedSink { Announcer.shared.sink = savedSink }
        Announcer.shared.forget()
        super.tearDown()
    }

    private func size(_ bodyWidth: CGFloat = 560, height: CGFloat = 208) -> CGSize {
        CGSize(width: PlayerLayout.paneWidth(bodyWidth: bodyWidth), height: height - 38 - NotchGeometry.bodyBottomPadding)
    }

    private func pane(
        _ isolated: ProbeStores, browser: ClipboardBrowser = ClipboardBrowser(),
        clear: ClipboardClearConfirmation? = nil, translate: @escaping (String) -> Void = { _ in }
    ) -> ClipboardPane {
        ClipboardPane(
            clipboard: isolated.stores.clipboard, privacy: isolated.stores.privacy, browser: browser,
            historyDefaults: isolated.suite, translate: translate, clearConfirmation: clear
        )
    }

    private func rowLabels(_ root: AXNode) -> [String] {
        root.all(role: "AXButton").map(\.label)
    }

    // MARK: The list

    func testPinnedRowsComeFirstAndEveryRowIsNamedByItsContent() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        isolated.record([.text("oldest"), .text("middle"), .text("newest")], into: clipboard)
        clipboard.setPinned(clipboard.items.first { $0.preview == "oldest" }!, true)

        let root = await AXProbe.tree(of: pane(isolated), size: size())
        XCTAssertEqual(rowLabels(root), ["oldest", "newest", "middle"], root.dump)
    }

    func testEachKindDrawsARowNamedForIt() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        let picture = try XCTUnwrap(ClipImage.make(data: ClipboardPinsTests.png(width: 120, height: 80), type: .png, sourceApp: "Photos"))
        isolated.record([
            .text("https://developer.apple.com/design"), .text("#FF453A"), .text("let x = 1;"), .image(picture),
            .file(URL(fileURLWithPath: "/tmp/Q3 Report.pdf")),
            .files([URL(fileURLWithPath: "/tmp/a.key"), URL(fileURLWithPath: "/tmp/b.key")]),
        ], into: clipboard)

        let root = await AXProbe.tree(of: pane(isolated), size: size(height: 400))
        let labels = rowLabels(root)
        XCTAssertEqual(
            labels,
            ["a.key + 1", "Q3 Report.pdf", "Image, 120 × 80", "let x = 1;", "#FF453A", "https://developer.apple.com/design"],
            root.dump
        )
    }

    func testTheFilterNarrowsTheList() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        isolated.record([.text("a note"), .text("https://example.com"), .file(URL(fileURLWithPath: "/tmp/a.txt"))], into: clipboard)
        let browser = ClipboardBrowser()
        browser.filter = .links
        let root = await AXProbe.tree(of: pane(isolated, browser: browser), size: size())
        XCTAssertEqual(rowLabels(root), ["https://example.com"], root.dump)
    }

    func testAnEmptyFilterSaysTheHistoryIsEmptyOfThatNotThatNothingWasCopied() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.record([.text("a note")], into: isolated.stores.clipboard)
        let browser = ClipboardBrowser()
        browser.filter = .images
        let root = await AXProbe.tree(of: pane(isolated, browser: browser), size: size())
        XCTAssertTrue(rowLabels(root).isEmpty, root.dump)
        XCTAssertNil(root.first(label: "No Results for “a”"))
    }

    // MARK: Search

    func testSearchFiltersAndNoMatchSaysSo() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.record([.text("Meet at the north entrance"), .text("south gate")], into: isolated.stores.clipboard)
        let browser = ClipboardBrowser()
        browser.beginSearch()
        browser.query = "NORTH"
        let found = await AXProbe.tree(of: pane(isolated, browser: browser), size: size())
        XCTAssertEqual(rowLabels(found), ["Meet at the north entrance"], found.dump)

        browser.query = "quarterly"
        let none = await AXProbe.tree(of: pane(isolated, browser: browser), size: size())
        XCTAssertTrue(rowLabels(none).isEmpty, none.dump)
        let words = none.all(role: "AXStaticText").map { $0.label.isEmpty ? $0.value : $0.label }
        XCTAssertTrue(words.contains("No Results for “quarterly”"), none.dump)
        XCTAssertTrue(words.contains("Check the spelling or try a new search."), none.dump)
    }

    func testTheSearchFieldHasAClearButtonAndAName() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let browser = ClipboardBrowser()
        browser.beginSearch()
        browser.query = "x"
        var wants = true
        let field = ClipboardSearchField(browser: browser, wantsKeyboard: Binding(get: { wants }, set: { wants = $0 }), close: { browser.endSearch() })
        let root = await AXProbe.tree(of: field, size: CGSize(width: 294, height: 22))
        XCTAssertNotNil(root.first(label: "Search"), root.dump)
        let clear = root.all(role: "AXButton").filter { $0.label == "Clear Search" }
        XCTAssertEqual(clear.count, 1, root.dump)
        XCTAssertTrue(clear.first?.press() ?? false)
        XCTAssertFalse(browser.isSearching)
        XCTAssertEqual(browser.query, "")
    }

    // MARK: Clear Everything, in place

    func testClearHistoryAsksInPlaceAndPinsStay() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        isolated.record([.text("keep"), .text("drop one"), .text("drop two")], into: clipboard)
        clipboard.setPinned(clipboard.items.first { $0.preview == "keep" }!, true)
        let ask = ClipboardClearConfirmation()
        ask.ask(count: clipboard.items.filter { !$0.isPinned }.count)
        defer { ask.cancel() }

        let root = await AXProbe.tree(of: pane(isolated, clear: ask), size: size())
        let words = root.all(role: "AXStaticText").map { $0.label.isEmpty ? $0.value : $0.label }
        XCTAssertTrue(words.contains("Clear 2 entries? Pinned items stay."), root.dump)
        XCTAssertEqual(spoken, ["Clear 2 entries? Pinned items stay."], "said to VoiceOver, which cannot see the bar change")
        let cancel = root.all(role: "AXButton").first { $0.label == "Cancel" || $0.title == "Cancel" }
        XCTAssertNotNil(cancel, root.dump)
        let yes = root.all(role: "AXButton").first { $0.label == "Clear History" || $0.title == "Clear History" }
        XCTAssertNotNil(yes, root.dump)

        XCTAssertTrue(yes?.press() ?? false)
        XCTAssertEqual(clipboard.items.map(\.preview), ["keep"], "pins survive Clear History")
        XCTAssertFalse(ask.isAsking)
    }

    func testCancelKeepsEverything() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        isolated.record([.text("a"), .text("b")], into: clipboard)
        let ask = ClipboardClearConfirmation()
        ask.ask(count: 2)
        let root = await AXProbe.tree(of: pane(isolated, clear: ask), size: size())
        let cancel = root.all(role: "AXButton").first { $0.label == "Cancel" || $0.title == "Cancel" }
        XCTAssertTrue(cancel?.press() ?? false, root.dump)
        XCTAssertEqual(clipboard.items.count, 2)
        XCTAssertFalse(ask.isAsking)
    }

    // MARK: Images

    func testTheImagesFilterIsAGridOfTilesWithTheFootnote() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        let one = try XCTUnwrap(ClipImage.make(data: ClipboardPinsTests.png(width: 90, height: 60), type: .png, sourceApp: "Photos"))
        let two = try XCTUnwrap(ClipImage.make(data: ClipboardPinsTests.png(width: 91, height: 60), type: .png, sourceApp: nil))
        isolated.record([.text("a note"), .image(one), .image(two)], into: clipboard)
        let browser = ClipboardBrowser()
        browser.filter = .images

        let root = await AXProbe.tree(of: pane(isolated, browser: browser), size: size())
        XCTAssertEqual(rowLabels(root), ["Image, 91 × 60", "Image, 90 × 60 · Photos"], root.dump)
        let words = root.all(role: "AXStaticText").map { $0.label.isEmpty ? $0.value : $0.label }
        XCTAssertTrue(words.contains("Images are kept in memory, like the rest of the history."), root.dump)

        // A tile copies the picture back, and says so once.
        let tile = root.all(role: "AXButton").first { $0.label == "Image, 91 × 60" }
        XCTAssertTrue(tile?.press() ?? false)
        XCTAssertEqual(isolated.pasteboard.data(forType: .png), ClipboardPinsTests.png(width: 91, height: 60))
        XCTAssertEqual(spoken, ["Copied"])
    }

    // MARK: Rows act

    func testPinFromTheRotorLiftsTheRowAndTranslateHandsOverTheText() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        isolated.record([.text("first"), .text("second")], into: clipboard)
        var translated: [String] = []
        let root = await AXProbe.tree(of: pane(isolated, translate: { translated.append($0) }), size: size())
        guard let row = root.all(role: "AXButton").first(where: { $0.label == "first" }) else { return XCTFail(root.dump) }
        XCTAssertTrue(row.perform(named: "Translate"), root.dump)
        XCTAssertEqual(translated, ["first"])
        XCTAssertTrue(row.perform(named: "Pin"), root.dump)
        XCTAssertEqual(clipboard.listed.map(\.preview), ["first", "second"])
        XCTAssertTrue(clipboard.items.first { $0.preview == "first" }?.isPinned == true)
        let after = await root.reread()
        XCTAssertEqual(after.all(role: "AXButton").first { $0.label == "first" }?.customActions, ["Unpin", "Translate", "Remove Entry"], after.dump)
    }

    func testFilesAndPicturesOfferNoTranslate() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.record([.file(URL(fileURLWithPath: "/tmp/a.txt"))], into: isolated.stores.clipboard)
        let root = await AXProbe.tree(of: pane(isolated), size: size())
        XCTAssertEqual(root.all(role: "AXButton").first?.customActions, ["Pin", "Remove Entry"], root.dump)
    }

    func testPlainTextCopyTrimsAndLeavesOnlyTheString() {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        clipboard.record(ClipItem(payload: .text("  padded\n"), date: Date()))
        XCTAssertTrue(clipboard.copyPlainText(clipboard.items[0]))
        XCTAssertEqual(isolated.pasteboard.string(forType: .string), "padded")
        // Only the string — AppKit adds its legacy alias for the same bytes —
        // and nothing rich or file-shaped travels with it.
        let types = Set(isolated.pasteboard.types ?? [])
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.isDisjoint(with: [.rtf, .html, .fileURL, .png, .tiff]), "\(types)")
        clipboard.record(ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/a")), date: Date()))
        XCTAssertFalse(clipboard.copyPlainText(clipboard.items[0]), "a file holds no string")
    }

    func testTheTranslateMenuItemTakesTheCommandedRoute() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.translateClipboardText("  bonjour  ")
        XCTAssertEqual(vm.tab, .translate)
        XCTAssertEqual(isolated.stores.translator.input, "bonjour", "prepared as ⌃⌥⌘T prepares it")
        XCTAssertTrue(vm.wantsKeyboard, "the Translate tab takes the keyboard")
    }

    // MARK: Covered

    func testCoveredRowsKeepTheirKindsAndHideTheirContent() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.record([.text("https://secret.example.com/path"), .text("#FF453A")], into: isolated.stores.clipboard)
        isolated.stores.privacy.setCovering(.clipboard, true)
        let root = await AXProbe.tree(of: pane(isolated), size: size())
        XCTAssertEqual(rowLabels(root), ["Hidden", "Hidden"], root.dump)
        XCTAssertTrue(root.all { $0.label.contains("secret") || $0.value.contains("secret") || $0.label.contains("FF453A") }.isEmpty, root.dump)
    }

    // MARK: Widths and Russian

    func testEveryKindHoldsAt480And620InRussian() async throws {
        LabLocalization.use("ru")
        for width in [CGFloat(480), 560, 620] {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let picture = try XCTUnwrap(ClipImage.make(data: ClipboardPinsTests.png(width: 120, height: 80), type: .png, sourceApp: "Фото"))
            isolated.record([
                .text("Встречаемся у северного входа в 18:30 — захватите кабель, пожалуйста, и не опаздывайте"),
                .text("https://developer.apple.com/design/human-interface-guidelines"),
                .image(picture), .text("#FF453A"),
                .files((0..<4).map { URL(fileURLWithPath: "/tmp/Квартальный отчёт \($0).pdf") }),
            ], into: isolated.stores.clipboard)
            isolated.stores.clipboard.setPinned(isolated.stores.clipboard.items[0], true)
            let root = await AXProbe.tree(of: pane(isolated), size: size(width, height: 400))
            let pane = CGRect(origin: .zero, size: self.size(width, height: 400))
            let rows = root.all(role: "AXButton").filter { $0.frame != nil }
            XCTAssertEqual(rows.count, 5, "\(width)\n\(root.dump)")
            for row in rows {
                let frame = try XCTUnwrap(row.frame)
                XCTAssertTrue(pane.insetBy(dx: -1, dy: -1).contains(frame), "\(row.label) \(frame) leaves \(pane) at \(width)")
                XCTAssertEqual(frame.height, ClipboardLayout.rowHeight, accuracy: 0.5, row.label)
                XCTAssertEqual(frame.width, ClipboardLayout.rowWidth(bodyWidth: width), accuracy: 0.5, row.label)
            }
            // Rows are 2 apart (the pinned one has the hairline's 7 under it).
            let ys = rows.compactMap { $0.frame?.minY }.sorted()
            XCTAssertEqual(ys.count, 5)
            XCTAssertEqual(ys[2] - ys[1], 30, accuracy: 0.5, "28 tall, 2 apart")
        }
    }

    /// "No truncation of controls" (spec §13): Russian's "Изображения" is wider
    /// than a 53 pt segment, so the control is symbols — named, with tooltips —
    /// at every width, where English keeps its words from 540 up.
    func testTheRussianFilterIsSymbolsBecauseItsWordsDoNotFit() throws {
        XCTAssertTrue(ClipboardHeader.wordsFit(), "English fits")
        LabLocalization.use("ru")
        XCTAssertEqual(ClipFilter.allCases.map(\.title), ["Все", "Текст", "Ссылки", "Изображения", "Файлы"])
        XCTAssertFalse(ClipboardHeader.wordsFit(), "the longest Russian name overruns its segment")
        for width in [CGFloat(480), 560, 620] {
            XCTAssertEqual(ClipboardHeader.filterSize(bodyWidth: width), CGSize(width: 150, height: 20), "\(width)")
            XCTAssertEqual(
                ClipboardHeader.filter(bodyWidth: width).maxX, ClipboardHeader.search(bodyWidth: width).minX - 3
            )
        }
        // The age's short words are the Russian ones.
        XCTAssertEqual(ClipboardAge.text(of: Date(timeIntervalSinceNow: -240)), "4 мин")
        LabLocalization.use("en")
        XCTAssertEqual(ClipboardHeader.filterSize(bodyWidth: 560), CGSize(width: 270, height: 20))
        XCTAssertEqual(ClipboardHeader.filterSize(bodyWidth: 480), CGSize(width: 150, height: 20))
    }

    func testTheFilterControlIsSymbolsOnlyWhereTheWordsDoNotFit() {
        let measure: (String) -> CGFloat = { _ in 50 }
        XCTAssertTrue(ClipboardHeader.wordsFit(measure: { _ in 20 }))
        XCTAssertFalse(ClipboardHeader.wordsFit(measure: measure), "50 + 8 is past 53.2")
        XCTAssertFalse(ClipboardHeader.usesSymbolSegments(bodyWidth: 560, wordsFit: true))
        XCTAssertTrue(ClipboardHeader.usesSymbolSegments(bodyWidth: 560, wordsFit: false))
        XCTAssertTrue(ClipboardHeader.usesSymbolSegments(bodyWidth: 539, wordsFit: true))
    }
}
