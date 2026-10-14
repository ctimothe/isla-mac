import CoreGraphics

/// Where everything sits inside the compact island (spec §3.1, §3.5, §3.6).
///
/// Island-local coordinates: the origin is the top-left of the island's *body* —
/// the shoulders' slack outside it is not counted — and y grows downward, the
/// way SwiftUI measures. Pure, so the margins the owner settled on 2026-10-15
/// are tests rather than numbers read off a board, and so the view that draws
/// them and the test that holds them cannot describe two islands.
///
/// Everything is vertically centred in the island's height, and that is the
/// whole of the "7 from the bottom" rule: on the 38 pt notch of a 14-inch
/// MacBook Pro a 24 pt cover centred is 7 from the top and 7 from the bottom;
/// the peek's 34 pt cover centred in 50 pt is 8 from both. Stating *centred*
/// rather than 7 keeps the cover on its row on a notch of another height
/// (32 pt at some display scalings), where a fixed 7 from the bottom would
/// have pushed it into the menu bar's top edge.
enum CompactIslandLayout {
    // MARK: Cover

    /// The cover's side and corner, from the one description the panel's
    /// travel also reads — see `Theme.artworkMetrics`.
    static var coverSide: CGFloat { Theme.artworkMetrics(isOpen: false).side }
    static var coverRadius: CGFloat { Theme.artworkMetrics(isOpen: false).cornerRadius }

    /// The cover while a new track is peeking: 34 pt, radius 8, concentric with
    /// the peek's 16.
    static var peekCoverSide: CGFloat { Theme.peekArtworkMetrics.side }

    static func coverFrame(height: CGFloat) -> CGRect {
        centred(side: coverSide, height: height, x: NotchMetrics.compactEdgeInset)
    }

    static func peekCoverFrame(height: CGFloat) -> CGRect {
        centred(side: peekCoverSide, height: height, x: NotchMetrics.compactEdgeInset)
    }

    private static func centred(side: CGFloat, height: CGFloat, x: CGFloat) -> CGRect {
        CGRect(x: x, y: (height - side) / 2, width: side, height: side)
    }

    // MARK: Equalizer

    /// Four bars, 2.5 wide with 2 between them: 16 in all. (The spec writes
    /// "16.5 in all"; 4 × 2.5 + 3 × 2 is 16. Its rule — the last bar ends 8 from
    /// the island's right edge — is the one kept exactly.)
    static let equalizerBarCount = 4
    static let equalizerBarWidth: CGFloat = 2.5
    static let equalizerBarSpacing: CGFloat = 2
    /// The box the bars move in. The tallest bar is 16, so a box of exactly
    /// that never clips and never claims more of the wing than it draws.
    static let equalizerHeight: CGFloat = 16
    static var equalizerWidth: CGFloat {
        CGFloat(equalizerBarCount) * equalizerBarWidth
            + CGFloat(equalizerBarCount - 1) * equalizerBarSpacing
    }

    /// Its last bar ends `compactEdgeInset` from the island's right edge,
    /// centred on the cover's row — also the peek's, at y 25 of 50.
    static func equalizerFrame(islandWidth: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: islandWidth - NotchMetrics.compactEdgeInset - equalizerWidth,
            y: (height - equalizerHeight) / 2,
            width: equalizerWidth,
            height: equalizerHeight
        )
    }

    // MARK: Peek text

    /// Where a peek's title and artist begin: 8 inset, a 34 pt cover and 10 pt
    /// of air, which is the board's x of 52.
    static var peekTextLeading: CGFloat {
        NotchMetrics.compactEdgeInset + peekCoverSide + 10
    }

    /// How wide the peek's two lines may run before they truncate at the tail.
    ///
    /// On a display with no cutout, the whole way to the equalizer, as the
    /// board draws it. Over a real notch only as far as the left wing: the
    /// board draws the title straight across the camera housing, where on
    /// hardware there is no pixel to light, so a title longer than the wing
    /// would lose its middle to the cutout instead of showing an ellipsis. The
    /// wing is narrow — 90 pt on the 14-inch — which is the cost of a peek that
    /// stays 520 pt (decision 3).
    static func peekTextWidth(islandWidth: CGFloat, notchWidth: CGFloat, isPhysical: Bool) -> CGFloat {
        if isPhysical {
            let wing = (islandWidth - notchWidth) / 2
            return max(0, wing - NotchMetrics.compactEdgeInset - peekTextLeading)
        }
        return max(0, islandWidth - peekTextLeading - 34)
    }

    // MARK: Moments

    /// The centre of the glyph in the left wing — where the cover sits, so a
    /// bolt or a pair of headphones replaces the cover rather than sitting
    /// beside it. Fixed at 20 from the left edge in both moments: in the
    /// headphones' 104 pt wing it does not drift towards the notch.
    static var momentGlyphCentreX: CGFloat {
        NotchMetrics.compactEdgeInset + coverSide / 2
    }

    /// The charge level's box: right-aligned, 8 from the edge, wide enough for
    /// "100%" at 12 pt semibold with tabular digits. It reaches 4 pt into the
    /// notch's zone on the 14-inch, which the text itself, right-aligned and
    /// about 26 pt long at "82%", never does.
    static let chargeLevelWidth: CGFloat = 44

    /// The device name's box in the right wing: from 6 pt past the notch to
    /// 8 pt short of the island's edge — 90 pt of a 104 pt wing — right-aligned
    /// and truncating at its tail.
    static func deviceNameWidth(wing: CGFloat) -> CGFloat {
        max(0, wing - 6 - NotchMetrics.compactEdgeInset)
    }
}
