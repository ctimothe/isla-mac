import XCTest
@testable import IslaKit

/// "When I click Use Online it's not even working instantly" (owner,
/// 2026-10-26, English → Russian with Russian not downloaded). Every engine
/// here is a fake: nothing is sent and no device language is read.
@MainActor
final class TranslateUseOnlineTests: XCTestCase {
    private final class Sent {
        var texts: [String] = []
        var failure: Error?
    }

    /// English → Russian on a Mac that offers the pair but has not downloaded
    /// it, the model unable to run: the owner's screen.
    private func rig(installed: @escaping () -> Bool = { false }) -> (TranslateRig, Sent) {
        let rig = TranslateRig()
        let sent = Sent()
        rig.translator.capabilitiesOverride = { _ in
            .init(systemInstalled: installed(), systemSupported: true)
        }
        rig.translator.onlineTranslate = { text, _ in
            sent.texts.append(text)
            if let failure = sent.failure { throw failure }
            return OnlineTranslation.Reply(text: "Салом (\(text))", sentCharacters: nil)
        }
        rig.translator.choose(source: .english)
        rig.translator.choose(target: .russian)
        rig.translator.input = "salom"
        return (rig, sent)
    }

    /// The press shows progress at once — in the same turn of the run loop, so
    /// on the next frame — and the run it starts skips the typing pause.
    func testThePressShowsProgressAtOnceAndSkipsTheTypingPause() async {
        let (rig, sent) = rig()
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()
        XCTAssertEqual(translator.failureKind, .obstacle(.needsDownload(.russian)))

        translator.useOnline()
        XCTAssertTrue(translator.isTranslating, "the spinner replaces the alert on the press itself")
        XCTAssertEqual(
            TranslatePane.showing(failure: translator.failure != nil, output: false, covered: false, translating: translator.isTranslating),
            .translating
        )
        XCTAssertEqual(translator.pauseBeforeRun(), .zero, "a press is not typing: no 320 ms wait")
        XCTAssertEqual(translator.pauseBeforeRun(), Translator.typingPause, "taken once; the next keystroke waits as before")

        translator.useOnline()
        let started = ContinuousClock.now
        await translator.runWhenSettled()
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(200))
        XCTAssertEqual(sent.texts, ["salom"])
        XCTAssertEqual(translator.engine, .online)
        XCTAssertFalse(translator.isTranslating)
    }

    /// One press stands for the pair: what is typed next goes online too, with
    /// Translate Online still off.
    func testLaterEditsTranslateOnlineWithoutAnotherPress() async {
        let (rig, sent) = rig()
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()
        translator.useOnline()
        await translator.translate()
        translator.input = "salom dunyo"
        await translator.translate()
        XCTAssertEqual(sent.texts, ["salom", "salom dunyo"])
        XCTAssertEqual(translator.engine, .online)
        XCTAssertNil(translator.failure)
        XCTAssertFalse(rig.defaults.bool(forKey: NotchViewModel.onlineTranslationKey), "the switch stays off")
    }

    /// Unreachable is one alert in the card with Try Again, and Try Again works
    /// without a second press because the choice still stands.
    func testANetworkFailureIsOneAlertAndTryAgainUsesTheStandingChoice() async {
        let (rig, sent) = rig()
        defer { rig.release() }
        let translator = rig.translator
        sent.failure = OnlineTranslation.Failure.unreachable
        await translator.translate()
        translator.useOnline()
        await translator.translate()
        XCTAssertEqual(translator.failureKind, .unreachable)
        XCTAssertEqual(translator.remedies, [.retry])
        XCTAssertTrue(translator.output.isEmpty)

        sent.failure = nil
        translator.retry()
        XCTAssertTrue(translator.isTranslating, "Try Again is a press too")
        await translator.translate()
        XCTAssertEqual(sent.texts, ["salom", "salom"])
        XCTAssertEqual(translator.engine, .online)
    }

    /// Once the language is downloaded the Mac answers again, though the choice
    /// still stands: online is only ever used when nothing here can run.
    func testADownloadedLanguageIsPreferredAgain() async {
        var installed = false
        let (rig, sent) = rig(installed: { installed })
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()
        translator.useOnline()
        await translator.translate()
        XCTAssertEqual(translator.engine, .online)

        installed = true
        let engines = Translator.engines(given: .init(systemInstalled: true, systemSupported: true, onlineByRequest: true))
        XCTAssertEqual(engines, [.system], "never online beside an engine that can run")
        XCTAssertEqual(sent.texts, ["salom"])
    }

    /// The choice is for this pair and this opening: a pair change, Clear and
    /// Escape still end it, as before.
    func testThePairClearAndEscapeStillEndTheChoice() async {
        let (rig, sent) = rig()
        defer { rig.release() }
        let translator = rig.translator
        await translator.translate()
        translator.useOnline()
        translator.choose(target: .ukrainian)
        XCTAssertNil(translator.onlineRequest)
        await translator.translate()
        XCTAssertTrue(sent.texts.isEmpty)

        translator.useOnline()
        translator.clear()
        XCTAssertNil(translator.onlineRequest)
        XCTAssertFalse(translator.isTranslating, "Clear takes the spinner down too")

        translator.input = "salom"
        translator.useOnline()
        translator.reset()
        XCTAssertNil(translator.onlineRequest)
    }

    /// Text the clipboard brings never rides a standing press (owner,
    /// 2026-10-26): ⌃⌥⌘T, the "Translate in Isla" service and a Clipboard
    /// row's Translate can carry a copied password or token, so the card asks
    /// again with Use Online. Typed edits still ride it.
    func testClipboardTextAsksAgainWhileTypedEditsKeepThePress() async throws {
        let (rig, sent) = rig()
        defer { rig.release() }
        let translator = rig.translator
        let vm = NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
        vm.open(.translate)
        vm.isOpen = true
        await translator.translate()
        translator.useOnline()
        await translator.translate()
        TranslatePane.typed("salom dunyo", privacy: rig.privacy, translator: translator)
        await translator.translate()
        XCTAssertEqual(sent.texts, ["salom", "salom dunyo"], "typing rides the press")

        vm.receiveCommandedTranslation(Translator.prepareCommandInput("hunter2-secret"))
        XCTAssertNil(translator.onlineRequest, "the hot key's text ends the press")
        await translator.translate()
        XCTAssertEqual(sent.texts, ["salom", "salom dunyo"], "nothing from the clipboard went online")
        XCTAssertEqual(translator.failureKind, .obstacle(.needsDownload(.russian)))
        let alert = TranslateAlert.make(
            kind: translator.failureKind, message: translator.failure ?? "", remedies: translator.remedies,
            allowanceSpent: false, covered: false
        )
        XCTAssertTrue(alert.actions.contains(.useOnline), "the card offers Use Online again once the text is shown")
        XCTAssertFalse(rig.defaults.bool(forKey: NotchViewModel.onlineTranslationKey))

        translator.useOnline()
        vm.translateClipboardText("another copied secret")
        XCTAssertNil(translator.onlineRequest, "a Clipboard row's Translate ends it too")

        translator.useOnline()
        await translator.translate()
        XCTAssertEqual(sent.texts.last, "another copied secret", "a fresh press sends it")
    }
}
