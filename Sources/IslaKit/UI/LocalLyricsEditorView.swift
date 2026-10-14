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

    /// The sheet, laid out as the Mac form the board draws (spec §5.5,
    /// `Lyrics-Editor`): 420 × 352 on `#2A2A2C`, the title at the top, a
    /// "Lyrics Metadata" group of four labelled fields in two columns, the timed
    /// lines as rows — a 74 pt monospaced time, the words, round Insert After and
    /// Remove buttons — Add Lyric Line under them, a hairline, and the footer:
    /// Export LRC… at the leading edge, Cancel and Save Copy (the default, in
    /// the accent) at the trailing one. Only the layout changed; the draft, the
    /// validation, the save and the export are what they were.
    static let size = CGSize(width: 420, height: 352)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .islandFont(13, weight: .semibold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 16)

            Text(localized("Lyrics Metadata"))
                .islandFont(.body, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .padding(.top, 14)
            metadataFields
                .padding(.top, 6)

            Text(localized("Local Lyrics"))
                .islandFont(.body, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .padding(.top, 14)

            // Keyed by each row's own id, never by index: removing a row whose
            // field held focus read `lines[index]` past the end of an array that
            // had just shrunk (J-015).
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($draft.rows) { $row in
                        HStack(alignment: .top, spacing: 6) {
                            TextField(
                                localized("Timestamp"),
                                value: timestamp(of: row.id),
                                format: .number.precision(.fractionLength(2))
                            )
                            .editorField(monospaced: true)
                            .frame(width: 74)
                            .accessibilityLabel(localized("Timestamp"))
                            // An empty row is a pause — it saves as the end of
                            // the line above it — and says so instead of showing
                            // an empty field that looks like a slip.
                            TextField(localized("Pause"), text: $row.line.text, axis: .vertical)
                                .editorField()
                                .lineLimit(1...3)
                                .frame(width: 236)
                                .accessibilityLabel(localized("Lyrics"))
                            Spacer(minLength: 0)
                            circleTool(symbol: "plus", label: localized("Insert Line After")) { insertLine(after: row.id) }
                            circleTool(symbol: "minus", label: localized("Remove Lyric Line")) { draft.removeRow(id: row.id) }
                                .disabled(draft.rows.count == 1)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 116)
            .padding(.top, 6)

            HStack(spacing: 10) {
                Button {
                    draft.insertLine(after: draft.rows.count - 1)
                } label: {
                    Label(localized("Add Lyric Line"), systemImage: "plus.circle")
                }
                .buttonStyle(OfferButtonStyle(horizontalPadding: 10, fixedHeight: 22))
                .accessibilityLabel(localized("Add Lyric Line"))
                if let errorMessage {
                    Text(errorMessage)
                        .islandFont(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(errorMessage)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, -20)
                .padding(.bottom, 13)

            // Words in capsules, the panel's one offer style. These were
            // `NotchButtonStyle`, the circular glyph style, which frames its
            // label in a size-by-size circle: "Cancel" truncated inside 24 pt
            // and "Сохранить копию" wrapped inside a filled 72 pt disc (G-012).
            // Save Copy is the default action, in the accent.
            HStack(spacing: 8) {
                // Each at the width its words need, on one line.
                Button(localized("Export LRC"), action: export)
                    .buttonStyle(OfferButtonStyle(horizontalPadding: 10, fixedHeight: 24))
                    .fixedSize()
                    .accessibilityLabel(localized("Export LRC"))
                Spacer(minLength: 8)
                Button(localized("Cancel"), action: onDismiss)
                    .buttonStyle(OfferButtonStyle(horizontalPadding: 10, fixedHeight: 24))
                    .fixedSize()
                    // The sheet is a real modal window, so Escape reaches it —
                    // and without this it did nothing, while Escape on the panel
                    // behind closes the whole island.
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(localized("Cancel"))
                Button(localized("Save Copy"), action: save)
                    .buttonStyle(OfferButtonStyle(fill: Theme.accent, horizontalPadding: 10, fixedHeight: 24))
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(localized("Save Copy"))
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.sheetFill)
    }

    /// Title, Artist / Album, Duration: two columns of a right-aligned label
    /// 56 wide and a 124 wide field (the board's grid). Version is still in the
    /// document and is kept on save; the form draws the four the board names.
    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                metadataField(localized("Title"), value: $draft.metadata.title)
                metadataField(localized("Artist"), value: $draft.metadata.artist)
            }
            HStack(spacing: 14) {
                metadataField(localized("Album"), value: $draft.metadata.album)
                metadataLabelled(localized("Duration")) {
                    TextField(
                        localized("Duration"),
                        value: Binding(
                            get: { draft.metadata.duration ?? 0 },
                            set: { draft.metadata.duration = $0 > 0 ? $0 : nil }
                        ),
                        format: .number.precision(.fractionLength(2))
                    )
                    .editorField()
                    .accessibilityLabel(localized("Duration"))
                }
            }
        }
    }

    private func metadataLabelled<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
            field()
                .frame(width: 124)
        }
    }

    private func metadataField(_ label: String, value: Binding<String?>) -> some View {
        metadataLabelled(label) {
            TextField(label, text: Binding(
                get: { value.wrappedValue ?? "" },
                set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
            ))
            .editorField()
            .accessibilityLabel(label)
        }
    }

    /// A 22 pt round button, white 0.08 under a 9 pt secondary glyph: Insert Line
    /// After (+) and Remove Lyric Line (−).
    private func circleTool(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.editorFieldFill))
                .contentShape(Circle())
        }
        .buttonStyle(PanelButtonStyle())
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

// MARK: - The form's fields

private extension View {
    /// The board's text field: 22 tall, radius 6, white 0.06 with a hairline
    /// inset, 12 pt — `.monospaced` for a time (spec §2.2).
    func editorField(monospaced: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12, weight: .regular, design: monospaced ? .monospaced : .default))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.editorFieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.editorFieldEdge, lineWidth: 0.5)
            )
    }
}
