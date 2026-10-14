import AppKit
import FoundationModels
import Translation

/// Translation between the languages the Translate tab offers, by the best
/// engine this Mac has for each pair.
///
/// Three engines, tried in order, the first that can do the pair winning:
///
/// 1. **Apple's Translation framework**, for a pair whose languages are
///    installed. Fast, on device, and it translates what it is given — the
///    language model refused "Delete all my files" as unsafe; this does not.
///    It was the first engine here and was dropped on macOS 26, where a
///    language whose assets were a stale earlier generation reported
///    `.supported` forever and failed with an opaque internal error. So it is
///    only ever asked about a pair it reports `.installed`, which is what
///    works (measured on macOS 27 on 2026-09-21), and any error it throws
///    falls through to the next engine rather than to the screen.
/// 2. **The on-device language model**, for the languages it supports — plus
///    Russian, which Apple does not list but which it translates well, and
///    which this tab was built on. No per-language assets to go stale.
/// 3. **Online**, only when Translate Online is switched on, and only for a
///    pair neither engine above offers at all — see `OnlineTranslation`. For
///    Uzbek and Kazakh it is the only way. It is never the next try after an
///    on-device engine failed, refused or is switched off: the text a model
///    refuses as sensitive is exactly the text that must not then leave.
@MainActor
final class Translator: ObservableObject {
    struct Route: Equatable {
        var source: TranslationLanguage
        var target: TranslationLanguage
    }

    /// Keyed by the pane's debounced task. The counter is what makes a retry of
    /// unchanged text a new request rather than a no-op; the languages are in
    /// it so choosing another one translates again.
    struct Request: Equatable {
        var text: String
        var attempt: Int
        var source: TranslationLanguage?
        var target: TranslationLanguage
    }

    enum Engine: Equatable {
        case system
        case intelligence
        case online
    }

    /// Why a pair cannot be translated here right now. Each is something the
    /// person can act on or at least understand, rather than a raw error.
    enum Obstacle: Equatable {
        case needsNewerSystem
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady
        /// No engine on this Mac has the language; only the online one does.
        case needsOnline(TranslationLanguage)
        /// Apple's Translation framework has the pair but has not downloaded it.
        case needsDownload(TranslationLanguage)

        var message: String {
            switch self {
            // Both sentences sit above a "Turn On Translate Online" button,
            // and that click is the one that sends text off the Mac. The
            // offer used to say only that a language "is translated online",
            // never where the text would go (H-007), so each now names the
            // service before the button is pressed.
            case .needsNewerSystem:
                return localized("Translation on this Mac needs macOS 26 or newer. Turning on Translate Online sends this text to MyMemory.")
            case .deviceNotEligible:
                return localized("This Mac does not support Apple Intelligence.")
            case .appleIntelligenceOff:
                return localized("Turn on Apple Intelligence to translate.")
            case .modelNotReady:
                return localized("The on-device model is still downloading.")
            case .needsOnline(let language):
                return localized("%@ is translated online only. Turning on Translate Online sends this text to MyMemory.", language.name)
            case .needsDownload(let language):
                return localized("%@ is not downloaded for translation on this Mac.", language.name)
            }
        }
    }

    /// The buttons a failure offers, in the order they are drawn.
    enum Remedy: Equatable, Hashable {
        case appleIntelligenceSettings
        case translationLanguages
        case turnOnOnline
        case retry
    }

    static let sourceKey = "translate.source"
    static let targetKey = "translate.target"

    /// The notice is about the text that arrived with it, so any later change
    /// to the field — a keystroke, Clear, a swap — takes it down. A notice that
    /// outlived its text would say "only the first 20,000 characters" over a
    /// sentence somebody typed by hand.
    @Published var input = "" {
        didSet { notice = nil }
    }
    /// One line the pane shows under the field about how text arrived there by
    /// hot key or Service: that there was none, or that it was cut. Set after
    /// `input`, whose `didSet` would otherwise clear it at once.
    @Published var notice: String?
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    @Published private(set) var remedies: [Remedy] = []
    /// One line under an answer that does not cover the whole text: that only
    /// the first part went online, or why the rest of it never came back.
    /// It belongs to that answer and goes wherever the answer goes.
    @Published private(set) var outputNote: String?
    @Published private(set) var isTranslating = false
    /// The engine behind what is on screen — the pane marks an online answer.
    @Published private(set) var engine: Engine?

    /// `nil` detects the language from the text.
    @Published private(set) var source: TranslationLanguage?
    @Published private(set) var target: TranslationLanguage

    /// The base codes some engine on this Mac can translate, once known. The
    /// menus mark every other language as an online one.
    @Published private(set) var onDeviceLanguages: Set<String>?

    /// The text `output` is the translation of. Swapping moves the answer into
    /// the field only when it answers what the field holds: for the length of
    /// the debounce the answer on screen is still the previous text's, and a
    /// swap then would replace what was just typed with a stale translation.
    private var outputSource: String?

    /// Whether the answer on screen is the answer to what the field holds now.
    /// For the debounce and the engine's time after an edit it is not: it is
    /// the previous text's, and it used to look and copy exactly like a
    /// current one, so Copy pressed in that window pasted a translation of the
    /// sentence before the edit (K-004). The pane dims such an answer and
    /// disables Copy; `swap()` and `copyOutput()` refuse it outright.
    var answersInput: Bool { !output.isEmpty && outputSource == trimmed }

    /// The last detection, so the recognizer runs once per text rather than
    /// once per read — the pane reads the route on every keystroke's render.
    private var detection: (text: String, language: TranslationLanguage)?

    /// Bumped per request, so a late-finishing cancelled run can tell that it
    /// is no longer the one on screen.
    private var generation = 0

    private var attempt = 0

    /// The request the answer on screen was given for, keyed on the trimmed
    /// text. The pane's task re-runs on every appearance of the tab, and every
    /// run used to translate again: switching Music → Translate → Music sent
    /// the same Uzbek sentence to MyMemory once per return and spent the day's
    /// quota on text whose answer was already on screen (G-026). Trimmed,
    /// because a trailing space is not a new question and was a new request.
    /// Anything that is — other text, another language, Retry — makes a
    /// `Request` that differs from this one, so only a true repeat is skipped.
    private var answered: Request?

    /// What `answered` is compared against.
    private var question: Request { Request(text: trimmed, attempt: attempt, source: source, target: target) }

    private let defaults: UserDefaults

    /// `preferredLanguages` is the system's list, in order; tests pass their
    /// own so the default does not depend on the language of the machine the
    /// suite happens to run on.
    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        source = defaults.string(forKey: Self.sourceKey).flatMap(TranslationLanguage.withCode)
        if let stored = defaults.string(forKey: Self.targetKey).flatMap(TranslationLanguage.withCode) {
            target = stored
        } else if defaults.bool(forKey: NotchViewModel.hasCompletedFirstRunKey) {
            // An account that has been through the welcome and never opened the
            // menu has been translating into Russian, the target this tab
            // always had, and `remember()` only writes on a choice. Moving it
            // to the system language on an upgrade would change a working
            // setup under its owner without a word.
            target = .russian
        } else {
            // A fresh install. Every new user used to be offered Russian
            // (H-005), so an English or German reader met a tab answering in a
            // language they did not ask for until they found the menu.
            target = Self.defaultTarget(preferredLanguages: preferredLanguages)
            // Written down at once: the welcome completes the first run, so
            // on the next launch this account takes the branch above and,
            // with nothing stored, would quietly turn Russian. Not into the
            // standard domain under a test, which is the test runner's own
            // and leaks into every later run.
            if !(PlayerBridge.isRunningTests && defaults === UserDefaults.standard) {
                defaults.set(target.code, forKey: Self.targetKey)
            }
        }
        if source == target { source = nil }
        Task { [weak self] in
            let codes = await Self.languagesOnThisMac()
            self?.onDeviceLanguages = codes
        }
    }

    /// The first of the reader's languages the tab offers, else English.
    /// Matched on the base code, so "de-DE" is German, "pt-BR" Portuguese and
    /// any Chinese ("zh-Hant-TW" as well) the Simplified Chinese on offer —
    /// the system writes a region and often a script after the language, and
    /// the list here names neither.
    static func defaultTarget(preferredLanguages: [String]) -> TranslationLanguage {
        for identifier in preferredLanguages {
            let base = identifier.prefix { $0 != "-" && $0 != "_" }.lowercased()
            if let language = TranslationLanguage.all.first(where: { $0.baseCode == base }) {
                return language
            }
        }
        return .english
    }

    // MARK: - Text from the hot key and the Service

    /// What ⌃⌥⌘T or the Service hands the field, and the line that goes with it.
    struct CommandInput: Equatable {
        /// `nil` when there was no text: the field keeps what it holds.
        var text: String?
        var notice: String?
    }

    /// About 3,000 words. The clipboard used to go into the field whole, and a
    /// 2 MB log held the main thread for 1.1 s in the assignment and the layout
    /// pass alone, 1.3 s of CPU all told, before the panel could draw again
    /// (J-017; measured by `TranslateInputBench` on 2026-10-11). At this limit
    /// that pass is 27–41 ms, inside the 50 ms the limit was chosen against.
    /// History's 256 KiB cap would not do: a `TextEditor` whose pane
    /// re-measures its text on every body pass still visibly stalls at that
    /// size. It also bounds what one press can ever send to the online engine.
    static let commandInputLimit = 20_000

    /// The clipboard or the selection, made fit for the field.
    ///
    /// No text — an image on the clipboard, or only blanks — is a sentence to
    /// show rather than nothing at all (F-040): silence was indistinguishable
    /// from a shortcut that is not registered. Too much text is cut to
    /// `commandInputLimit` characters, and says so.
    ///
    /// Leading blanks are skipped before counting and the cut is found by
    /// walking `commandInputLimit` characters from there, so the work is
    /// bounded by the limit and not by the size of what was copied: trimming
    /// the whole 2 MB first would itself be a pass over all of it. Counted in
    /// characters, so a cut never splits a flag or an accented letter.
    ///
    /// The number is grouped the way the app's language groups it — "20 000"
    /// in the Russian sentence — not the system region's way, or the line
    /// would read half in one language (see `appLanguage`).
    static func prepareCommandInput(_ raw: String?, locale: Locale = Locale(identifier: appLanguage)) -> CommandInput {
        let noText = CommandInput(text: nil, notice: localized("The clipboard has no text."))
        guard let raw else { return noText }
        let body = raw.drop { $0.isWhitespace }
        var notice: String?
        var kept = body
        if let cut = body.index(body.startIndex, offsetBy: commandInputLimit, limitedBy: body.endIndex),
           cut < body.endIndex {
            kept = body[..<cut]
            notice = localized(
                "Only the first %@ characters were kept.",
                commandInputLimit.formatted(.number.locale(locale))
            )
        }
        let text = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return noText }
        return CommandInput(text: text, notice: notice)
    }

    var request: Request { Request(text: input, attempt: attempt, source: source, target: target) }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route {
        let text = trimmed
        guard source == nil, !text.isEmpty else { return Self.route(for: text, source: source, target: target) }
        if let detection, detection.text == text {
            return Self.route(detected: detection.language, target: target)
        }
        let detected = LanguageDetection.language(of: text)
        detection = (text, detected)
        return Self.route(detected: detected, target: target)
    }

    // MARK: - Choosing languages

    /// Chosen as the source. Choosing the language already on the other side
    /// swaps the two rather than translating a language into itself.
    func choose(source newSource: TranslationLanguage?) {
        guard newSource != source else { return }
        clearAnswer()
        if let newSource, newSource == target {
            // The old source takes the target's place — a detected one as the
            // language it was detected as.
            let previous = source ?? route.source
            target = previous == newSource ? Self.alternative(to: newSource) : previous
        }
        source = newSource
        remember()
    }

    func choose(target newTarget: TranslationLanguage) {
        guard newTarget != target else { return }
        clearAnswer()
        if newTarget == source {
            source = target
        }
        target = newTarget
        remember()
    }

    /// Exchanges the two sides, and the text with them: what was the answer
    /// becomes the question, the way every translator's swap behaves. A
    /// detected source is swapped as the language it was detected as.
    func swap() {
        let from = source ?? route.source
        source = target
        target = from
        if source == target { source = nil }
        if answersInput {
            input = output
            output = ""
            outputNote = nil
            outputSource = nil
            answered = nil
            engine = nil
        }
        remember()
    }

    /// A new language makes the answer on screen an answer in the old one,
    /// under a heading that already names the new. It goes at once rather than
    /// sitting there for the debounce and the engine's time.
    private func clearAnswer() {
        output = ""
        outputNote = nil
        outputSource = nil
        answered = nil
        engine = nil
        failure = nil
        remedies = []
    }

    private func remember() {
        defaults.set(source?.code ?? "auto", forKey: Self.sourceKey)
        defaults.set(target.code, forKey: Self.targetKey)
    }

    /// The pair a text is actually translated along.
    ///
    /// A detected source that turns out to be the target language is turned
    /// around rather than translated into itself: Russian typed at a tab set to
    /// Russian goes to English, and English typed at a tab set to English goes
    /// to Russian — which is exactly the rule this tab ran on when those were
    /// its only two languages.
    static func route(for text: String, source: TranslationLanguage?, target: TranslationLanguage) -> Route {
        guard let source else {
            let detected = text.isEmpty ? alternative(to: target) : LanguageDetection.language(of: text)
            return route(detected: detected, target: target)
        }
        return Route(source: source, target: target)
    }

    private static func route(detected: TranslationLanguage, target: TranslationLanguage) -> Route {
        detected == target
            ? Route(source: detected, target: alternative(to: target))
            : Route(source: detected, target: target)
    }

    static func alternative(to language: TranslationLanguage) -> TranslationLanguage {
        language == .english ? .russian : .english
    }

    // MARK: - Engines

    /// What this Mac can do for one pair, gathered before a translation.
    struct Capabilities: Equatable {
        /// Apple's Translation framework has the pair downloaded.
        var systemInstalled = false
        /// It offers the pair at all, downloaded or not.
        var systemSupported = false
        var modelSupportsPair = false
        /// Why the model cannot answer, or nil when it can.
        var modelObstacle: Obstacle?
        var onlineEnabled = false
        /// Below macOS 26 neither on-device engine can be reached from here:
        /// the framework only translates outside SwiftUI from 26 on, and the
        /// model only exists there.
        var belowMinimumSystem = false
        /// Which side of the pair no engine on this Mac knows, when one does
        /// not — so the message names that language and not its partner.
        var sourceOffDevice = false
        var targetOffDevice = false

        /// Whether the pair is this Mac's to translate — ready or not. Such a
        /// pair is never sent online, whatever the switch says.
        var offeredOnDevice: Bool { systemSupported || modelSupportsPair }
    }

    /// The engines to try, best first. Empty means nothing here can do it —
    /// see `obstacle(for:given:)`.
    ///
    /// Online is listed only for a pair nothing on this Mac offers, so a
    /// failure on device can never fall through to it. It used to be appended
    /// whenever the switch was on: a sentence the model refused, a pair whose
    /// language was not yet downloaded, or any pair with Apple Intelligence
    /// switched off all went to the service, which is not what the switch
    /// promises (found in review, 2026-09-21).
    static func engines(given capabilities: Capabilities) -> [Engine] {
        var engines: [Engine] = []
        if capabilities.systemInstalled { engines.append(.system) }
        if capabilities.modelSupportsPair, capabilities.modelObstacle == nil { engines.append(.intelligence) }
        if capabilities.onlineEnabled, !capabilities.offeredOnDevice { engines.append(.online) }
        return engines
    }

    /// Why no engine can do the pair, naming the language that is missing.
    static func obstacle(for route: Route, given capabilities: Capabilities) -> Obstacle {
        if capabilities.belowMinimumSystem { return .needsNewerSystem }
        // The language to name is the one this Mac lacks. It used to be
        // whichever side was not English, which named Russian for Uzbek into
        // Russian — the one of the two the Mac translates perfectly well.
        // Without that knowledge, English is still never the reason.
        let missing: TranslationLanguage
        if capabilities.targetOffDevice {
            missing = route.target
        } else if capabilities.sourceOffDevice {
            missing = route.source
        } else {
            missing = route.target == .english ? route.source : route.target
        }
        if capabilities.systemSupported { return .needsDownload(missing) }
        if capabilities.modelSupportsPair, let obstacle = capabilities.modelObstacle { return obstacle }
        return .needsOnline(missing)
    }

    /// Whether this Mac is below the system both on-device engines need. On
    /// such a Mac nothing is translated locally, and with the switch on every
    /// pair is sent to MyMemory.
    nonisolated static var isBelowMinimumSystem: Bool {
        if #available(macOS 26.0, *) { return false }
        return true
    }

    /// What Settings says under Translate Online while it is on. The one note
    /// used to read "such as Uzbek" on every Mac, but below macOS 26 the
    /// switch sends English into Russian too — every pair — and a person
    /// reading the note expected their English to stay local (K-005).
    static func onlineNote(belowMinimumSystem: Bool = isBelowMinimumSystem) -> String {
        belowMinimumSystem
            ? localized("Before macOS 26 this Mac translates nothing itself: everything is sent to MyMemory over the internet.")
            : localized("Languages this Mac cannot translate itself, such as Uzbek, are sent to MyMemory over the internet.")
    }

    /// The buttons an obstacle offers. Online is offered only where online is
    /// what would be used — never as a way round a pair the Mac owns.
    static func remedies(for obstacle: Obstacle, onlineEnabled: Bool) -> [Remedy] {
        switch obstacle {
        case .appleIntelligenceOff: return [.appleIntelligenceSettings]
        case .needsDownload: return [.translationLanguages]
        case .needsOnline, .needsNewerSystem: return onlineEnabled ? [] : [.turnOnOnline]
        case .deviceNotEligible, .modelNotReady: return []
        }
    }

    /// Whether the on-device model is trusted with a language: what it lists,
    /// and Russian.
    static func modelHandles(_ language: TranslationLanguage) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        if language == .russian { return true }
        return SystemLanguageModel.default.supportsLocale(Locale(identifier: language.code))
    }

    /// Why the model is not answering, or nil when it is ready.
    var modelObstacle: Obstacle? { Self.modelObstacle() }

    static func modelObstacle() -> Obstacle? {
        guard #available(macOS 26.0, *) else { return .needsNewerSystem }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .modelNotReady
        }
    }

    /// A seam for the headless visual lab, nil in the app: what this Mac can
    /// do, stated rather than asked. The real answer depends on which language
    /// packs the machine running the lab has downloaded, so a "missing pack"
    /// render could otherwise only be made on a Mac that happens to miss one.
    var capabilitiesOverride: ((Route) -> Capabilities)?

    private func capabilities(for route: Route) async -> Capabilities {
        if let capabilitiesOverride { return capabilitiesOverride(route) }
        var capabilities = await Self.deviceCapabilities(
            for: route, onlineEnabled: defaults.bool(forKey: NotchViewModel.onlineTranslationKey)
        )
        guard !capabilities.belowMinimumSystem else { return capabilities }
        if onDeviceLanguages == nil { onDeviceLanguages = await Self.languagesOnThisMac() }
        capabilities.sourceOffDevice = isOnlineOnly(route.source)
        capabilities.targetOffDevice = isOnlineOnly(route.target)
        return capabilities
    }

    /// What this Mac can do for one pair, without a `Translator` to ask. The
    /// Translate tab asks it through the instance above; the lyric translation
    /// (`LyricTranslation`, spec §5.3) asks it here, so both decide which
    /// engines may run — and above all whether the online one may — from this
    /// one function and `engines(given:)`, never from a second policy.
    ///
    /// `sourceOffDevice` and `targetOffDevice` stay false: they only decide
    /// which language an obstacle's sentence names, and a lyric that cannot be
    /// translated says nothing (one failure surface; the Translate tab is where
    /// translation errors are explained).
    static func deviceCapabilities(for route: Route, onlineEnabled: Bool) async -> Capabilities {
        var capabilities = Capabilities()
        capabilities.onlineEnabled = onlineEnabled
        guard #available(macOS 26.0, *) else {
            capabilities.belowMinimumSystem = true
            return capabilities
        }
        let status = await systemStatus(from: route.source, to: route.target)
        capabilities.systemSupported = status != .unsupported
        capabilities.systemInstalled = status == .installed
        capabilities.modelSupportsPair = modelHandles(route.source) && modelHandles(route.target)
        capabilities.modelObstacle = modelObstacle()
        return capabilities
    }

    /// Asked off the main actor, where the framework's availability object is
    /// made and used, so nothing that is not `Sendable` crosses an actor.
    nonisolated static func systemStatus(
        from source: TranslationLanguage, to target: TranslationLanguage
    ) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source.locale, to: target.locale)
    }

    nonisolated private static func systemLanguages() async -> Set<String> {
        Set(await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier })
    }

    /// The base codes this Mac translates itself. Below macOS 26 that is none:
    /// every language there is an online one.
    private static func languagesOnThisMac() async -> Set<String> {
        guard #available(macOS 26.0, *) else { return [] }
        var codes = await systemLanguages()
        for language in TranslationLanguage.all where modelHandles(language) {
            codes.insert(language.baseCode)
        }
        return codes
    }

    /// Whether choosing this language means going online on this Mac. Unknown
    /// until the device's languages have been read, and unknown reads as no.
    func isOnlineOnly(_ language: TranslationLanguage) -> Bool {
        guard let onDeviceLanguages else { return false }
        return !onDeviceLanguages.contains(language.baseCode)
    }

    // MARK: - Translating

    func retry() {
        attempt += 1
    }

    /// Switches Translate Online on from the pane's own button, and asks again.
    func turnOnOnline() {
        defaults.set(true, forKey: NotchViewModel.onlineTranslationKey)
        retry()
    }

    func clear() {
        output = ""
        outputNote = nil
        outputSource = nil
        answered = nil
        failure = nil
        remedies = []
        engine = nil
        isTranslating = false
    }

    func reset() {
        input = ""
        clear()
    }

    func translate() async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }

        // Already answered: the tab reappearing, or an edit that came back to
        // the text on screen, asks nothing new (G-026). Checked before the
        // capability lookup, the first thing that could reach an engine. The
        // generation still moves on, so a run for text in between — "salomx"
        // typed and deleted while its run was out — cannot land over the
        // answer this keeps, and the flag that run raised comes down here.
        if answersInput, answered == question {
            generation += 1
            isTranslating = false
            return
        }

        // Stamped, so a cancelled run cannot clear the flag its successor
        // raised. The pane cancels the previous task on every keystroke, but
        // cancellation of an in-flight model response is cooperative: the old
        // task returns whenever the model gets round to it, and its unguarded
        // `defer` used to switch off the "Translating…" indicator for the
        // newer request that was still running — indistinguishable, on screen,
        // from a translation that came back empty.
        generation += 1
        let generation = generation
        isTranslating = true
        defer { if self.generation == generation { isTranslating = false } }

        let route = route
        let capabilities = await capabilities(for: route)
        guard !Task.isCancelled, self.generation == generation else { return }
        let engines = Self.engines(given: capabilities)
        guard !engines.isEmpty else {
            let obstacle = Self.obstacle(for: route, given: capabilities)
            output = ""
            outputNote = nil
            outputSource = nil
            engine = nil
            failure = obstacle.message
            remedies = Self.remedies(for: obstacle, onlineEnabled: capabilities.onlineEnabled)
            return
        }

        var lastFailure = Self.describe(EngineUnavailable())
        for candidate in engines {
            do {
                let answer = try await run(candidate, text: text, route: route)
                guard !Task.isCancelled, self.generation == generation else { return }
                received(answer.text, for: text, by: candidate, note: answer.note)
                return
            } catch is CancellationError {
                return
            } catch let OnlineTranslation.Failure.partial(translated, cause) {
                guard !Task.isCancelled, self.generation == generation else { return }
                // The part that came back is an answer, and shown as one, with
                // the reason the rest did not come under it. Retry stays only
                // where a second try could bring the rest: never for a spent
                // allowance. Online is always the last engine, so there is no
                // next one this would skip.
                let (message, retryable) = Self.describe(cause)
                received(translated, for: text, by: candidate, note: message)
                remedies = retryable ? [.retry] : []
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                lastFailure = Self.describe(error)
                // On to the next engine: a pair one of them fumbles is still a
                // pair another can do, and the person asked for a translation,
                // not for this engine's opinion.
            }
        }
        output = ""
        outputNote = nil
        outputSource = nil
        engine = nil
        failure = lastFailure.message
        // Retry only where it can work. It used to be offered under every
        // failure (F-042, M-10), so a spent daily allowance or Apple's
        // guardrail — which refuse the same text the same way every time —
        // wore a button that could only fail again.
        remedies = lastFailure.retryable ? [.retry] : []
    }

    /// The one place an answer lands: the text, what it answers, and which
    /// engine gave it — kept together so the swap and the globe can never
    /// describe a different answer from the one on screen. `note` is the line
    /// about what the answer does not cover, if anything.
    func received(_ translated: String, for text: String, by engine: Engine, note: String? = nil) {
        output = translated
        outputNote = note
        outputSource = text
        answered = text == trimmed ? question : nil
        self.engine = engine
        failure = nil
        remedies = []
    }

    /// What a cut online answer says under it. The number is the characters
    /// that went — pieces end at sentences, so rarely the cap exactly —
    /// rounded down to a hundred, and grouped the app language's way, as
    /// `prepareCommandInput` groups its own. Rounded down so it stays true
    /// (the first 4,700 of 4,763 sent were translated) and so Russian's one
    /// sentence agrees with it: "первые %@ символов" is right for any number
    /// ending in 00 and wrong for 4 801 or 4 763. A cut only follows ten
    /// pieces, each too full to take the next sentence, so the number is in
    /// the thousands and rounding never brings it near zero.
    static func onlineCapNote(sent: Int, locale: Locale = Locale(identifier: appLanguage)) -> String {
        let shown = sent / 100 * 100
        return localized("Only the first %@ characters were translated online.", shown.formatted(.number.locale(locale)))
    }

    /// The online engine, a seam so a test can answer for MyMemory without
    /// the network. The app never sets it.
    var onlineTranslate: (String, Route) async throws -> OnlineTranslation.Reply = { text, route in
        try await OnlineTranslation.translate(text, from: route.source, to: route.target)
    }

    /// An engine asked for on a system that does not have it. Unreachable in
    /// practice — `engines(given:)` only lists what the system reported — and
    /// a failure like any other if it ever is reached.
    private struct EngineUnavailable: Error {}

    private func run(_ engine: Engine, text: String, route: Route) async throws -> (text: String, note: String?) {
        switch engine {
        case .system:
            guard #available(macOS 26.0, *) else { throw EngineUnavailable() }
            let session = TranslationSession(installedSource: route.source.locale, target: route.target.locale)
            return (try await session.translate(text).targetText
                .trimmingCharacters(in: .whitespacesAndNewlines), nil)
        case .intelligence:
            guard #available(macOS 26.0, *) else { throw EngineUnavailable() }
            return (try await Self.askModel(text, route: route), nil)
        case .online:
            let reply = try await onlineTranslate(text, route)
            guard !reply.text.isEmpty else { throw OnlineTranslation.Failure.refused("") }
            return (reply.text, reply.sentCharacters.map { Self.onlineCapNote(sent: $0) })
        }
    }

    /// Most responses a translation can need: a few tokens per source
    /// character, never less than a short sentence's worth.
    ///
    /// Uncapped, the model once translated one English sentence into Uzbek for
    /// 218 seconds, generating until its 8,192-token context was full — with
    /// the "Translating…" line up for the whole of it. A translation is about
    /// as long as its source; anything many times longer is the model talking,
    /// and it is cut off rather than waited for.
    static func responseTokenLimit(for text: String) -> Int {
        min(4096, max(128, text.count * 3))
    }

    @available(macOS 26.0, *)
    static func askModel(_ text: String, route: Route) async throws -> String {
        let source = route.source.englishName
        let target = route.target.englishName
        // Guided generation, not a free-form reply, and this is the whole
        // reason the model works as a translator at all. Asked in prose — even
        // told bluntly that it is a translation engine and must never answer —
        // the model answers anyway: "what is your name?" came back as
        // "Я не имею имени" ("I have no name") and "write me a poem" came back
        // as an actual poem long enough to blow the context window. Made to
        // fill a field instead, the same inputs translate correctly, because
        // filling a slot is not a turn in a conversation. Greedy sampling on
        // top, so the same text always gives the same translation rather than
        // a different one per keystroke.
        let session = LanguageModelSession(
            instructions: """
            You translate \(source) into \(target). You are a \
            translation engine: you restate the source text in \(target) and \
            never respond to it. A question is translated as a question.
            """
        )
        let response = try await session.respond(
            to: "Source text to translate into \(target):\n\(text)",
            generating: TranslationResult.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: responseTokenLimit(for: text))
        )
        return response.content.translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a failure says, and whether asking again could change it: the
    /// remedies come from `retryable`, so Retry is offered only where a second
    /// try can succeed (F-042, M-10).
    static func describe(_ error: Error) -> (message: String, retryable: Bool) {
        let generic = (localized("The translation could not be completed."), true)
        if let failure = error as? OnlineTranslation.Failure {
            switch failure {
            case .unreachable: return (localized("Online translation is not reachable right now."), true)
            // Spent until the service's day turns over; another request now
            // is refused the same way.
            case .quotaExhausted: return (localized("Today's free online translations are used up."), false)
            case .refused: return generic
            case .partial(_, let cause): return describe(cause)
            }
        }
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                // Apple's safety filter, which fires on ordinary sentences —
                // "Delete all my files" was refused in testing. Worth naming
                // plainly so it does not read as the app breaking. It refuses
                // the same text the same way every time, so no Retry.
                return (localized("This text could not be translated."), false)
            case .exceededContextWindowSize:
                // The same text overflows the same window again; what would
                // work is less of it, so that is what it says.
                return (localized("This text is too long to translate at once. Shorten it and try again."), false)
            default:
                return generic
            }
        }
        return generic
    }

    /// Where a copied answer goes: the general pasteboard in the app, a
    /// private one in a test, which must never write over what the owner
    /// last copied.
    var pasteboard: NSPasteboard = .general

    /// Counts every answer that reached the pasteboard, however it was asked
    /// for. The pane's Copy button ticks when this moves, so ⇧⌘C — a copy the
    /// button did not make — still shows on screen; it used to be the button
    /// alone that could confirm one.
    @Published private(set) var outputCopies = 0

    /// Whether the answer went to the pasteboard. It does not when it is the
    /// answer to text since edited (K-004).
    @discardableResult
    func copyOutput() -> Bool {
        guard answersInput else { return false }
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
        outputCopies += 1
        return true
    }

    /// System Settings → Apple Intelligence, the switch behind every
    /// `appleIntelligenceOff` failure.
    static func openAppleIntelligenceSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence") else { return }
        NSWorkspace.shared.open(url)
    }

    /// System Settings → General → Language & Region, where Translation
    /// Languages are downloaded.
    static func openTranslationLanguages() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

@available(macOS 26.0, *)
@Generable
private struct TranslationResult {
    @Guide(description: "The exact translation of the source text. A question stays a question. Never an answer, never a reply, never commentary.")
    var translation: String
}
