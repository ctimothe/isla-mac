import AVFoundation
import Foundation

/// What the Speak button needs of a speech engine, and nothing more, so a test
/// stands a fake in and never speaks (redesign 2026-10-15, spec §11).
///
/// The two callbacks are what the engine reports about the utterance it is
/// reading: the word it is about to say (`NSRange` into the text it was given,
/// UTF-16 units, as `AVSpeechSynthesizerDelegate` gives it) and that it has
/// stopped, for any reason. Both arrive on the main actor.
typealias SpeechWordHandler = @MainActor (NSRange) -> Void
typealias SpeechFinishHandler = @MainActor () -> Void

@MainActor
protocol SpeechSynthesizing: AnyObject {
    var onSpeakingWord: SpeechWordHandler? { get set }
    var onFinished: SpeechFinishHandler? { get set }
    /// Whether this Mac has a voice for the language. A language with none —
    /// Uzbek, Kazakh — would be read in the system's own voice, which is a
    /// mispronunciation and not a translation read aloud.
    func canSpeak(languageCode: String) -> Bool
    func speak(_ text: String, languageCode: String)
    func stop()
}

/// Reads the translation aloud and says which words are being read.
///
/// One speaker per `Translator`. The pane draws from `isSpeaking` and
/// `spokenEnd`; everything that ends speech — the panel closing, the tab
/// changing, the text changing, Speak Button turned off — calls `stop()`, the
/// one door, so no path can leave a voice running over a pane that is gone.
@MainActor
final class TranslationSpeaker: ObservableObject {
    @Published private(set) var isSpeaking = false
    /// The UTF-16 offset where the word being said ends: the sweep's edge. 0
    /// before the first word.
    @Published private(set) var spokenEnd = 0
    /// What is being read, so the pane can tell a sweep that belongs to the text
    /// on screen from a stale one.
    private(set) var text: String?

    private var synthesizer: SpeechSynthesizing?
    private let makeSynthesizer: () -> SpeechSynthesizing

    /// The real engine is built the first time something is spoken, never at
    /// launch and never under test: constructing a Translator must not touch
    /// speech.
    init(synthesizer: SpeechSynthesizing? = nil) {
        self.synthesizer = synthesizer
        makeSynthesizer = { SystemSpeechSynthesizer() }
    }

    private var engine: SpeechSynthesizing {
        if let synthesizer { return synthesizer }
        let made = makeSynthesizer()
        synthesizer = made
        wire(made)
        return made
    }

    private func wire(_ engine: SpeechSynthesizing) {
        engine.onSpeakingWord = { [weak self] range in
            guard let self, self.isSpeaking else { return }
            self.spokenEnd = NSMaxRange(range)
        }
        engine.onFinished = { [weak self] in self?.finished() }
    }

    func canSpeak(languageCode: String) -> Bool {
        engine.canSpeak(languageCode: languageCode)
    }

    /// The button's press: starts reading, or stops if already reading.
    func toggle(_ text: String, languageCode: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text, languageCode: languageCode)
        }
    }

    func speak(_ text: String, languageCode: String) {
        guard !text.isEmpty else { return }
        let engine = engine
        // Wired on every start, not only when made: an injected synthesizer is
        // already in hand and has had no callbacks given it.
        wire(engine)
        self.text = text
        spokenEnd = 0
        isSpeaking = true
        engine.speak(text, languageCode: languageCode)
    }

    /// Ends speech at once and puts the sweep away. Safe to call when nothing
    /// is being said, which is most of the time: it is called from every
    /// `didSet` that a stale voice could outlive.
    func stop() {
        guard isSpeaking else { return }
        isSpeaking = false
        spokenEnd = 0
        text = nil
        synthesizer?.stop()
    }

    private func finished() {
        guard isSpeaking else { return }
        isSpeaking = false
        spokenEnd = 0
        text = nil
    }

    /// The text split at the end of the word being said: what has been spoken
    /// is lit, the rest waits dim (spec §11 "the spoken words sweep like a
    /// lyric"). The offset is clamped, and moved off the middle of a character,
    /// so a late or odd range from the engine can never crash the pane.
    static func split(_ text: String, upTo utf16End: Int) -> (spoken: String, rest: String) {
        let units = text.utf16
        let end = units.index(units.startIndex, offsetBy: min(max(utf16End, 0), units.count))
        // An offset inside a surrogate pair rounds down to its scalar when it
        // is used to slice, so the split can fall between characters of a
        // cluster but never inside a scalar.
        return (String(text[..<end]), String(text[end...]))
    }
}

/// The real engine: `AVSpeechSynthesizer`, in the voice of the target language.
@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    var onSpeakingWord: SpeechWordHandler?
    var onFinished: SpeechFinishHandler?

    /// Built on the first utterance, not with this object.
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let made = AVSpeechSynthesizer()
        made.delegate = self
        return made
    }()
    /// Callbacks for an utterance that was stopped arrive after the next one has
    /// begun; only the current utterance's are believed.
    private var current: AVSpeechUtterance?
    private var voices: [String: AVSpeechSynthesisVoice?] = [:]

    /// The best voice installed for a language, by its two-letter base: the
    /// framework matches full tags ("ru-RU"), and the tab's codes are bases or
    /// scripts ("zh-Hans"). Remembered, since the body asks on every render.
    private func voice(for code: String) -> AVSpeechSynthesisVoice? {
        if let known = voices[code] { return known }
        let base = String(code.prefix { $0 != "-" }).lowercased()
        let found = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(base + "-") || $0.language.lowercased() == base }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        voices[code] = found
        return found
    }

    func canSpeak(languageCode: String) -> Bool {
        voice(for: languageCode) != nil
    }

    func speak(_ text: String, languageCode: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: languageCode)
        current = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.onSpeakingWord?(characterRange)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance) }
    }

    private func ended(_ utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        onFinished?()
    }
}
