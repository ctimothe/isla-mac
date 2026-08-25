import AppKit

/// The trackpad's haptic engine, used the way the system uses it.
///
/// Three rules from Apple's own guidance on audio-haptic feedback, and the
/// third is the one that decides what is in here:
///
/// - **Causality** — it must be obvious what caused the feedback, so it fires on
///   the causal event itself, not near it.
/// - **Harmony** — it lands on the same frame as the visual change, never after.
/// - **Utility** — only where it earns its place. Feedback on everything trains
///   people to feel nothing, so transport taps and hovers get none: they already
///   answer visibly and instantly, and a click that ticks every time is noise.
///
/// Reserved here for the moments the system itself would mark: a discrete value
/// committing, and something snapping into place.
///
/// Silent on Macs with no Force Touch trackpad, and on an external mouse. That
/// is the platform's own behaviour, not a failure — the feedback is a bonus for
/// the hardware that has it, never the only signal.
@MainActor
enum Haptics {
    /// A discrete value changed and stuck: an output device chosen, a mode
    /// switched. The system uses this one for stepping through values.
    static func levelChange() {
        perform(.levelChange)
    }

    /// Something landed where it belongs: a seek that snapped to a lyric line.
    /// The system uses alignment for exactly this — an object finding its place.
    static func alignment() {
        perform(.alignment)
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            pattern,
            // `.drawCompleted`, not `.now`.
            //
            // Harmony is the rule: the touch and the picture have to arrive on
            // the same frame, and a gap between them is what breaks the
            // illusion that one caused the other. `.now` fires the moment the
            // handler runs — before SwiftUI has drawn anything — so the tap
            // landed slightly *ahead* of the change it was describing. This
            // hands the timing to the window server, which fires it with the
            // frame that shows the result.
            performanceTime: .drawCompleted
        )
    }
}
