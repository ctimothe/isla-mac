import Combine
import Foundation

/// An editable, in-memory copy of a local LRC document. Saving always creates
/// an Isla-owned copy; selected-folder files remain untouched.
@MainActor
final class LocalLyricsDraft: ObservableObject {
    @Published var metadata: LocalLyricsMetadata
    @Published var lines: [LyricsStore.Line]
    @Published var offset: TimeInterval

    init(document: LocalLyricsDocument) {
        metadata = document.metadata
        lines = document.lines
        offset = document.offset
    }

    func document() throws -> LocalLyricsDocument {
        let normalizedLines = lines.map { line -> LyricsStore.Line in
            guard !line.words.isEmpty,
                  line.text != line.words.map(\.text).joined(separator: " ")
            else { return line }
            // Editing a word-timed line's text without editing its individual
            // word edges must not export stale words under a new visible line.
            // Retain the edit honestly as line-level timing instead.
            var edited = line
            edited.words = []
            return edited
        }
        // Serialization is deterministic, and parsing it again keeps editor
        // saves subject to the exact same timing validation as imports.
        return try LocalLyricsDocument.parse(
            LocalLyricsDocument(metadata: metadata, lines: normalizedLines, offset: offset).serialize()
        )
    }
}

@MainActor
final class LocalLyricsEditor {
    private let library: LocalLyricsLibrary

    init(library: LocalLyricsLibrary) {
        self.library = library
    }

    func saveOwnedCopy(
        _ draft: LocalLyricsDraft,
        binding: LocalTrackIdentity?
    ) throws -> LocalLyricsCandidate {
        try library.importDocument(draft.document().serialize(), binding: binding)
    }

    func export(_ draft: LocalLyricsDraft, to url: URL) throws {
        let document = try draft.document()
        try Data(document.serialize().utf8).write(to: url, options: .atomic)
    }
}
