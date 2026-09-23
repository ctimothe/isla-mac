import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One shortcut in Settings: what it does, and a well that shows the keys. A
/// click on the well records the next combination, the way the shortcut
/// fields in System Settings → Keyboard do.
///
/// Recording needs key presses, and this panel never takes the keyboard on
/// its own. So a recording asks for it through the same `wantsKeyboard` claim
/// the Translate field uses, and gives it back when the recording ends. That
/// covers a key, Esc, the panel losing key status, and the row going away.
struct ShortcutRecorderRow: View {
    let action: HotKeyAction
    let symbol: String
    @ObservedObject var center: HotKeyCenter
    @Binding var wantsKeyboard: Bool

    @State private var monitor: Any?

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
        .onChange(of: wantsKeyboard) { _, wants in
            // Clicking into another app takes the keyboard away, and a
            // recording without the keyboard would wait forever.
            if !wants, isRecording { stopRecording() }
        }
        .onDisappear { if isRecording { stopRecording() } }
    }

    private var wellText: String {
        if isRecording { return localized("Type Shortcut") }
        return center.bindings[action]?.displayString ?? localized("None")
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        // One recording at a time. Starting a second one ends the first.
        if center.recording != nil { center.endRecording() }
        center.beginRecording(action)
        wantsKeyboard = true
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            // Every press is swallowed while recording, so none of them reaches
            // the panel's own Esc handling or types into anything.
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.intersection([.command, .control, .option]).isEmpty
        if plain, Int(event.keyCode) == kVK_Escape {
            stopRecording()
        } else if plain, Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            center.setBinding(nil, for: action)
            stopRecording()
        } else if let binding = HotKeyBinding(keyCode: event.keyCode, flags: flags) {
            center.setBinding(binding, for: action)
            stopRecording()
        } else {
            // A key with no ⌘, ⌃ or ⌥. Say no and keep listening, the way
            // System Settings' own shortcut fields do.
            NSSound.beep()
        }
    }

    private func stopRecording() {
        removeMonitor()
        center.endRecording()
        wantsKeyboard = false
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
