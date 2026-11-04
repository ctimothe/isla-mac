import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The open island as a person finds it, at the two ends of Panel Width and in
/// the language with the longest words: every surface hosted whole
/// (`NotchContentView`, the shell the app draws) and read through the
/// accessibility tree, which gives every control's real frame.
///
/// These replace hardware sittings that were a person looking for things that
/// are cut off, on top of one another or off the notch's line (run sheet,
/// "Could be a test": R8-H1, R8b-H8, R8c-H6, MR-H1, MR-H20). What a tree
/// cannot see stays with a pair of eyes: a sentence that wraps one line too
/// many inside a box that is itself on the page is not a frame outside
/// anything. Wherever the shipped table lets that happen the layout tests
/// measure the strings (`PlayerLayoutTests`, `HeaderNotchBandTests`,
/// `TranslatePaneLayoutTests`); this file holds the frames.
///
/// Panel Width is read when the geometry is made, from the standard defaults,
/// so it is answered from the argument domain — in memory, never written to
/// disk — the way the visual lab does, and put back after.
@MainActor
final class PanelLayoutSweepTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    private var savedArguments: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        LabLocalization.use("en")
        UpdateCheck.sharedOverride = nil
        super.tearDown()
    }

    // MARK: - The harness

    /// One open surface, read.
    @MainActor
    private struct Opened {
        let vm: NotchViewModel
        let root: AXNode
        /// The body's rectangle in the tree's coordinates (the window's, top
        /// down): centred in the window, hung from its top edge.
        let body: CGRect
        let notchHeight: CGFloat

        func button(_ label: String) -> AXNode? {
            root.all { $0.role == "AXButton" && $0.label == label }.first
        }
    }

    /// Opens `surface` at `width` in `language` on a physical notch, hands the
    /// result to `check`, and tears the stores down.
    private func open(
        _ surface: Surface, width: CGFloat, language: String = "en", settle: TimeInterval = 0.4,
        file: StaticString = #filePath, line: UInt = #line,
        prepare: (ProbeStores, NotchViewModel) async throws -> Void = { _, _ in },
        check: (Opened) throws -> Void
    ) async throws {
        var arguments = savedArguments
        arguments[NotchViewModel.bodyWidthKey] = Double(width)
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        LabLocalization.use(language)
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(), on: isolated.stores.media)
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        XCTAssertEqual(vm.geometry.expandedSize.width, width, "the fixture: the panel is \(width) wide", file: file, line: line)
        try await prepare(isolated, vm)
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let host = AXProbe.present(NotchContentView(vm: vm).defaultAppStorage(isolated.suite), size: size)
        vm.isOpen = true
        switch surface {
        case .drop: vm.isDropTargeted = true
        case .welcome: vm.isShowingWelcome = true
        default: vm.surface = surface
        }
        let root = await AXProbe.read(host, settle: settle, file: file, line: line)
        let bodySize = vm.bodySize
        try check(Opened(
            vm: vm, root: root,
            body: CGRect(x: (size.width - bodySize.width) / 2, y: 0, width: bodySize.width, height: bodySize.height),
            notchHeight: vm.geometry.notchSize.height
        ))
    }

    /// Three files on the Shelf, kept the way the bubble's tests keep them.
    private func keepFiles(_ count: Int, on isolated: ProbeStores) {
        let shelf = isolated.stores.shelf
        shelf.requestThumbnail = { _, done in done(nil) }
        shelf.makeBookmark = { _ in nil }
        let urls = (0..<count).map { isolated.temp.appendingPathComponent("Квартальный отчёт \($0).txt") }
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
        shelf.add(urls)
    }

    private func fill(_ surface: Surface, _ isolated: ProbeStores) {
        switch surface {
        case .tray:
            keepFiles(6, on: isolated)
        case .clipboard:
            isolated.record([
                .text("Встречаемся у северного входа в 18:30 — захватите кабель, пожалуйста"),
                .text("https://developer.apple.com/design/human-interface-guidelines"),
                .text("#FF453A"),
            ], into: isolated.stores.clipboard)
        case .stage:
            isolated.stores.lyrics.present(.ready(LyricTimeline(
                lines: [
                    .init(at: 1, text: "Первая строка песни, достаточно длинная, чтобы занять две строки на сцене"),
                    .init(at: 84, text: "Строка, которая звучит сейчас"),
                    .init(at: 200, text: "Последняя строка"),
                ],
                granularity: .line
            )))
        default:
            break
        }
    }

    // MARK: - What the frames must satisfy

    /// The nodes a check looks at: the tree without what a scroll view holds
    /// below the fold (Settings' form, Translate's text, a list's later rows),
    /// which are laid out beyond the body by design.
    private func visible(_ node: AXNode) -> [AXNode] {
        if node.role == "AXScrollArea" { return [node] }
        return [node] + node.children.flatMap(visible)
    }

    private static let overlapRoles: Set<String> = [
        "AXButton", "AXSlider", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXTextField",
    ]

    /// Nothing the island draws leaves its body, and no two controls cover one
    /// another. The island's own button is the whole header strip, and the
    /// Translate editor and the empty-state glyph sit inside cards by design.
    private func assertHolds(_ opened: Opened, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let nodes = visible(opened.root).filter { $0.frame != nil && $0.label != ProductIdentity.displayName }
        let allowed = opened.body.insetBy(dx: -1, dy: -1)
        for node in nodes where node.role != "AXGroup" {
            let frame = node.frame!
            XCTAssertTrue(
                allowed.contains(frame),
                "\(what): \(node.role) \"\(node.label)\" \(frame) leaves the body \(opened.body)\n\(opened.root.dump)",
                file: file, line: line
            )
        }
        let controls = nodes.filter { Self.overlapRoles.contains($0.role) }
        for (index, a) in controls.enumerated() {
            for b in controls[(index + 1)...] {
                let overlap = a.frame!.intersection(b.frame!)
                XCTAssertFalse(
                    !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                    "\(what): \"\(a.label)\" \(a.frame!) covers \"\(b.label)\" \(b.frame!)\n\(opened.root.dump)",
                    file: file, line: line
                )
            }
        }
        // The header's items stand on the notch row's centre line.
        let strip = nodes.filter {
            $0.frame!.maxY <= opened.notchHeight + 2 && $0.frame!.height < opened.notchHeight
                && $0.role != "AXGroup"
        }
        XCTAssertFalse(strip.isEmpty, "\(what): the header has items\n\(opened.root.dump)", file: file, line: line)
        for node in strip {
            XCTAssertEqual(
                node.frame!.midY, opened.notchHeight / 2, accuracy: 1.5,
                "\(what): header item \(node.role) \"\(node.label)\" \(node.frame!) is off the notch row's centre",
                file: file, line: line
            )
        }
    }

    // MARK: - R8-H1 and R8b-H8: Russian at both ends of Panel Width

    /// Every surface at Panel Width 480 and 620 in Russian: the player, the
    /// stage, the tray, the drop surface, Clipboard, Translate, Settings and
    /// the welcome — nothing outside its body, no control on top of another,
    /// the header's items on the notch row's centre. (The Tools page the
    /// checklist line also names went with R8b.)
    ///
    /// And, on the four pages, R8b-H8's other half: the dots and the gear stand
    /// clear of the content. The dots are a row under the page, the gear a well
    /// at the header's end, and neither has a control of the page in its frame.
    func testEverySurfaceHoldsInRussianAt480And620() async throws {
        for width in [CGFloat(480), 620] {
            for surface in [Surface.player, .stage, .tray, .drop, .clipboard, .translate, .settings, .welcome] {
                try await open(
                    surface, width: width, language: "ru", settle: surface == .settings ? 0.9 : 0.4,
                    prepare: { isolated, _ in self.fill(surface, isolated) }
                ) { opened in
                    let what = "\(surface) at \(Int(width)) in Russian"
                    // The drop surface and the welcome draw over the island's
                    // own button, which then has no header strip of items to
                    // centre; every other surface does.
                    if surface == .drop || surface == .welcome {
                        let nodes = self.visible(opened.root).filter { $0.frame != nil && $0.label != ProductIdentity.displayName }
                        for node in nodes where node.role != "AXGroup" {
                            XCTAssertTrue(
                                opened.body.insetBy(dx: -1, dy: -1).contains(node.frame!),
                                "\(what): \(node.role) \"\(node.label)\" \(node.frame!) leaves the body \(opened.body)\n\(opened.root.dump)"
                            )
                        }
                        return
                    }
                    self.assertHolds(opened, what)
                    guard Surface.pages.contains(surface) else { return }

                    // R8b-H8: the dots and the gear clear the content.
                    let row = PageDotsLayout.rowFrame(bodySize: opened.body.size)
                        .offsetBy(dx: opened.body.minX, dy: opened.body.minY)
                    let gear = try? XCTUnwrap(opened.button("Настройки"), "\(what): the gear\n\(opened.root.dump)")
                    let others = self.visible(opened.root).filter {
                        $0.frame != nil && $0.role != "AXGroup" && $0.role != "AXScrollArea"
                            && $0.label != ProductIdentity.displayName
                            && $0.label != PageDots.accessibilityLabel() && $0.label != "Настройки"
                    }
                    for node in others {
                        XCTAssertFalse(
                            node.frame!.intersects(row),
                            "\(what): \(node.role) \"\(node.label)\" \(node.frame!) is in the dots' row \(row)"
                        )
                        if let gear = gear?.frame {
                            XCTAssertFalse(
                                node.frame!.intersects(gear),
                                "\(what): \(node.role) \"\(node.label)\" \(node.frame!) is on the gear \(gear)"
                            )
                        }
                    }
                    let dots = opened.root.all { $0.label == PageDots.accessibilityLabel() }.first
                    XCTAssertNotNil(dots, "\(what): the dots are found by VoiceOver\n\(opened.root.dump)")
                    XCTAssertEqual(dots?.frame?.midX ?? 0, opened.body.midX, accuracy: 1, "\(what): the dots are centred")
                }
            }
        }
    }

    // MARK: - MR-H1 and MR-H20: the gear, the X and the wells

    /// A check with a release waiting, so the gear has something to carry.
    private func updateIsAvailable() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v99.0.0", "html_url": "https://github.com/ctimothe/isla-mac/releases/tag/v99.0.0",
            "body": "Fixes.",
        ])
        let check = UpdateCheck(
            fetch: { request in (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            currentVersion: { "0.0.1" }
        )
        check.check()
        for _ in 0..<400 where check.state == .checking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(check.hasUpdate, "the fixture: a release is waiting")
        UpdateCheck.sharedOverride = check
    }

    /// Every page and the lyric stage carry the gear, with the update dot when
    /// a release waits; Settings carries the X that goes back, with no dot;
    /// and on the Shelf Remove All stands 8 pt before the gear (no empty slot
    /// where Tools' button was). At 560 and 480.
    ///
    /// MR-H20 on the same trees: the gear, its X, History and Remove All's
    /// trash are the one 26 pt well; Paste is Remove All's kind of button, the
    /// same well's height; the stage's four tools are 28 pt; nothing in a
    /// header is taller than the notch's row. (The glyph and the playing app's
    /// squircle being one size is `HeaderIconSpecTests`; the lightening under
    /// the pointer and a click answered the first time need a pointer.)
    func testTheGearIsOnEveryPageAndTheXOnSettingsAndTheWellsAreOneSize() async throws {
        try await updateIsAvailable()
        for width in [CGFloat(560), 480] {
            let wellSize = CGSize(width: HeaderIcon.well, height: HeaderIcon.well)
            for surface in [Surface.player, .stage, .tray, .clipboard, .translate] {
                let what = "\(surface) at \(Int(width))"
                try await open(surface, width: width, prepare: { isolated, _ in
                    self.fill(surface, isolated)
                    isolated.suite.set(true, forKey: NotchViewModel.translateKeepHistoryKey)
                }) { opened in
                    let gear = try XCTUnwrap(opened.button("Settings"), "\(what): the gear\n\(opened.root.dump)")
                    XCTAssertEqual(gear.value, "Update available", "\(what): the dot, said to VoiceOver")
                    XCTAssertNil(opened.button("Close Settings"), "\(what): no X on a page")
                    let frame = try XCTUnwrap(gear.frame)
                    XCTAssertEqual(frame.size, wellSize, "\(what): the gear is the 26 pt well")
                    let placed = SurfaceHeaderLayout.gear(bodyWidth: opened.body.width, notchHeight: opened.notchHeight)
                        .offsetBy(dx: opened.body.minX, dy: 0)
                    XCTAssertEqual(frame.minX, placed.minX, accuracy: 1, "\(what): the gear where the layout puts it")
                    XCTAssertEqual(frame.midY, opened.notchHeight / 2, accuracy: 1, "\(what): on the notch row")

                    switch surface {
                    case .tray:
                        let removeAll = try XCTUnwrap(opened.button("Remove All"), "\(what): Remove All\n\(opened.root.dump)")
                        let all = try XCTUnwrap(removeAll.frame)
                        XCTAssertEqual(all.maxX + SurfaceHeaderLayout.notchClearance, frame.minX, accuracy: 1, "\(what): 8 pt before the gear")
                        XCTAssertEqual(all.height, wellSize.height, "\(what): the trash is the gear's height")
                        XCTAssertEqual(all.midY, frame.midY, accuracy: 1, "\(what): on the gear's line")
                    case .translate:
                        let history = try XCTUnwrap(opened.button("History"), "\(what): History\n\(opened.root.dump)")
                        XCTAssertEqual(history.frame?.size, wellSize, "\(what): History is the 26 pt well")
                        XCTAssertEqual(history.frame?.midY ?? 0, frame.midY, accuracy: 1)
                        XCTAssertFalse(history.frame!.intersects(frame), "\(what): History clear of the gear")
                        let paste = try XCTUnwrap(opened.button("Paste"), "\(what): Paste\n\(opened.root.dump)")
                        XCTAssertEqual(paste.frame?.height, wellSize.height, "\(what): Paste is Remove All's kind of button")
                        let swap = try XCTUnwrap(opened.button("Swap Languages"), "\(what): Swap\n\(opened.root.dump)")
                        XCTAssertEqual(swap.frame?.height, TranslateLayout.pairHeight, "\(what): Swap stands the pop-ups' height")
                    case .stage:
                        let tools = opened.root.all(role: "AXButton").filter {
                            $0.frame?.size == CGSize(width: StageToolFrames.side, height: StageToolFrames.side)
                        }
                        XCTAssertEqual(tools.count, 4, "\(what): More, Output, Volume and Hide Lyrics are one 28 pt tool\n\(opened.root.dump)")
                        XCTAssertEqual(Set(tools.compactMap { $0.frame?.midY }.map { ($0 * 2).rounded() }).count, 1, "\(what): on one line")
                    default:
                        break
                    }

                    // No header grows for any of it.
                    for node in opened.root.flattened where node.role == "AXButton" && node.label != ProductIdentity.displayName {
                        guard let box = node.frame, box.maxY <= opened.notchHeight + 2 else { continue }
                        XCTAssertLessThanOrEqual(box.height, opened.notchHeight, "\(what): \"\(node.label)\" is taller than the row")
                    }
                }
            }

            // Settings: the X, unlit and with no dot, in the gear's place.
            try await open(.settings, width: width, settle: 0.9) { opened in
                let what = "settings at \(Int(width))"
                let close = try XCTUnwrap(opened.button("Close Settings"), "\(what): the X\n\(opened.root.dump)")
                XCTAssertNil(opened.button("Settings"), "\(what): the gear is the X here")
                XCTAssertEqual(close.value, "", "\(what): Settings shows the update itself")
                XCTAssertEqual(close.frame?.size, wellSize, "\(what): the X is the gear's well")
                let placed = SurfaceHeaderLayout.gear(bodyWidth: opened.body.width, notchHeight: opened.notchHeight)
                    .offsetBy(dx: opened.body.minX, dy: 0)
                XCTAssertEqual(close.frame?.minX ?? 0, placed.minX, accuracy: 1, "\(what): in the gear's place")
            }
        }

        // Without a release waiting the gear carries no dot.
        UpdateCheck.sharedOverride = nil
        try await open(.clipboard, width: 560) { opened in
            let gear = try XCTUnwrap(opened.button("Settings"))
            XCTAssertEqual(gear.value, "", "no release, no dot")
        }
    }

    // MARK: - R8c-H6: the Shelf's and Clipboard's header, and Paste

    /// Remove All's trash is no larger than the gear's well, Clipboard's search
    /// field and filter stand one height on one line, and Translate's Paste and
    /// the Shelf's Remove All show their whole word in English and Russian at
    /// both ends of Panel Width. (The tiles' day-over-time reading the
    /// checklist also names was withdrawn.)
    func testRemoveAllClipboardsHeaderAndPasteFitAtEveryWidthInBothLanguages() async throws {
        for language in ["en", "ru"] {
            for width in [CGFloat(480), 620] {
                let what = "\(language) at \(Int(width))"
                try await open(.tray, width: width, language: language, prepare: { isolated, _ in
                    self.fill(.tray, isolated)
                }) { opened in
                    let gear = try XCTUnwrap(opened.button(localized("Settings")))
                    let removeAll = try XCTUnwrap(opened.button(localized("Remove All")), "\(what)\n\(opened.root.dump)")
                    let box = try XCTUnwrap(removeAll.frame)
                    XCTAssertLessThanOrEqual(box.height, try XCTUnwrap(gear.frame).height, "\(what): the trash is no taller than the gear")
                    XCTAssertEqual(box.width, ShelfRemoveAllButton.width(), accuracy: 0.5, "\(what): and takes the width its word needs")
                    XCTAssertGreaterThanOrEqual(
                        box.width, Self.iconWordWidth(localized("All")), "\(what): \"\(localized("All"))\" is not cut"
                    )
                }
                try await open(.clipboard, width: width, language: language, prepare: { isolated, _ in
                    self.fill(.clipboard, isolated)
                }) { opened in
                    let search = ClipboardHeader.searchField.offsetBy(dx: opened.body.minX, dy: opened.notchHeight - 0)
                    let filter = ClipboardHeader.filter(bodyWidth: opened.body.width).offsetBy(dx: opened.body.minX, dy: opened.notchHeight)
                    XCTAssertEqual(search.height, filter.height, "\(what): one height")
                    XCTAssertEqual(search.midY, filter.midY, accuracy: 0.001, "\(what): one line")
                    let group = try XCTUnwrap(
                        opened.root.all { $0.role == "AXRadioGroup" }.first, "\(what): the filter\n\(opened.root.dump)"
                    )
                    // The radio group is VoiceOver's stand-in
                    // (`accessibilityRepresentation`), never drawn. On macOS
                    // 27 it takes the drawn control's frame; on the CI
                    // runner's macOS 26 it keeps its own, four radio buttons
                    // stacked 84 pt tall, over the same 28 pt drawing
                    // (2026-11-04). Its height says what is drawn only where
                    // it follows the drawing; ClipboardHeader above holds the
                    // drawing everywhere.
                    if ProcessInfo.processInfo.isOperatingSystemAtLeast(
                        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
                    ) {
                        XCTAssertEqual(group.frame?.height ?? 0, search.height, accuracy: 1, "\(what): the drawn filter is the field's height")
                    }
                    XCTAssertEqual(group.frame?.minY ?? 0, search.minY, accuracy: 1, "\(what): and starts on its line")
                    let field = try XCTUnwrap(opened.root.all(role: "AXTextField").first, "\(what): the search field")
                    XCTAssertTrue(search.insetBy(dx: -1, dy: -1).contains(field.frame!), "\(what): the typing is inside the field's plate")
                }
                try await open(.translate, width: width, language: language) { opened in
                    let paste = try XCTUnwrap(opened.button(localized("Paste")), "\(what)\n\(opened.root.dump)")
                    XCTAssertGreaterThanOrEqual(
                        paste.frame?.width ?? 0, Self.iconWordWidth(localized("Paste")),
                        "\(what): \"\(localized("Paste"))\" reads in full"
                    )
                }
            }
        }
    }

    /// A glyph, its gap, a word and the padding either side: what an
    /// `IconWordButton` needs to show the word whole.
    private static func iconWordWidth(_ word: String) -> CGFloat {
        let text = (word as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: HeaderIcon.wordSize, weight: .medium),
        ]).width
        return ceil(ShelfLayout.removeAllGlyphWidth + ShelfLayout.removeAllGap + text + 2 * ShelfLayout.removeAllPadding) - 1
    }

    // MARK: - R4-H7: Translate's alerts and pop-ups in Russian at 480

    /// Each way a translation can stop, worded in Russian, in the result card at
    /// Panel Width 480: the sentence and its buttons are inside the card, the
    /// buttons clear of one another, and nothing drops below the card's foot.
    func testTranslatesAlertCardsFitTheCardInRussianAt480() async throws {
        LabLocalization.use("ru")
        struct Case {
            var name: String
            var capabilities: Translator.Capabilities
            var target: TranslationLanguage = .russian
            var online: ((String, Translator.Route) async throws -> OnlineTranslation.Reply)?
        }
        let cases: [Case] = [
            Case(name: "not downloaded", capabilities: .init(systemSupported: true), target: .ukrainian),
            Case(name: "online only and off", capabilities: .init(), target: .uzbek),
            Case(name: "newer system", capabilities: .init(belowMinimumSystem: true)),
            Case(name: "Apple Intelligence off", capabilities: .init(modelSupportsPair: true, modelObstacle: .appleIntelligenceOff)),
            Case(name: "not eligible", capabilities: .init(modelSupportsPair: true, modelObstacle: .deviceNotEligible)),
            Case(name: "model downloading", capabilities: .init(modelSupportsPair: true, modelObstacle: .modelNotReady)),
            Case(name: "unreachable", capabilities: .init(onlineEnabled: true), target: .uzbek,
                 online: { _, _ in throw OnlineTranslation.Failure.unreachable }),
            Case(name: "quota", capabilities: .init(onlineEnabled: true), target: .uzbek,
                 online: { _, _ in throw OnlineTranslation.Failure.quotaExhausted }),
        ]
        let size = CGSize(width: 480, height: TranslateLayout.contentHeight)
        let card = TranslateLayout.resultCard(bodyWidth: size.width)
        for item in cases {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let translator = isolated.stores.translator
            translator.allowanceSpent = { false }
            translator.capabilitiesOverride = { _ in item.capabilities }
            if let online = item.online { translator.onlineTranslate = online }
            translator.choose(target: item.target)
            translator.input = "Где находится вокзал?"
            await translator.translate()
            let message = try XCTUnwrap(translator.failure, "\(item.name): the translator worded a failure")
            XCTAssertFalse(message.isEmpty, item.name)

            let pane = TranslatePane(translator: translator, privacy: isolated.stores.privacy, wantsKeyboard: .constant(false), bodyWidth: size.width)
                .background(Color.black)
            let root = await AXProbe.tree(of: pane, size: size)
            let inside = root.all { node in
                guard let frame = node.frame, frame.minX >= card.minX - 1, frame.minY >= card.minY - 1 else { return false }
                return ["AXStaticText", "AXButton", "AXProgressIndicator", "AXImage"].contains(node.role)
            }
            XCTAssertFalse(inside.isEmpty, "\(item.name): the card holds the alert\n\(root.dump)")
            for node in inside {
                XCTAssertTrue(
                    card.insetBy(dx: -1, dy: -1).contains(node.frame!),
                    "\(item.name): \(node.role) \"\(node.label)\" \(node.frame!) leaves the result card \(card)\n\(root.dump)"
                )
            }
            let buttons = inside.filter { $0.role == "AXButton" }
            for (index, a) in buttons.enumerated() {
                for b in buttons[(index + 1)...] {
                    let overlap = a.frame!.intersection(b.frame!)
                    XCTAssertFalse(
                        !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                        "\(item.name): \"\(a.label)\" covers \"\(b.label)\""
                    )
                }
            }
            let sentence = try XCTUnwrap(
                root.all { $0.value == message || $0.label == message || $0.title == message }.first,
                "\(item.name): the sentence is on the card\n\(root.dump)"
            )
            XCTAssertLessThanOrEqual(
                sentence.frame!.maxY, card.maxY - 4, "\(item.name): the sentence ends above the card's foot"
            )
        }
    }

    /// A language pop-up's label that does not fit gives up its tail and keeps
    /// the chevron: two titles that share a long beginning draw the same
    /// pixels, and the chevron is where it is with a short title. A label cut
    /// at the head or the middle shows its end, and the two differ.
    func testAPopUpLabelTooLongForTheRussianPlateIsCutAtTheTail() throws {
        LabLocalization.use("ru")
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let plate = TranslateLayout.pairBar(bodyWidth: 480).from.size

        func render(_ title: String) throws -> NSBitmapImageRep {
            try draw(TranslatePopUp(
                translator: isolated.stores.translator, side: .source, title: title,
                label: localized("Translate From"), apply: { $0() }
            ))
        }
        func draw<V: View>(_ content: V) throws -> NSBitmapImageRep {
            let view = content
                .frame(width: plate.width, height: plate.height)
                .background(Color.black)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: plate), styleMask: [.borderless], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: plate)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            window.contentView = nil
            return rep
        }
        func bytes(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:]) ?? Data() }
        func columns(_ rep: NSBitmapImageRep, from x0: Int, to x1: Int) -> [UInt32] {
            var out: [UInt32] = []
            for x in x0..<x1 {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    out.append(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
            return out
        }

        let long = "Узбекский (только онлайн) — язык с очень длинным названием для узкой плашки"
        let a = try render(long + " один")
        let b = try render(long + " два")
        XCTAssertEqual(bytes(a), bytes(b), "the end of a long label is not on the plate: it is cut off the tail")
        // The technique tells the cuts apart: the same two titles cut at the
        // head, as a label might be, do not draw alike.
        func headCut(_ title: String) throws -> NSBitmapImageRep {
            try draw(Text(title).lineLimit(1).truncationMode(.head).foregroundStyle(.white).padding(.horizontal, 9))
        }
        XCTAssertNotEqual(bytes(try headCut(long + " один")), bytes(try headCut(long + " два")), "a head cut shows the end")
        let short = try render("Русский")
        XCTAssertNotEqual(bytes(a), bytes(short), "the fixture: the long label draws something other than the short one")
        // The chevron sits where it does with a short label: the label never
        // reaches it.
        let width = a.pixelsWide
        let chevron = Int(Double(width) * 0.93)..<width - 4
        XCTAssertEqual(
            columns(a, from: chevron.lowerBound, to: chevron.upperBound),
            columns(short, from: chevron.lowerBound, to: chevron.upperBound),
            "the long label stops short of the chevron"
        )
    }
}
