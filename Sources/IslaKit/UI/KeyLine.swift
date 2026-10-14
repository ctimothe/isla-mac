import SwiftUI

/// The island's key line (spec §3.3): a 1 pt stroke just outside the black,
/// tinted to what the island shows, so a black island does not vanish on a
/// black wallpaper.
///
/// This file holds the decisions as pure functions — whether to draw it, in
/// which colour — so the rules the owner approved are tests, and `Shape` that
/// draws it. `NotchContentView` puts the shape under the island's black, where
/// only its outer half shows.
enum KeyLine {
    /// Drawn on a dark wallpaper, where the island would disappear, and on
    /// **every** wallpaper while Increase Contrast is on: that setting asks for
    /// defined edges, and the island's edge is the one thing it has to offer
    /// that on a mid-dark desktop is hard to find. Anything the wallpaper
    /// check could not establish is `.unknown`, which is not dark: the line is
    /// then absent rather than wrong.
    static func isShown(tone: WallpaperTone.Reading, increaseContrast: Bool) -> Bool {
        increaseContrast || tone == .dark
    }

    enum Style: Equatable {
        /// The cover's tint at half strength: the island or panel is showing
        /// music.
        case music
        /// White at 0.26: every other tab and moment.
        case neutral
    }

    /// Which of the two the island wears.
    ///
    /// Open, it is the Music tab with a song loaded — the other tabs, the
    /// welcome and an empty player are neutral. Shut, it is the music pill, and
    /// a charger or headphones having their moment over it is neutral: the line
    /// says what the island is *about* right now, and for those two moments it
    /// is not the song.
    static func style(
        isOpen: Bool, onMusicTab: Bool, hasTrack: Bool, pillShowsMusic: Bool, momentShowing: Bool
    ) -> Style {
        if isOpen { return onMusicTab && hasTrack ? .music : .neutral }
        return pillShowsMusic && !momentShowing ? .music : .neutral
    }

    static func opacity(for style: Style) -> Double {
        switch style {
        case .music: return Theme.keyLineMusicOpacity
        case .neutral: return Theme.keyLineNeutralOpacity
        }
    }

    static func color(for style: Style, tint: CoverTint) -> Color {
        switch style {
        case .music: return tint.color.opacity(opacity(for: style))
        case .neutral: return Color.white.opacity(opacity(for: style))
        }
    }
}

/// The island's outline without its top edge: the two concave shoulders, both
/// sides and the bottom, exactly the path `NotchShape` fills, left open along
/// the top.
///
/// Never along the top: that edge is the bezel, and a line there would be a
/// bright seam between the island and the screen's own edge. The stroke is
/// centred on the path, so it is drawn twice the width wanted *under* the
/// island's black and only the outer half shows — the black, filled over it,
/// is what makes it "just outside".
struct KeyLineShape: Shape {
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
