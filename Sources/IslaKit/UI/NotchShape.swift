import SwiftUI

/// The island's outline (redesign spec §19.2): concave shoulders that melt into
/// the top edge of the display, straight sides, rounded bottom. The body is
/// inset by `topRadius` on both sides, so the containing frame must be that
/// much wider.
///
/// Both corners are quadratic Béziers — the shoulder's control point on the
/// top edge, the bottom corner's on the corner — not circular arcs: a circular
/// corner of the same radius reads heavier, and the outlines measured from the
/// reference do not fit one. `IslandOutlineTests` pins the control points for
/// the resting notch, the player and an alert.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = openPath(in: rect)
        path.closeSubpath()
        return path
    }

    /// The outline from the left shoulder round to the right one, left open
    /// along the top edge. The fill closes it; the stroke draws it as it is
    /// (`IslandStrokeShape`), which is how it never touches the bezel.
    func openPath(in rect: CGRect) -> Path {
        let tr = max(0, min(topRadius, rect.width / 2))
        let br = max(0, min(bottomRadius, rect.width / 2 - tr, rect.height))
        let left = rect.minX + tr
        let right = rect.maxX - tr

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + tr),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: left + br, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - br),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY)
        )
        return path
    }
}
