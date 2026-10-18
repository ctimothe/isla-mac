import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Speak (redesign 2026-10-15, spec §11): the button reads the answer aloud in
/// the target language's voice, the spoken words sweep, and everything that makes
/// the words stale — the panel closing, the tab changing, the text changing,
/// Speak Button turning off — puts the voice away. Every engine here is a fake:
/// nothing in this file speaks.
@MainActor
final class TranslateSpeechTests: XCTestCase {
    // MARK: - The speaker

    func testSpeakingTogglesStateAndAsksTheEngineOnce() {
        let fake = FakeSynthesizer()
        let speaker = TranslationSpeaker(synthesizer: fake)
        XCTAssertFalse(speaker.isSpeaking)
        speaker.toggle("Привет", languageCode: "ru")
        XCTAssertTrue(speaker.isSpeaking)
        XCTAssertEqual(speaker.text, "Привет")
        XCTAssertEqual(fake.spoken.count, 1)
        XCTAssertEqual(fake.spoken.first?.language, "ru", "in the target language's voice")
        speaker.toggle("Привет", languageCode: "ru")
        XCTAssertFalse(speaker.isSpeaking, "pressed again, it stops")
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.spoken.count, 1)
        XCTAssertNil(speaker.text)
    }

    /// The sweep follows the engine's word ranges; a stale or absurd range cannot
    /// run past the text, and the end of the utterance ends the speaking.
    func testTheSweepFollowsTheWordsAndEndsWithTheUtterance() {
        let fake = FakeSynthesizer()
        let speaker = TranslationSpeaker(synthesizer: fake)
        speaker.speak("Где ближайшая станция?", languageCode: "ru")
        XCTAssertEqual(speaker.spokenEnd, 0)
        fake.say(NSRange(location: 0, length: 3))
        XCTAssertEqual(speaker.spokenEnd, 3)
        fake.say(NSRange(location: 4, length: 9))
        XCTAssertEqual(speaker.spokenEnd, 13)
        let split = TranslationSpeaker.split("Где ближайшая станция?", upTo: speaker.spokenEnd)
        XCTAssertEqual(split.spoken, "Где ближайшая")
        XCTAssertEqual(split.rest, " станция?")
        XCTAssertEqual(TranslationSpeaker.split("abc", upTo: 99).spoken, "abc", "clamped")
        XCTAssertEqual(TranslationSpeaker.split("abc", upTo: -4).rest, "abc", "clamped")
        XCTAssertEqual(TranslationSpeaker.split("a😀b", upTo: 2).spoken.count >= 1, true, "never inside a scalar")

        fake.finish()
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertEqual(speaker.spokenEnd, 0)
        fake.say(NSRange(location: 0, length: 2))
        XCTAssertEqual(speaker.spokenEnd, 0, "a word after the end is ignored")
    }

    func testNothingIsSpokenForEmptyText() {
        let fake = FakeSynthesizer()
        let speaker = TranslationSpeaker(synthesizer: fake)
        speaker.speak("", languageCode: "ru")
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertTrue(fake.spoken.isEmpty)
    }

    // MARK: - What ends it

    /// The text changing: an edit to the field, or a new answer, ends it.
    func testTheTextChangingStopsIt() {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.answer("Hello", "Привет")
        rig.translator.speaker.speak("Привет", languageCode: "ru")
        XCTAssertTrue(rig.translator.speaker.isSpeaking)
        rig.translator.input = "Hello!"
        XCTAssertFalse(rig.translator.speaker.isSpeaking, "an edit ends it")

        rig.answer("Hello", "Привет")
        rig.translator.speaker.speak("Привет", languageCode: "ru")
        rig.translator.received("Здравствуйте", for: "Hello", by: .system)
        XCTAssertFalse(rig.translator.speaker.isSpeaking, "a new answer ends it")

        rig.translator.speaker.speak("Здравствуйте", languageCode: "ru")
        rig.translator.reset()
        XCTAssertFalse(rig.translator.speaker.isSpeaking, "Clear ends it")
    }

    func testTheSameTextAgainDoesNotStopIt() {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.answer("Hello", "Привет")
        rig.translator.speaker.speak("Привет", languageCode: "ru")
        rig.translator.input = "Hello"
        XCTAssertTrue(rig.translator.speaker.isSpeaking, "an editor writing back what it holds is not an edit")
    }

    private func model(_ rig: TranslateRig) throws -> NotchViewModel {
        NotchViewModel(
            geometry: try LabGeometry.make(),
            stores: NotchStores(translator: rig.translator, privacy: rig.privacy),
            defaults: rig.defaults
        )
    }

    /// The panel closing and the surface changing, from the view model: no view
    /// on screen to notice.
    func testClosingThePanelAndChangingSurfacesStopIt() throws {
        let rig = TranslateRig()
        defer { rig.release() }
        let vm = try model(rig)
        vm.open(.translate)
        rig.answer()
        vm.isOpen = true
        rig.translator.speaker.speak("Привет", languageCode: "ru")
        vm.isOpen = false
        XCTAssertFalse(rig.translator.speaker.isSpeaking, "the panel closing")

        vm.isOpen = true
        rig.translator.speaker.speak("Привет", languageCode: "ru")
        vm.open(.tray)
        XCTAssertFalse(rig.translator.speaker.isSpeaking, "the surface changing")
    }

    func testTurningSpeakButtonOffStopsIt() throws {
        let rig = TranslateRig()
        defer { rig.release() }
        let vm = try model(rig)
        rig.answer()
        rig.translator.speaker.speak("Привет", languageCode: "ru")
        vm.setTranslateSpeakButton(true)
        XCTAssertTrue(rig.translator.speaker.isSpeaking, "turning it on touches nothing")
        vm.setTranslateSpeakButton(false)
        XCTAssertFalse(rig.translator.speaker.isSpeaking)
    }

    // MARK: - The button

    private func tree(_ rig: TranslateRig) async -> AXNode {
        let pane = TranslatePane(translator: rig.translator, privacy: rig.privacy, wantsKeyboard: .constant(false))
            .background(Color.black)
        return await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
    }

    /// Present with an answer and the setting on (the default); a press reads
    /// the answer in the target's voice and turns the button into Stop Speaking.
    func testSpeakIsOnTheAnswerAndPressingItSpeaks() async {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.translator.choose(target: .russian)
        rig.answer("Hello", "Привет")
        let root = await tree(rig)
        let speak = root.first(label: "Speak")
        XCTAssertNotNil(speak, root.dump)
        XCTAssertTrue(speak?.enabled ?? false, root.dump)
        XCTAssertTrue(speak?.press() ?? false)
        XCTAssertEqual(rig.synthesizer.spoken.first?.text, "Привет")
        XCTAssertEqual(rig.synthesizer.spoken.first?.language, "ru")
        let speaking = await root.reread()
        XCTAssertNotNil(speaking.first(label: "Stop Speaking"), speaking.dump)
        XCTAssertNil(speaking.first(label: "Speak"), speaking.dump)
    }

    /// Hidden entirely when Speak Button is off: nothing to press and nothing
    /// to hear about.
    func testSpeakIsAbsentWhenTheSettingIsOff() async {
        let rig = TranslateRig(speakButton: false)
        defer { rig.release() }
        rig.answer()
        let root = await tree(rig)
        XCTAssertNil(root.first(label: "Speak"), root.dump)
        XCTAssertNil(root.first(label: "Stop Speaking"), root.dump)
        XCTAssertNotNil(root.first(label: "Copy Translation"), "Copy stays\n\(root.dump)")
        XCTAssertTrue(rig.synthesizer.spoken.isEmpty)
    }

    func testSpeakIsAbsentBeforeThereIsAnAnswer() async {
        let rig = TranslateRig()
        defer { rig.release() }
        let root = await tree(rig)
        XCTAssertNil(root.first(label: "Speak"), root.dump)
    }

    /// A language this Mac has no voice for is not read in the wrong one: the
    /// button is there and dimmed.
    func testALanguageWithNoVoiceCannotBeSpoken() async {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.synthesizer.voices = ["ru"]
        rig.translator.choose(target: .uzbek)
        rig.answer("Hello", "Salom")
        let root = await tree(rig)
        XCTAssertFalse(root.first(label: "Speak")?.enabled ?? true, root.dump)
    }

    /// Under the cover the answer is dust, and reading it aloud would be showing
    /// it: no Speak.
    func testSpeakIsAbsentWhileCovered() async {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.privacy.setCovering(.translate, true)
        rig.answer("secret", "секрет")
        let root = await tree(rig)
        XCTAssertNil(root.first(label: "Speak"), root.dump)
        XCTAssertNotNil(root.first(label: "Hidden"), root.dump)
    }

    /// The swap, a new target and Clear all drop the answer, and with it the voice.
    func testChangingTheLanguageStopsIt() {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.answer("Hello", "Привет")
        rig.translator.speaker.speak("Привет", languageCode: "ru")
        rig.translator.choose(target: .german)
        XCTAssertFalse(rig.translator.speaker.isSpeaking)
    }
}
