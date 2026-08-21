import AppKit
import FoundationModels

/// Translation, driven by the on-device foundation model rather than by the
/// Translation framework.
///
/// The Translation framework was the obvious choice and did not survive
/// contact with a real Mac: it gates on `LanguageAvailability.status` being
/// `.installed`, and on macOS 26 a language whose assets are a stale earlier
/// generation reports `.supported` forever — downloaded according to System
/// Settings, unusable according to the framework, and `translate()` fails with
/// an opaque internal error no matter what. Nothing in an app can repair that.
///
/// The foundation model has no per-language assets to go stale. It ships with
/// Apple Intelligence, runs on device, costs nothing, needs no key, and makes
/// no network request.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    struct Route: Equatable {
        var source: Locale.Language
        var target: Locale.Language
    }

    /// Keyed by the pane's debounced task. The counter is what makes a retry of
    /// unchanged text a new request rather than a no-op.
    struct Request: Equatable {
        var text: String
        var attempt: Int
    }

    /// Why the model cannot answer, when it cannot. Each case is something the
    /// user can act on or at least understand, rather than a raw error.
    enum Unavailable: Equatable {
        case needsNewerSystem
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady

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
            }
        }

        /// Only the switch the user owns is worth offering a button for.
        var isSettable: Bool { self == .appleIntelligenceOff }
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// Set when the failure is one System Settings can fix, so the pane can
    /// offer the button that goes there.
    @Published private(set) var needsSettings = false
    @Published private(set) var isTranslating = false

    /// Bumped per request, so a late-finishing cancelled run can tell that it
    /// is no longer the one on screen.
    private var generation = 0

    private var attempt = 0

    var request: Request { Request(text: input, attempt: attempt) }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route { Self.route(for: trimmed) }

    /// Russian goes out to English, everything else comes in to Russian.
    ///
    /// Decided by script rather than by language detection: a single word is
    /// far too short to identify reliably, and "привет" comes back as Bulgarian
    /// often enough to matter.
    static func route(for text: String) -> Route {
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return cyrillic
            ? Route(source: russian, target: english)
            : Route(source: english, target: russian)
    }

    func retry() {
        attempt += 1
    }

    func clear() {
        output = ""
        failure = nil
        needsSettings = false
        isTranslating = false
    }

    func reset() {
        input = ""
        clear()
    }

    /// Why the model is not answering, or nil when it is ready.
    var unavailable: Unavailable? {
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

    func translate() async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }

        if let unavailable {
            output = ""
            failure = unavailable.message
            needsSettings = unavailable.isSettable
            isTranslating = false
            return
        }

        guard #available(macOS 26.0, *) else { return }

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

        let route = Self.route(for: text)
        let target = Self.name(route.target)

        do {
            // Guided generation, not a free-form reply, and this is the whole
            // reason the feature works at all. Asked in prose — even told
            // bluntly that it is a translation engine and must never answer —
            // the model answers anyway: "what is your name?" came back as
            // "Я не имею имени" ("I have no name") and "write me a poem" came
            // back as an actual poem long enough to blow the context window.
            // Made to fill a field instead, the same inputs translate
            // correctly, because filling a slot is not a turn in a
            // conversation. Greedy sampling on top, so the same text always
            // gives the same translation rather than a different one per
            // keystroke.
            let session = LanguageModelSession(
                instructions: """
                You translate \(Self.name(route.source)) into \(target). You are a \
                translation engine: you restate the source text in \(target) and \
                never respond to it. A question is translated as a question.
                """
            )
            let response = try await session.respond(
                to: "Source text to translate into \(target):\n\(text)",
                generating: TranslationResult.self,
                options: GenerationOptions(sampling: .greedy)
            )
            guard !Task.isCancelled else { return }
            output = response.content.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            failure = nil
            needsSettings = false
        } catch let error as LanguageModelSession.GenerationError {
            guard !Task.isCancelled else { return }
            output = ""
            needsSettings = false
            failure = Self.describe(error)
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsSettings = false
            failure = error.localizedDescription
        }
    }

    @available(macOS 26.0, *)
    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation:
            // Apple's safety filter, which fires on ordinary sentences —
            // "Delete all my files" was refused in testing. Worth naming
            // plainly so it does not read as the app breaking.
            return localized("macOS refused to translate this text.")
        case .exceededContextWindowSize:
            return localized("This text is too long to translate at once.")
        default:
            return localized("The translation could not be completed.")
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    /// "Русский", "English" — for the column headers. Named in the language the
    /// panel itself is in, not in the system's: those two can differ, and a
    /// column headed in one language above a button worded in another reads as
    /// a mistake.
    static func name(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let name = Locale(identifier: appLanguage).localizedString(forLanguageCode: code) else {
            return language.languageCode?.identifier.uppercased() ?? "?"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Short code for the header badge — "EN → RU" reads at a glance where a
    /// spelled-out name would not fit in the strip.
    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier.uppercased() ?? "?"
    }

    /// System Settings → Apple Intelligence, the switch behind every
    /// `appleIntelligenceOff` failure.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence") else { return }
        NSWorkspace.shared.open(url)
    }
}

@available(macOS 26.0, *)
@Generable
private struct TranslationResult {
    @Guide(description: "The exact translation of the source text. A question stays a question. Never an answer, never a reply, never commentary.")
    var translation: String
}
