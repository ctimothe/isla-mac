import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// How a translated lyric is laid out and reached (spec §19.6, §5.3): the pitch
/// with and without a translation under each line, where the sung pair sits, the
/// translation row's type and brightness, the header tool's menu as a pure
/// function, and the stage in the accessibility tree. The column's `Ct` and the
/// tall page's `Tt` (§5.1) were withdrawn with those states (§19.11): the stage
/// is the one lyric surface, with one pitch and one pitch for a pair.
@MainActor
final class LyricTranslationLayoutTests: XCTestCase {
    // MARK: - Pitch and frames (spec §19.6)

    /// A line is a 28 pt line and the 10 between lines: 38 a slot; a pair is the
    /// line, the 2 pt gap, a 13 pt row and the 10 between: 56.
    func testAPairIsFiftySixWhereALoneLineIsThirtyEight() throws {
        XCTAssertEqual(LyricsStage.Metrics.stage.slot(translated: false), 38)
        XCTAssertEqual(LyricsStage.Metrics.stage.slot(translated: true), 56, "38 → 56 per translated pair")
        XCTAssertEqual(LyricsStage.Metrics.stage.lineHeight, 28)
        XCTAssertEqual(LyricsStage.slotHeight, 38)

        // Nothing else moves: the translation is a change of the lines' region
        // and its pitch, never of the foot around it — the stage's frames take
        // no translation at all.
        for width: CGFloat in [480, 560, 620] {
            let layout = StageLayout(bodyWidth: width)
            XCTAssertEqual(layout.lines, CGRect(x: 24, y: 0, width: width - 48, height: 268), "lines at \(width)")
            XCTAssertLessThan(layout.lines.maxY, layout.hairline.minY, "the lines end above the foot's hairline")
        }
    }

    /// The sung line's top is at y 138 on the board: its centre in the lines'
    /// own coordinates is 138 − 38 + 14. A pair is centred on the same place
    /// (the stage's anchor does the centring), so the reading centre does not
    /// depend on a translation.
    func testTheReadingCentreIsTheBoards() {
        XCTAssertEqual(StageLayout.readingCentre, 138 - 38 + 28.0 / 2)
        XCTAssertEqual(StageLayout.readingCentre, 114)
        XCTAssertLessThan(StageLayout.readingCentre, StageLayout.linesHeight / 2, "above the middle: more lines to come than gone")
    }

    /// A pair is centred in its slot, so the arithmetic the stage already does —
    /// the anchor that puts a row's centre at the reading centre — holds for the
    /// taller slot exactly as it did for the lone line.
    func testTheAnchorLandsATranslatedRowsCentreOnTheReadingCentre() throws {
        let area = StageLayout(bodyWidth: 560).lines
        for slot in [LyricsStage.Metrics.stage.slot(translated: false), LyricsStage.Metrics.stage.slot(translated: true)] {
            let centre = LyricsStage.holdingCentre(centre: StageLayout.readingCentre, viewport: area.height)
            XCTAssertEqual(centre, StageLayout.readingCentre, "inside the viewport, held where the board has it")
            let unit = LyricsStage.anchorUnit(centre: centre, viewport: area.height, slot: slot)
            XCTAssertEqual(unit * area.height - unit * slot + slot / 2, centre, accuracy: 0.001)
            let air = LyricsStage.air(viewport: area.height, slot: slot, centre: centre)
            XCTAssertEqual(air.top, centre - slot / 2, accuracy: 0.001, "the first pair can sit at the centre")
            XCTAssertEqual(air.bottom, area.height - centre - slot / 2, accuracy: 0.001, "and so can the last")
        }
    }

    // MARK: - The translation row's type and brightness (spec §19.6, §2.1)

    /// 13 regular under every line, the sung one's as well (§19.6).
    func testTheTranslationRowsTypeIs13Regular() {
        for isSung in [false, true] {
            let style = PlayerLayout.translationStyle(isSung: isSung)
            XCTAssertEqual(style.size, 13, "sung \(isSung)")
            XCTAssertEqual(style.size, Theme.TypeRole.subhead.size, "13 → the subhead role")
            XCTAssertEqual(style.weight, .regular)
        }
        // A line over its translation fits the slot it is given, gap included.
        // The pair: the 28 pt line, the 2 pt gap, the 13 pt row's 16 pt line and the
        // 10 between pairs.
        XCTAssertEqual(
            Double(LyricsStage.Metrics.stage.lineHeight) + Double(LyricRow.translationGap) + 16 + 10,
            Double(LyricsStage.Metrics.stage.translatedPitch)
        )
    }

    /// The board dims a context line's translation to 0.45; that is under the
    /// contrast floor for text this small, and the floor wins (§2.1). The sung
    /// line's is the board's 0.66, never under the floor.
    func testTranslationsHoldTheContrastFloorOverBlack() {
        for increaseContrast in [false, true] {
            let floor = Theme.tertiaryOpacity(increaseContrast: increaseContrast)
            for isSung in [false, true] {
                let opacity = PlayerLayout.translationOpacity(isSung: isSung, increaseContrast: increaseContrast)
                XCTAssertGreaterThanOrEqual(opacity, floor)
                XCTAssertGreaterThanOrEqual(
                    Theme.contrast(textOpacity: opacity, overGrey: 0), 4.5,
                    "AA for 13 pt text over the island's black (sung \(isSung), IC \(increaseContrast))"
                )
            }
        }
        XCTAssertEqual(PlayerLayout.translationOpacity(isSung: true, increaseContrast: false), 0.66)
        XCTAssertEqual(PlayerLayout.translationOpacity(isSung: false, increaseContrast: false), 0.50)
        XCTAssertGreaterThan(
            PlayerLayout.translationOpacity(isSung: true, increaseContrast: false),
            PlayerLayout.translationOpacity(isSung: false, increaseContrast: false),
            "the sung line's translation is the brightest"
        )
    }

    // MARK: - The translation menu (spec §5.2)

    func testTheMenuIsShowTranslationLanguagesAndWhereItWasDone() {
        let items = LyricsTranslateMenuModel.items(
            isShown: true, languages: [.english, .russian, .ukrainian, .german, .spanish],
            current: .russian, engine: .system
        )
        XCTAssertEqual(items.map(\.title), [
            "Show Translation", "", "Translate To",
            "English", "Russian", "Ukrainian", "German", "Spanish",
            "", "Translated on this Mac",
        ])
        XCTAssertEqual(items.map(\.kind), [
            .showTranslation, .separator, .header,
            .language("en"), .language("ru"), .language("uk"), .language("de"), .language("es"),
            .separator, .provenance,
        ])
        XCTAssertTrue(items[0].isChecked, "Show Translation checked when on")
        XCTAssertEqual(items.filter(\.isChecked).map(\.title), ["Show Translation", "Russian"],
                       "the current language is the one other check")
        XCTAssertFalse(items.last!.isEnabled, "the provenance line is a readout")
        XCTAssertFalse(
            LyricsTranslateMenuModel.items(isShown: false, languages: [.english], current: .english, engine: nil)[0].isChecked
        )
    }

    func testTheMenuSaysWhenTheBatchWentOnline() {
        let online = LyricsTranslateMenuModel.items(
            isShown: true, languages: [.uzbek], current: .uzbek, engine: .online
        )
        XCTAssertEqual(online.last?.title, "Translated online by MyMemory", "the existing sentence, said where it left the Mac")
        XCTAssertEqual(online.last?.isEnabled, false)
        for engine in [Translator.Engine.system, .intelligence] {
            XCTAssertEqual(
                LyricsTranslateMenuModel.items(isShown: true, languages: [], current: .russian, engine: engine).last?.title,
                "Translated on this Mac"
            )
        }
    }

    /// The five most recent targets and the current one, with a menu opened before
    /// anything was chosen still a menu, and the order stable across a choice.
    func testTheMenusLanguagesAreTheRecentsAndTheCurrentOne() {
        let recents: [TranslationLanguage] = [.korean, .german, .french, .italian, .spanish]
        XCTAssertEqual(
            LyricsTranslateMenuModel.languages(recents: recents, current: .korean).map(\.code).sorted(),
            ["de", "es", "fr", "it", "ko"], "the five, the current one among them"
        )
        XCTAssertEqual(
            LyricsTranslateMenuModel.languages(recents: recents, current: .russian).count, 6,
            "the five most recent plus the current one when it is not among them"
        )
        XCTAssertTrue(LyricsTranslateMenuModel.languages(recents: recents, current: .russian).contains(.russian))
        let fresh = LyricsTranslateMenuModel.languages(recents: [], current: .english)
        XCTAssertEqual(fresh.count, 5, "made up to five from the usual choices")
        XCTAssertTrue(fresh.contains(.english))
        let order = TranslationLanguage.all
        XCTAssertEqual(fresh, fresh.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! },
                       "in the Translate tab's own order, so a choice never moves the others")
        XCTAssertEqual(
            LyricsTranslateMenuModel.languages(recents: [.russian, .english], current: .russian).filter { $0 == .russian }.count, 1,
            "never twice"
        )
    }

    func testTheMenuControllerBuildsCheckedItemsAndActs() throws {
        var log: [String] = []
        let controller = LyricsTranslateMenuController(
            context: {
                .init(isShown: true, languages: [.english, .russian], current: .russian, engine: .online)
            },
            actions: .init(
                toggleShown: { log.append("toggle") },
                choose: { log.append("choose \($0.code)") }
            )
        )
        let menu = controller.makeMenu()
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        XCTAssertEqual(titles, [
            "Show Translation", "-", "Translate To", "English", "Russian", "-", "Translated online by MyMemory",
        ])
        XCTAssertEqual(menu.items[0].state, .on)
        XCTAssertEqual(menu.items[3].state, .off)
        XCTAssertEqual(menu.items[4].state, .on, "the current language is ticked")
        XCTAssertFalse(menu.items[6].isEnabled)
        XCTAssertTrue(menu.items[2].isSectionHeader)

        controller.perform(.showTranslation)
        controller.perform(.language("en"))
        controller.perform(.language("zz"))
        controller.perform(.provenance)
        controller.perform(.header)
        XCTAssertEqual(log, ["toggle", "choose en"], "an unknown code, the readout and the header do nothing")
    }

    /// A right-click, or a Control-click, opens the menu; nothing else does — so
    /// the primary click is the button's.
    func testWhatCountsAsASecondaryClick() {
        XCTAssertTrue(SecondaryClick.isSecondary(type: .rightMouseDown, modifiers: []))
        XCTAssertTrue(SecondaryClick.isSecondary(type: .leftMouseDown, modifiers: [.control]))
        XCTAssertFalse(SecondaryClick.isSecondary(type: .leftMouseDown, modifiers: []))
        XCTAssertFalse(SecondaryClick.isSecondary(type: .leftMouseDown, modifiers: [.command]))
        XCTAssertFalse(SecondaryClick.isSecondary(type: .rightMouseUp, modifiers: []))
        XCTAssertFalse(SecondaryClick.isSecondary(type: .mouseMoved, modifiers: [.control]))
    }

    func testTheHeaderToolsLabelAndGlyphFollowTheSwitch() {
        XCTAssertEqual(TranslationToolButton.symbol(isShown: false), "character.bubble")
        XCTAssertEqual(TranslationToolButton.symbol(isShown: true), "character.bubble.fill")
        XCTAssertEqual(TranslationToolButton.label(isShown: false), "Show Translation")
        XCTAssertEqual(TranslationToolButton.label(isShown: true), "Hide Translation")
    }

    // MARK: - The header's tool follows Settings

    func testTheToolIsThereOnlyWhileTranslateLyricsIsOn() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        XCTAssertFalse(vm.showsTranslationTool, "hidden while Translate Lyrics is off")
        isolated.suite.set(true, forKey: NotchViewModel.translateLyricsKey)
        isolated.stores.lyricTranslation.refresh()
        XCTAssertTrue(vm.showsTranslationTool)
        isolated.suite.set(false, forKey: NotchViewModel.translateLyricsKey)
        isolated.stores.lyricTranslation.refresh()
        XCTAssertFalse(vm.showsTranslationTool)
    }

    // MARK: - The stage, in the accessibility tree

    /// The lines' own area at the default 560 body: `bw − 48` by 268.
    private static let size = CGSize(width: 512, height: 268)
    private static let lines: [LyricsStore.Line] = [
        .init(at: 1, text: "First line"), .init(at: 4, text: "Second line"), .init(at: 8, text: "Third line"),
    ]

    private func stage(
        lyrics: LyricsStore, media: MediaController, translation: LyricTranslation
    ) -> LyricsStage {
        LyricsStage(
            media: media, lyrics: lyrics, onlineEnabled: { false },
            readingCentre: StageLayout.readingCentre, translation: translation
        )
    }

    private func rowPitch(_ root: AXNode, labels: [String]) throws -> [CGFloat] {
        let frames = try labels.map { label in
            try XCTUnwrap(
                root.all { $0.role == "AXButton" && ($0.label ?? "").hasPrefix(label) }.first?.frame,
                "no row \"\(label)\"\n\(root.dump)"
            )
        }
        return zip(frames, frames.dropFirst()).map { $1.minY - $0.minY }
    }

    func testTheStageDrawsATranslationUnderEachLineAtTheLargerPitch() async throws {
        for (plain, translated) in [(CGFloat(38), CGFloat(56))] {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let store = LyricsStore(
                offsetsDirectory: isolated.temp.appendingPathComponent("tr-offsets", isDirectory: true),
                defaults: isolated.suite
            )
            store.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
            isolated.suite.set(true, forKey: NotchViewModel.translateLyricsKey)
            isolated.suite.set("ru", forKey: NotchViewModel.translateTargetKey)
            let service = LyricTranslation(
                defaults: isolated.suite,
                backend: LyricTranslation.Backend(
                    capabilities: { _ in Translator.Capabilities(systemInstalled: true, systemSupported: true) },
                    system: { texts, _ in texts.map { "перевод: \($0)" } },
                    model: { _, _ in [] }, online: { _, _ in "" },
                    detect: { _ in .english }
                )
            )

            // Without a translation: the plain pitch.
            let bare = await AXProbe.tree(
                of: stage(lyrics: store, media: isolated.stores.media, translation: .idle)
                    .defaultAppStorage(isolated.suite),
                size: Self.size
            )
            XCTAssertEqual(
                try rowPitch(bare, labels: ["First line", "Second line"]), [plain], accuracy: 0.5,
                "\(bare.dump)"
            )

            // With one: a pair a slot, and the translation is read with its line.
            // A batch is asked for only while a lyric surface is up (the stage
            // below sets the same demand when it appears).
            service.setDemand(.lyricArea, true)
            service.present(lines: Self.lines)
            await service.settled()
            let root = await AXProbe.tree(
                of: stage(lyrics: store, media: isolated.stores.media, translation: service)
                    .defaultAppStorage(isolated.suite),
                size: Self.size
            )
            XCTAssertNotNil(
                root.first(label: "First line. перевод: First line"), "the row says its translation\n\(root.dump)"
            )
            XCTAssertEqual(
                try rowPitch(root, labels: ["First line", "Second line"]), [translated], accuracy: 0.5,
                "\(root.dump)"
            )
        }
    }

    /// With Translate Lyrics off a bilingual file still draws its second row as
    /// the translation, and the pitch grows for it.
    func testABilingualFileIsDrawnAsLineAndTranslationWithTheSettingOff() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let store = LyricsStore(
            offsetsDirectory: isolated.temp.appendingPathComponent("bi-offsets", isDirectory: true),
            defaults: isolated.suite
        )
        let lines: [LyricsStore.Line] = [
            .init(at: 1, text: "First line\nПервая строка"), .init(at: 4, text: "Second line\nВторая строка"),
        ]
        store.present(.ready(LyricTimeline(lines: lines, granularity: .line)))
        let service = LyricTranslation(defaults: isolated.suite, backend: .inert)
        XCTAssertFalse(service.isEnabled)
        let root = await AXProbe.tree(
            of: stage(lyrics: store, media: isolated.stores.media, translation: service)
                .defaultAppStorage(isolated.suite),
            size: Self.size
        )
        XCTAssertNotNil(root.first(label: "First line. Первая строка"), root.dump)
        XCTAssertEqual(try rowPitch(root, labels: ["First line", "Second line"]), [56], accuracy: 0.5, root.dump)
    }
}

private func XCTAssertEqual(
    _ actual: [CGFloat], _ expected: [CGFloat], accuracy: CGFloat, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
    for (a, e) in zip(actual, expected) {
        XCTAssertEqual(a, e, accuracy: accuracy, message, file: file, line: line)
    }
}
