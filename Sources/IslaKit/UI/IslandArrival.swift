import SwiftUI

/// How content arrives on the island and leaves it (redesign spec §19.3).
///
/// Content does not fade onto the black shape: it comes into focus with it.
/// An expanded activity's or a surface's content starts at opacity 0, blur 30
/// and scale (0.6, 0.2) anchored at (0.5, 0.4) of its frame — squashed toward a
/// point a little above its middle, the way the reference's alerts unfold out
/// of the notch's line; a compact activity's starts at opacity 0, blur 15 and
/// 0.8 of its width, since a compact activity only ever grows sideways. Both
/// ride the outline's spring (`Theme.islandSpring`) and leave by the same path
/// reversed. When one activity turns into another the old content leaves while
/// the outline moves and the new arrives on the same curve, so the two are
/// never both at full opacity.
///
/// Reduce Motion keeps the change and drops the travel: a crossfade, with no
/// blur and no scale.
///
/// A value rather than a transition so the numbers are tests
/// (`MotionValuesTests`); `Theme.expandedArrival` and `Theme.compactArrival`
/// build the transitions from it, and `PillPresence` the compact content's
/// state-driven form.
struct IslandArrival: Equatable {
    var opacity: Double
    var blur: CGFloat
    var scale: CGSize
    var anchor: UnitPoint

    /// Arrived: fully drawn, in focus, at its own size. Anchored where its
    /// arrival was, so the scale interpolates about one point.
    static func arrived(anchor: UnitPoint = .center) -> IslandArrival {
        IslandArrival(opacity: 1, blur: 0, scale: CGSize(width: 1, height: 1), anchor: anchor)
    }

    /// The anchor an expanded arrival grows from: across the middle, a little
    /// above centre.
    static let expandedAnchor = UnitPoint(x: 0.5, y: 0.4)

    /// An expanded activity's or a surface's content before it arrives.
    static func expanded(reduceMotion: Bool) -> IslandArrival {
        reduceMotion
            ? IslandArrival(opacity: 0, blur: 0, scale: CGSize(width: 1, height: 1), anchor: expandedAnchor)
            : IslandArrival(opacity: 0, blur: 30, scale: CGSize(width: 0.6, height: 0.2), anchor: expandedAnchor)
    }

    /// A compact activity's content before it arrives.
    static func compact(reduceMotion: Bool) -> IslandArrival {
        reduceMotion
            ? IslandArrival(opacity: 0, blur: 0, scale: CGSize(width: 1, height: 1), anchor: .center)
            : IslandArrival(opacity: 0, blur: 15, scale: CGSize(width: 0.8, height: 1), anchor: .center)
    }
}

/// Draws content at one end of an arrival.
struct IslandArrivalEffect: ViewModifier {
    let look: IslandArrival

    func body(content: Content) -> some View {
        content
            .blur(radius: look.blur)
            .scaleEffect(x: look.scale.width, y: look.scale.height, anchor: look.anchor)
            .opacity(look.opacity)
    }
}

extension Theme {
    /// An expanded activity's or a surface's content arriving and leaving
    /// (spec §19.3). The curve is the transaction's — the outline's spring.
    static func expandedArrival(reduceMotion: Bool) -> AnyTransition {
        .modifier(
            active: IslandArrivalEffect(look: .expanded(reduceMotion: reduceMotion)),
            identity: IslandArrivalEffect(look: .arrived(anchor: IslandArrival.expandedAnchor))
        )
    }

    /// A compact activity's content arriving and leaving (spec §19.3).
    static func compactArrival(reduceMotion: Bool) -> AnyTransition {
        .modifier(
            active: IslandArrivalEffect(look: .compact(reduceMotion: reduceMotion)),
            identity: IslandArrivalEffect(look: .arrived())
        )
    }
}
