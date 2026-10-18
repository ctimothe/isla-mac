import AppKit
import XCTest
@testable import IslaKit

/// The language pop-ups' menus (redesign 2026-10-15, spec §11), as a list a test
/// can read: the order, the headers, the " (Online)" suffix, what is ticked, and
/// what pressing a row does. AppKit only ever sees the list.
@MainActor
final class TranslateMenuTests: XCTestCase {
    override func tearDown() {
        LabLocalization.use("en")
        super.tearDown()
    }

    private func kinds(_ entries: [TranslateMenuEntry]) -> [TranslateMenuEntry.Kind] { entries.map(\.kind) }

    private func titles(_ entries: [TranslateMenuEntry]) -> [String] { entries.map(\.title) }

    // MARK: - Recents

    /// The last three targets, newest first, a language chosen again moving to
    /// the front rather than being listed twice.
    func testRecentsKeepTheLastThreeTargets() {
        var recents: [TranslationLanguage] = []
        for language in [TranslationLanguage.russian, .english, .uzbek, .german] {
            recents = TranslateMenuModel.recents(recents, adding: language)
        }
        XCTAssertEqual(recents, [.german, .uzbek, .english])
        XCTAssertEqual(TranslateMenuModel.recents(recents, adding: .english), [.english, .german, .uzbek])
        XCTAssertEqual(TranslateMenuModel.recents([.russian], adding: .russian), [.russian])
        XCTAssertEqual(TranslateMenuModel.recentCapacity, 3)
    }

    /// The translator keeps them for the session, starting from the target the
    /// tab opens on, and every way a target changes (a choice, a swap, picking
    /// the other side's language) records it.
    func testTheTranslatorRemembersRecentTargetsInMemory() {
        let rig = TranslateRig()
        defer { rig.release() }
        let translator = rig.translator
        XCTAssertEqual(translator.recentTargets, [.english], "opens on its own target")
        translator.choose(target: .russian)
        translator.choose(target: .uzbek)
        translator.choose(target: .german)
        XCTAssertEqual(translator.recentTargets, [.german, .uzbek, .russian], "capped at three")
        translator.choose(target: .uzbek)
        XCTAssertEqual(translator.recentTargets, [.uzbek, .german, .russian])
        translator.swap()
        XCTAssertEqual(translator.recentTargets.first, translator.target, "a swap's new target is the most recent")
        XCTAssertEqual(Translator(defaults: rig.defaults, preferredLanguages: ["en"]).recentTargets, [translator.target],
                       "memory only: a new translator starts from its target alone")
    }

    // MARK: - The entries

    private func targetEntries(chosen: TranslationLanguage = .russian, recents: [TranslationLanguage] = [.russian, .english, .uzbek],
                               online: Set<TranslationLanguage> = [.uzbek]) -> [TranslateMenuEntry] {
        TranslateMenuModel.entries(side: .target, chosen: chosen, recents: recents, isOnlineOnly: { online.contains($0) })
    }

    /// Recent, its three rows, a rule, On this Mac, the rest, a rule, and
    /// Translation Languages…; nothing above Recent in the target's menu.
    func testTheTargetMenuIsRecentThenThisMacThenTheSettingsRow() {
        let entries = targetEntries()
        XCTAssertEqual(entries.first?.kind, .header)
        XCTAssertEqual(entries.first?.title, "Recent")
        XCTAssertEqual(titles(Array(entries[1...3])), ["Russian", "English", "Uzbek (Online)"])
        XCTAssertEqual(entries[4].kind, .separator)
        XCTAssertEqual(entries[5].kind, .header)
        XCTAssertEqual(entries[5].title, "On this Mac")
        XCTAssertEqual(entries[entries.count - 2].kind, .separator)
        XCTAssertEqual(entries.last?.kind, .translationLanguages)
        XCTAssertEqual(entries.last?.title, "Translation Languages…")
        XCTAssertFalse(kinds(entries).contains(.detect), "Detect Language is the source's alone")
    }

    /// Every language once: the recent ones are not repeated under On this Mac,
    /// so a tick is in one place, and all sixteen are reachable.
    func testEveryLanguageAppearsOnce() {
        let entries = targetEntries()
        let codes: [String] = entries.compactMap { if case .language(let code) = $0.kind { return code } else { return nil } }
        XCTAssertEqual(codes.count, TranslationLanguage.all.count)
        XCTAssertEqual(Set(codes).count, codes.count, "no language listed twice")
        XCTAssertEqual(Set(codes), Set(TranslationLanguage.all.map(\.code)))
    }

    /// Online-only languages say so, in Recent and in On this Mac alike.
    func testOnlineOnlyLanguagesAreSuffixedEverywhere() {
        let entries = targetEntries(recents: [.russian], online: [.uzbek, .kazakh])
        XCTAssertTrue(titles(entries).contains("Uzbek (Online)"), "under On this Mac")
        XCTAssertTrue(titles(entries).contains("Kazakh (Online)"))
        XCTAssertTrue(titles(entries).contains("German"), "an installed one is plain")
        XCTAssertEqual(TranslateMenuModel.title(of: .uzbek, isOnlineOnly: true), "Uzbek (Online)")
        XCTAssertEqual(TranslateMenuModel.title(of: .uzbek, isOnlineOnly: false), "Uzbek")
    }

    func testTheChosenLanguageIsTheOneTick() {
        let ticked = targetEntries(chosen: .russian).filter(\.isChecked)
        XCTAssertEqual(titles(ticked), ["Russian"])
    }

    func testTheSourceMenuStartsWithDetectLanguage() {
        let detecting = TranslateMenuModel.entries(side: .source, chosen: nil, recents: [.russian], isOnlineOnly: { _ in false })
        XCTAssertEqual(detecting.first?.kind, .detect)
        XCTAssertEqual(detecting.first?.title, "Detect Language")
        XCTAssertTrue(detecting.first?.isChecked ?? false, "detecting ticks Detect Language")
        XCTAssertEqual(detecting[1].kind, .separator)
        XCTAssertEqual(detecting.filter(\.isChecked).count, 1)

        let told = TranslateMenuModel.entries(side: .source, chosen: .german, recents: [.russian], isOnlineOnly: { _ in false })
        XCTAssertFalse(told.first?.isChecked ?? true)
        XCTAssertEqual(titles(told.filter(\.isChecked)), ["German"])
    }

    // MARK: - The pop-up's label

    /// "English (Detected)" once there is text to hear; "Detect Language" before.
    func testTheSourceLabelSaysWhatItHeard() {
        XCTAssertEqual(
            TranslateMenuModel.sourceTitle(chosen: nil, detected: .english, hasText: true, isOnlineOnly: false),
            "English (Detected)"
        )
        XCTAssertEqual(
            TranslateMenuModel.sourceTitle(chosen: nil, detected: .english, hasText: false, isOnlineOnly: false),
            "Detect Language"
        )
        XCTAssertEqual(
            TranslateMenuModel.sourceTitle(chosen: .german, detected: .english, hasText: true, isOnlineOnly: false),
            "German", "told, it is not second-guessed"
        )
        XCTAssertEqual(
            TranslateMenuModel.sourceTitle(chosen: .uzbek, detected: .english, hasText: true, isOnlineOnly: true),
            "Uzbek (Online)"
        )
    }

    /// The same rows in Russian, from the table, so the headers are not English
    /// words over a Russian list.
    func testTheHeadersAreRussianInRussian() {
        LabLocalization.use("ru")
        let entries = targetEntries()
        XCTAssertEqual(entries.first?.title, "Недавние")
        XCTAssertTrue(titles(entries).contains("На этом Mac"))
        // The language's own name follows the process's language (`appLanguage`),
        // which a test does not change; the words around it are the table's.
        XCTAssertEqual(
            TranslateMenuModel.sourceTitle(chosen: nil, detected: .english, hasText: true, isOnlineOnly: false),
            "\(TranslationLanguage.english.name) (определён)"
        )
        XCTAssertEqual(
            TranslateMenuModel.sourceTitle(chosen: nil, detected: .english, hasText: false, isOnlineOnly: false),
            "Определить язык"
        )
        XCTAssertTrue(titles(entries).contains("\(TranslationLanguage.uzbek.name) (онлайн)"))
    }

    // MARK: - The controller

    func testChoosingRowsActsOnTheTranslator() {
        let rig = TranslateRig()
        defer { rig.release() }
        var opened = 0
        let target = TranslateMenuController(translator: rig.translator, side: .target, openLanguages: { opened += 1 })
        target.perform(.language("de"))
        XCTAssertEqual(rig.translator.target, .german)
        target.perform(.translationLanguages)
        XCTAssertEqual(opened, 1)
        target.perform(.header)
        target.perform(.separator)
        XCTAssertEqual(rig.translator.target, .german, "a header does nothing")

        let source = TranslateMenuController(translator: rig.translator, side: .source)
        source.perform(.language("uz"))
        XCTAssertEqual(rig.translator.source, .uzbek)
        source.perform(.detect)
        XCTAssertNil(rig.translator.source, "Detect Language hands the source back to detection")
    }

    /// The menu AppKit gets: headers are section headers, the chosen row is the
    /// one the pop-up lays over its button, and a rule is a rule.
    func testTheMenuAppKitGetsHasHeadersAndTheChosenRowOverTheButton() {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.translator.choose(target: .russian)
        let controller = TranslateMenuController(translator: rig.translator, side: .target)
        let (menu, selected) = controller.makeMenu()
        XCTAssertEqual(selected?.title, "Russian")
        XCTAssertEqual(selected?.state, .on)
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), ["Recent", "On this Mac"])
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 2)
        XCTAssertEqual(menu.items.count, controller.entries().count)
        XCTAssertEqual(menu.items.last?.title, "Translation Languages…")
        XCTAssertEqual(menu.title, "Translate To")
    }
}
