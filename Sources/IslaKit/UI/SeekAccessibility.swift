import SwiftUI

/// How the drawn bars — the panel's scrubber, the lock card's scrubber and its
/// volume — are declared to assistive tech.
///
/// Each one is a capsule with a drag gesture, which is nothing at all to
/// VoiceOver, so each used to be declared by hand as one element with a
/// label, a value and an adjustable action. The code said so; the tree
/// SwiftUI actually built said otherwise (H-023). The open panel's dump showed
/// "Playback Position" as an AXUnknown carrying its label and nothing else —
/// no value to hear, so a listener could find the bar and never learn where
/// the song was. An `accessibilityRepresentation` of a real `Slider` is what
/// makes AppKit vend an AXSlider, with a value and VO-Up and VO-Down, instead
/// of an element it has no role for.
///
/// The bars keep drawing themselves: the slider exists only in the
/// accessibility tree. An `NSSlider` through `NSViewRepresentable` would have
/// been a second drawing path to keep in step with the theme for the sake of
/// one role.
enum SeekAccessibility {
    /// How far one VoiceOver step moves the song: 5% of it, never under five
    /// seconds and never over fifteen.
    ///
    /// The step used to be 5% of the length and nothing else (G-034). On a
    /// song that is ten or twelve seconds, which is fine; on a three-hour
    /// audiobook it is nine minutes, and a chapter could not be found by
    /// stepping. Fifteen seconds is the Podcasts app's skip, the vocabulary a
    /// listener of long things already has. The floor keeps a very short track
    /// (or one whose length has not arrived yet) from stepping by a fraction
    /// of a second that the player rounds away.
    static func seekStep(duration: TimeInterval) -> TimeInterval {
        min(max(duration * 0.05, 5), 15)
    }

    /// One VoiceOver step of the volume: the 5% the bar has always moved by,
    /// which is roughly one press of the volume keys.
    static let volumeStep: Double = 0.05
}

extension View {
    /// Declares a drawn scrubber as the playback position: a slider heard as
    /// "0:27 of 3:58", stepped by `SeekAccessibility.seekStep`.
    ///
    /// `shown` is the time the bar is drawn at, which a drag in flight leads;
    /// `position` is read at the moment of a step, so a step is taken from
    /// where the song is rather than from where the bar was last drawn.
    func playbackPositionAccessibility(
        shown: TimeInterval,
        duration: TimeInterval,
        position: @escaping () -> TimeInterval,
        seek: @escaping (TimeInterval) -> Void
    ) -> some View {
        let label = localized("Playback Position")
        return self
            .accessibilityRepresentation {
                // A setter that seeks straight to the value, for a client that
                // writes the value rather than stepping it. Steps go through
                // the adjustable action below, not the slider's own increment,
                // which would snap to multiples of a step counted from zero
                // and land somewhere other than "fifteen seconds on".
                Slider(
                    value: Binding(get: { min(max(shown, 0), max(duration, 1)) }, set: { seek($0) }),
                    in: 0...max(duration, 1)
                ) {
                    Text(label)
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(localized("%@ of %@", formatTime(shown), formatTime(duration)))
            .accessibilityAdjustableAction { direction in
                let step = SeekAccessibility.seekStep(duration: duration)
                switch direction {
                case .increment: seek(position() + step)
                case .decrement: seek(position() - step)
                @unknown default: break
                }
            }
    }

    /// Declares a drawn volume bar as the output volume: a slider heard as a
    /// percentage, stepped by 5%. `set` receives the new level, already
    /// clamped to 0...1. A muted output is heard as "Muted" rather than as a
    /// level nobody can hear (G-023); the increment still raises it, which
    /// unmutes, as the volume keys do.
    func volumeAccessibility(level: Double, muted: Bool = false, set: @escaping (Double) -> Void) -> some View {
        let label = localized("Volume")
        return self
            .accessibilityRepresentation {
                Slider(value: Binding(get: { level }, set: { set(min(max($0, 0), 1)) }), in: 0...1) {
                    Text(label)
                }
            }
            .accessibilityLabel(label)
            // Whole percents. CoreAudio hands the level over as a Float, and
            // 0.42 widened to a Double is 0.41999998…, which the bare
            // `.percent` style spoke as "41.999999 percent" — found by the
            // test that first read this value back.
            .accessibilityValue(
                muted ? Text(localized("Muted")) : Text(level, format: .percent.precision(.fractionLength(0)))
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(min(level + SeekAccessibility.volumeStep, 1))
                case .decrement: set(max(level - SeekAccessibility.volumeStep, 0))
                @unknown default: break
                }
            }
    }
}
