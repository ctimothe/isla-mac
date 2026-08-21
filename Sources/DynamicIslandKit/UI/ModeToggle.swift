import SwiftUI

/// Shuffle and repeat, drawn the one way.
///
/// These were white-when-on and grey-when-off, which is the same difference as
/// between an enabled and a disabled control and read as neither. The system's
/// own players mark an engaged mode with the accent colour and a dot beneath
/// it — a mark that survives a glance and cannot be confused with "dimmed".
/// One view so the island and the lock card cannot drift apart on it.
struct ModeToggle: View {
    let symbol: String
    let isOn: Bool
    var accent: Color = .white
    var size: CGFloat = 24
    var glyphSize: CGFloat = 13
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(isOn ? accent : Theme.tertiary)
                Circle()
                    .fill(isOn ? accent : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.contentAnimation, value: isOn)
    }
}
