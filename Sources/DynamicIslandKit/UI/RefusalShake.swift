import SwiftUI

/// A short damped wobble, played once per trigger.
///
/// The vocabulary is deliberately the one macOS already uses for "that is not
/// going to work": the sideways shudder the login window gives a wrong
/// password. It says *refused* rather than *broken*, and it says it without a
/// label, a sound, or anything that could be mistaken for the panel beginning
/// to open.
struct RefusalShake: ViewModifier {
    /// Increment to play it again.
    var trigger: Int
    /// Sideways travel at the first swing. Was 7, which on a 32pt pill at the
    /// top of a locked screen was too small to register as a refusal — it read
    /// as a rendering wobble, if it read at all.
    var amplitude: CGFloat = 11
    /// Full swings. Three reads as a shake; more reads as a wobble toy.
    var shakes: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(ShakeOffset(progress: progress, amplitude: amplitude, shakes: shakes))
            .onChange(of: trigger) { _, _ in
                // Motion is the whole message here, so with Reduce Motion on
                // there is nothing honest to substitute — a colour flash would
                // be a different statement. It simply does not play.
                guard !reduceMotion else { return }
                progress = 0
                withAnimation(.easeOut(duration: 0.50)) { progress = 1 }
            }
    }
}

/// Decaying sine, so the last swing is the smallest and it settles at zero
/// rather than stopping mid-travel.
private struct ShakeOffset: GeometryEffect {
    var progress: CGFloat
    var amplitude: CGFloat
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard progress > 0, progress < 1 else { return ProjectionTransform(.identity) }
        let decay = 1 - progress
        let offset = amplitude * decay * sin(progress * .pi * 2 * shakes)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

extension View {
    /// Plays a refusal wobble whenever `trigger` changes.
    func refusalShake(trigger: Int) -> some View {
        modifier(RefusalShake(trigger: trigger))
    }
}
