import SwiftUI

/// The island's stroke and shadow (redesign spec §19.2): a 2 pt line centred on
/// the outline, so a black island holds its edge on a black wallpaper and a
/// tinted activity says what it is about before it is read.
///
/// It replaced §3.3's key line on 2026-10-17. That line was 1 pt, drawn under
/// the black so only its outer half showed, and only where the desktop picture
/// behind the notch measured dark — which meant reading the wallpaper, keeping
/// that answer current across Spaces, wakes and display changes, and drawing
/// nothing on a wallpaper that sat behind a privacy gate. The reference the
/// owner chose draws its line on every wallpaper at a strength faint enough
/// that a bright desktop does not turn it into a frame, so the wallpaper
/// question left the island; `WallpaperTone` now serves only the lock card's
/// Automatic material.
///
/// The decisions are pure functions here so the rules are tests; the view
/// draws `IslandStrokeShape` over the fill and under the content.
enum IslandStroke {
    /// Drawn whenever the shape is out of the notch — an activity, an alert, a
    /// surface, or the resting notch nudged out under the pointer — and never
    /// on the bare notch, which is the notch and has no edge to give.
    static func isShown(isOpen: Bool, activityShowing: Bool, notchAwake: Bool) -> Bool {
        isOpen || activityShowing || notchAwake
    }

    /// The activity's tint at 0.21 or white at 0.14; Increase Contrast, which
    /// asks for defined edges, raises them to 0.42 and 0.30.
    static func opacity(tinted: Bool, increaseContrast: Bool) -> Double {
        switch (tinted, increaseContrast) {
        case (true, false): return Theme.islandStrokeTintOpacity
        case (false, false): return Theme.islandStrokeWhiteOpacity
        case (true, true): return Theme.islandStrokeTintContrastOpacity
        case (false, true): return Theme.islandStrokeWhiteContrastOpacity
        }
    }

    /// The flat tint, never its gradient: the gradient is for glyphs and levels.
    static func color(tint: Color?, increaseContrast: Bool) -> Color {
        let opacity = opacity(tinted: tint != nil, increaseContrast: increaseContrast)
        return (tint ?? Color.white).opacity(opacity)
    }

    /// Which tint the island wears. In R7 only Charging has one (§19.4); Music,
    /// the Shelf, headphones, the volume pop-up, the peek and every surface are
    /// white. The cover's colour, which the key line used to borrow, stays on
    /// the equalizer. A charge that is only held, or a Mac that reports no
    /// level, is drawn white and so is its line — the stroke says what the
    /// content says.
    static func tint(for activity: IslandActivity, isOpen: Bool) -> Color? {
        guard !isOpen, case .ambient(let ambient) = activity, ambient.usesChargingGreen else { return nil }
        return Theme.chargingGreen
    }

    /// A shape taller than 68 casts black 0.22, radius 14, no offset, so a
    /// surface separates from a busy window under it. A compact activity and
    /// the 50 pt peek sit on the menu bar's own strip and cast nothing.
    static func castsShadow(height: CGFloat) -> Bool {
        height > Theme.islandShadowThreshold
    }
}

/// The island's outline without its top edge: the two shoulders, both sides and
/// the bottom, exactly the path `NotchShape` fills, left open along the top.
///
/// Never along the top: that edge is the bezel, and a line there would be a
/// bright seam between the island and the screen's own edge. Centred on the
/// path and drawn over the black, so a point of it lies outside the shape and a
/// point inside — the reference's line, measured.
struct IslandStrokeShape: Shape {
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
        // The island's own outline, not a copy of its arithmetic: the line can
        // only ever follow the shape it frames.
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).openPath(in: rect)
    }
}
