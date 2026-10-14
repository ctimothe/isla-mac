import Foundation
import Translation

/// A translated line under each lyric line (spec §5.3, owner decision 11).
///
/// **One batch, once, kept.** When Translate Lyrics is on, the whole timeline
/// of the song on screen is translated in a single batch through the engines
/// the Translate tab already uses, and the answer is kept in memory for the
/// session under the timeline's identity and the target — so showing it again,
/// or choosing a language already done, is a lookup and not a second batch.
/// The rows appear together, never one by one: nothing is published until the
/// batch is whole.
///
/// **Only while it is shown.** A batch starts only while a surface that draws
/// translations is on screen (`setDemand`: the lyric column or tall page now,
/// the lock card in R2) *and* Show Translation is on. Before this a batch ran
/// for every song the moment its lyrics arrived — panel closed, translations
/// hidden — and below macOS 26, where neither on-device engine exists, with
/// Translate Online on that meant a request per line of every song played
/// against MyMemory's 5,000 characters a day (review 2026-10-15). Closing the
/// panel, hiding translations or switching Translate Lyrics off cancels the
/// batch in flight. A song's distinct lines are each sent once, whatever the
/// engine: a chorus sung four times is one request, its answer laid under all
/// four.
///
/// **Consent is part of the question.** What the Translate Online switch says
/// is read with the song and the language: turning it off cancels an online
/// batch before its next line goes out, and turning it on asks again about a
/// song that had no engine a moment ago.
///
/// **No second policy.** Which engines may run for a pair is
/// `Translator.deviceCapabilities` and `Translator.engines(given:)`, the very
/// functions the Translate tab runs on: Apple's Translation framework for an
/// installed pair, the on-device model for the languages it handles, and
/// MyMemory only when Translate Online is on *and* nothing on this Mac offers
/// the pair — never as the next try after an on-device engine failed. A lyric
/// is text a person did not type, so that last rule matters more here than
/// anywhere: nothing about a song leaves the Mac unless the person already
/// said, in Settings, that text may.
///
/// **One failure surface.** A batch that cannot run — no engine for the pair,
/// the model off, the service unreachable — leaves the lines as they were,
/// untranslated and unmarked. No toast, no banner: the Translate tab is where
/// translation errors are explained, and a column of lyrics is no place for one.
/// A failure is not cached, so a later change of song or language tries again.
/// An online batch cut short — a line failed, the per-song budget or the day's
/// allowance (`OnlineAllowance`) ran out — is shown for what it has but is
/// **not cached**: the lines it answered are kept apart, and the next time the
/// song is presented only the lines still missing are sent.
///
/// **What the lock card needs (R2).** `translation(atLine:)` is the one read:
/// the translation row of a line of the timeline most recently presented. It is
/// the same answer the column draws, bilingual files included.
@MainActor
final class LyricTranslation: ObservableObject {
    // MARK: - Identity

    /// What a batch was made for: the words of every line, in order, and the
    /// language. The words and not the timestamps — a nudge moves every stamp
    /// and changes nothing that needs translating — and not a document id,
    /// because the catalogue's timelines have none.
    struct Key: Hashable, Sendable {
        let texts: [String]
        let target: String
    }

    /// A batch's answer, kept whole.
    struct Presented: Equatable {
        let key: Key
        /// One entry per line of the timeline, nil where a line has none:
        /// a credit, a line already in the target language, a bilingual line
        /// (its second row is its translation), or a line the engine did not
        /// answer.
        let rows: [String?]
        /// Which engine gave it. Nil when nothing was translated at all (the
        /// song is already in the target language).
        let engine: Translator.Engine?
    }

    // MARK: - The engines, as seams

    /// What a batch needs from outside, so a test runs the whole service with
    /// fakes and never reaches the network, a real model or the Translation
    /// framework.
    struct Backend {
        /// What this Mac can do for the pair: `Translator.Capabilities`, whose
        /// `onlineEnabled` is how the Translate Online switch reaches the batch.
        var capabilities: @MainActor (Translator.Route) async -> Translator.Capabilities
        /// Apple's Translation framework, one batch. One answer per question,
        /// in order.
        var system: @MainActor ([String], Translator.Route) async throws -> [String?]
        /// The on-device language model.
        var model: @MainActor ([String], Translator.Route) async throws -> [String?]
        /// MyMemory, **one line**: the service owns the loop, so it can stop
        /// between lines when the person withdraws consent, the panel closes or
        /// the allowance is spent.
        var online: @MainActor (String, Translator.Route) async throws -> String
        /// The language a piece of text is in, for the song as a whole and for
        /// each line.
        var detect: @MainActor (String) -> TranslationLanguage
        /// Translate Online as Settings has it *right now*: asked before every
        /// online line and when a song is evaluated.
        var onlineEnabled: @MainActor () -> Bool = { true }
        /// Whether the service's allowance still has room (`OnlineAllowance`).
        var onlineAvailable: @MainActor () -> Bool = { true }

        /// The app's own engines. `onlineEnabled` is read when the batch
        /// runs, not when the service is built: the switch moves while the app
        /// runs.
        static func live(defaults: UserDefaults = .standard) -> Backend {
            Backend(
                capabilities: { route in
                    await Translator.deviceCapabilities(
                        for: route, onlineEnabled: defaults.bool(forKey: NotchViewModel.onlineTranslationKey)
                    )
                },
                system: { texts, route in
                    guard #available(macOS 26.0, *) else { throw Failure.unavailable }
                    return try await LyricTranslation.systemBatch(texts, route: route)
                },
                model: { texts, route in
                    guard #available(macOS 26.0, *) else { throw Failure.unavailable }
                    return try await LyricTranslation.modelBatch(texts, route: route)
                },
                online: { text, route in
                    try await OnlineTranslation.translate(text, from: route.source, to: route.target).text
                },
                detect: { LanguageDetection.language(of: $0) },
                onlineEnabled: { defaults.bool(forKey: NotchViewModel.onlineTranslationKey) },
                onlineAvailable: { !OnlineAllowance.shared.isExhausted }
            )
        }

        /// Nothing can translate: the stand-in for a surface with no session
        /// behind it.
        static let inert = Backend(
            capabilities: { _ in Translator.Capabilities() },
            system: { _, _ in [] }, model: { _, _ in [] }, online: { _, _ in "" },
            detect: { LanguageDetection.language(of: $0) },
            onlineEnabled: { false }, onlineAvailable: { false }
        )
    }

    enum Failure: Error {
        case unavailable
        case nothingTranslated
    }

    // MARK: - State

    /// The answer for the timeline and language on screen, once it is whole.
    @Published private(set) var presented: Presented?

    /// Translate Lyrics, as Settings has it. Published so a switch flipped
    /// while the column is up redraws it; read from the defaults on every
    /// `refresh()`.
    @Published private(set) var isEnabled: Bool

    /// Translate To, as Settings has it.
    @Published private(set) var target: TranslationLanguage

    /// The header's Show Translation. Persisted: someone who hid the
    /// translations did not mean to see them again at the next launch.
    @Published private(set) var isShown: Bool

    /// The most recent targets, newest first, for the translation menu.
    @Published private(set) var recents: [TranslationLanguage]

    private let defaults: UserDefaults
    private let backend: Backend
    private let preferredLanguages: [String]
    private var lines: [LyricsStore.Line]?

    /// What a batch is asked: the words, the language, and whether the person
    /// allows the one engine that leaves the Mac. Consent is part of the
    /// question, so withdrawing it ends the batch and granting it asks again
    /// about a song that had no engine a moment ago (review 2026-10-15, Codex
    /// P1).
    private struct Evaluation: Equatable {
        let key: Key
        let online: Bool
    }

    /// The evaluation the service last settled on: in flight, answered, or
    /// failed. Evaluating again with the same one is a no-op, so a lyrics
    /// recheck or an unrelated defaults write never starts a second batch, and a
    /// failed batch is not retried in a loop.
    private var evaluated: Evaluation?
    /// True only once a batch ended with part of an online answer. The next
    /// `present(lines:)` or change of demand may then go again for the lines
    /// still missing; an unrelated defaults write may not.
    private var retryable = false
    /// The online lines that did come back for a batch that ended short, by
    /// the text sent, so the retry sends only what is missing and a song's
    /// share of the day's allowance is spent once.
    private var onlineKept: [Key: [String: String]] = [:]
    private var cache: [Key: Presented] = [:]
    /// Insertion order of `cache`, oldest first, so it can be capped.
    private var cacheOrder: [Key] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var observer: NSObjectProtocol?
    /// The song's language, from all of its sung lines, kept for the lines it
    /// was read from.
    private var songLanguageCache: (texts: [String], language: TranslationLanguage)?

    /// The surfaces that draw translations and are on screen right now.
    enum Surface: Hashable {
        /// The lyric column and the tall page (`LyricsStage`).
        case lyricArea
        /// The lock card's sung-line translation (R2 adds itself here).
        case lockCard
    }
    /// Counted, not a set: SwiftUI may bring a new stage on screen (the column
    /// becoming the tall page) before the old one's `onDisappear` has run, and
    /// a set would read that as the surface going.
    private var demand: [Surface: Int] = [:]

    /// Whether any surface that draws translations is on screen: what a batch
    /// waits for. Not published — nothing draws differently for it, and the
    /// views that set it must not redraw because they did.
    var isPresentedSomewhere: Bool { !demand.isEmpty }

    /// A session of songs is a few hundred at most and a batch is a few kilobytes;
    /// the cap keeps a week of idle listening from being a leak.
    nonisolated static let cacheLimit = 64

    /// How many recent targets the menu offers (spec §5.2).
    nonisolated static let recentLimit = 5

    init(
        defaults: UserDefaults = .standard,
        backend: Backend? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults
        self.backend = backend ?? .live(defaults: defaults)
        self.preferredLanguages = preferredLanguages
        isEnabled = NotchViewModel.translateLyricsEnabled(in: defaults)
        target = NotchViewModel.translateTarget(in: defaults, preferredLanguages: preferredLanguages)
        isShown = NotchViewModel.showTranslationEnabled(in: defaults)
        recents = Self.recentTargets(in: defaults)
        // Settings writes the defaults directly, like every other row there; this
        // is how the column hears of it.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The stand-in a lyric surface is built with when nothing hands it the
    /// session's service: it never translates. Shared, so a stage built for a
    /// test or a render does not make an object per body pass.
    static let idle = LyricTranslation(defaults: .standard, backend: .inert)

    // MARK: - Driving it

    /// The song on screen: its lines, or nil when there are none (looking, off,
    /// not found). Called whenever the lyrics store changes state, with the same
    /// lines again on every recheck of one song — which is why nothing starts
    /// unless the evaluation moved. A batch that ended short is the one
    /// exception: presenting the song again goes for its missing lines.
    func present(lines: [LyricsStore.Line]?) {
        self.lines = lines
        evaluate(retrying: true)
    }

    /// A surface that draws translations came on screen or went. A batch runs
    /// only while at least one is up (see the type's comment); the lock card
    /// adds itself here in R2.
    ///
    /// `epoch` is the `demandEpoch` the registration was made under. A lowering
    /// that names an older epoch is ignored: `resetDemand` already dropped it,
    /// and a late `onDisappear` from a discarded view must not take away the
    /// rebuilt panel's own registration. Nil means "now" (tests, raising).
    func setDemand(_ surface: Surface, _ on: Bool, epoch: Int? = nil) {
        if !on, let epoch, epoch != demandEpoch { return }
        let before = isPresentedSomewhere
        if on {
            demand[surface, default: 0] += 1
        } else if let count = demand[surface] {
            demand[surface] = count > 1 ? count - 1 : nil
        }
        if before != isPresentedSomewhere { evaluate(retrying: true) }
    }

    /// Bumped by every `resetDemand`; the registration token of `setDemand`.
    private(set) var demandEpoch = 0

    /// Forgets every registration. The controller calls it when it drops the
    /// panel's content (`rebuild()`, `teardown()`): demand is a counter on a
    /// session store, lowered by a view's `onDisappear`, and AppKit hosting
    /// does not promise that call when a content view is discarded. A column
    /// open through a display change raised it again on the rebuild while the
    /// old view's lowering never came, so the count stuck above zero and every
    /// song's lyrics were translated, online too, with the panel closed (review
    /// 2026-10-15). Views registered afterwards carry the new epoch.
    func resetDemand() {
        demandEpoch += 1
        guard !demand.isEmpty else { return }
        demand.removeAll()
        evaluate()
    }

    /// Reads Settings again. Cheap and idempotent: it runs on every write to
    /// the defaults domain, and changes only what actually changed.
    func refresh() {
        let enabled = NotchViewModel.translateLyricsEnabled(in: defaults)
        let shown = NotchViewModel.showTranslationEnabled(in: defaults)
        let recents = Self.recentTargets(in: defaults)
        if isEnabled != enabled { isEnabled = enabled }
        if isShown != shown { isShown = shown }
        if self.recents != recents { self.recents = recents }
        evaluate()
    }

    /// Choosing a language, from the menu. Settings does the same through
    /// `record(target:in:)`.
    func choose(target: TranslationLanguage) {
        Self.record(target: target, in: defaults)
        refresh()
    }

    func setShown(_ shown: Bool) {
        defaults.set(shown, forKey: NotchViewModel.showTranslationKey)
        refresh()
    }

    func toggleShown() { setShown(!isShown) }

    /// Writes the choice and moves it to the front of the recents. A function
    /// of the defaults alone so Settings, which has no service in hand, makes
    /// the same record.
    static func record(target: TranslationLanguage, in defaults: UserDefaults) {
        defaults.set(target.code, forKey: NotchViewModel.translateTargetKey)
        let codes = ([target] + recentTargets(in: defaults)).map(\.code)
        var seen = Set<String>()
        let unique = codes.filter { seen.insert($0).inserted }
        defaults.set(Array(unique.prefix(recentLimit)), forKey: NotchViewModel.translateRecentsKey)
    }

    /// One row of Settings' Translate To pop-up: Automatic first, then the
    /// languages. Settings used to list only languages and show the system
    /// language as if it were chosen, while the service sent a song already in
    /// that language to English, so the two disagreed about the same default
    /// (review 2026-10-15). Automatic is "nothing stored" and means spec §5.3:
    /// the system language, or English when the song is in it.
    enum TargetChoice: Hashable, Identifiable {
        case automatic
        case language(TranslationLanguage)

        var id: String {
            switch self {
            case .automatic: return "automatic"
            case .language(let language): return language.code
            }
        }

        /// The pop-up's items in order; `separatorAfter` is the first one.
        static var all: [TargetChoice] { [.automatic] + TranslationLanguage.all.map(TargetChoice.language) }
        static func separatorAfter(_ choice: TargetChoice) -> Bool { choice == .automatic }

        /// What the defaults say right now: Automatic unless a language is stored.
        @MainActor static func current(in defaults: UserDefaults) -> TargetChoice {
            NotchViewModel.storedTranslateTarget(in: defaults).map(TargetChoice.language) ?? .automatic
        }

        /// A language is stored (and joins the recents); Automatic removes the
        /// stored value.
        @MainActor func apply(to defaults: UserDefaults) {
            switch self {
            case .automatic: defaults.removeObject(forKey: NotchViewModel.translateTargetKey)
            case .language(let language): LyricTranslation.record(target: language, in: defaults)
            }
        }
    }

    static func recentTargets(in defaults: UserDefaults) -> [TranslationLanguage] {
        (defaults.stringArray(forKey: NotchViewModel.translateRecentsKey) ?? [])
            .compactMap(TranslationLanguage.withCode)
    }

    /// The language lyrics go into: what was chosen, else the system's unless the
    /// song is in it, then English (spec §5.3). The song is looked at only when
    /// nothing was chosen.
    private func resolvedTarget() -> TranslationLanguage {
        let song = NotchViewModel.storedTranslateTarget(in: defaults) == nil ? songLanguage() : nil
        return NotchViewModel.translateTarget(
            in: defaults, preferredLanguages: preferredLanguages, songLanguage: song
        )
    }

    /// The language of the song on screen, read once for its sung lines.
    private func songLanguage() -> TranslationLanguage? {
        guard let lines else { return nil }
        let sung = lines.filter(Self.isTranslatable).map(\.text)
        guard !sung.isEmpty else { return nil }
        if let known = songLanguageCache, known.texts == sung { return known.language }
        // The song's language, from all of it: a line is too little for the
        // recognizer, and a Russian song with an English chorus is still a
        // Russian song to translate from.
        let language = backend.detect(sung.joined(separator: "\n"))
        songLanguageCache = (sung, language)
        return language
    }

    /// Ends whatever is in flight and forgets that it was asked, so the next
    /// time something wants translations the question is asked afresh.
    private func stop() {
        generation += 1
        task?.cancel()
        task = nil
        evaluated = nil
        retryable = false
    }

    private func evaluate(retrying: Bool = false) {
        guard isEnabled, let lines, !lines.isEmpty else {
            stop()
            if presented != nil { presented = nil }
            let resolved = resolvedTarget()
            if target != resolved { target = resolved }
            return
        }
        let resolved = resolvedTarget()
        if target != resolved { target = resolved }
        // Nothing draws a translation, so nothing is asked for one: no panel,
        // or translations hidden. What was answered stays, hidden or not on
        // screen, for the next time.
        guard isShown, isPresentedSomewhere else {
            stop()
            return
        }
        let key = Key(texts: lines.map(\.text), target: target.code)
        let evaluation = Evaluation(key: key, online: backend.onlineEnabled())
        let again = evaluation == evaluated
        guard !again || (retrying && retryable) else { return }
        evaluated = evaluation
        retryable = false
        generation += 1
        task?.cancel()
        task = nil
        // The previous answer is for another song or another language. It is
        // dropped at once, rather than left under lines it does not belong to
        // for the length of a batch. (A retry keeps the part it has: those rows
        // are still right.)
        if let hit = cache[key] {
            presented = hit
            return
        }
        if !again, presented != nil { presented = nil }
        let generation = generation
        let target = target
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.translate(lines: lines, key: key, target: target)
            guard !Task.isCancelled, self.generation == generation, let outcome else { return }
            if outcome.complete {
                self.onlineKept[key] = nil
                self.store(outcome.presented)
            } else {
                self.retryable = true
            }
            self.presented = outcome.presented
        }
    }

    /// Returns once the batch in flight, if any, has landed or failed: how a test
    /// waits for the one answer without sleeping.
    func settled() async {
        await task?.value
    }

    private func store(_ answer: Presented) {
        if cache[answer.key] == nil { cacheOrder.append(answer.key) }
        cache[answer.key] = answer
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    // MARK: - The batch

    /// Whether a line is the machine's to translate: sung words, in one row. A
    /// credit is not a lyric; a line of two rows is a bilingual file's own
    /// translation, and a blank has nothing in it.
    nonisolated static func isTranslatable(_ line: LyricsStore.Line) -> Bool {
        !line.isCredit && !line.text.contains("\n")
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct Outcome {
        let presented: Presented
        /// False for an online answer that stopped short: shown, not kept.
        let complete: Bool
    }

    /// Nil when nothing could be done and nothing should be remembered (no
    /// engine for the pair, every engine failed, cancelled); an outcome with
    /// empty rows when the song is already in the target language, which is an
    /// answer and is kept.
    private func translate(lines: [LyricsStore.Line], key: Key, target: TranslationLanguage) async -> Outcome? {
        let indices = lines.indices.filter { Self.isTranslatable(lines[$0]) }
        let empty = Outcome(
            presented: Presented(key: key, rows: Array(repeating: nil, count: lines.count), engine: nil),
            complete: true
        )
        guard !indices.isEmpty, let song = songLanguage() else { return empty }
        guard song != target else { return empty }

        // A line already in the target language gets no row — the English
        // chorus of a song translated into English. Only the lines that
        // remain are sent, and each distinct text once: a chorus sung four
        // times is one question, its answer laid under all four.
        var languages: [String: TranslationLanguage] = [:]
        var positions: [String: [Int]] = [:]
        var texts: [String] = []
        for index in indices {
            let text = lines[index].text
            if languages[text] == nil { languages[text] = backend.detect(text) }
            guard languages[text] != target else { continue }
            if positions[text] == nil { texts.append(text) }
            positions[text, default: []].append(index)
        }
        guard !texts.isEmpty else { return empty }

        let route = Translator.Route(source: song, target: target)
        let capabilities = await backend.capabilities(route)
        guard !Task.isCancelled else { return nil }
        for engine in Translator.engines(given: capabilities) {
            do {
                var answers: [String: String] = [:]
                var complete = true
                switch engine {
                case .system, .intelligence:
                    let batch: [String?]
                    if engine == .system {
                        batch = try await backend.system(texts, route)
                    } else {
                        batch = try await backend.model(texts, route)
                    }
                    for (position, text) in texts.enumerated() where position < batch.count {
                        if let answer = batch[position] { answers[text] = answer }
                    }
                case .online:
                    // The switch is asked again here, not trusted from the
                    // capabilities a moment ago: it may have moved since, and
                    // this is the engine that sends the song away.
                    guard backend.onlineEnabled(), backend.onlineAvailable() else { continue }
                    (answers, complete) = try await askOnline(texts, key: key, route: route)
                }
                var rows = [String?](repeating: nil, count: lines.count)
                var any = false
                for (text, at) in positions {
                    if let row = Self.usable(answers[text], for: text) {
                        for index in at { rows[index] = row }
                        any = true
                    }
                }
                // An engine that answered nothing for any line did not answer.
                guard any else { throw Failure.nothingTranslated }
                return Outcome(presented: Presented(key: key, rows: rows, engine: engine), complete: complete)
            } catch is CancellationError {
                return nil
            } catch {
                // On to the next engine, as the Translate tab does; and past the
                // last one, silence.
                continue
            }
        }
        return nil
    }

    /// MyMemory, one distinct line at a time inside one batch's budget
    /// (`OnlineTranslation.maximumOnlineCharacters` — the day's allowance is
    /// about the same size, which is why nothing else is allowed to ask for a
    /// song twice). Stops, keeping what it has, the moment the person withdraws
    /// consent, the allowance is spent, the budget is, or the service cannot be
    /// reached (a line it merely refuses is skipped, remembered as untranslated); throws
    /// cancellation so a batch the panel no longer wants sends nothing more.
    private func askOnline(
        _ texts: [String], key: Key, route: Translator.Route
    ) async throws -> (answers: [String: String], complete: Bool) {
        var answers = onlineKept[key] ?? [:]
        // What an earlier, shorter try of this song already spent counts
        // against its budget.
        var budget = OnlineTranslation.maximumOnlineCharacters - answers.keys.reduce(0) { $0 + $1.count }
        defer {
            if onlineKept.count >= 8 { onlineKept.removeAll() }
            onlineKept[key] = answers
        }
        for text in texts where answers[text] == nil {
            try Task.checkCancellation()
            guard backend.onlineEnabled(), backend.onlineAvailable(), text.count <= budget else { break }
            budget -= text.count
            do {
                answers[text] = try await backend.online(text, route)
            } catch is CancellationError {
                throw CancellationError()
            } catch OnlineTranslation.Failure.refused {
                // The service answered, and declined this one text. That is a
                // fact about the line, not about the batch: it is recorded as
                // "no translation" for the session (blank, which `usable`
                // drops and `answers[text] != nil` counts as asked) and the
                // rest of the song goes on. It used to stop the batch, so one
                // line MyMemory always refuses starved every line after it
                // and was sent again on every reopen (review 2026-10-15).
                answers[text] = ""
            } catch {
                // The allowance, an unreachable service, anything unknown: the
                // batch ends, partial and uncached, as before.
                break
            }
        }
        return (answers, texts.allSatisfy { answers[$0] != nil })
    }

    /// A translation worth drawing: not blank, and not the line itself — a name
    /// or an interjection comes back unchanged and a second copy of it under the
    /// first is clutter.
    nonisolated static func usable(_ answer: String?, for source: String) -> String? {
        guard let trimmed = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let same = trimmed.compare(
            source.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
        return same ? nil : trimmed
    }

    // MARK: - Bilingual files (spec §5.3)

    /// The two rows of a bilingual LRC line, which the parser merged with a
    /// newline (`LocalLyricsDocument.parse`): the original and its translation.
    nonisolated static func rows(of text: String) -> (primary: String, secondary: String?) {
        guard let newline = text.firstIndex(of: "\n") else { return (text, nil) }
        let primary = String(text[..<newline])
        let rest = text[text.index(after: newline)...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (primary, rest.isEmpty ? nil : rest)
    }

    // MARK: - What a surface draws

    /// The row under each line, parallel to `lines`.
    ///
    /// A bilingual file's second row is drawn whatever Translate Lyrics says —
    /// it is the file's own words — unless the person has hidden translations
    /// with Translate Lyrics on, the one case where the header offers that
    /// choice. A machine translation is drawn only with Translate Lyrics on and
    /// Show Translation on, and only for the lines it was made for: an answer
    /// for another song or language is never laid under these. The file's own
    /// row wins over the machine's for a line that has both (a bilingual line is
    /// never sent, so it never does).
    func displayRows(for lines: [LyricsStore.Line]) -> [String?] {
        Self.displayRows(
            lines: lines, machine: presented, enabled: isEnabled, shown: isShown, target: target
        )
    }

    nonisolated static func displayRows(
        lines: [LyricsStore.Line], machine: Presented?, enabled: Bool, shown: Bool, target: TranslationLanguage
    ) -> [String?] {
        let hidden = enabled && !shown
        guard !hidden else { return Array(repeating: nil, count: lines.count) }
        let answer = enabled
            && machine?.key == Key(texts: lines.map(\.text), target: target.code) ? machine : nil
        return lines.indices.map { index in
            if let second = rows(of: lines[index].text).secondary { return second }
            return answer?.rows[index]
        }
    }

    nonisolated static func hasRows(_ rows: [String?]) -> Bool {
        rows.contains { $0 != nil }
    }

    /// Whether the lyric area draws a translation under any line of this state:
    /// what decides the taller pitch.
    func drawsTranslations(in state: LyricsStore.State) -> Bool {
        guard case .synced(let lines) = state else { return false }
        return Self.hasRows(displayRows(for: lines))
    }

    /// The translation row of line `index` of the timeline last presented — what
    /// the lock card shows under the sung line (R2). Nil when Translate Lyrics
    /// is off, translations are hidden, the line has none, or no timeline is
    /// presented. A read, never a request: it starts nothing.
    func translation(atLine index: Int) -> String? {
        guard let lines, lines.indices.contains(index) else { return nil }
        return displayRows(for: lines)[index]
    }

    /// What Settings says under Translate To: where the work is done, true for
    /// the state it is in. It used to say "Translated on this Mac" with
    /// Translate Online on, and below macOS 26 — where nothing is translated
    /// on this Mac — with it off (review 2026-10-15). With the switch on it is
    /// the Translate tab's own note (`Translator.onlineNote`, K-005).
    static func settingsNote(
        onlineEnabled: Bool, belowMinimumSystem: Bool = Translator.isBelowMinimumSystem
    ) -> String {
        if onlineEnabled { return Translator.onlineNote(belowMinimumSystem: belowMinimumSystem) }
        return belowMinimumSystem
            ? localized("Before macOS 26 this Mac cannot translate lyrics itself. Turn on Translate Online to translate them.")
            : localized("Translated on this Mac. Nothing is sent over the internet.")
    }

    /// Where the batch the column shows went: the menu's last row. Answers only
    /// for the timeline and language on screen now. `evaluate()` leaves
    /// `presented` standing while translations are hidden (so showing them again
    /// is free), which let Translate To move to a language nothing had run for
    /// and the menu still credit "Translated online" to it (Codex review
    /// 2026-10-15). The cached answer is not dropped, only not claimed: switch
    /// back and it is credited again.
    var engine: Translator.Engine? {
        guard let presented, let lines,
              presented.key == Key(texts: lines.map(\.text), target: target.code)
        else { return nil }
        return presented.engine
    }

    // MARK: - Live engines

    /// Apple's Translation framework for the whole song in one request. The
    /// session is made from an *installed* pair, as the Translate tab makes it,
    /// so nothing here can raise a download prompt. Answers are matched back by
    /// the client identifier rather than by order.
    @available(macOS 26.0, *)
    private static func systemBatch(_ texts: [String], route: Translator.Route) async throws -> [String?] {
        let session = TranslationSession(installedSource: route.source.locale, target: route.target.locale)
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $1, clientIdentifier: String($0))
        }
        let responses = try await session.translations(from: requests)
        var answers = [String?](repeating: nil, count: texts.count)
        for response in responses {
            if let identifier = response.clientIdentifier, let index = Int(identifier), answers.indices.contains(index) {
                answers[index] = response.targetText
            }
        }
        return answers
    }

    /// The on-device model, a line at a time inside the one batch: its guided
    /// generation takes one text, and a line it refuses (Apple's guardrail
    /// fires on ordinary sentences) must not cost the song its other lines.
    @available(macOS 26.0, *)
    private static func modelBatch(_ texts: [String], route: Translator.Route) async throws -> [String?] {
        var answers = [String?](repeating: nil, count: texts.count)
        for (index, text) in texts.enumerated() {
            try Task.checkCancellation()
            do {
                answers[index] = try await Translator.askModel(text, route: route)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                answers[index] = nil
            }
        }
        return answers
    }
}
