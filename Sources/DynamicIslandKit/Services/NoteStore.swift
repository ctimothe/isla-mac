import AppKit

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var edited: Date
}

/// Scratch notes: somewhere to put a thought down for an hour.
///
/// Deliberately not a notes app. No folders, no formatting, no search — for
/// that there are real editors. This replaces the unsaved buffer people keep
/// in one: a phone number from a call, half a link, a thought to come back to
/// — written fast, then deleted or carried off through the clipboard.
///
/// Everything here is shaped by that shortness of life: notes are created
/// empty and instantly, deleted in one click, and the blank ones sweep
/// themselves out when the tab is left. The file they live in is an
/// implementation detail — unlike the snippets file, nobody is expected to
/// edit it by hand.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    /// Which note the editor shows. Lives here rather than in the pane so the
    /// choice survives the pane being unmounted with the panel.
    @Published var selected: Note.ID?
    /// True when the file exists but cannot be parsed — a hand edit, or
    /// something else, left it broken. Writing is forbidden in that state,
    /// same as `SnippetStore`: a debounced `persist()` that fired against a
    /// corrupted file would otherwise overwrite it with whatever happened to
    /// be in memory (#7).
    @Published private(set) var fileBroken = false

    private let fileURL: URL

    private let saves = DebouncedWrite()

    init(fileURL: URL = AppPaths.live.supportFile("notes.json")) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Editing

    /// A new empty note, selected and ready to type into. Newest on top, and
    /// the order never changes afterwards: a list that reshuffles itself on
    /// every edit loses the reader's place for tidiness nobody asked for.
    func add() {
        let note = Note(id: UUID(), text: "", edited: Date())
        notes.insert(note, at: 0)
        selected = note.id
        scheduleSave()
    }

    func update(_ id: Note.ID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        notes[index].edited = Date()
        scheduleSave()
    }

    func remove(_ id: Note.ID) {
        notes.removeAll { $0.id == id }
        if selected == id { selected = notes.first?.id }
        scheduleSave()
    }

    /// Called when the user leaves the tab: notes that never got any text
    /// sweep themselves out. They cost one hover to recreate, and a trail of
    /// blank cards is exactly the clutter a scratchpad exists to avoid.
    func leave() {
        notes.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let selected, !notes.contains(where: { $0.id == selected }) {
            self.selected = notes.first?.id
        }
        flush()
    }

    // MARK: - Persistence

    private func load() {
        // No file is an honest empty list — first launch — and not corruption.
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            notes = try JSONDecoder().decode([Note].self, from: data)
            selected = notes.first?.id
        } catch {
            // The file exists and says something — it just cannot be read.
            // Raise the flag so persist() refuses to write over it.
            fileBroken = true
            NSLog("Dynamic Island: notes.json is not readable: \(error.localizedDescription)")
        }
    }

    /// A moment after the typing pauses, not on every keystroke: the text
    /// lives in memory either way, and the file only has to be right by the
    /// time somebody could read it.
    private func scheduleSave() {
        saves.schedule { [weak self] in self?.persist() }
    }

    func flush() { saves.flush() }

    private func persist() {
        guard !fileBroken else { return }
        do {
            try JSONEncoder().encode(notes).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Dynamic Island: cannot write notes.json: \(error.localizedDescription)")
        }
    }
}
