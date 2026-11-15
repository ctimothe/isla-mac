import SwiftUI

/// The shut island's resting shape, stroke and outline. Stored properties live in NotchContentView.swift.
extension NotchContentView {
    // MARK: - Resting in the notch

    /// Nothing playing, the panel shut, on a Mac with a real notch.
    ///
    /// The island used to stay drawn whenever it was idle: the notch's own
    /// width, plus a 6pt concave shoulder each side and its own bottom curve.
    /// Those shoulders and corners fall *outside* the hardware cutout, so an
    /// idle Mac carried two small black ears on the menu bar beside the notch —
    /// an island with nothing to say, still saying it. At rest it now sits just
    /// inside the cutout, where no pixel exists to draw, and is indistinguishable
    /// from the notch itself. On an external display there is no cutout to hide
    /// in, so the synthetic notch stays drawn as before.
    private var restsInNotch: Bool {
        !isOpen && !pillShown && vm.geometry.isPhysical
    }

    /// The pointer is on the island, or a press is under way.
    private var isAwake: Bool { vm.isHovering || isPressed }

    /// Hidden at rest, awake under the pointer, and everything else as before.
    var shapeTopRadius: CGFloat {
        restsInNotch && !isAwake ? 0 : topRadius
    }

    var shapeBottomRadius: CGFloat {
        // The surface's own: 34 for the Shelf's two, 44 for every other
        // (spec §19.6–§19.8). The shape animates its radii, so they spring with
        // the body when one surface turns into another.
        if isOpen { return vm.openBottomRadius }
        if restsInNotch && !isAwake { return Theme.restingNotchBottomRadius }
        // Each expanded alert its own (§19.5; a new track the pop-up's,
        // §3.5), every compact activity 12.67 — whichever is drawn, since
        // an alert replaces what it outranks.
        return IslandShapeRadii.closed(for: vm.activity, liveControls: vm.showsLiveControls).bottom
    }

    /// The island's surface: black, or `#1C1C1E` while the pointer is on it
    /// or a press is under way (spec §3.2). One solid fill rather than a lift
    /// painted over the black — nothing about a playing island moves, only its
    /// colour answers the pointer, and the resting notch growing out of the
    /// cutout takes the same colour. Open, the panel is always black.
    ///
    /// Not an overlay on the wings that stops at the cutout, as the old lift
    /// was: that existed to keep a pale rectangle out of the camera housing,
    /// and the housing is not a display — there is no pixel inside the cutout
    /// for the fill to light, so the whole shape can be one colour.
    var shapeFill: Color {
        !isOpen && isAwake ? Theme.islandHover : Color.black
    }

    // MARK: - Stroke (spec §19.2)

    /// Whether the island draws its stroke: whenever the shape is out of the
    /// notch, on every wallpaper — never on the bare notch.
    var strokeShown: Bool {
        IslandStroke.isShown(isOpen: isOpen, activityShowing: pillShown, notchAwake: restsInNotch && isAwake)
    }

    /// The activity's tint at 0.21, or white at 0.14 (0.42 and 0.30 under
    /// Increase Contrast).
    var strokeColor: Color {
        IslandStroke.color(
            tint: IslandStroke.tint(for: vm.activity, isOpen: isOpen),
            increaseContrast: appearance.increaseContrast
        )
    }

    // MARK: - The outline (spec §19.12)

    /// What the outline is right now, for the layers that draw it: the shape's
    /// size and radii, the fill, the line with whether it is shown folded into
    /// its alpha (a hidden line is one with none, and fades in as it), and the
    /// shadow's strength. The same properties that drew the SwiftUI outline,
    /// so the two cannot say different things.
    var outlineState: OutlineState {
        let height = shapeSize.height
        return OutlineState(
            width: Double(drawnShapeSize.width), height: Double(drawnShapeSize.height),
            topRadius: Double(shapeTopRadius), bottomRadius: Double(shapeBottomRadius),
            fill: OutlineColor(shapeFill),
            stroke: OutlineColor(strokeColor).scalingAlpha(by: strokeShown ? 1 : 0),
            strokeWidth: Double(Theme.islandStrokeWidth),
            shadowOpacity: IslandStroke.castsShadow(height: height) ? Theme.islandShadowOpacity : 0
        )
    }

    /// The outline as drawn: `shapeSize` with the pull's give on its height
    /// (owner, 2026-10-25). Only the outline and what it cuts take it — the
    /// shadow's threshold, the content's frame and the hit region are the
    /// shape's own size, so a pull a few points long neither lights a shadow
    /// on a compact pill nor moves anything the pointer aims at.
    var drawnShapeSize: CGSize {
        CGSize(width: shapeSize.width, height: max(0, shapeSize.height + pull.points))
    }

    var shapeSize: CGSize {
        guard restsInNotch else {
            return Self.clearingCutout(
                CGSize(width: size.width + 2 * topRadius, height: size.height),
                notchHeight: vm.geometry.notchSize.height, isPhysical: vm.geometry.isPhysical
            )
        }
        return isAwake
            ? Self.awakeShape(notch: size, shoulder: topRadius)
            : Self.restingShape(notch: size)
    }

    /// The resting island: a point inside the cutout on every visible edge,
    /// so nothing of it lands on a pixel. Pure, so the "invisible at rest"
    /// promise is a test rather than a hope — `RestingNotchTests`.
    static func restingShape(notch: CGSize) -> CGSize {
        CGSize(
            width: notch.width - 2 * NotchMetrics.restingInset,
            height: notch.height - NotchMetrics.restingInset
        )
    }

    /// The outline of a shape out of the notch, dropped by half the stroke
    /// where it is no taller than the cutout. The 2 pt line is centred on the
    /// outline, so on a pill as tall as the notch — the song, the Shelf,
    /// charging — its inner half lay inside the camera housing, where there is
    /// no pixel to light: the bottom line read 1 pt under the camera and 2 pt
    /// beside it (owner, 2026-10-20). Only the outline moves; the content keeps
    /// the body's frame, centred on the notch, and so does the hit region.
    /// Taller shapes and displays with no cutout are drawn as they were.
    static func clearingCutout(_ shape: CGSize, notchHeight: CGFloat, isPhysical: Bool) -> CGSize {
        guard isPhysical else { return shape }
        let clear = notchHeight + Theme.islandStrokeWidth / 2
        return CGSize(width: shape.width, height: max(shape.height, clear))
    }

    /// Awake under the pointer: out past the notch on both sides and a little
    /// below, with the shoulders back, so the notch visibly becomes the island.
    static func awakeShape(notch: CGSize, shoulder: CGFloat) -> CGSize {
        CGSize(
            width: notch.width + 2 * (shoulder + NotchMetrics.hoverNudgeWidth),
            height: notch.height + NotchMetrics.hoverNudgeDepth
        )
    }
}
