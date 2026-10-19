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
    /// §19.5 f, an update ready to install.
    static let update = ExpandedAlertShape(
        reference: CGSize(width: 335.4, height: 158), topRadius: 24, bottomRadius: 36
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
        case .update:
            return (ExpandedAlertShape.update.topRadius, ExpandedAlertShape.update.bottomRadius)
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

/// Where the update alert's parts sit (spec §19.5 f). Body-local, from the
/// reference's shape-relative numbers. A shape wider than the reference — a
/// notch that needs more — keeps the glyph, the text and Later where they
/// were and takes Install with its right edge.
enum UpdateAlertLayout {
    static let shape = ExpandedAlertShape.update

    /// `arrow.down.circle.fill`, 38 × 38 at (45.5, 56), in the blue gradient.
    static let glyphSize = CGSize(width: 38, height: 38)
    static let glyphSymbol = "arrow.down.circle.fill"

    static func glyphFrame(notchHeight: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: shape.x(45.5), y: shape.y(56, notchHeight: notchHeight)), size: glyphSize)
    }

    /// The title and the lines under it start at x 105.
    static var textLeading: CGFloat { shape.x(105) }

    /// The text ends where Install does, right 35, and truncates there.
    static func textWidth(islandWidth: CGFloat) -> CGFloat {
        max(0, islandWidth - textLeading - shape.trailing(buttonsRight))
    }

    /// "Isla %@ is ready", 14 semibold, white, baseline 64.
    static let titleSize: CGFloat = 14
    static func titleBaseline(notchHeight: CGFloat) -> CGFloat { shape.y(64, notchHeight: notchHeight) }

    /// 11 medium, white 0.55, a line height of 14 from baseline 81.5: the
    /// summary, then "Isla restarts when it is done."
    static let detailSize: CGFloat = 11
    static let detailOpacity: Double = 0.55
    static let detailLineHeight: CGFloat = 14
    static func detailBaseline(line: Int, notchHeight: CGFloat) -> CGFloat {
        shape.y(81.5, notchHeight: notchHeight) + CGFloat(line) * detailLineHeight
    }

    /// The buttons: capsules 35 tall at y 113. Later 128 wide at x 35, Install
    /// 127.4 wide at x 173 — on the reference, right 35.
    static let buttonHeight: CGFloat = 35
    static let laterWidth: CGFloat = 128
    static let installWidth: CGFloat = 127.4
    static let buttonsRight: CGFloat = 335.4 - 173 - 127.4
    static let buttonTitleSize: CGFloat = 14
    /// Later's capsule, grey 0.22; Install's, blue 0.22.
    static let buttonFillOpacity: Double = 0.22

    static func laterFrame(notchHeight: CGFloat) -> CGRect {
        CGRect(x: shape.x(35), y: shape.y(113, notchHeight: notchHeight), width: laterWidth, height: buttonHeight)
    }

    static func installFrame(islandWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        CGRect(
            x: islandWidth - shape.trailing(buttonsRight) - installWidth, y: shape.y(113, notchHeight: notchHeight),
            width: installWidth, height: buttonHeight
        )
    }

    /// While the install runs the buttons give way to its progress: a 4 pt
    /// bar across the span the two buttons took, on the line through their
    /// middle (plan 2026-10-19; the spec is silent after Install).
    static let progressHeight: CGFloat = 4
    static let progressTrackOpacity: Double = 0.18

    static func progressFrame(islandWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let later = laterFrame(notchHeight: notchHeight)
        let install = installFrame(islandWidth: islandWidth, notchHeight: notchHeight)
        return CGRect(
            x: later.minX, y: later.midY - progressHeight / 2,
            width: install.maxX - later.minX, height: progressHeight
        )
    }
}
