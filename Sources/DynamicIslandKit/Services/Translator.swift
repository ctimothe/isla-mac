import AppKit
import Translation

/// Apple's on-device translator, driven from the panel.
///
/// The session is not ours to create: `translationTask` hands one over and owns
/// its lifetime, so everything here is about deciding *what* to translate and
/// holding the result. `TranslatePane` supplies the session.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    /// Both ends are always named. Leaving the source to the framework looks
    /// tempting, but its identifier is a separate asset that is not installed
    /// either — auto-detection fails with `unableToIdentifyLanguage`, and the
    /// translation that follows hangs instead of returning an error.
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

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// The failure is a missing language pack, which is a thing the user can
    /// go and fix — so the pane offers the button that takes them there.
    @Published private(set) var needsDownload = false

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
        needsDownload = false
    }

    func reset() {
        input = ""
        clear()
    }

    func run(_ session: TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }

        // `.installed` is the gate, and it has to stay the gate.
        //
        // Measured, because this looks wrong and invites exactly the wrong
        // fix: attempting a `.supported` pair anyway does not work. On a Mac
        // reporting en→es `.installed` and en→ru `.supported`, the first
        // translates ("hello" → "Hola") and the second fails every time with
        // `TranslationError(cause: .internalError)` — "Unable to Translate",
        // domain Translation.TranslationError code 1, empty userInfo — even
        // though `prepareTranslation()` returns without throwing first. So
        // `.supported` means "will fail", and refusing up front with an
        // actionable message beats surfacing an opaque internal error.
        //
        // The message says asset rather than pack deliberately: macOS can
        // list a language as downloaded under Translation Languages while the
        // framework still has no asset for it, which is what makes this state
        // so confusing to hit.
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            output = ""
            needsDownload = status == .supported
            failure = needsDownload
                ? localized(
                    "macOS has no %@ → %@ translation asset. If it is listed as downloaded, remove it and download it again.",
                    Self.name(source),
                    Self.name(target)
                )
                : localized("macOS does not translate this pair of languages.")
            return
        }

        do {
            let translated = try await translate(text, using: session)
            guard !Task.isCancelled else { return }
            output = translated
            failure = nil
            needsDownload = false
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error is Timeout
                ? localized("Translation timed out.")
                : error.localizedDescription
        }
    }

    private struct Timeout: Error {}

    /// Bounded, because the failure mode being guarded against is a hang
    /// rather than an error: asking for an asset that is not there can put up
    /// a system prompt, and this app is an `.accessory` behind a borderless
    /// panel that never activates, so such a prompt has nowhere to appear and
    /// nothing would ever come back. A translation that has not answered in
    /// this long is treated as one that never will.
    private func translate(_ text: String, using session: TranslationSession) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await session.translate(text).targetText }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Timeout() }
            return first
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

    /// System Settings → General → Language & Region, which is where the
    /// "Translation Languages…" button lives.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
