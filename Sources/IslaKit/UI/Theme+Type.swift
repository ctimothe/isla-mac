import SwiftUI

/// Type roles and tracking.
extension Theme {
    // MARK: - Type

    /// Letter-spacing for a given size, following the shape of SF's own
    /// tracking table.
    ///
    /// Tracking is size-specific and a single value is wrong somewhere: as type
    /// grows, the same spacing reads as letters drifting apart, so large text
    /// wants *negative* tracking; small text wants slightly positive to stay
    /// legible. Apple ships a table for this and applies it automatically to the
    /// semantic text styles — `.headline`, `.body` — but **not** to
    /// `.system(size:)`, which is what a fixed-size panel has to use. So it is
    /// applied here by hand.
    ///
    /// Why not the semantic styles: they scale with the user's text size, and
    /// both surfaces this app draws are windows that cannot resize. The lock
    /// card is a fixed 460×300 whose window is deliberately never resized, and
    /// larger type would simply be cut off. Honest tracking on a fixed size is
    /// worth more than a Dynamic Type that overflows.
    static func tracking(forSize size: CGFloat) -> CGFloat {
        switch size {
        case ..<12: return 0.07      // small labels open up a little
        case ..<15: return 0         // body sits at the neutral point
        case ..<18: return -0.2
        case ..<23: return -0.35
        default: return -0.5         // display sizes tighten most
        }
    }

    /// Six roles, not fifteen sizes.
    ///
    /// Every size here was chosen locally and well, which is how there came to
    /// be fifteen of them — 7, 8, 9, 10, 10.5, 11, 11.5, 12, 13, 15, 16, 20,
    /// 21, 22, 26, 28, plus computed. A reader cannot tell 10pt from 11pt
    /// apart as a decision, only as noise, so the roles are the vocabulary and
    /// a size that is not a role has to justify itself where it stands. Each
    /// role sits at the rung its cluster already gathered around: the 9pt
    /// labels carrying most of the panel rise to the caption floor AppKit
    /// itself sets at 10pt, the 10.5/11.5 in-betweens rejoin the body they
    /// were always a rounding away from, and the lyric stage's 15 meets the
    /// card's 16 at the title they already shared a tracking band at.
    ///
    /// `tracking(forSize:)` stays: the table is Apple's, indexed by points,
    /// and the roles read from it rather than replacing it.
    enum TypeRole: CaseIterable {
        /// Tab titles, counters, scrubber times, section headers, footnotes —
        /// most of the panel's labels. AppKit's own caption floor.
        case caption
        /// The reading voice: row titles, translated text, status lines.
        case body
        /// The redesign's reading text (spec §2.2): the boards' 12 and 12.5 —
        /// a player's subtitle, a clipboard row, the charge level and a device
        /// name on the compact island. Half a point over `body`, which is the
        /// difference between a status line and a line that is the content.
        case reading
        /// One step up from reading: rail icons, empty-state status, picker rows.
        case subhead
        /// Track titles and lyric lines.
        case title
        /// The tall lyric page (spec §2.2): 17 pt, a step over `title` because
        /// the page is read from an arm's length and the sung line is carried
        /// by weight and brightness, never by size (decision 6).
        case lyric
        /// Empty-state glyphs and transport symbols.
        case display
        /// The artwork placeholder and the lock card's play button.
        case hero

        var size: CGFloat {
            switch self {
            case .caption: return 10
            case .body: return 11
            case .reading: return 12.5
            case .subhead: return 13
            case .title: return 16
            case .lyric: return 17
            case .display: return 21
            case .hero: return 28
            }
        }

        /// What the role usually weighs. Titles arrive semibold; everything
        /// else arrives medium and says so only when it wants otherwise.
        var weight: Font.Weight {
            switch self {
            case .title: return .semibold
            default: return .medium
            }
        }

        /// The role as a `Font`, for the places a view modifier cannot reach —
        /// a `KaraokeText` parameter, a monospaced digit chain, a button style.
        func font(weight: Font.Weight? = nil) -> Font {
            .system(size: size, weight: weight ?? self.weight)
        }
    }
}
