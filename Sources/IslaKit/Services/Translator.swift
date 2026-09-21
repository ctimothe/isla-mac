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
            case .needsNewerSystem:
                return localized("Translation needs macOS 26 or newer.")
            case .deviceNotEligible:
                return localized("This Mac does not support Apple Intelligence.")
            case .appleIntelligenceOff:
                return localized("Turn on Apple Intelligence to translate.")
            case .modelNotReady:
                return localized("The on-device model is still downloading.")
            case .needsOnline(let language):
                return localized("%@ is translated online. Turn on Translate Online to use it.", language.name)
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

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    @Published private(set) var remedies: [Remedy] = []
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

    /// The last detection, so the recognizer runs once per text rather than
    /// once per read — the pane reads the route on every keystroke's render.
    private var detection: (text: String, language: TranslationLanguage)?

    /// Bumped per request, so a late-finishing cancelled run can tell that it
    /// is no longer the one on screen.
    private var generation = 0

    private var attempt = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        source = defaults.string(forKey: Self.sourceKey).flatMap(TranslationLanguage.withCode)
        target = defaults.string(forKey: Self.targetKey).flatMap(TranslationLanguage.withCode) ?? .russian
        if source == target { source = nil }
        Task { [weak self] in
            let codes = await Self.languagesOnThisMac()
            self?.onDeviceLanguages = codes
        }
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
        if !output.isEmpty, outputSource == trimmed {
            input = output
            output = ""
            outputSource = nil
            engine = nil
        }
        remember()
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
        // The language to name is the one that is not English: English is on
        // every engine, so it is never the reason.
        let missing = route.target == .english ? route.source : route.target
        if capabilities.systemSupported { return .needsDownload(missing) }
        if capabilities.modelSupportsPair, let obstacle = capabilities.modelObstacle { return obstacle }
        return .needsOnline(missing)
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
    var modelObstacle: Obstacle? {
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

    private func capabilities(for route: Route) async -> Capabilities {
        var capabilities = Capabilities()
        capabilities.onlineEnabled = defaults.bool(forKey: NotchViewModel.onlineTranslationKey)
        guard #available(macOS 26.0, *) else {
            capabilities.belowMinimumSystem = true
            return capabilities
        }
        let status = await Self.systemStatus(from: route.source, to: route.target)
        capabilities.systemSupported = status != .unsupported
        capabilities.systemInstalled = status == .installed
        capabilities.modelSupportsPair = Self.modelHandles(route.source) && Self.modelHandles(route.target)
        capabilities.modelObstacle = modelObstacle
        return capabilities
    }

    /// Asked off the main actor, where the framework's availability object is
    /// made and used, so nothing that is not `Sendable` crosses an actor.
    nonisolated private static func systemStatus(
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
        outputSource = nil
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
            outputSource = nil
            engine = nil
            failure = obstacle.message
            remedies = Self.remedies(for: obstacle, onlineEnabled: capabilities.onlineEnabled)
            return
        }

        var lastFailure = localized("The translation could not be completed.")
        for candidate in engines {
            do {
                let translated = try await run(candidate, text: text, route: route)
                guard !Task.isCancelled, self.generation == generation else { return }
                received(translated, for: text, by: candidate)
                return
            } catch is CancellationError {
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
        outputSource = nil
        engine = nil
        failure = lastFailure
        remedies = [.retry]
    }

    /// The one place an answer lands: the text, what it answers, and which
    /// engine gave it — kept together so the swap and the globe can never
    /// describe a different answer from the one on screen.
    func received(_ translated: String, for text: String, by engine: Engine) {
        output = translated
        outputSource = text
        self.engine = engine
        failure = nil
        remedies = []
    }

    /// An engine asked for on a system that does not have it. Unreachable in
    /// practice — `engines(given:)` only lists what the system reported — and
    /// a failure like any other if it ever is reached.
    private struct EngineUnavailable: Error {}

    private func run(_ engine: Engine, text: String, route: Route) async throws -> String {
        switch engine {
        case .system:
            guard #available(macOS 26.0, *) else { throw EngineUnavailable() }
            let session = TranslationSession(installedSource: route.source.locale, target: route.target.locale)
            return try await session.translate(text).targetText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .intelligence:
            guard #available(macOS 26.0, *) else { throw EngineUnavailable() }
            return try await Self.askModel(text, route: route)
        case .online:
            let translated = try await OnlineTranslation.translate(text, from: route.source, to: route.target)
            guard !translated.isEmpty else { throw OnlineTranslation.Failure.refused("") }
            return translated
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
    private static func askModel(_ text: String, route: Route) async throws -> String {
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

    private static func describe(_ error: Error) -> String {
        if let failure = error as? OnlineTranslation.Failure {
            switch failure {
            case .unreachable: return localized("Online translation is not reachable right now.")
            case .quotaExhausted: return localized("Today's free online translations are used up.")
            case .refused: return localized("The translation could not be completed.")
            }
        }
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                // Apple's safety filter, which fires on ordinary sentences —
                // "Delete all my files" was refused in testing. Worth naming
                // plainly so it does not read as the app breaking.
                return localized("This text could not be translated.")
            case .exceededContextWindowSize:
                return localized("This text is too long to translate at once.")
            default:
                return localized("The translation could not be completed.")
            }
        }
        return localized("The translation could not be completed.")
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
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
