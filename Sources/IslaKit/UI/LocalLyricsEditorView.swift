import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A compact, listener-controlled editor for an owned LRC copy. It deliberately
/// does not expose a referenced folder file for in-place editing.
struct LocalLyricsEditorView: View {
    @StateObject private var draft: LocalLyricsDraft
    private let editor: LocalLyricsEditor
    private let binding: LocalTrackIdentity?
    private let onSaved: (LocalLyricsCandidate) -> Void
    private let onDismiss: () -> Void

    @State private var errorMessage: String?

    init(
        document: LocalLyricsDocument,
        editor: LocalLyricsEditor,
        binding: LocalTrackIdentity?,
        onSaved: @escaping (LocalLyricsCandidate) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _draft = StateObject(wrappedValue: LocalLyricsDraft(document: document))
        self.editor = editor
        self.binding = binding
        self.onSaved = onSaved
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localized("Edit Lyrics"))
                    .islandFont(.title, weight: .semibold)
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
                    ForEach(draft.lines.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            TextField(
                                localized("Timestamp"),
                                value: $draft.lines[index].at,
                                format: .number.precision(.fractionLength(2))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 74)
                            .accessibilityLabel(localized("Timestamp"))
                            TextField(localized("Lyrics"), text: $draft.lines[index].text, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                                .accessibilityLabel(localized("Lyrics"))
                            Button { draft.lines.remove(at: index) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(NotchButtonStyle(size: 22))
                            .disabled(draft.lines.count == 1)
                            .accessibilityLabel(localized("Remove Lyric Line"))
                        }
                    }
                    Button {
                        let timestamp = (draft.lines.last?.at ?? 0) + 1
                        draft.lines.append(LyricsStore.Line(at: timestamp, text: ""))
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

            HStack {
                Button(localized("Cancel"), action: onDismiss)
                    .buttonStyle(NotchButtonStyle(size: 24))
                    // The sheet is a real modal window, so Escape reaches it —
                    // and without this it did nothing, while Escape on the panel
                    // behind closes the whole island.
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(localized("Cancel"))
                Spacer()
                Button(localized("Export LRC"), action: export)
                    .buttonStyle(NotchButtonStyle(size: 76))
                    .accessibilityLabel(localized("Export LRC"))
                Button(localized("Save Copy"), action: save)
                    .buttonStyle(NotchButtonStyle(size: 72, prominent: true))
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

    private func save() {
        do {
            let saved = try editor.saveOwnedCopy(draft, binding: binding)
            onSaved(saved)
        } catch {
            errorMessage = localized("This LRC file is invalid.")
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
        } catch {
            errorMessage = localized("This LRC file is invalid.")
        }
    }
}
