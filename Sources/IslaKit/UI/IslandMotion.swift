import SwiftUI

/// The island's motion per change, measured on the iPhone (plan
/// `2026-11-14-islandcn-activities`, spec §19.3 amended 2026-11-14).
///
/// Until this, every change of the island's size rode one spring,
/// `Theme.islandSpring` (0.5 / 0.75): growing out of the notch, opening into an
/// alert, folding back and going home all moved alike. The phone does not.
/// islandcn (MIT, `THIRD_PARTY_NOTICES.md`) recorded the simulator's island
/// frame by frame and fitted one spring to each kind of change: a compact
/// activity arriving overshoots by 8 to 11 percent (0.483 / 0.62), an alert
/// opening barely does (0.54 / 0.811), a fold back to compact is almost
/// critically damped (0.535 / 0.84), and going home to the bare notch does
/// not overshoot at all (0.432 / 1.019). Those are the numbers here, and the
/// change picks its spring the way islandcn's `shapeTransition` does: from the
/// presentation the island leaves and the one it goes to.
///
/// What is not ported, and why: the phone's collapse first aims at the idle
/// pill and retargets 0.29 to 0.31 s in, and its height, top and corner each
/// have a spring of their own. The outline here is drawn by Core Animation
/// from one sampled curve per part (`OutlineCurve`, `IslandOutlineHost`); a
/// second leg would need a keyframed path of its own. The edge spring is the
/// one the eye follows, and it is the one carried over.
///
/// Reduce Motion is unchanged: the 0.24 s ease-in-out, no overshoot.
enum IslandMotion {
    /// A change between the island's presentations, as islandcn names them.
    enum Transition: String, CaseIterable, Equatable {
        /// The bare notch to a compact activity.
        case appear
        /// A compact activity opening into its own expanded view.
        case expand
        /// The bare notch straight to an expanded alert.
        case appearExpand
        /// To an expanded view of another activity than the one showing.
        case swap
        /// An expanded view folding to a compact one, by a click.
        case collapse
        /// An expanded alert folding to a compact one when its hold runs out.
        case alertCollapse
        /// A compact activity parting into the island and a bubble.
        case split
        /// The bubble merging back into the island.
        case unsplit
        /// Anything going home to the bare notch.
        case dismiss
        /// The same presentation changing size in place: a peek's longer
        /// title, the Shelf's count gaining a digit.
        case resize
    }

    /// A spring in SwiftUI's terms, which are the terms islandcn fitted in.
    struct Spring: Equatable {
        var response: Double
        var damping: Double
    }

    /// islandcn's edge springs (`lib/island/motion.ts`, `islandMotion.shape`,
    /// commit 0011a41): the left and right edges, so the width and the place.
    static func spring(for transition: Transition) -> Spring {
        switch transition {
        case .appear: return Spring(response: 0.483, damping: 0.62)
        case .expand: return Spring(response: 0.517, damping: 0.824)
        case .appearExpand: return Spring(response: 0.54, damping: 0.811)
        case .swap: return Spring(response: 0.498, damping: 0.829)
        case .collapse: return Spring(response: 0.479, damping: 0.894)
        case .alertCollapse: return Spring(response: 0.535, damping: 0.84)
        case .split: return Spring(response: 0.505, damping: 0.815)
        case .unsplit: return Spring(response: 0.487, damping: 0.794)
        case .dismiss: return Spring(response: 0.432, damping: 1.019)
        case .resize: return Spring(response: 0.5, damping: 0.82)
        }
    }

    static func animation(for transition: Transition, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return Theme.reducedMotion }
        let spring = spring(for: transition)
        return .spring(response: spring.response, dampingFraction: spring.damping)
    }

    /// What the shut island is drawn as. The identity is the activity's kind,
    /// so a song turning into the Shelf is a swap of content and a song's
    /// peek is the same pill made wider.
    enum Presentation: Equatable {
        case idle
        case compact(String)
        case expanded(String)
        /// A compact activity with a second waiting as the bubble beside it.
        case split(String)

        var isExpanded: Bool {
            if case .expanded = self { return true }
            return false
        }
    }

    /// The presentation an activity is drawn in (spec §19.4, §19.5): the
    /// charger, the confirmation, the peek and the live activities are
    /// compact; the pop-up, headphones and the update are expanded alerts.
    static func presentation(of activity: IslandActivity, hasBubble: Bool = false) -> Presentation {
        let compact: String
        switch activity {
        case .none: return .idle
        case .hud: return .expanded("hud")
        case .ambient(.headphones): return .expanded("headphones")
        case .update: return .expanded("update")
        case .ambient(.charging): compact = "charging"
        case .confirmation: compact = "confirmation"
        // The peek is the song's own pill made wider (§3.5).
        case .peek, .music: compact = "music"
        case .shelf: compact = "shelf"
        }
        return hasBubble ? .split(compact) : .compact(compact)
    }

    /// The change between two presentations, by islandcn's rule
    /// (`geometry.ts`, `shapeTransition`). `wasAlert` says the expanded view
    /// being left was an alert whose hold ran out rather than one a click
    /// folded; on the phone the two returns differ a little.
    static func transition(from: Presentation, to: Presentation, wasAlert: Bool = true) -> Transition {
        if from == to { return .resize }
        switch (from, to) {
        case (_, .idle): return .dismiss
        case (.idle, .expanded): return .appearExpand
        case (.split, .expanded): return .swap
        case (.expanded, .expanded): return .swap
        case (.compact(let a), .expanded(let b)): return a == b ? .expand : .swap
        case (.expanded, .split): return .split
        case (.expanded, _): return wasAlert ? .alertCollapse : .collapse
        case (.idle, _): return .appear
        case (.compact(let a), .split(let b)): return a == b ? .split : .resize
        case (.split(let a), .compact(let b)): return a == b ? .unsplit : .resize
        case (.compact, .compact), (.split, .split): return .resize
        }
    }

    /// The curve a change between two presentations rides.
    static func animation(from: Presentation, to: Presentation, reduceMotion: Bool) -> Animation {
        animation(for: transition(from: from, to: to), reduceMotion: reduceMotion)
    }
}

/// Picks the island's spring for each change from the presentation it leaves
/// and the one it reaches.
///
/// `.animation(_:value:)` is evaluated in the body pass that sees the new
/// value, and `onChange` runs after that pass, so during the pass that
/// animates the change `previous` still holds the presentation being left.
/// The pass `onChange` causes sees the two equal and picks `resize`, but the
/// keyed values have not changed in it, so nothing rides that curve.
struct IslandMorph<Key: Equatable>: ViewModifier {
    let presentation: IslandMotion.Presentation
    let keys: Key
    let reduceMotion: Bool
    @State private var previous: IslandMotion.Presentation?

    func body(content: Content) -> some View {
        content
            .animation(
                IslandMotion.animation(from: previous ?? presentation, to: presentation, reduceMotion: reduceMotion),
                value: keys
            )
            .onChange(of: presentation, initial: true) { _, now in previous = now }
    }
}
