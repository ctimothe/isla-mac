import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// What review of release R4 found wrong in the Translate tab (2026-10-15), one
/// test per finding. Every engine, pasteboard, defaults suite and voice here is
/// a fake: nothing is sent, spoken or read from the owner's machine.
@MainActor
final class TranslateReviewFixTests: XCTestCase {
    // MARK: - Use Online authorizes one request (privacy)

    /// Counts what would have left the Mac. A box, so the closure the translator
    /// holds and the test read the same list.
    private final class Sent {
        var texts: [String] = []
        var routes: [Translator.Route] = []
        var failure: Error?
    }

    /// A rig on a pair the Mac has but has not downloaded — nothing can run, so
    /// the only way anything is sent is a Use Online press — and a counting
    /// stand-in for MyMemory.
    private func downloadRig(keepHistory: Bool = false) -> (rig: TranslateRig, sent: Sent) {
        let rig = TranslateRig(keepHistory: keepHistory)
        let sent = Sent()
        rig.translator.capabilitiesOverride = { _ in .init(systemSupported: true) }
        rig.translator.onlineTranslate = { text, route in
            sent.texts.append(text)
            sent.routes.append(route)
            if let failure = sent.failure { throw failure }
            return OnlineTranslation.Reply(text: "Привіт", sentCharacters: nil)
        }
        rig.translator.choose(target: .ukrainian)
        rig.translator.input = "Hello"
        return (rig, sent)
    }

    /// A press used to cover the next pair too: `onlineRequest` held only the
    /// text, so choosing French after pressing Use Online for Ukrainian sent the
    /// same text to MyMemory with the switch off and nobody pressing anything.
    func testAPressDoesNotCoverAnotherTarget() async {
        let (rig, sent) = downloadRig()
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()
        translator.useOnline()
        translator.choose(target: .french)
        XCTAssertNil(translator.onlineRequest, "a pair change ends the permission")
        await translator.translate()
        XCTAssertTrue(sent.texts.isEmpty, "nothing left the Mac: \(sent.texts)")
        XCTAssertEqual(translator.failureKind, .obstacle(.needsDownload(.french)))
    }

    func testAPressDoesNotCoverAnotherSource() async {
        let (rig, sent) = downloadRig()
        defer { rig.release() }
        let translator = rig.translator
        translator.choose(source: .english)
        await translator.translate()
        translator.useOnline()
        translator.choose(source: .german)
        XCTAssertNil(translator.onlineRequest)
        await translator.translate()
        XCTAssertTrue(sent.texts.isEmpty, "\(sent.texts)")
    }

    func testAPressDoesNotSurviveASwap() async {
        let (rig, sent) = downloadRig()
        defer { rig.release() }
        let translator = rig.translator
        translator.choose(source: .english)
        await translator.translate()
        translator.useOnline()
        translator.swap()
        XCTAssertNil(translator.onlineRequest, "the swap is a pair change")
        // And back, to the very pair that was pressed: still nothing.
        translator.swap()
        translator.input = "Hello"
        await translator.translate()
        XCTAssertTrue(sent.texts.isEmpty, "\(sent.texts)")
    }

    /// Ukrainian, French, Ukrainian again: the pair on screen is the pair that
    /// was pressed, and the press is long gone.
    func testAPressDoesNotComeBackWithThePair() async {
        let (rig, sent) = downloadRig()
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()
        translator.useOnline()
        translator.choose(target: .french)
        translator.choose(target: .ukrainian)
        await translator.translate()
        XCTAssertTrue(sent.texts.isEmpty, "A to B to A must not revive the press: \(sent.texts)")
        XCTAssertEqual(translator.failureKind, .obstacle(.needsDownload(.ukrainian)))
    }

    /// The press is spent by its request. A Try Again, a debounce re-run of the
    /// same request or an edit back to the same text finds it gone.
    func testAPressIsSpentWhenItsRequestSucceeds() async {
        let (rig, sent) = downloadRig()
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()
        translator.useOnline()
        await translator.translate()
        XCTAssertEqual(sent.texts, ["Hello"])
        XCTAssertEqual(translator.engine, .online)
        XCTAssertNil(translator.onlineRequest, "consumed by the request it authorized")
        XCTAssertEqual(sent.routes.first, Translator.Route(source: .english, target: .ukrainian))

        translator.retry()
        await translator.translate()
        XCTAssertEqual(sent.texts, ["Hello"], "Try Again is a new request and was not pressed for")
        XCTAssertEqual(translator.failureKind, .obstacle(.needsDownload(.ukrainian)))
    }

    func testAPressIsSpentWhenItsRequestFails() async {
        let (rig, sent) = downloadRig()
        defer { rig.release() }
        let translator = rig.translator
        sent.failure = OnlineTranslation.Failure.unreachable
        await translator.translate()
        translator.useOnline()
        await translator.translate()
        XCTAssertEqual(sent.texts, ["Hello"])
        XCTAssertEqual(translator.failureKind, .unreachable)
        XCTAssertNil(translator.onlineRequest)

        // The Try Again under "not reachable" does not send a second time: the
        // person pressed Use Online once, and a second send needs a second press.
        sent.failure = nil
        translator.retry()
        await translator.translate()
        XCTAssertEqual(sent.texts, ["Hello"], "no second online send without another press")
    }

    func testAPressEndsWithAnEditClearAndEscape() async {
        let (rig, sent) = downloadRig()
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()

        translator.useOnline()
        translator.input = "Hello!"
        XCTAssertNil(translator.onlineRequest, "an edit")

        translator.useOnline()
        translator.clear()
        XCTAssertNil(translator.onlineRequest, "Clear")

        translator.input = "Hello"
        translator.useOnline()
        translator.reset()
        XCTAssertNil(translator.onlineRequest, "the reset Escape and the Clear button both make")
        XCTAssertTrue(sent.texts.isEmpty)
    }

    func testAnEscapePressRevokesIt() throws {
        let (rig, _) = downloadRig()
        defer { rig.release() }
        let vm = NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: rig.translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
        vm.select(.translate)
        rig.translator.useOnline()
        XCTAssertTrue(vm.consumeEscape())
        XCTAssertNil(rig.translator.onlineRequest)
    }

    /// Restoring from History puts an answer back and asks nobody anything; it
    /// also ends a press, which belonged to the pair and text it was made on.
    func testRestoringFromHistoryEndsAPressAndSendsNothing() async {
        let (rig, sent) = downloadRig(keepHistory: true)
        defer { rig.release() }
        let translator = rig.translator
        rig.answer("Good morning", "Добрий ранок", by: .system)
        let entry = rig.history.entries[0]
        translator.input = "Hello"
        translator.useOnline()
        translator.restore(entry)
        XCTAssertNil(translator.onlineRequest)
        await translator.translate()
        XCTAssertTrue(sent.texts.isEmpty, "\(sent.texts)")
        XCTAssertEqual(translator.output, "Добрий ранок")
    }

    func testClosingThePanelEndsAPress() throws {
        let (rig, _) = downloadRig()
        defer { rig.release() }
        let vm = NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: rig.translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
        vm.select(.translate)
        vm.isOpen = true
        rig.translator.useOnline()
        XCTAssertNotNil(rig.translator.onlineRequest)
        vm.isOpen = false
        XCTAssertNil(rig.translator.onlineRequest)
    }

    func testTheCoverEndsAPress() throws {
        let (rig, _) = downloadRig()
        defer { rig.release() }
        let vm = NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: rig.translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
        vm.select(.translate)
        rig.privacy.reveal(TranslatePane.revealID)
        rig.translator.useOnline()
        rig.privacy.setCovering(.translate, true)
        // Covering is on but this pane was uncovered by hand: it is still shown.
        XCTAssertNotNil(rig.translator.onlineRequest, "an uncovered pane is not hidden")
        rig.privacy.coverEverything()
        XCTAssertNil(rig.translator.onlineRequest, "the pane went back under its dots")

        rig.privacy.reveal(TranslatePane.revealID)
        rig.translator.useOnline()
        rig.privacy.conceal(TranslatePane.revealID)
        XCTAssertNil(rig.translator.onlineRequest, "concealed by the hot key's new text")
        _ = vm
    }

    /// The exception the comment promises: a pair the Mac has. A pair no engine
    /// on the Mac offers is Turn On Translate Online's, not a press's.
    func testAPressOnlyOpensOnlineForAPairTheMacHas() {
        var capabilities = Translator.Capabilities()
        capabilities.onlineByRequest = true
        XCTAssertEqual(Translator.engines(given: capabilities), [], "the Mac does not offer this pair at all")
        capabilities.systemSupported = true
        XCTAssertEqual(Translator.engines(given: capabilities), [.online], "offered, not downloaded")
        capabilities = Translator.Capabilities(modelSupportsPair: true, modelObstacle: .appleIntelligenceOff)
        capabilities.onlineByRequest = true
        XCTAssertEqual(Translator.engines(given: capabilities), [], "a model that is off is not a language the Mac lacks")
        capabilities = Translator.Capabilities(belowMinimumSystem: true)
        capabilities.onlineByRequest = true
        XCTAssertEqual(Translator.engines(given: capabilities), [])
    }

    // MARK: - Use Online is not offered under the cover (privacy)

    func testACoveredCardOffersNothingThatSendsText() {
        let download = TranslateAlert.make(
            kind: .obstacle(.needsDownload(.ukrainian)), message: "m", remedies: [.translationLanguages],
            allowanceSpent: false, covered: true
        )
        XCTAssertEqual(download.actions, [.translationLanguages], "Use Online is withheld, the settings button stays")

        let online = TranslateAlert.make(
            kind: .obstacle(.needsOnline(.uzbek)), message: "m", remedies: [.turnOnOnline],
            allowanceSpent: false, covered: true
        )
        XCTAssertFalse(online.actions.contains(.turnOnOnline))
        XCTAssertEqual(online.message, "m", "the sentence stays: it names no text")

        let retry = TranslateAlert.make(
            kind: .unreachable, message: "m", remedies: [.retry], allowanceSpent: false, covered: true
        )
        XCTAssertEqual(retry.actions, [.tryAgain], "Try Again stays")

        let uncovered = TranslateAlert.make(
            kind: .obstacle(.needsDownload(.ukrainian)), message: "m", remedies: [.translationLanguages],
            allowanceSpent: false, covered: false
        )
        XCTAssertEqual(uncovered.actions, [.translationLanguages, .useOnline])
    }

    func testThePaneDoesNotDrawUseOnlineWhileCovered() async {
        let (rig, _) = downloadRig()
        defer { rig.release() }
        await rig.translator.translate()
        XCTAssertEqual(rig.translator.failureKind, .obstacle(.needsDownload(.ukrainian)))

        let pane = TranslatePane(translator: rig.translator, privacy: rig.privacy, wantsKeyboard: .constant(false))
            .background(Color.black)
        let open = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
        XCTAssertNotNil(open.first(label: "Use Online"), open.dump)

        rig.privacy.setCovering(.translate, true)
        let covered = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
        XCTAssertNil(covered.first(label: "Use Online"), covered.dump)
        XCTAssertNotNil(covered.first(label: "Translation Languages…"), "the settings button stays\n\(covered.dump)")
    }

    // MARK: - The limit refuses an edit instead of cutting the end

    /// Typing a letter into the middle of a full field used to keep the first
    /// 20,000 characters, which silently threw away the last one of the
    /// person's own text.
    func testAnInsertionPastTheLimitIsRefused() {
        let rig = TranslateRig()
        defer { rig.release() }
        let limit = Translator.commandInputLimit
        let full = String(repeating: "a", count: limit - 1) + "z"
        rig.translator.input = full
        let edited = String(full.prefix(10)) + "X" + String(full.dropFirst(10))
        TranslatePane.typed(edited, privacy: rig.privacy, translator: rig.translator)
        XCTAssertEqual(rig.translator.input, full, "the text is exactly as it was")
        XCTAssertTrue(rig.translator.input.hasSuffix("z"), "the end is still there")
        XCTAssertNotNil(rig.translator.notice, "and the refusal is said")
    }

    /// The simpler rule: the notice stands while the edits keep being refused,
    /// and any edit that lands takes it down — `input.didSet` clears it — so it
    /// is gone the moment the text drops below the limit or is cleared.
    func testTheNoticeStandsUntilTheTextChanges() {
        let rig = TranslateRig()
        defer { rig.release() }
        let limit = Translator.commandInputLimit
        let full = String(repeating: "a", count: limit)
        rig.translator.input = full
        TranslatePane.typed(full + "b", privacy: rig.privacy, translator: rig.translator)
        let notice = rig.translator.notice
        XCTAssertNotNil(notice)
        TranslatePane.typed(full + "c", privacy: rig.privacy, translator: rig.translator)
        XCTAssertEqual(rig.translator.notice, notice, "a second refusal says the same")
        XCTAssertEqual(rig.translator.input, full)

        TranslatePane.typed(String(full.dropLast()), privacy: rig.privacy, translator: rig.translator)
        XCTAssertEqual(rig.translator.input.count, limit - 1)
        XCTAssertNil(rig.translator.notice, "below the limit again")

        TranslatePane.typed(rig.translator.input + "d", privacy: rig.privacy, translator: rig.translator)
        XCTAssertEqual(rig.translator.input.count, limit, "exactly the limit is within it")
        XCTAssertNil(rig.translator.notice)
        TranslatePane.typed(full + "e", privacy: rig.privacy, translator: rig.translator)
        XCTAssertNotNil(rig.translator.notice)
        rig.translator.reset()
        XCTAssertNil(rig.translator.notice, "cleared")
    }

    /// Paste into an empty field is the one cut that remains: there is nothing
    /// of the person's own to lose, a pasted block cannot be refused a piece
    /// at a time, and the notice says what was kept.
    func testAPasteIntoAnEmptyFieldIsStillCutAndSaysSo() {
        let rig = TranslateRig()
        defer { rig.release() }
        let limit = Translator.commandInputLimit
        TranslatePane.typed(String(repeating: "p", count: limit + 40), privacy: rig.privacy, translator: rig.translator)
        XCTAssertEqual(rig.translator.input.count, limit)
        XCTAssertNotNil(rig.translator.notice)
    }

    // MARK: - Paste under Don't Allow

    /// A named provider that offers a string type and never supplies it, the
    /// shape a refused read takes.
    private final class SilentProvider: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
    }

    private func offerSilently(on board: NSPasteboard, provider: SilentProvider) {
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        board.writeObjects([item])
    }

    func testPasteIsDisabledUnderDontAllowWithAReason() async {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("Hello", forType: .string)
        rig.translator.pasteboardAccessOverride = { .denied }
        XCTAssertTrue(rig.translator.pasteboardOffersText)
        XCTAssertFalse(rig.translator.canPaste)

        let pane = TranslatePane(translator: rig.translator, privacy: rig.privacy, wantsKeyboard: .constant(false))
            .background(Color.black)
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
        let paste = root.first(label: "Paste")
        XCTAssertNotNil(paste, root.dump)
        XCTAssertFalse(paste?.enabled ?? true, root.dump)
        XCTAssertEqual(paste?.help, Translator.pasteRefusedSentence, "the tooltip says why\n\(root.dump)")

        rig.translator.pasteboardAccessOverride = { .allowed }
        XCTAssertTrue(rig.translator.canPaste)
    }

    func testARefusedReadSaysSoAndNotThatTheClipboardHasNoText() {
        let rig = TranslateRig()
        defer { rig.release() }
        let provider = SilentProvider()
        offerSilently(on: rig.pasteboard, provider: provider)
        rig.translator.pasteboardAccessOverride = { .ask }
        let refused = rig.translator.textFromPasteboard()
        XCTAssertNil(refused.text)
        XCTAssertEqual(refused.notice, Translator.pasteRefusedSentence,
                       "the types promised text and the read came back empty: that is a refusal")

        rig.translator.pasteboardAccessOverride = { .denied }
        XCTAssertEqual(rig.translator.textFromPasteboard().notice, Translator.pasteRefusedSentence)

        // Nothing to read is a different sentence.
        rig.pasteboard.clearContents()
        rig.translator.pasteboardAccessOverride = { .allowed }
        XCTAssertEqual(rig.translator.textFromPasteboard().notice, localized("The clipboard has no text."))
        rig.translator.pasteboardAccessOverride = { .ask }
        XCTAssertEqual(rig.translator.textFromPasteboard().notice, localized("The clipboard has no text."),
                       "no text on offer is no refusal")
    }

    // MARK: - History keeps what the answer was

    func testAPartialAnswerKeepsItsWarningInHistory() {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        let note = Translator.onlineCapNote(sent: 4_763, locale: Locale(identifier: "en"))
        rig.translator.input = "Hello"
        rig.translator.received("Привет", for: "Hello", by: .online, note: note)
        XCTAssertEqual(rig.history.entries.first?.note, note)

        rig.translator.reset()
        rig.translator.restore(rig.history.entries[0])
        XCTAssertEqual(rig.translator.output, "Привет")
        XCTAssertEqual(rig.translator.outputNote, note, "a restore does not show a cut answer as a whole one")
    }

    func testRestoringADetectedSourceKeepsDetectLanguageOn() {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        XCTAssertNil(rig.translator.source)
        rig.translator.choose(target: .russian)
        rig.answer("Hello", "Привет")
        XCTAssertEqual(rig.history.entries[0].detectedSource, true)
        rig.translator.choose(target: .german)
        rig.translator.restore(rig.history.entries[0])
        XCTAssertNil(rig.translator.source, "Detect Language is still on after a restore")
        XCTAssertEqual(rig.translator.target, .russian)
        XCTAssertNil(rig.defaults.string(forKey: Translator.sourceKey).flatMap(TranslationLanguage.withCode),
                     "and the stored choice is Detect too")
    }

    func testRestoringAChosenSourceKeepsIt() {
        let rig = TranslateRig(keepHistory: true)
        defer { rig.release() }
        rig.translator.choose(source: .english)
        rig.translator.choose(target: .russian)
        rig.answer("Hello", "Привет")
        XCTAssertEqual(rig.history.entries[0].detectedSource, false)
        rig.translator.choose(source: nil)
        rig.translator.restore(rig.history.entries[0])
        XCTAssertEqual(rig.translator.source, .english)
    }

    // MARK: - Speech voices

    private typealias Voice = (language: String, quality: Int)

    private func pick(_ code: String, _ voices: [Voice]) -> String? {
        VoiceMatch.best(for: code, among: voices).map { voices[$0].language }
    }

    func testVoiceMatchingPrefersTheExactLanguage() {
        let chinese: [Voice] = [("zh-HK", 3), ("zh-TW", 3), ("zh-CN", 1)]
        XCTAssertEqual(pick("zh-Hans", chinese), "zh-CN", "Simplified is the mainland voice, whatever the quality of the others")
        XCTAssertEqual(pick("zh-Hant", chinese), "zh-TW", "Traditional picks the best Hant voice")
        XCTAssertEqual(pick("zh-Hant", [("zh-CN", 3), ("zh-HK", 1), ("zh-TW", 2)]), "zh-TW")
        XCTAssertEqual(pick("zh-Hans", [("zh-HK", 3), ("zh-TW", 2)]), nil,
                       "no Simplified voice: Cantonese and Taiwanese are not a stand-in")
        XCTAssertEqual(pick("zh-Hans", [("zh-Hans", 1), ("zh-CN", 3)]), "zh-Hans", "an exact identifier wins")

        let portuguese: [Voice] = [("pt-PT", 3), ("pt-BR", 1)]
        XCTAssertEqual(pick("pt-BR", portuguese), "pt-BR")
        XCTAssertEqual(pick("pt-PT", portuguese), "pt-PT")
        XCTAssertEqual(pick("pt-BR", [("pt-PT", 2)]), "pt-PT", "the same language without the region is better than silence")
        XCTAssertEqual(pick("pt", [("pt-PT", 1), ("pt-BR", 3)]), "pt-BR", "the bare code takes the best of the language")
    }

    func testVoiceMatchingByBaseCodeQualityAndNone() {
        let voices: [Voice] = [("en-GB", 1), ("en-US", 3), ("ru-RU", 2), ("de-DE", 2)]
        XCTAssertEqual(pick("en", voices), "en-US", "best quality among the language's voices")
        XCTAssertEqual(pick("ru", voices), "ru-RU")
        XCTAssertNil(pick("uz", voices))
        XCTAssertNil(pick("kk", []))
        XCTAssertNil(pick("zh-Hans", voices))
        XCTAssertEqual(pick("en", [("en_US", 1)]), "en_US", "an underscore is the same tag")
        XCTAssertNil(pick("en", [("eng-US", 1)]), "a longer language is not a prefix match")
    }

    /// The voice list is loaded when the panel asks, not from a body, and the
    /// pane learns it arrived.
    func testRefreshingVoicesIsAskedOfTheEngineAndBumpsTheVersion() {
        let fake = FakeSynthesizer()
        let speaker = TranslationSpeaker(synthesizer: fake)
        let before = speaker.voicesVersion
        speaker.refreshVoices()
        XCTAssertEqual(fake.refreshCount, 1)
        XCTAssertEqual(speaker.voicesVersion, before + 1)
    }

    func testOpeningThePanelOnTranslateRefreshesVoices() throws {
        let rig = TranslateRig()
        defer { rig.release() }
        let vm = NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: rig.translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
        vm.select(.translate)
        let before = rig.synthesizer.refreshCount
        vm.isOpen = true
        XCTAssertEqual(rig.synthesizer.refreshCount, before + 1)
    }

    // MARK: - The History button follows the setting

    func testTheHistoryButtonFollowsKeepHistoryLive() async {
        let rig = TranslateRig(keepHistory: false)
        defer { rig.release() }
        let view = Color.black.modifier(TranslateHeaderTools(
            isShown: true, bodyWidth: 560, defaults: rig.defaults,
            isHistoryOpen: .constant(false), isExpanded: .constant(false)
        ))
        let off = await AXProbe.tree(of: view, size: CGSize(width: 560, height: 60))
        XCTAssertNil(off.first(label: "History"), off.dump)
        rig.defaults.set(true, forKey: NotchViewModel.translateKeepHistoryKey)
        let on = await off.reread(settle: 0.3)
        XCTAssertNotNil(on.first(label: "History"), "turning Keep History on shows History without a rebuild\n\(on.dump)")
        rig.defaults.set(false, forKey: NotchViewModel.translateKeepHistoryKey)
        let gone = await on.reread(settle: 0.3)
        XCTAssertNil(gone.first(label: "History"), gone.dump)
    }
}
