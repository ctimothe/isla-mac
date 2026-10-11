import SwiftUI

/// A short damped wobble, played once per trigger.
///
/// The vocabulary is deliberately the one macOS already uses for "that is not
/// going to work": the sideways shudder the login window gives a wrong
/// password. It says *refused* rather than *broken*, and it says it without a
/// label, a sound, or anything that could be mistaken for the panel beginning
/// to open.
///
/// Time-driven, not transaction-driven. It used to be a `withAnimation` on a
/// progress value, and the locked branch of `NotchContentView` ends in
/// `.transaction { $0.animation = nil }` — which wipes any animation written
/// beneath it, so the shake almost certainly never played; and from a resting
/// progress of 1, writing 0 and animating back to 1 in one pass nets no change,
/// so a second click could not replay it either (F-018). Here the offset is a
/// function of the seconds since the last trigger, drawn by a `TimelineView`,
/// so no `Animation` is involved for that transaction to cancel — and the nil
/// transaction stays, because it is what keeps the lock itself a cut.
struct RefusalShake: ViewModifier {
    /// Increment to play it again.
    var trigger: Int
    /// Sideways travel at the first swing. Was 7, which on a 32pt pill at the
    /// top of a locked screen was too small to register as a refusal — it read
    /// as a rendering wobble, if it read at all.
    static let standardAmplitude: CGFloat = 11
    var amplitude: CGFloat = standardAmplitude
    /// Full swings. Three reads as a shake; more reads as a wobble toy.
    static let shakes: Double = 3
    /// The whole shake, seconds.
    static let duration: TimeInterval = 0.5
    /// The Reduce Motion dip, seconds: over before the shake would have been.
    static let reducedDuration: TimeInterval = 0.36
    /// How far the pill's content dims at the bottom of the dip.
    static let reducedFloor: Double = 0.45
    /// The decaying envelope is ramped in over this long, so the first frame
    /// is a nudge and not a jump. Ease-out progress put 8.8 pt on the screen
    /// in frame one.
    private static let rampIn: TimeInterval = 0.04

    /// Sideways offset `t` seconds after the trigger: a linear phase, so every
    /// half-swing takes the same time (the ease-out progress it replaces
    /// halved the beat), under an envelope that decays to zero at the end and
    /// is ramped in over 40 ms.
    static func offset(at t: TimeInterval, amplitude: Double = Double(standardAmplitude)) -> Double {
        guard t > 0, t < duration else { return 0 }
        let ramp = min(1, t / rampIn)
        return amplitude * ramp * (1 - t / duration) * sin(2 * .pi * shakes * t / duration)
    }

    /// Opacity of the pill's content `t` seconds after the trigger, with Reduce
    /// Motion on: 1 → `reducedFloor` → 1 on a sine, so the ends meet the
    /// resting state with no corner. Motion was the whole message, and with it
    /// off the refusal used to be removed entirely, which left a locked click
    /// answering nothing at all; a dip says "no" without moving anything.
    static func reducedOpacity(at t: TimeInterval) -> Double {
        guard t > 0, t < reducedDuration else { return 1 }
        let s = sin(.pi * t / reducedDuration)
        return 1 - (1 - reducedFloor) * s * s
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: startedAt == nil)) { timeline in
            let elapsed = startedAt.map { timeline.date.timeIntervalSince($0) } ?? 0
            content
                .offset(x: reduceMotion ? 0 : CGFloat(Self.offset(at: elapsed, amplitude: Double(amplitude))))
                // On the content alone, through the environment: the black
                // shape stays opaque, so nothing shows through the cutout.
                .environment(\.refusalContentOpacity, reduceMotion ? Self.reducedOpacity(at: elapsed) : 1)
        }
        .onChange(of: trigger) { _, _ in startedAt = .now }
        // Clears the clock so the timeline pauses again; restarting replaces
        // the task (new id), which cancels the sleep before it can clear.
        .task(id: startedAt) {
            guard startedAt != nil else { return }
            try? await Task.sleep(for: .seconds(Self.duration))
            if !Task.isCancelled { startedAt = nil }
        }
    }
}

private struct RefusalContentOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// Set by `RefusalShake` under Reduce Motion; the locked pill's content
    /// reads it and leaves its black shape alone.
    var refusalContentOpacity: Double {
        get { self[RefusalContentOpacityKey.self] }
        set { self[RefusalContentOpacityKey.self] = newValue }
    }
}

/// Dims what it wraps by `refusalContentOpacity`. A modifier of its own because
/// the environment flows down: `NotchContentView` sits above `RefusalShake` and
/// would read the default, so the read has to happen in a view beneath it.
private struct RefusalContentDim: ViewModifier {
    @Environment(\.refusalContentOpacity) private var opacity

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}

extension View {
    /// The pill's content takes the Reduce Motion dip of `refusalShake`.
    func refusalContentDim() -> some View { modifier(RefusalContentDim()) }

    /// Plays a refusal wobble whenever `trigger` changes. An amplitude of
    /// zero keeps the modifier — and the view's identity — without moving.
    func refusalShake(trigger: Int, amplitude: CGFloat = RefusalShake.standardAmplitude) -> some View {
        modifier(RefusalShake(trigger: trigger, amplitude: amplitude))
    }
}
