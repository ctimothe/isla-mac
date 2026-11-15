import CoreGraphics

/// Where everything sits inside the compact island (spec §19.4; a new track is
/// an expanded alert since §3.5's amendment of 2026-11-15, `NewTrackAlertLayout`).
///
/// Island-local coordinates: the origin is the top-left of the island's *body* —
/// the shoulders' slack outside it is not counted — and y grows downward, the
/// way SwiftUI measures. The spec writes its positions from the *shape's* edge,
/// shoulders included, because that is how the reference screenshots were
/// measured; each constant below is stated in the spec's terms and turned into
/// the body's by subtracting `shoulder`, so the number in the code is the
/// number in the spec. Pure, so the view that draws them and the test that
/// holds them cannot describe two islands.
///
/// Everything is vertically centred in the island's height `H`. That keeps the
/// reference's rows — the cover 8 from the top of a 38 pt island, the bars 10 —
/// on the notch of another height (32 pt at some display scalings), where a
/// fixed offset would push the cover into the menu bar's top edge. Below 32 —
/// the 24 pt notch Isla draws on a display without one — the cover is 16 and
/// every glyph is three quarters of its size, or a 22 pt cover would leave one
/// point above and below.
enum CompactIslandLayout {
    /// The outline's shoulder, which the spec's positions include and this
    /// layout's do not.
    static var shoulder: CGFloat { Theme.collapsedTopRadius }

    /// Three quarters on an island shorter than 32, else full size.
    static func glyphScale(height: CGFloat) -> CGFloat {
        height < 32 ? 0.75 : 1
    }

    // MARK: Cover

    /// The cover's left edge: 17.3 from the shape's.
    static let coverLeading: CGFloat = 17.3
    static var coverInset: CGFloat { coverLeading - shoulder }

    /// 22 pt at radius 5 — the morph's compact end, `Theme.artworkMetrics` —
    /// or 16 at 4 on the short island.
    static func coverSide(height: CGFloat) -> CGFloat {
        glyphScale(height: height) < 1 ? 16 : Theme.artworkMetrics(isOpen: false).side
    }

    static func coverRadius(height: CGFloat) -> CGFloat {
        glyphScale(height: height) < 1 ? 4 : Theme.artworkMetrics(isOpen: false).cornerRadius
    }

    static func coverFrame(height: CGFloat) -> CGRect {
        centred(side: coverSide(height: height), height: height, x: coverInset)
    }

    private static func centred(side: CGFloat, height: CGFloat, x: CGFloat) -> CGRect {
        CGRect(x: x, y: (height - side) / 2, width: side, height: side)
    }

    // MARK: Equalizer

    /// Six bars 2.2 wide across an 18 pt box, ending 19.3 from the shape's
    /// right edge. The spec gives the box and the bars; the gap is what is
    /// left, 0.96.
    static let equalizerBarCount = 6
    static let equalizerBarWidth: CGFloat = 2.2
    static let equalizerSide: CGFloat = 18
    static var equalizerBarSpacing: CGFloat {
        (equalizerSide - CGFloat(equalizerBarCount) * equalizerBarWidth) / CGFloat(equalizerBarCount - 1)
    }
    static let equalizerTrailing: CGFloat = 19.3
    static var equalizerTrailingInset: CGFloat { equalizerTrailing - shoulder }

    /// Centred on the cover's row.
    static func equalizerFrame(islandWidth: CGFloat, height: CGFloat) -> CGRect {
        let side = equalizerSide * glyphScale(height: height)
        return CGRect(
            x: islandWidth - equalizerTrailingInset - side,
            y: (height - side) / 2,
            width: side,
            height: side
        )
    }

    /// How far a wing's text stays from the camera's cutout.
    static let cutoutClearance: CGFloat = 8

    // MARK: The Shelf (spec §19.4)

    /// `tray.full.fill`, 26 × 20 at (17.3, 9).
    static let shelfGlyphSize = CGSize(width: 26, height: 20)

    static func shelfGlyphFrame(height: CGFloat) -> CGRect {
        let scale = glyphScale(height: height)
        let size = CGSize(width: shelfGlyphSize.width * scale, height: shelfGlyphSize.height * scale)
        return CGRect(x: coverInset, y: (height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The count, SF Pro Rounded 16, tabular, ending 18.3 from the shape's
    /// right edge.
    static let shelfCountFontSize: CGFloat = 16
    static let shelfCountTrailing: CGFloat = 18.3
    static var shelfCountTrailingInset: CGFloat { shelfCountTrailing - shoulder }

    // MARK: Charging (spec §19.4)

    /// "Charging", 14 regular, white 0.88, from 18.5.
    static let chargingTextLeading: CGFloat = 18.5
    static var chargingTextInset: CGFloat { chargingTextLeading - shoulder }
    static let chargingTextSize: CGFloat = 14
    static let chargingTextOpacity: Double = 0.88

    /// The level, then 6 pt, then the battery.
    static let levelToBatteryGap: CGFloat = 6

    /// A drawn battery, not `battery.100`: the symbol's fill steps in quarters,
    /// and the level is the thing this activity exists to show. Body 28 × 16,
    /// radius 6; 1.5 pt; a cap 2 × 6, radius 1.5; ending 19.3 from the shape's
    /// right edge.
    static let batteryBodySize = CGSize(width: 28, height: 16)
    static let batteryRadius: CGFloat = 6
    static let batteryCapGap: CGFloat = 1.5
    static let batteryCapSize = CGSize(width: 2, height: 6)
    static let batteryCapRadius: CGFloat = 1.5
    static let batteryTrailing: CGFloat = 19.3
    /// The body's and the cap's track, in the tint.
    static let batteryTrackOpacity: Double = 0.30

    static func batteryFrame(islandWidth: CGFloat, height: CGFloat) -> (body: CGRect, cap: CGRect) {
        let scale = glyphScale(height: height)
        let capSize = CGSize(width: batteryCapSize.width * scale, height: batteryCapSize.height * scale)
        let bodySize = CGSize(width: batteryBodySize.width * scale, height: batteryBodySize.height * scale)
        let cap = CGRect(
            x: islandWidth - (batteryTrailing - shoulder) - capSize.width,
            y: (height - capSize.height) / 2,
            width: capSize.width, height: capSize.height
        )
        let body = CGRect(
            x: cap.minX - batteryCapGap * scale - bodySize.width,
            y: (height - bodySize.height) / 2,
            width: bodySize.width, height: bodySize.height
        )
        return (body, cap)
    }

    /// The level's share of the body, never past either end of it.
    static func batteryFillWidth(level: Int, bodyWidth: CGFloat) -> CGFloat {
        bodyWidth * CGFloat(min(max(level, 0), 100)) / 100
    }
}
