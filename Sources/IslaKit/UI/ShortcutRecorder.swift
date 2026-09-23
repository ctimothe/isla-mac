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
    let symbol: String
    @ObservedObject var center: HotKeyCenter
    @Binding var wantsKeyboard: Bool

    @State private var leaving = false

    private var isRecording: Bool { center.recording == action }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .islandFont(.body)
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(action.title)
                .islandFont(.body)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Button(action: toggleRecording) {
                Text(wellText)
                    .font(Theme.TypeRole.body.font())
                    .foregroundStyle(isRecording || center.bindings[action] == nil ? Theme.tertiary : .white)
                    .frame(minWidth: 64)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? Theme.surfaceHover : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isRecording ? Theme.secondary : Theme.hairline, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(PanelButtonStyle())
            .accessibilityLabel(action.title)
            .accessibilityValue(wellText)
            .accessibilityHint(localized("Records a new shortcut. Press Delete to clear it, Escape to cancel."))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
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
