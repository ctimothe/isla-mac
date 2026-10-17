import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Keep History and the list it keeps (redesign 2026-10-15, spec §11): the last
/// 20 translations, newest first, in memory only; a click puts a pair and both
/// texts back; turning the switch off empties it; a covered pane covers it.
@MainActor
final class TranslateHistoryTests: XCTestCase {
    private func record(_ history: TranslationHistory, _ index: Int) {
        history.record(
            source: "text \(index)", result: "перевод \(index)", from: .english, to: .russian, engine: .system
        )
    }

    // MARK: - The list

    func testTheListKeepsTwentyNewestFirst() {
        let history = TranslationHistory()
        for index in 1...25 { record(history, index) }
        XCTAssertEqual(TranslationHistory.capacity, 20)
        XCTAssertEqual(history.entries.count, 20)
        XCTAssertEqual(history.entries.first?.source, "text 25", "newest first")
        XCTAssertEqual(history.entries.last?.source, "text 6", "the oldest five are gone")
    }

    /// The same text on the same pair asked twice is one entry, at the top.
    func testTheSameTranslationAgainMovesToTheTop() {
        let history = TranslationHistory()
        record(history, 1)
        record(history, 2)
        record(history, 1)
        XCTAssertEqual(history.entries.map(\.source), ["text 1", "text 2"])
        history.record(source: "text 2", result: "x", from: .english, to: .german, engine: .system)
        XCTAssertEqual(history.entries.count, 3, "another pair is another translation")
    }

    func testTheLabelAndTheAgeAreTheBoards() {
        let history = TranslationHistory(now: { Date(timeIntervalSince1970: 1_000) })
        history.record(source: "a", result: "b", from: .english, to: .russian, engine: .system)
        history.record(source: "c", result: "d", from: .uzbek, to: .english, engine: .online)
        XCTAssertEqual(history.entries.map(\.pairLabel), ["UZ → EN", "EN → RU"])
        let entry = history.entries[0]
        XCTAssertEqual(ClipboardAge.text(of: entry.date, now: entry.date), "Now")
        XCTAssertEqual(ClipboardAge.text(of: entry.date, now: entry.date.addingTimeInterval(600)), "10 min")
    }

    // MARK: - Memory only

    /// Nothing is written: the history takes no URL and no defaults, and keeping
    /// twenty answers leaves the defaults suite and the temporary folder as they
    /// were. (The injected store is the rig's private suite.)
    func testNothingIsWrittenToDisk() async {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        let temporary = FileManager.default.temporaryDirectory
        func related() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
            return Set(names.filter { $0.localizedCaseInsensitiveContains("histor") || $0.localizedCaseInsensitiveContains("translat") })
        }
        let before = related()
        let suiteBefore = Set(rig.defaults.dictionaryRepresentation().keys)

        rig.translator.capabilitiesOverride = { _ in .init(onlineEnabled: true) }
        rig.translator.onlineTranslate = { text, _ in OnlineTranslation.Reply(text: "Salom \(text)", sentCharacters: nil) }
        rig.translator.choose(target: .uzbek)
        for index in 1...5 {
            rig.translator.input = "Hello \(index)"
            await rig.translator.translate()
        }
        XCTAssertEqual(rig.history.entries.count, 5, "kept")

        // The only keys that appeared are the language choice the tab has always
        // remembered; the list has none, and no stored value holds an answer.
        let added = Set(rig.defaults.dictionaryRepresentation().keys).subtracting(suiteBefore)
        XCTAssertTrue(added.isSubset(of: [Translator.sourceKey, Translator.targetKey]), "new keys: \(added)")
        for key in rig.defaults.dictionaryRepresentation().keys {
            XCTAssertFalse("\(rig.defaults.object(forKey: key) ?? "")".contains("Salom"), "\(key) holds an answer")
        }
        XCTAssertEqual(related(), before, "no file was written")
    }

    func testAFreshTranslatorStartsEmpty() {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        rig.answer()
        XCTAssertEqual(rig.history.entries.count, 1)
        let next = Translator(defaults: rig.defaults, preferredLanguages: ["en"])
        XCTAssertTrue(next.history.entries.isEmpty, "empties at quit: a new process has nothing")
    }

    // MARK: - Keep History

    /// Off by default (spec §14): nothing is kept, and the header offers nothing.
    func testNothingIsKeptWhileKeepHistoryIsOff() async {
        let rig = TranslateRig(keepHistory: false)
        defer { rig.release() }
        rig.answer()
        XCTAssertTrue(rig.history.entries.isEmpty)
        XCTAssertFalse(NotchViewModel.translateKeepHistoryEnabled(in: UserDefaults(suiteName: "TranslateHistoryTests.fresh.\(UUID())")!),
                       "off when nothing is stored")
        XCTAssertFalse(TranslateHeader.showsHistory(keepHistory: false))
        XCTAssertTrue(TranslateHeader.showsHistory(keepHistory: true))
    }

    func testAnAnswerIsKeptWithItsPairAndEngine() {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        rig.translator.choose(target: .russian)
        rig.answer("Hello", "Привет", by: .system)
        let entry = rig.history.entries.first
        XCTAssertEqual(entry?.source, "Hello")
        XCTAssertEqual(entry?.result, "Привет")
        XCTAssertEqual(entry?.from, .english, "a detected source is kept as the language it was detected as")
        XCTAssertEqual(entry?.to, .russian)
        XCTAssertEqual(entry?.engine, .system)
    }

    /// An answer to text since edited is not an answer to the field, and is not
    /// kept as one.
    func testAStaleAnswerIsNotKept() {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        rig.translator.input = "Hello again"
        rig.translator.received("Привет", for: "Hello", by: .system)
        XCTAssertTrue(rig.history.entries.isEmpty)
    }

    /// Turning Keep History off empties the list and closes it; turning it on
    /// touches nothing.
    func testTurningKeepHistoryOffEmptiesIt() throws {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        let vm = NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: rig.translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
        rig.answer("one", "один")
        rig.answer("two", "два")
        vm.translateShowsHistory = true
        vm.setTranslateKeepHistory(true)
        XCTAssertEqual(rig.history.entries.count, 2, "on touches nothing")
        XCTAssertTrue(vm.translateShowsHistory)
        vm.setTranslateKeepHistory(false)
        XCTAssertTrue(rig.history.entries.isEmpty)
        XCTAssertFalse(vm.translateShowsHistory)
    }

    func testTheListIsPutAwayWithTheVisit() throws {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        let vm = NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: rig.translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
        vm.open(.translate)
        vm.isOpen = true
        vm.translateShowsHistory = true
        vm.isOpen = false
        XCTAssertFalse(vm.translateShowsHistory, "closing")
        vm.isOpen = true
        vm.translateShowsHistory = true
        vm.open(.tray)
        XCTAssertFalse(vm.translateShowsHistory, "changing surface")
        vm.open(.translate)
        vm.translateShowsHistory = true
        vm.receiveCommandedTranslation(.init(text: "from the hot key", notice: nil))
        XCTAssertFalse(vm.translateShowsHistory, "text arriving by hot key lands in the field, not under a list")
        vm.translateShowsHistory = true
        XCTAssertTrue(vm.consumeEscape(), "Escape closes the list first")
        XCTAssertFalse(vm.translateShowsHistory)
        XCTAssertEqual(rig.translator.input, "from the hot key", "and leaves the text")
    }

    // MARK: - Restore

    func testRestoringPutsBackThePairAndBothTexts() async {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        rig.translator.choose(target: .russian)
        rig.answer("Hello", "Привет")
        let entry = rig.history.entries[0]
        rig.translator.choose(target: .german)
        rig.translator.input = "something else"

        rig.translator.restore(entry)
        XCTAssertEqual(rig.translator.input, "Hello")
        XCTAssertEqual(rig.translator.output, "Привет")
        XCTAssertEqual(rig.translator.target, .russian)
        XCTAssertNil(rig.translator.source, "the source was detected, so Detect Language comes back (see TranslateReviewFixTests)")
        XCTAssertEqual(rig.translator.engine, .system)
        XCTAssertTrue(rig.translator.answersInput)
        XCTAssertEqual(rig.history.entries.count, 1, "a restore is not a new translation")

        // And no engine is asked: the answer is already the field's.
        var asked = false
        rig.translator.capabilitiesOverride = { _ in asked = true; return .init() }
        await rig.translator.translate()
        XCTAssertFalse(asked, "the pane's task finds nothing left to translate")
        XCTAssertEqual(rig.translator.output, "Привет")
    }

    // MARK: - The list on screen

    private final class Flag { var on = true }

    private func list(_ rig: TranslateRig, flag: Flag = Flag()) -> some View {
        TranslatePane(
            translator: rig.translator, privacy: rig.privacy, wantsKeyboard: .constant(false),
            showsHistory: Binding(get: { flag.on }, set: { flag.on = $0 })
        )
        .background(Color.black)
    }

    func testTheListShowsRowsAndAClickRestoresOne() async {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        rig.answer("Where is the station?", "Где вокзал?")
        rig.answer("Good morning", "Доброе утро")
        let flag = Flag()
        let root = await AXProbe.tree(of: list(rig, flag: flag), size: CGSize(width: 488, height: 154))
        XCTAssertFalse(root.all { $0.value == "Recent" }.isEmpty, root.dump)
        let rows = root.all { $0.label.contains(", ") && $0.label.contains("Доброе") }
        XCTAssertEqual(rows.count, 1, root.dump)
        XCTAssertNil(root.first(label: "Swap Languages"), "the list replaces the pair bar and the cards\n\(root.dump)")

        let older = root.all { $0.label.hasPrefix("Where is the station?") }.first
        XCTAssertNotNil(older, root.dump)
        XCTAssertTrue(older?.press() ?? false)
        XCTAssertEqual(rig.translator.input, "Where is the station?")
        XCTAssertEqual(rig.translator.output, "Где вокзал?")
        XCTAssertFalse(flag.on, "a click returns to the cards")
    }

    func testAnEmptyListSaysSo() async {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        let root = await AXProbe.tree(of: list(rig), size: CGSize(width: 488, height: 154))
        XCTAssertFalse(root.all { $0.value == "No translations yet" || $0.label == "No translations yet" }.isEmpty, root.dump)
    }

    /// While Keep History is off the list is never drawn, whatever asked for it.
    func testTheListIsNotDrawnWithKeepHistoryOff() async {
        let rig = TranslateRig(keepHistory: false)
        defer { rig.release() }
        rig.answer()
        let root = await AXProbe.tree(of: list(rig), size: CGSize(width: 488, height: 154))
        // (The pop-ups' own rows have a "Recent" header; the list has rows.)
        XCTAssertTrue(root.all { $0.label.hasPrefix("Hello, ") }.isEmpty, root.dump)
        XCTAssertTrue(root.all { $0.value == "No translations yet" }.isEmpty, "not even the empty list\n\(root.dump)")
        XCTAssertNotNil(root.first(label: "Swap Languages"), root.dump)
    }

    /// A covered Translate covers the list too: the rows are dust, their text is
    /// nowhere in the tree, and one reveal uncovers them.
    func testACoveredListIsCovered() async {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        rig.answer("a secret sentence", "секретное предложение")
        rig.privacy.setCovering(.translate, true)
        let root = await AXProbe.tree(of: list(rig), size: CGSize(width: 488, height: 154))
        XCTAssertFalse(root.dump.contains("secret"), root.dump)
        XCTAssertFalse(root.dump.contains("секрет"), root.dump)
        XCTAssertNotNil(root.first(label: "Hidden"), root.dump)

        XCTAssertTrue(root.first(label: "Hidden")?.press() ?? false, root.dump)
        let revealed = await root.reread()
        XCTAssertTrue(revealed.dump.contains("a secret sentence"), revealed.dump)
    }
}
