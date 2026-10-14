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

    /// The four things a batch needs from outside, so a test runs the whole
    /// service with fakes and never reaches the network, a real model or the
    /// Translation framework.
    struct Backend {
        /// What this Mac can do for the pair: `Translator.Capabilities`, whose
        /// `onlineEnabled` is how the Translate Online switch reaches the batch.
        var capabilities: @MainActor (Translator.Route) async -> Translator.Capabilities
        /// Apple's Translation framework, one batch. One answer per question,
        /// in order.
        var system: @MainActor ([String], Translator.Route) async throws -> [String?]
        /// The on-device language model.
        var model: @MainActor ([String], Translator.Route) async throws -> [String?]
        /// MyMemory. Nil where the allowance or a failure cut the batch short.
        var online: @MainActor ([String], Translator.Route) async throws -> [String?]
        /// The language a piece of text is in, for the song as a whole and for
        /// each line.
        var detect: @MainActor (String) -> TranslationLanguage

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
                online: { texts, route in try await LyricTranslation.onlineBatch(texts, route: route) },
                detect: { LanguageDetection.language(of: $0) }
            )
        }

        /// Nothing can translate: the stand-in for a surface with no session
        /// behind it.
        static let inert = Backend(
            capabilities: { _ in Translator.Capabilities() },
            system: { _, _ in [] }, model: { _, _ in [] }, online: { _, _ in [] },
            detect: { LanguageDetection.language(of: $0) }
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
    /// The key the service last settled on: in flight, answered, or failed.
    /// Evaluating again with the same key is a no-op, so a lyrics recheck or
    /// an unrelated defaults write never starts a second batch, and a failed
    /// batch is not retried in a loop.
    private var evaluatedKey: Key?
    private var cache: [Key: Presented] = [:]
    /// Insertion order of `cache`, oldest first, so it can be capped.
    private var cacheOrder: [Key] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var observer: NSObjectProtocol?

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
    /// unless the key moved.
    func present(lines: [LyricsStore.Line]?) {
        self.lines = lines
        evaluate()
    }

    /// Reads Settings again. Cheap and idempotent: it runs on every write to
    /// the defaults domain, and changes only what actually changed.
    func refresh() {
        let enabled = NotchViewModel.translateLyricsEnabled(in: defaults)
        let target = NotchViewModel.translateTarget(in: defaults, preferredLanguages: preferredLanguages)
        let shown = NotchViewModel.showTranslationEnabled(in: defaults)
        let recents = Self.recentTargets(in: defaults)
        if isEnabled != enabled { isEnabled = enabled }
        if self.target != target { self.target = target }
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

    static func recentTargets(in defaults: UserDefaults) -> [TranslationLanguage] {
        (defaults.stringArray(forKey: NotchViewModel.translateRecentsKey) ?? [])
            .compactMap(TranslationLanguage.withCode)
    }

    private func evaluate() {
        guard isEnabled, let lines, !lines.isEmpty else {
            generation += 1
            task?.cancel()
            task = nil
            evaluatedKey = nil
            if presented != nil { presented = nil }
            return
        }
        let key = Key(texts: lines.map(\.text), target: target.code)
        guard key != evaluatedKey else { return }
        evaluatedKey = key
        generation += 1
        task?.cancel()
        task = nil
        // The previous answer is for another song or another language. It is
        // dropped at once, rather than left under lines it does not belong to
        // for the length of a batch.
        if let hit = cache[key] {
            presented = hit
            return
        }
        if presented != nil { presented = nil }
        let generation = generation
        let target = target
        task = Task { [weak self] in
            guard let self else { return }
            let answer = await self.translate(lines: lines, key: key, target: target)
            guard !Task.isCancelled, self.generation == generation, let answer else { return }
            self.store(answer)
            self.presented = answer
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

    /// Nil when nothing could be done and nothing should be remembered (no
    /// engine for the pair, every engine failed, cancelled); a `Presented`
    /// with empty rows when the song is already in the target language, which
    /// is an answer and is kept.
    private func translate(lines: [LyricsStore.Line], key: Key, target: TranslationLanguage) async -> Presented? {
        let indices = lines.indices.filter { Self.isTranslatable(lines[$0]) }
        let empty = Presented(key: key, rows: Array(repeating: nil, count: lines.count), engine: nil)
        guard !indices.isEmpty else { return empty }

        // The song's language, from all of it: a line is too little for the
        // recognizer, and a Russian song with an English chorus is still a
        // Russian song to translate from.
        let song = backend.detect(indices.map { lines[$0].text }.joined(separator: "\n"))
        guard song != target else { return empty }

        // A line already in the target language gets no row — the English
        // chorus of a song translated into English. Only the lines that
        // remain are sent.
        let sent = indices.filter { backend.detect(lines[$0].text) != target }
        guard !sent.isEmpty else { return empty }
        let texts = sent.map { lines[$0].text }

        let route = Translator.Route(source: song, target: target)
        let capabilities = await backend.capabilities(route)
        guard !Task.isCancelled else { return nil }
        for engine in Translator.engines(given: capabilities) {
            do {
                let answers: [String?]
                switch engine {
                case .system: answers = try await backend.system(texts, route)
                case .intelligence: answers = try await backend.model(texts, route)
                case .online: answers = try await backend.online(texts, route)
                }
                var rows = [String?](repeating: nil, count: lines.count)
                var any = false
                for (position, index) in sent.enumerated() where position < answers.count {
                    if let row = Self.usable(answers[position], for: texts[position]) {
                        rows[index] = row
                        any = true
                    }
                }
                // An engine that answered nothing for any line did not answer.
                guard any else { throw Failure.nothingTranslated }
                return Presented(key: key, rows: rows, engine: engine)
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

    /// Where the batch the column shows went: the menu's last row.
    var engine: Translator.Engine? { presented?.engine }

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

    /// MyMemory, a line at a time and within the same daily character budget
    /// one Translate-tab paste has (`OnlineTranslation.maximumOnlineCharacters`):
    /// a song's lines are short and answered separately, so no line is
    /// ever folded into another's answer. A failure after some lines answered
    /// keeps them; a failure on the first throws.
    private static func onlineBatch(_ texts: [String], route: Translator.Route) async throws -> [String?] {
        var answers = [String?](repeating: nil, count: texts.count)
        var budget = OnlineTranslation.maximumOnlineCharacters
        for (index, text) in texts.enumerated() {
            try Task.checkCancellation()
            guard text.count <= budget else { break }
            budget -= text.count
            do {
                let reply = try await OnlineTranslation.translate(text, from: route.source, to: route.target)
                answers[index] = reply.text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if index == 0 { throw error }
                break
            }
        }
        return answers
    }
}
