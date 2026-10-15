import AppKit
import XCTest
@testable import IslaKit

/// A speech engine that records what it was asked and says nothing, so no test
/// of the Translate tab ever speaks (redesign 2026-10-15, spec §11). The test
/// drives the engine's two callbacks by hand: `say(_:)` is the word the voice has
/// reached, `finish()` is the utterance ending on its own.
@MainActor
final class FakeSynthesizer: SpeechSynthesizing {
    var onSpeakingWord: SpeechWordHandler?
    var onFinished: SpeechFinishHandler?
    /// Languages this fake has a voice for; nil is every language.
    var voices: Set<String>?
    private(set) var spoken: [(text: String, language: String)] = []
    private(set) var stopCount = 0
    private(set) var refreshCount = 0

    func canSpeak(languageCode: String) -> Bool { voices?.contains(languageCode) ?? true }

    func speak(_ text: String, languageCode: String) {
        spoken.append((text, languageCode))
    }

    func stop() { stopCount += 1 }

    func refreshVoices(then done: @escaping SpeechFinishHandler) {
        refreshCount += 1
        done()
    }

    /// The voice reaches a word: `range` is into the text that was spoken.
    func say(_ range: NSRange) { onSpeakingWord?(range) }
    func finish() { onFinished?() }
}

/// A lazy pasteboard item that counts every time the pasteboard asks it for
/// bytes. On a real pasteboard that is a content read — the thing macOS's
/// "Paste from Other Apps" alert is raised for — so the count is the number of
/// alerts a person under Ask would have seen (the same device as
/// `ClipboardStoreTests`' provider, which is private to that file).
final class CountingTextProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var calls = 0
    private let text: String

    init(text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        calls += 1
        item.setString(text, forType: type)
    }
}

/// A translator on a private defaults suite, a private pasteboard and a fake
/// voice: nothing of the owner's is read or written, nothing is spoken, and no
/// language is downloaded or sent anywhere.
@MainActor
final class TranslateRig {
    let suiteName = "TranslateRig.\(UUID().uuidString)"
    let defaults: UserDefaults
    let synthesizer = FakeSynthesizer()
    let history: TranslationHistory
    let translator: Translator
    let pasteboard: NSPasteboard
    let privacy: PrivacyMode

    init(keepHistory: Bool = false, speakButton: Bool = true, now: @escaping () -> Date = { Date() }) {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(keepHistory, forKey: NotchViewModel.translateKeepHistoryKey)
        defaults.set(speakButton, forKey: NotchViewModel.translateSpeakButtonKey)
        history = TranslationHistory(now: now)
        translator = Translator(
            defaults: defaults, preferredLanguages: ["en"], history: history,
            speaker: TranslationSpeaker(synthesizer: synthesizer)
        )
        translator.capabilitiesOverride = { _ in Translator.Capabilities() }
        translator.allowanceSpent = { false }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("TranslateRig.\(UUID().uuidString)"))
        translator.pasteboard = pasteboard
        privacy = PrivacyMode(defaults: defaults)
    }

    func release() {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeSuite(named: suiteName)
    }

    /// An answer on screen for `text`, as an engine would have left it.
    func answer(_ text: String = "Hello", _ translated: String = "Привет", by engine: Translator.Engine = .system) {
        translator.input = text
        translator.received(translated, for: text, by: engine)
    }
}
