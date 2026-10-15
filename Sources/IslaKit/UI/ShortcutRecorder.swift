import AppKit
import SwiftUI

/// One shortcut in Settings: what it does, and a well that shows the keys. A
/// click on the well records the next combination, the way the shortcut
/// fields in System Settings → Keyboard do.
///
/// The row only starts and stops recordings. The key monitor and what each
/// key means belong to `HotKeyCenter`, so there is only ever one monitor,
/// whichever row started it. Recording needs key presses, and this panel
/// never takes the keyboard on its own. So a recording asks for it through
/// the `wantsKeyboard` claim the Translate field uses, and the row gives it
/// back when its recording ends while the row is still on screen. A row that
/// is leaving, for Translate, which wants the keyboard too, leaves the claim
/// to the tab change.
struct ShortcutRecorderRow: View {
    let action: HotKeyAction
    @ObservedObject var center: HotKeyCenter
    @Binding var wantsKeyboard: Bool

    @State private var leaving = false

    private var isRecording: Bool { center.recording == action }

    /// The well is 96 pt (spec §10): wide enough for the longest combination
    /// the three defaults make, ⌃⌥⌘ and a letter, and for "Type Shortcut" in
    /// Russian, and the same width recording as at rest so the row never moves.
    static let wellWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 8) {
            // Hidden: the well below carries this title as its own name, so
            // VoiceOver read the row's name twice, once as text and once on the
            // control it belongs to (H-009).
            Text(action.title)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Button(action: toggleRecording) {
                Text(wellText)
                    .font(Theme.TypeRole.body.font())
                    .foregroundStyle(isRecording || center.bindings[action] == nil ? Theme.tertiary : .white)
                    .lineLimit(1)
                    .frame(width: Self.wellWidth, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? Theme.recordingFill : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isRecording ? Theme.accent : Theme.hairline,
                                lineWidth: isRecording ? Theme.recordingRingWidth : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(PanelButtonStyle())
            .accessibilityLabel(action.title)
            .accessibilityValue(wellText)
            // No hint: the one instruction sits under the three recorders as a
            // footnote (`SettingsTable`), and the same sentence on each of them
            // had VoiceOver read it four times down the section.
        }
        .padding(.horizontal, SettingsLayout.rowInset)
        .frame(minHeight: SettingsLayout.rowHeight)
        .onAppear { leaving = false }
        .onChange(of: center.recording) { old, new in
            // This row's recording ended with the row still here: the keyboard
            // goes back. Not when another row took the recording over, which
            // holds the keyboard itself.
            if old == action, new == nil, !leaving { wantsKeyboard = false }
        }
        .onChange(of: wantsKeyboard) { _, wants in
            // Clicking into another app takes the keyboard away, and a
            // recording without the keyboard would wait forever.
            if !wants, isRecording { center.endRecording() }
        }
        .onDisappear {
            leaving = true
            if isRecording { center.endRecording() }
        }
    }

    private var wellText: String {
        if isRecording { return localized("Type Shortcut") }
        return center.bindings[action]?.displayString ?? localized("None")
    }

    private func toggleRecording() {
        if isRecording {
            center.endRecording()
        } else {
            center.beginRecording(action)
            wantsKeyboard = true
        }
    }
}
