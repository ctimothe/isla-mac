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
    /// Reads the list of installed voices again, off the main actor, and calls
    /// `done` on it when the new list is in place. Asked when the panel opens;
    /// `canSpeak` only ever consults the list that was last loaded, because it is
    /// asked from the footer's `body` and must cost nothing.
    func refreshVoices(then done: @escaping SpeechFinishHandler)
}

extension SpeechSynthesizing {
    /// An engine with no list to load has nothing to refresh.
    func refreshVoices(then done: @escaping SpeechFinishHandler) { done() }
}

/// Which installed voice reads a language (spec §11), as a pure function over
/// the voices' language tags and qualities so it is tested without a speech
/// engine.
///
/// The tab's codes are bases ("ru"), scripts ("zh-Hans") or, for the menu's
/// regional rows, a region ("pt-BR"); a voice's language is a BCP-47 tag with a
/// region ("zh-CN", "pt-PT"). The old match took everything with the same
/// two-letter base, so Simplified Chinese was read by whichever of zh-HK, zh-TW
/// or zh-CN scored highest (a Cantonese voice among them) and Brazilian
/// Portuguese by a European one. It now goes by tiers, and the best voice of the
/// first tier that has one wins:
///
/// 1. the same tag ("pt-BR" for "pt-BR", "zh-Hans" for a voice that says so);
/// 2. the same language and script — Simplified is zh-CN or zh-SG, Traditional
///    zh-TW first, then zh-HK or zh-MO;
/// 3. the same language with no region or script to disagree about ("pt" for
///    pt-BR or pt-PT; "pt-BR" for a Mac that only has pt-PT), never across a
///    script that is known on both sides.
///
/// No tier has one: the language cannot be spoken here, and the button is off —
/// the system would read it in its own voice, which is a mispronunciation.
enum VoiceMatch {
    struct Tag: Equatable {
        var language: String
        var script: String?
        var region: String?

        init(_ text: String) {
            let parts = text.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            language = (parts.first ?? "").lowercased()
            for part in parts.dropFirst() {
                if part.count == 4, part.allSatisfy(\.isLetter) {
                    script = part.lowercased()
                } else if part.count == 2 || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                    region = part.uppercased()
                }
            }
        }

        /// The script written out, or the one a Chinese region implies.
        var effectiveScript: String? {
            if let script { return script }
            guard language == "zh", let region else { return nil }
            switch region {
            case "CN", "SG": return "hans"
            case "TW", "HK", "MO": return "hant"
            default: return nil
            }
        }
    }

    /// Where a script reads best when several regions share it.
    private static let preferredRegion: [String: String] = ["hans": "CN", "hant": "TW"]

    /// The index of the voice to use, or nil when none speaks the language.
    static func best(for code: String, among voices: [(language: String, quality: Int)]) -> Int? {
        let wanted = Tag(code)
        guard !wanted.language.isEmpty else { return nil }
        let tags = voices.map { Tag($0.language) }
        let sameLanguage = voices.indices.filter { tags[$0].language == wanted.language }
        let tiers: [[Int]] = [
            sameLanguage.filter { tags[$0] == wanted },
            sameLanguage.filter {
                guard let script = wanted.effectiveScript else { return false }
                return tags[$0].effectiveScript == script
            },
            sameLanguage.filter {
                guard let a = wanted.effectiveScript, let b = tags[$0].effectiveScript else { return true }
                return a == b
            },
        ]
        for tier in tiers where !tier.isEmpty {
            var winner = tier[0]
            for index in tier.dropFirst() where outranks(index, winner, voices: voices, tags: tags, wanted: wanted) {
                winner = index
            }
            return winner
        }
        return nil
    }

    private static func outranks(
        _ a: Int, _ b: Int, voices: [(language: String, quality: Int)], tags: [Tag], wanted: Tag
    ) -> Bool {
        let preferred = wanted.effectiveScript.flatMap { preferredRegion[$0] }
        let aPreferred = tags[a].region == preferred && preferred != nil
        let bPreferred = tags[b].region == preferred && preferred != nil
        if aPreferred != bPreferred { return aPreferred }
        return voices[a].quality > voices[b].quality
    }
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
    /// Moves each time the voice list is reloaded, so the Speak button — whose
    /// enabled state is read from a `body` — is drawn again with the new list.
    @Published private(set) var voicesVersion = 0

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

    /// Reloads the installed voices, off the main actor: when the panel opens
    /// and when the Translate tab appears, so a voice installed (or removed) in
    /// System Settings is noticed without a relaunch. It used to be read inside
    /// the footer's `body` and remembered per language for the life of the app.
    func refreshVoices() {
        engine.refreshVoices { [weak self] in self?.voicesVersion += 1 }
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
    /// The installed voices as plain values, loaded by `refreshVoices` and read by
    /// `canSpeak` from the footer's body. Nil until the first load; a Mac whose
    /// panel has not opened yet speaks nothing, which is also true.
    private var catalog: [SpeechVoice]?
    private var matches: [String: SpeechVoice?] = [:]
    private var loading = false

    private struct SpeechVoice: Sendable {
        var identifier: String
        var language: String
        var quality: Int
    }

    func refreshVoices(then done: @escaping SpeechFinishHandler) {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let voices = AVSpeechSynthesisVoice.speechVoices().map {
                SpeechVoice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.catalog = voices
                self.matches = [:]
                self.loading = false
                done()
            }
        }
    }

    /// The voice for a language code (`VoiceMatch`), remembered until the list
    /// is reloaded. Never loads the list itself: it is asked from a `body`.
    private func voice(for code: String) -> SpeechVoice? {
        if let known = matches[code] { return known }
        guard let catalog else { return nil }
        let found = VoiceMatch.best(for: code, among: catalog.map { ($0.language, $0.quality) }).map { catalog[$0] }
        matches[code] = found
        return found
    }

    func canSpeak(languageCode: String) -> Bool {
        voice(for: languageCode) != nil
    }

    func speak(_ text: String, languageCode: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: languageCode).flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
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
