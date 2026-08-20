import SwiftUI

/// Raises a flag and lowers it again a moment later.
///
/// The moment is 1.1 s everywhere in the panel, and it is a compromise between
/// two failures: shorter and the checkmark is gone before the eye returns from
/// wherever the copy was going, longer and a second copy lands while the first
/// is still being confirmed, so the tick never appears to move.
@MainActor
func flash(_ flag: Binding<Bool>) {
    flag.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
        flag.wrappedValue = false
    }
}

/// Copies, then says so.
///
/// The panel has no other way to confirm a copy: the pasteboard is invisible,
/// and the thing that was copied is usually going somewhere the panel cannot
/// see. Turning the icon into a tick for a moment is the whole feedback, which
/// is why it is worth having in one place rather than four.
struct CopyButton: View {
    let copy: () -> Void

    @State private var copied = false

    var body: some View {
        Button {
            copy()
            flash($copied)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Theme.secondary)
        }
        .buttonStyle(.plain)
        .help(localized("Copy"))
        .animation(Theme.contentAnimation, value: copied)
    }
}

/// A destructive action that asks before it acts.
///
/// Two presses rather than a dialog. This panel never activates and hangs off
/// the top edge of the screen: a sheet would either fail to take focus or
/// cover the very thing being confirmed. Arming in place keeps the question
/// where the answer is, and walking away is the safe outcome — the arming
/// lapses on its own, so the dangerous state is never the resting one.
struct ConfirmTextButton: View {
    let title: String
    let armedTitle: String
    let action: () -> Void

    @State private var armed = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            disarm?.cancel()
            if armed {
                armed = false
                action()
            } else {
                armed = true
                disarm = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    armed = false
                }
            }
        } label: {
            Text(armed ? armedTitle : title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(armed ? Theme.danger : Theme.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(armed ? armedTitle : title)
        .accessibilityHint(armed ? "" : localized("Asks for confirmation before acting."))
        .animation(Theme.contentAnimation, value: armed)
        .onDisappear { disarm?.cancel() }
    }
}

/// The settings-row shape of `ConfirmTextButton`.
struct ConfirmRow: View {
    let symbol: String
    let title: String
    let armedTitle: String
    var disabled = false
    let action: () -> Void

    @State private var armed = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            disarm?.cancel()
            if armed {
                armed = false
                action()
            } else {
                armed = true
                disarm = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    armed = false
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: armed ? "exclamationmark.triangle.fill" : symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(armed ? Theme.danger : Theme.secondary)
                    .frame(width: 16)
                Text(armed ? armedTitle : title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(armed ? Theme.danger : .white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(armed ? armedTitle : title)
        .accessibilityHint(armed ? "" : localized("Asks for confirmation before acting."))
        .animation(Theme.contentAnimation, value: armed)
        .onDisappear { disarm?.cancel() }
    }
}
