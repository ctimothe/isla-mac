import SwiftUI

/// A transport symbol: white, bare, pressed by dimming rather than by a well
/// lighting up behind it.
///
/// Shared by the island and the lock card. They had two different answers —
/// a filled disc under the island's play button, nothing under the card's —
/// which is the sort of difference nobody can name but everybody feels.
struct TransportGlyphStyle: ButtonStyle {
    var size: CGFloat = 30
    /// Nil is a square target. The lyrics stage's wells are 32 / 34 wide and
    /// 30 tall, and its hit targets stay what they were.
    var height: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: size, height: height ?? size)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}

/// A row in the output picker: no fill until the pointer is on it, then the
/// faint one macOS uses for a highlighted menu row.
///
/// Not `.plain`, which gives no hover at all, and not a permanent background,
/// which turns a list into a stack of buttons. The list should read as text
/// until it is being pointed at.
struct OutputRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.10 : 0)))
            )
            .padding(.horizontal, 8)
            .onHover { hovering = $0 }
            .animation(Theme.contentAnimation, value: hovering)
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}
