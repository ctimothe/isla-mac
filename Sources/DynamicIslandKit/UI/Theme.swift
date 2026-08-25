import SwiftUI

enum Theme {
    /// Critically damped, on purpose.
    ///
    /// Apple's own rule, from *Designing Fluid Interfaces*: start at a damping
    /// ratio of 1.0, and add overshoot **only when the gesture itself carried
    /// momentum** — a flick, a throw, a drag release. Bounce on something a
    /// flick threw feels right; bounce on something a click opened feels like
    /// the interface wobbling at you.
    ///
    /// The island opens from a click. There is no momentum to inherit and there
    /// was nothing for the overshoot to express, so 0.82 spent it on a wobble
    /// at the end of every open. Response is the time to reach the target, not
    /// a duration — Apple ships 0.4 for a move and 0.3 for a sheet, and this
    /// sits between them.
    static let openAnimation = Animation.spring(response: 0.34, dampingFraction: 1.0)
    /// The pill resizing around a track that just started. Also nothing anybody
    /// threw, so also critically damped.
    static let compactAnimation = Animation.spring(response: 0.28, dampingFraction: 1.0)
    static let contentAnimation = Animation.easeOut(duration: 0.16)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.easeOut(duration: 0.18)
    static let paneIn = Animation.easeOut(duration: 0.20).delay(0.04)
    static let paneOut = Animation.easeIn(duration: 0.12)
    // A skip delivers its new title and cover in 68ms, so the crossfade is
    // what the wait actually is. Short enough to read as immediate, long
    // enough that the swap is still a fade rather than a cut.
    static let artworkAnimation = Animation.easeOut(duration: 0.16)

    /// Motion-aware variants. Reduce Motion asks for the state change to
    /// still happen, just without the travel — so the spring becomes a short
    /// fade and scale transitions become plain opacity, rather than the panel
    /// snapping between states with no transition at all.
    static func open(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : openAnimation
    }

    static func compact(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : compactAnimation
    }

    static func scaleIn(_ scale: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: scale))
    }

    // MARK: - Type

    /// Letter-spacing for a given size, following the shape of SF's own
    /// tracking table.
    ///
    /// Tracking is size-specific and a single value is wrong somewhere: as type
    /// grows, the same spacing reads as letters drifting apart, so large text
    /// wants *negative* tracking; small text wants slightly positive to stay
    /// legible. Apple ships a table for this and applies it automatically to the
    /// semantic text styles — `.headline`, `.body` — but **not** to
    /// `.system(size:)`, which is what a fixed-size panel has to use. So it is
    /// applied here by hand.
    ///
    /// Why not the semantic styles: they scale with the user's text size, and
    /// both surfaces this app draws are windows that cannot resize. The lock
    /// card is a fixed 460×300 whose window is deliberately never resized, and
    /// larger type would simply be cut off. Honest tracking on a fixed size is
    /// worth more than a Dynamic Type that overflows.
    static func tracking(forSize size: CGFloat) -> CGFloat {
        switch size {
        case ..<12: return 0.07      // small labels open up a little
        case ..<15: return 0         // body sits at the neutral point
        case ..<18: return -0.2
        case ..<23: return -0.35
        default: return -0.5         // display sizes tighten most
        }
    }

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    static let secondary = Color.white.opacity(0.55)
    /// Carries nearly every 9–10pt label in the panel — tab titles, counters,
    /// scrubber times, section headers, placeholders. At 0.32 white over black
    /// that computes to 2.67:1, far under the 4.5:1 WCAG AA asks of text this
    /// size, and 9pt is precisely the type least able to afford it. 0.46 gives
    /// 4.58:1 and clears it without turning every label into a headline.
    static let tertiary = Color.white.opacity(0.46)
    static let surface = Color.white.opacity(0.08)
    static let surfaceHover = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
    /// Only for an action that destroys something, and only once it is armed.
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.40)
}

/// Flat, focus-free button used for every control in the panel.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 17 : 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(prominent ? Theme.surfaceHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

extension View {
    /// The system font at a size, with the tracking that size actually wants.
    ///
    /// Everything drawn here used `.system(size:weight:)` bare, which takes
    /// Apple's font and leaves its tracking table behind — the one thing that
    /// keeps type looking deliberate as it changes size.
    func islandFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
            .tracking(Theme.tracking(forSize: size))
    }
}
