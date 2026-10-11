import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A compact, listener-controlled editor for an owned LRC copy. It deliberately
/// does not expose a referenced folder file for in-place editing.
struct LocalLyricsEditorView: View {
    @StateObject private var draft: LocalLyricsDraft
    private let editor: LocalLyricsEditor
    /// The document, the song the copy will be bound to and that song's
    /// name, all fixed when Edit was pressed. The source document's id is
    /// recorded on the copy so the library can tell an edit from an
    /// unrelated file with the same tags.
    private let session: LocalLyricsEditor.EditingSession
    private let onSaved: (LocalLyricsCandidate) -> Void
    private let onDismiss: () -> Void

    @State private var errorMessage: String?

    init(
        session: LocalLyricsEditor.EditingSession,
        editor: LocalLyricsEditor,
        onSaved: @escaping (LocalLyricsCandidate) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _draft = StateObject(wrappedValue: LocalLyricsDraft(document: session.candidate.document))
        self.editor = editor
        self.session = session
        self.onSaved = onSaved
        self.onDismiss = onDismiss
    }

    /// Names the song the save will be bound to. Nothing in the sheet said
    /// which song it was editing, so a track change underneath it went
    /// unnoticed until the wrong song showed the edited words (J-009).
    private var heading: String {
        guard let title = session.title else { return localized("Edit Lyrics") }
        return localized("Edit Lyrics for %@", title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(heading)
                    .islandFont(.title, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .islandFont(.caption, weight: .semibold)
                }
                .buttonStyle(NotchButtonStyle(size: 24))
                .accessibilityLabel(localized("Cancel"))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Lyrics Metadata"))
                        .islandFont(.caption, weight: .semibold)
                        .foregroundStyle(Theme.tertiary)
                    metadataFields

                    Text(localized("Local Lyrics"))
                        .islandFont(.caption, weight: .semibold)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 4)
                    // Keyed by each row's own id, never by index: removing a
                    // row whose field held focus read `lines[index]` past the
                    // end of an array that had just shrunk (J-015).
                    ForEach($draft.rows) { $row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            TextField(
                                localized("Timestamp"),
                                value: timestamp(of: row.id),
                                format: .number.precision(.fractionLength(2))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 74)
                            .accessibilityLabel(localized("Timestamp"))
                            // An empty row is a pause — it saves as the end of
                            // the line above it — and says so instead of
                            // showing an empty field that looks like a slip.
                            TextField(localized("Pause"), text: $row.line.text, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                                .accessibilityLabel(localized("Lyrics"))
                            Button { insertLine(after: row.id) } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(NotchButtonStyle(size: 22))
                            .accessibilityLabel(localized("Insert Line After"))
                            Button { draft.removeRow(id: row.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(NotchButtonStyle(size: 22))
                            .disabled(draft.rows.count == 1)
                            .accessibilityLabel(localized("Remove Lyric Line"))
                        }
                    }
                    Button {
                        draft.insertLine(after: draft.rows.count - 1)
                    } label: {
                        Label(localized("Add Lyric Line"), systemImage: "plus.circle")
                            .islandFont(.caption, weight: .medium)
                    }
                    .buttonStyle(PanelButtonStyle())
                    .accessibilityLabel(localized("Add Lyric Line"))
                }
                .padding(.vertical, 2)
            }

            if let errorMessage {
                Text(errorMessage)
                    .islandFont(.caption)
                    .foregroundStyle(Theme.danger)
                    .accessibilityLabel(errorMessage)
            }

            // Words in capsules, the panel's one offer style. These were
            // `NotchButtonStyle`, the circular glyph style, which frames its
            // label in a size-by-size circle: "Cancel" truncated inside 24 pt
            // and "Сохранить копию" wrapped inside a filled 72 pt disc (G-012).
            // Save Copy is the default action and sits one step brighter, as
            // the welcome page's primary does.
            HStack(spacing: 8) {
                Button(localized("Cancel"), action: onDismiss)
                    .buttonStyle(OfferButtonStyle())
                    .fixedSize()
                    // The sheet is a real modal window, so Escape reaches it —
                    // and without this it did nothing, while Escape on the panel
                    // behind closes the whole island.
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(localized("Cancel"))
                Spacer()
                // Each at the width its words need, on one line: the sheet
                // widens for "Экспортировать LRC" rather than squeezing it.
                Button(localized("Export LRC"), action: export)
                    .buttonStyle(OfferButtonStyle())
                    .fixedSize()
                    .accessibilityLabel(localized("Export LRC"))
                Button(localized("Save Copy"), action: save)
                    .buttonStyle(OfferButtonStyle(fill: Theme.surfaceHover))
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(localized("Save Copy"))
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 340)
        .background(Theme.surface)
    }

    private var metadataFields: some View {
        VStack(spacing: 8) {
            metadataField(localized("Title"), value: $draft.metadata.title)
            metadataField(localized("Artist"), value: $draft.metadata.artist)
            metadataField(localized("Album"), value: $draft.metadata.album)
            metadataField(localized("Version"), value: $draft.metadata.version)
            TextField(
                localized("Duration"),
                value: Binding(
                    get: { draft.metadata.duration ?? 0 },
                    set: { draft.metadata.duration = $0 > 0 ? $0 : nil }
                ),
                format: .number.precision(.fractionLength(2))
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(localized("Duration"))
        }
    }

    private func metadataField(_ label: String, value: Binding<String?>) -> some View {
        TextField(label, text: Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        ))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(label)
    }

    /// The Timestamp field's binding: a write is a retime, which moves the
    /// row's words and end with it. Looked up by id at the moment of the
    /// write, so a field committing after its row moved still edits its own.
    private func timestamp(of id: UUID) -> Binding<TimeInterval> {
        Binding(
            get: { draft.rows.first { $0.id == id }?.line.at ?? 0 },
            set: { time in
                guard let index = draft.rows.firstIndex(where: { $0.id == id }) else { return }
                draft.retime(row: index, to: time)
            }
        )
    }

    private func insertLine(after id: UUID) {
        guard let index = draft.rows.firstIndex(where: { $0.id == id }) else { return }
        draft.insertLine(after: index)
    }

    /// A row Isla cannot write is named by its line number; anything else
    /// the save refuses keeps the general message.
    private func failureMessage(for error: Error) -> String {
        (error as? LocalLyricsDraft.ValidationError)?.message ?? localized("This LRC file is invalid.")
    }

    private func save() {
        do {
            let saved = try editor.saveOwnedCopy(draft, for: session)
            onSaved(saved)
        } catch {
            errorMessage = failureMessage(for: error)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        // A registry lookup, not a constant: `.lrc` is usually claimed by some
        // app, but a Mac where nothing has ever registered it returns nil, and
        // a save panel is no place to crash.
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.nameFieldStringValue = "lyrics.lrc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try editor.export(draft, to: url)
            errorMessage = nil
        } catch {
            errorMessage = failureMessage(for: error)
        }
    }
}
