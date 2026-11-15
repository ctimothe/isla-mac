import SwiftUI

/// The SwiftUI cut by the island's outline: the content masked by `NotchShape`
/// at the shape's own size and radii. Active only for a shell that draws its
/// own outline; with the outline on Core Animation the mask is a layer's.
struct OutlineMask: ViewModifier {
    let active: Bool
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let size: CGSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.mask(alignment: .top) {
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                    .frame(width: size.width, height: size.height)
            }
        } else {
            content
        }
    }
}

/// The pages' frame while they travel, and no cut at all at rest: a pane's
/// shadows, its menus' anchors and the cover flying in from the pill are
/// never clipped by it outside a swipe.
struct PaneClip: Shape {
    var isCutting: Bool

    func path(in rect: CGRect) -> Path {
        Path(isCutting ? rect : rect.insetBy(dx: -10_000, dy: -10_000))
    }
}

/// The island's one accessibility element: a button called Isla. Built by
/// `NotchContentView.islandAccessibility(open:)`, which decides the value, the
/// hint and what a press does; this only says them.
///
/// The children are ignored rather than combined: what the wings draw — a
/// cover, bars, a charge level — is in the value already, and a folded wing is
/// drawn at nothing, so combining would describe a pill that is not there.
struct IslandAccessibility: ViewModifier {
    /// The update alert is up, with buttons of its own (spec §19.5 f): the
    /// island stands aside as a plain container and lets them through.
    /// Values, not a branch, so the stack under it keeps its identity — the
    /// music's fold and morph — as the alert comes and goes.
    var containsControls = false
    let value: String
    let hint: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: containsControls ? .contain : .ignore)
            .accessibilityLabel(containsControls ? value : ProductIdentity.displayName)
            .accessibilityValue(containsControls ? "" : value)
            .accessibilityHint(containsControls ? "" : hint)
            .accessibilityAddTraits(containsControls ? [] : .isButton)
            .accessibilityAction(.default, action)
    }
}

/// The pill's content arriving out of the notch and leaving back into it.
///
/// Blur, scale and opacity together — the way the system's own island
/// dissolves what it shows — rather than a flat fade, on the outline's spring
/// (spec §19.3): from blur 15 and 0.8 of its width, with the shape, and back the
/// same way (`IslandArrival.compact`). The content is pinned to the island's
/// edges (`CompactIslandLayout`), so it travels with them and no edge ever
/// crosses it; only how present it is moves here.
struct PillPresence: ViewModifier {
    let shown: Bool
    let reduceMotion: Bool

    /// How the content looks at either end. Pure, so "folded means nothing
    /// drawn" is a test rather than a hope — `PillFoldTests`.
    nonisolated static func appearance(shown: Bool, reduceMotion: Bool) -> IslandArrival {
        shown ? .arrived() : .compact(reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        let look = Self.appearance(shown: shown, reduceMotion: reduceMotion)
        return content.animation(Theme.pill(reduceMotion: reduceMotion)) { view in
            view.modifier(IslandArrivalEffect(look: look))
        }
    }
}

extension View {
    func pillPresence(_ shown: Bool, reduceMotion: Bool) -> some View {
        modifier(PillPresence(shown: shown, reduceMotion: reduceMotion))
    }
}

/// Everything whose change moves the shut island's outline between
/// activities, as one value for `IslandMorph`.
struct MorphKeys: Equatable {
    var compact: CompactMediaActivity
    var ambient: AmbientActivity?
    var confirmation: IslandConfirmation?
    var update: String?
    /// Which live activities stand, by kind: a timer ticking or a download
    /// growing redraws inside the island and moves no edge.
    var live: [String]
    var liveControls: Bool
    var bubble: IslandMotion.Presentation?
}
