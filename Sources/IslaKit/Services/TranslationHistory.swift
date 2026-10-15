import Foundation

/// The Translate tab's History (redesign 2026-10-15, spec §11): the last 20
/// translations, newest first, in memory.
///
/// **Memory only, on purpose.** What somebody translates is what they are
/// reading or writing, and keeping it is a choice — Keep History is off until
/// it is turned on (`NotchViewModel.translateKeepHistoryKey`), and even then the
/// list lives and dies with the process, like the Clipboard's. There is no
/// file, no defaults key and no export here: the type takes no URL and no
/// `UserDefaults`, and `TranslationHistoryTests` holds that nothing reaches the
/// disk. Turning Keep History off empties it
/// (`NotchViewModel.setTranslateKeepHistory`) — a person who switches the
/// feature off expects the record to go with it.
@MainActor
final class TranslationHistory: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        /// The text as it was translated (trimmed).
        var source: String
        var result: String
        /// The pair the text went along; a detected source is stored as the
        /// language it was detected as, so restoring it names a real choice.
        var from: TranslationLanguage
        var to: TranslationLanguage
        /// Which engine answered, so a restored online answer still says it left
        /// the Mac.
        var engine: Translator.Engine
        var date: Date

        /// "EN → RU": the two base codes, upper case. The board's 10.5 pt
        /// tertiary label. Written out rather than looked up: codes and an arrow
        /// read the same in every language, and a table row whose Russian is its
        /// own key is what the localization gate rejects as untranslated.
        var pairLabel: String {
            "\(from.baseCode.uppercased()) → \(to.baseCode.uppercased())"
        }
    }

    /// The most entries kept (spec §11).
    static let capacity = 20

    @Published private(set) var entries: [Entry] = []

    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Adds an answer at the top. The same text on the same pair is the same
    /// translation asked twice — a Retry, a swap and back — and takes the old
    /// entry's place rather than listing itself twice, so twenty slots hold
    /// twenty different sentences.
    func record(source: String, result: String, from: TranslationLanguage, to: TranslationLanguage, engine: Translator.Engine) {
        entries.removeAll { $0.source == source && $0.from == from && $0.to == to }
        entries.insert(
            Entry(id: UUID(), source: source, result: result, from: from, to: to, engine: engine, date: now()),
            at: 0
        )
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
    }
}
