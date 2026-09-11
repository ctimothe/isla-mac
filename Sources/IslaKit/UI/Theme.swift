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

    /// The lyrics page moving to the next line.
    ///
    /// The one animation here allowed to overshoot, and it is allowed because
    /// the rule at the top of this file is about momentum rather than about
    /// taste: the page is not something a click moved, it is carried by a voice
    /// that is already moving, and a page that stops dead the instant it
    /// arrives reads as the song being cut off rather than sung.
    ///
    /// It used to borrow `contentAnimation` — the generic 0.16s ease that also
    /// drives a badge appearing — for a page travel of one whole slot
    /// (`LyricsStage.slotHeight` 40 + `slotSpacing` 8 = 48pt). That put the page
    /// ahead of the word sweep it exists to carry: `KaraokeText` fills a line
    /// over `.linear(duration: 0.25)`, so the page had already settled at the
    /// reading centre while the sweep was barely half-way across the words it
    /// was moving them into view for. The page arrived before the voice did.
    /// The response therefore has to be longer than that 0.25s, not shorter.
    ///
    /// 0.86 is a small overshoot, deliberately: enough that the page reads as
    /// having been carried, not enough to wobble. `MotionValuesTests`
    /// `testTheLyricScrollIsSlowerThanTheWordSweepAndMayOvershoot` holds both
    /// ends of that, and `testNothingWithoutMomentumOvershoots` walks
    /// `criticallyDampedSprings` so this stays the single exception. Any spring
    /// added to this file belongs in that list unless it can name the momentum
    /// it inherited.
    /// Every spring in this file that is **not** allowed to overshoot.
    ///
    /// Listed rather than inferred so the guard is a list somebody has to
    /// deliberately edit. It used to be hardcoded inside the test, which meant
    /// a fourth spring at 0.7 would have passed it without anyone noticing.
    static let criticallyDampedSprings: [Animation] = [openAnimation, compactAnimation]

    static let lyricScrollResponse: Double = 0.42
    static let lyricScrollDamping: Double = 0.86
    static let lyricScroll = Animation.spring(response: lyricScrollResponse,
                                              dampingFraction: lyricScrollDamping)

    /// Reduce Motion refuses the travel, and a spring is nothing but travel —
    /// so the page still moves to the next line, it just stops carrying
    /// anything there. Same short ease every other reduced variant here uses.
    static func lyricScroll(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : lyricScroll
    }

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

    // MARK: - Artwork

    /// The two ends of the cover's travel between the pill and the open panel.
    ///
    /// One function because there is one cover. The pill hardcoded 22 pt at
    /// radius 6 in `NotchContentView` and the pane hardcoded 118 pt at radius 14
    /// in `MediaPane` — two descriptions of one object, in two files, which is
    /// the same mistake as drawing it twice and crossfading between the copies.
    /// A `matchedGeometryEffect` interpolates the frame; what it cannot do is
    /// notice that the two ends disagree about what shape they are.
    ///
    /// The corner is absolute at each end, not a proportion of the side.
    ///
    /// It was briefly proportional, at the `side / 5.5` `LockScreenCard` draws
    /// its own cover at, on the reasoning that one object should keep its shape
    /// while it travels. That is the wrong reasoning and it shows: a thumbnail
    /// wants to read as a rounded chip and a large cover wants to read as a
    /// picture, which is why Apple's small artwork is proportionally rounder
    /// than its large artwork rather than the same. Holding the ratio put the
    /// 118 pt cover at 21.5 pt — 18 per cent — a chip the size of a postcard.
    /// `side / 5.5` is right for the 42–62 pt thumbnail it was set on and wrong
    /// at this size, so each end keeps the value it actually wants and the
    /// morph interpolates the frame between them.
    static func artworkMetrics(isOpen: Bool) -> (side: CGFloat, cornerRadius: CGFloat) {
        // Both ends of the travel, described once. They used to be two hardcoded
        // pairs in two files — 22/6 in the compact header and 118/14 in the
        // media pane — which is the same mistake as two views of one cover, one
        // level down.
        //
        // The radius does not scale with the side, and that is deliberate. An
        // earlier version held the ratio constant on the reasoning that one
        // object keeps its proportions while it travels; it took the open cover
        // to 21.45pt, which reads as a chip the size of a postcard. Apple's
        // small artwork is proportionally rounder than its large artwork —
        // a thumbnail is a chip, a cover is a picture — so the two ends carry
        // the values each size actually wants and let the morph interpolate
        // between them. `side / 5.5` on the lock card is right for the 42–62pt
        // cover it was set on, and wrong here.
        isOpen ? (118, 14) : (22, 6)
    }

    // MARK: - Contrast ramp
    //
    // Every token below is a function of Increase Contrast, not a flat value.
    // The setting used to reach two `strokeBorder` calls in `GlassSurface` and
    // nothing else, while the type ramp sat untouched and the lyric context
    // lines at white 0.18 computed to 1.54:1. The opacity functions are pure so
    // tests can compute WCAG ratios against black (`ContrastRampTests`); the
    // `Color` accessors below read `SystemAppearance.shared.increaseContrast`,
    // and the one observation that makes a live change redraw lives on
    // `NotchContentView` — every pane is its descendant, so one `@ObservedObject`
    // at the root invalidates the whole tree.
    //
    // The existing names keep working so call sites do not all change at once;
    // new code that cares about the setting can call the functions directly.

    /// White 0.55 over black is 6.27:1; 0.75 is 11.45:1.
    static func secondaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.75 : 0.55
    }

    /// Carries nearly every 9–10pt label in the panel — tab titles, counters,
    /// scrubber times, section headers, placeholders. At 0.32 white over black
    /// that computes to 2.67:1, far under the 4.5:1 WCAG AA asks of text this
    /// size, and 9pt is precisely the type least able to afford it. 0.46 gives
    /// 4.58:1 and clears it without turning every label into a headline; 0.65
    /// gives 8.60:1 once Increase Contrast is on.
    static func tertiaryOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.65 : 0.46
    }

    /// A filled shape has to read as a filled shape. 0.08 was 1.14:1 over
    /// black — the selected tab chip and the empty scrubber track were not
    /// visible as shapes at all. 0.16 is 1.44:1, the smallest round value that
    /// clears the 1.4 floor `ContrastRampTests` holds; this is a shape fix for
    /// everyone, not an accessibility variant, so the base moves and not only
    /// the contrast one.
    static func surfaceOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.28 : 0.16
    }

    /// 0.14 was 1.35:1. 0.26 is 2.10:1, the smallest round value clearing the
    /// 2.0 floor — same reasoning as `surfaceOpacity`: the hover state has to
    /// differ from the surface by something a person can see.
    static func surfaceHoverOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.38 : 0.26
    }

    /// A 1pt edge, not a fill, so the base stays hairline-thin at 0.10
    /// (1.20:1) and only the contrast variant becomes a defined border at
    /// 0.55 — the same white-0.55 `ShelfPane`'s selected tile already uses.
    /// Hairline-only edges stay thin by design; raising them is follow-up, not this change.
    static func hairlineOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.55 : 0.10
    }

    /// The selected rail chip's own fill, following `ShelfPane`'s selected
    /// tile: a 0.18 fill plus a 1.5pt white-0.55 border. It used to borrow
    /// `surfaceHover`, which meant the selected tab and a hovered tab were the
    /// same colour and neither had an edge.
    static func selectedChipOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.30 : 0.18
    }

    /// The selected chip's edge: `ShelfPane`'s 0.55, or the 0.85 defined
    /// border `GlassSurface` draws under Increase Contrast.
    static func selectedChipBorderOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 0.85 : 0.55
    }

    @MainActor static var secondary: Color {
        Color.white.opacity(secondaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var tertiary: Color {
        Color.white.opacity(tertiaryOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var surface: Color {
        Color.white.opacity(surfaceOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var surfaceHover: Color {
        Color.white.opacity(surfaceHoverOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var hairline: Color {
        Color.white.opacity(hairlineOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var selectedChip: Color {
        Color.white.opacity(selectedChipOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
    @MainActor static var selectedChipBorder: Color {
        Color.white.opacity(selectedChipBorderOpacity(increaseContrast: SystemAppearance.shared.increaseContrast))
    }
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

    /// One end of a travelling object, when there is a namespace to travel in.
    ///
    /// The namespace is optional because the views that carry these ids are also
    /// rendered on their own — `MediaPane` by the layout tests, with no panel
    /// around it and nothing to travel to. `matchedGeometryEffect` has no
    /// tolerant form: it takes a `Namespace.ID`, not an optional, so the choice
    /// has to be made here rather than at every call site.
    ///
    /// Apply this **inside** the fixed frame that declares the end's size, never
    /// outside it. Outside, the effect proposes the other end's size to a frame
    /// that is already pinned to its own, so the cover moves without ever
    /// growing — a hero animation that silently loses half its job.
    @ViewBuilder
    func morph(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
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
