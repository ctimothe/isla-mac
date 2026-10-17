import CoreGraphics

/// An expanded alert's outline (spec §19.2, §19.5): the reference's measured
/// shape, and how it becomes Isla's on a notch of any size.
///
/// The reference measured each alert as a whole shape — shoulders included, on
/// its 38 pt notch. Isla's island is the body between the shoulders, hung from
/// a notch `nw` × `H`, so each alert keeps its measured width (less its two
/// shoulders) unless the notch needs more — never narrower than `nw + 20`, ten
/// points of black either side of the camera — and keeps the depth it reaches
/// below the notch, not its total height. Its content sits in that depth,
/// below the camera, so a position is the reference's less 38 plus `H`.
///
/// Positions in the spec run from the shape's left edge, or as `right n` from
/// its right; `x(_:)` and `trailing(_:)` turn them into the body's. A shape
/// wider than the reference keeps its leading content where it was and moves
/// its trailing content with the edge.
struct ExpandedAlertShape: Equatable {
    let reference: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    /// The notch the reference was measured on.
    static let referenceNotchHeight: CGFloat = 38
    /// The narrowest an expanded alert's body may be, past the notch.
    static let widthPastTheNotch: CGFloat = 20

    /// §19.5 c, headphones connected.
    static let headphones = ExpandedAlertShape(
        reference: CGSize(width: 370.3, height: 95), topRadius: 20, bottomRadius: 38
    )
    /// §19.5 d, volume and brightness.
    static let volume = ExpandedAlertShape(
        reference: CGSize(width: 245.4, height: 103), topRadius: 18.67, bottomRadius: 22.67
    )

    /// How far below the notch the shape reaches.
    var depth: CGFloat { reference.height - Self.referenceNotchHeight }

    /// The body: the measured width or the notch's floor, whichever is wider,
    /// never wider than the panel it would open into.
    func bodySize(notchSize: CGSize, bodyWidth: CGFloat) -> CGSize {
        let measured = reference.width - 2 * topRadius
        let width = min(max(measured, notchSize.width + Self.widthPastTheNotch), bodyWidth)
        return CGSize(width: width, height: notchSize.height + depth)
    }

    /// A spec x, from the shape's left edge, in the body's coordinates.
    func x(_ shapeX: CGFloat) -> CGFloat { shapeX - topRadius }

    /// A spec `right n` as the body's trailing inset.
    func trailing(_ right: CGFloat) -> CGFloat { right - topRadius }

    /// A spec y, measured under the reference's notch, under one `notchHeight`
    /// tall.
    func y(_ shapeY: CGFloat, notchHeight: CGFloat) -> CGFloat {
        shapeY - Self.referenceNotchHeight + notchHeight
    }
}

/// The outline's radii for what the shut island shows: each expanded alert its
/// own, the peek its taller bottom corner, every compact activity the
/// reference's 8.67 / 12.67. One function, read by the shape and by both hit
/// rects, so the black and the clickable cannot disagree about the shoulders.
enum IslandShapeRadii {
    static func closed(for activity: IslandActivity) -> (top: CGFloat, bottom: CGFloat) {
        switch activity {
        case .hud:
            return (ExpandedAlertShape.volume.topRadius, ExpandedAlertShape.volume.bottomRadius)
        case .ambient(.headphones):
            return (ExpandedAlertShape.headphones.topRadius, ExpandedAlertShape.headphones.bottomRadius)
        case .peek:
            return (Theme.collapsedTopRadius, Theme.peekBottomRadius)
        case .ambient(.charging), .music, .shelf, .none:
            return (Theme.collapsedTopRadius, Theme.collapsedBottomRadius)
        }
    }
}

/// Where the headphones alert's parts sit (spec §19.5 c). Body-local, from the
/// reference's shape-relative numbers.
enum HeadphonesAlertLayout {
    static let shape = ExpandedAlertShape.headphones

    /// The device's own symbol, hierarchical, white at 0.85, 43 × 34 at
    /// (40.6, 38.75).
    static let glyphSize = CGSize(width: 43, height: 34)
    static let glyphOpacity: Double = 0.85

    static func glyphFrame(notchHeight: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: shape.x(40.6), y: shape.y(38.75, notchHeight: notchHeight)), size: glyphSize)
    }

    /// "Connected" and the name both start at x 102.4.
    static var textLeading: CGFloat { shape.x(102.4) }

    /// "Connected", 13 regular, white 0.40, baseline 54.
    static let connectedSize: CGFloat = 13
    static let connectedOpacity: Double = 0.40
    static func connectedBaseline(notchHeight: CGFloat) -> CGFloat { shape.y(54, notchHeight: notchHeight) }

    /// The name, 15 regular, white 0.82, baseline 75.
    static let nameSize: CGFloat = 15
    static let nameOpacity: Double = 0.82
    static func nameBaseline(notchHeight: CGFloat) -> CGFloat { shape.y(75, notchHeight: notchHeight) }

    /// The name runs to where the battery ring ends, right 37.7, and truncates
    /// at its tail there. The ring itself is R9's (§19.15): with no level to
    /// show there is no ring, and the name takes its width.
    static func nameWidth(islandWidth: CGFloat) -> CGFloat {
        max(0, islandWidth - textLeading - shape.trailing(37.7))
    }
}
