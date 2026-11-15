import SwiftUI

/// The gooey neck between the island and its bubble while the two are close
/// (plan `2026-11-14-islandcn-activities` S6, ported from islandcn's
/// `bridgePath`, MIT, `THIRD_PARTY_NOTICES.md`).
///
/// The bubble used to fade in 16 pt beside the island as if it had come from
/// nowhere. On the iPhone it pinches off the island's end: the two are one
/// liquid shape until the gap between them opens, and the neck between them
/// thins to nothing as the gap reaches `maxGap`, so the pinch-off has no pop.
/// Merging back runs the same path the other way.
enum IslandNeck {
    struct Circle: Equatable {
        var centre: CGPoint
        var radius: CGFloat
    }

    /// islandcn's measured neck: spread 0.3 (the iOS bridge is thinner than
    /// a textbook metaball), handle 2.4, broken at a 5 pt gap (the simulator's
    /// breaks between 4.6 and 4.9).
    static let handleSize: CGFloat = 2.4
    static let spread: CGFloat = 0.3
    static let maxGap: CGFloat = 5
    static let power: CGFloat = 1.5

    /// The closed neck between `a` and `b`, overlapping both, so filled with
    /// them the union reads as one shape. Nil once the gap reaches `maxGap`,
    /// when one circle holds the other, or when either has no size.
    static func bridge(_ a: Circle, _ b: Circle) -> Path? {
        let dx = b.centre.x - a.centre.x
        let dy = b.centre.y - a.centre.y
        let d = hypot(dx, dy)
        guard a.radius > 0, b.radius > 0, d > abs(a.radius - b.radius) else { return nil }
        let gap = d - a.radius - b.radius
        guard gap < maxGap else { return nil }

        let reach = max(0, gap) / maxGap
        let v = spread * pow(1 - reach, power)
        guard v > 1e-4 else { return nil }

        var u1: CGFloat = 0
        var u2: CGFloat = 0
        if d < a.radius + b.radius {
            u1 = acos(clamp((a.radius * a.radius + d * d - b.radius * b.radius) / (2 * a.radius * d)))
            u2 = acos(clamp((b.radius * b.radius + d * d - a.radius * a.radius) / (2 * b.radius * d)))
        }
        let between = atan2(dy, dx)
        let maxSpread = acos(clamp((a.radius - b.radius) / d))

        let angle1 = between + u1 + (maxSpread - u1) * v
        let angle2 = between - u1 - (maxSpread - u1) * v
        let angle3 = between + .pi - u2 - (.pi - u2 - maxSpread) * v
        let angle4 = between - .pi + u2 + (.pi - u2 - maxSpread) * v

        let p1 = polar(a.centre, angle1, a.radius)
        let p2 = polar(a.centre, angle2, a.radius)
        let p3 = polar(b.centre, angle3, b.radius)
        let p4 = polar(b.centre, angle4, b.radius)

        let total = a.radius + b.radius
        let handle = min(v * handleSize, hypot(p1.x - p3.x, p1.y - p3.y) / total) * min(1, d * 2 / total)
        let h1 = polar(p1, angle1 - .pi / 2, a.radius * handle)
        let h2 = polar(p2, angle2 + .pi / 2, a.radius * handle)
        let h3 = polar(p3, angle3 + .pi / 2, b.radius * handle)
        let h4 = polar(p4, angle4 - .pi / 2, b.radius * handle)

        var path = Path()
        path.move(to: p1)
        path.addCurve(to: p3, control1: h1, control2: h3)
        path.addLine(to: p4)
        path.addCurve(to: p2, control1: h4, control2: h2)
        path.closeSubpath()
        return path
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(1, max(-1, value)) }

    private static func polar(_ origin: CGPoint, _ angle: CGFloat, _ length: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Where the bubble stands at `progress` of its split, in its own
    /// coordinates (its left edge at rest is x = 0): 0 is merged into the
    /// island's end, 1 is at rest `IslandBubbleLayout.gap` beyond it.
    /// The bubble's own end circle travels from the island's end circle out
    /// to its place, growing from 0.4 of its size, so the gap the neck reads
    /// opens from overlapping to the full 16 pt.
    struct Split: Equatable {
        var shift: CGFloat
        var scale: CGFloat
        var island: Circle
        var bubble: Circle

        static func at(_ progress: CGFloat, height: CGFloat) -> Split {
            let p = min(1, max(0, progress))
            let radius = height / 2
            let island = Circle(
                centre: CGPoint(x: -IslandBubbleLayout.gap - radius, y: radius), radius: radius
            )
            let scale = 0.4 + 0.6 * p
            let bubbleRadius = radius * scale
            // Merged, the bubble's end circle sits on the island's; at rest
            // it is where the bubble's left edge puts it. Its centre travels
            // between the two, and the bubble (scaled from its leading edge)
            // follows it.
            let centreX = island.centre.x + (radius - island.centre.x) * p
            let shift = centreX - bubbleRadius
            let bubble = Circle(centre: CGPoint(x: centreX, y: radius), radius: bubbleRadius)
            return Split(shift: shift, scale: scale, island: island, bubble: bubble)
        }
    }

    /// The bubble's arrival and leave: it grows out of the island's end on
    /// the split spring and merges back on the unsplit one, which the layer
    /// sets. Reduce Motion keeps the compact content's own fade
    /// (`IslandArrival.compactArrival`): nothing travels.
    static func bubbleTransition(reduceMotion: Bool, height: CGFloat) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .modifier(
            active: SplitModifier(progress: 0, height: height),
            identity: SplitModifier(progress: 1, height: height)
        )
    }

    struct SplitModifier: ViewModifier, Animatable {
        var progress: CGFloat
        let height: CGFloat

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let split = Split.at(progress, height: height)
            content
                .scaleEffect(split.scale, anchor: .leading)
                .offset(x: split.shift)
                // The content inside only appears once the bubble is its own
                // shape: a timer's digits squeezed into the neck read as a
                // smear.
                .opacity(Double(min(1, max(0, progress * 1.6 - 0.3))))
                .background(alignment: .topLeading) {
                    if let neck = IslandNeck.bridge(split.island, split.bubble) {
                        neck.fill(Color.black).allowsHitTesting(false)
                    }
                }
        }
    }
}
