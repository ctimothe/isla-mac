import Combine
import Foundation

/// An editable, in-memory copy of a local LRC document. Saving always creates
/// an Isla-owned copy; selected-folder files remain untouched.
@MainActor
final class LocalLyricsDraft: ObservableObject {
    /// One line on screen, with an identity of its own.
    ///
    /// The editor keyed its rows by index and removed them in place, the
    /// SwiftUI pattern that traps when the removed row's field holds focus:
    /// the field's binding reads `lines[index]` after the array has shrunk
    /// under it (J-015). A row's id lives as long as the row, through edits,
    /// inserts and removals around it.
    struct Row: Identifiable, Equatable {
        let id: UUID
        var line: LyricsStore.Line

        init(id: UUID = UUID(), line: LyricsStore.Line) {
            self.id = id
            self.line = line
        }

        /// No words to sing: a pause. Saved as a bare stamp, which the parser
        /// reads as the end of the line before it.
        var isPause: Bool { Self.isPause(line) }

        static func isPause(_ line: LyricsStore.Line) -> Bool {
            line.words.isEmpty && line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Why the draft cannot be saved, by the row that is wrong. `row` is the
    /// row's position on screen counted from zero, the same index
    /// `retime(row:to:)` takes; `message` counts from one, as people do.
    enum ValidationError: Swift.Error, Equatable {
        case row(Int)

        var message: String {
            switch self {
            case .row(let index): localized("Line %d has a time Isla can't use.", index + 1)
            }
        }
    }

    @Published var metadata: LocalLyricsMetadata
    @Published var rows: [Row]
    @Published var offset: TimeInterval

    init(document: LocalLyricsDocument) {
        metadata = document.metadata
        rows = document.lines.map { Row(line: $0) }
        offset = document.offset
    }

    /// The rows' lines in screen order, for code that thinks in lines. A
    /// write keeps each position's id, so editing through it is an edit, not
    /// a new row; only a longer array mints ids for the rows it adds.
    var lines: [LyricsStore.Line] {
        get { rows.map(\.line) }
        set {
            rows = newValue.enumerated().map { index, line in
                Row(id: index < rows.count ? rows[index].id : UUID(), line: line)
            }
        }
    }

    /// A new empty row after `index`, halfway to the row below it, so a
    /// forgotten line goes back where it was forgotten. Add used to append a
    /// second after the last row and nothing could move it. After the last
    /// row there is no halfway, and the second stays.
    func insertLine(after index: Int) {
        guard rows.indices.contains(index) else { return }
        let start = rows[index].line.at
        var at = start + 1
        if index + 1 < rows.count {
            let next = rows[index + 1].line.at
            if next.isFinite, start.isFinite, next > start { at = start + (next - start) / 2 }
        }
        rows.insert(Row(line: LyricsStore.Line(at: at, text: "")), at: index + 1)
    }

    func removeRow(id: UUID) {
        rows.removeAll { $0.id == id }
    }

    /// Moves a row to `time`, and its words and its end with it. The
    /// Timestamp field wrote `line.at` alone, so a word-timed line moved
    /// later left its words before its own start, and the save's re-parse
    /// refused the file as invalid (J-015). A time that is not a number moves
    /// nothing but the stamp, which `validate` then names.
    func retime(row index: Int, to time: TimeInterval) {
        guard rows.indices.contains(index) else { return }
        var line = rows[index].line
        let delta = time - line.at
        line.at = time
        if delta.isFinite {
            line.words = line.words.map { word in
                LyricWord(at: word.at + delta, text: word.text, end: word.end.map { $0 + delta })
            }
            line.end = line.end.map { $0 + delta }
        }
        rows[index].line = line
    }

    /// Every row's time, before anything is written. The writer clamps a
    /// stamp it cannot write — negative, not a number, past 999 minutes — to
    /// one it can, so such a row used to move silently to 0:00 or the end,
    /// and every other failure read "This LRC file is invalid." with no row
    /// named. The first bad row on screen is the one reported.
    func validate() throws {
        let latest = TimeInterval((LocalLyricsDocument.maximumMinutes + 1) * 60)
        for (index, row) in rows.enumerated() {
            let at = row.line.at
            guard at.isFinite, at >= 0, at < latest else { throw ValidationError.row(index) }
        }
    }

    func document() throws -> LocalLyricsDocument {
        try validate()
        // Screen order is the listener's, time order is the file's: a row
        // inserted or retimed out of place is sorted here, ties kept in the
        // order they are shown. `parse` sorts as well (LY-02), but `serialize`
        // decides whether a line's end can be written by looking at the line
        // after it, and that has to be the line after it in time.
        let ordered = rows.enumerated()
            .sorted { ($0.element.line.at, $0.offset) < ($1.element.line.at, $1.offset) }
            .map(\.element)
        var normalizedLines: [LyricsStore.Line] = []
        for row in ordered {
            var line = row.line
            // Joined by nothing, as `parse` builds the line: a word carries its
            // own spaces. Joined with a space, every character-timed Chinese
            // line ('我爱你' against '我 爱 你') looked edited, and a Save Copy
            // that changed nothing stripped its karaoke.
            if !line.words.isEmpty, line.text != line.words.map(\.text).joined() {
                // Editing a word-timed line's text without editing its
                // individual word edges must not export stale words under a
                // new visible line. Retain the edit honestly as line-level
                // timing instead.
                line.words = []
            }
            // Asked after the words are dropped: a word-timed line whose text
            // was cleared is a pause as much as a row added blank.
            if Row.isPause(line) {
                // A pause the listener placed ends the line before it, even
                // where the file gave that line an end of its own: the editor
                // does not show ends, and a pause written after one is a
                // second stamp in the same gap, which `parse` ignores.
                if !normalizedLines.isEmpty { normalizedLines[normalizedLines.count - 1].end = nil }
                line.text = ""
                line.end = nil
            }
            normalizedLines.append(line)
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
    /// What Edit was pressed on, fixed at the press: the document, the song it
    /// will be bound to, and that song's name for the sheet's header.
    ///
    /// The sheet read the coordinator's current identity every time its
    /// parent redrew, so when the playlist moved on while the editor was up,
    /// Save Copy bound song A's edit to song B and B showed A's words, with
    /// nothing in the sheet naming either song (J-009).
    struct EditingSession: Identifiable {
        /// A fresh id per press, so editing the same document twice opens a
        /// fresh sheet with a fresh draft.
        let id = UUID()
        let candidate: LocalLyricsCandidate
        let identity: LocalTrackIdentity?
        /// The song's name as the player gave it, or the file's own title
        /// when nothing was playing; nil when neither says.
        let title: String?

        /// A session on an empty document for this song: the editor for a bound
        /// file Isla could not read, where there is no document to open it on
        /// (`Lyrics-Invalid-File`'s Edit Lyrics…). The song's own tags seed the
        /// metadata and a single empty row waits to be typed into; saving writes
        /// an Isla-owned copy bound to the song, which replaces the broken
        /// binding the way any saved edit does. The candidate's id is a fresh one
        /// that names nothing the library holds, so the copy records no source.
        static func blank(identity: LocalTrackIdentity?) -> EditingSession {
            let document = LocalLyricsDocument(
                metadata: LocalLyricsMetadata(
                    title: identity?.title, artist: identity?.artist, album: identity?.album,
                    version: nil, duration: identity.map(\.duration)
                ),
                lines: [LyricsStore.Line(at: 0, text: "")],
                offset: 0
            )
            return EditingSession(
                candidate: LocalLyricsCandidate(id: UUID(), document: document, origin: .imported),
                identity: identity
            )
        }

        init(candidate: LocalLyricsCandidate, identity: LocalTrackIdentity?) {
            self.candidate = candidate
            self.identity = identity
            let named = [identity?.title, candidate.document.metadata.title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            title = named
        }
    }

    private let library: LocalLyricsLibrary

    init(library: LocalLyricsLibrary) {
        self.library = library
    }

    func saveOwnedCopy(
        _ draft: LocalLyricsDraft,
        editedFrom source: UUID?,
        binding: LocalTrackIdentity?
    ) throws -> LocalLyricsCandidate {
        try library.importDocument(draft.document().serialize(), binding: binding, editedFrom: source)
    }

    /// Saves the copy against the session's song and source, never against
    /// whatever happens to be playing now.
    func saveOwnedCopy(_ draft: LocalLyricsDraft, for session: EditingSession) throws -> LocalLyricsCandidate {
        try saveOwnedCopy(draft, editedFrom: session.candidate.id, binding: session.identity)
    }

    func export(_ draft: LocalLyricsDraft, to url: URL) throws {
        let document = try draft.document()
        try Data(document.serialize().utf8).write(to: url, options: .atomic)
    }
}
