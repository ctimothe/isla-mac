import CoreGraphics
import XCTest
@testable import IslaKit

/// The compact island's measurements (redesign spec §3.1, §3.5, §3.6, §3.8),
/// stated as numbers so a change to any of them is a decision made in a test
/// rather than a drift read off a board.
///
/// Island-local coordinates throughout: x from the island body's left edge,
/// y down from its top. Run at notch widths 180, 200 and 220 — a synthetic
/// notch before the redesign, the new synthetic notch, and a 14-inch MacBook
/// Pro — because the margins are promised to be the same on all three.
final class CompactIslandLayoutTests: XCTestCase {
    private let notchHeight: CGFloat = 38
    private let notchWidths: [CGFloat] = [180, 200, 220]

    private func island(notchWidth: CGFloat, peeking: Bool = false) -> CGSize {
        CompactMediaActivity.playing.bodySize(
            notchSize: CGSize(width: notchWidth, height: notchHeight), peeking: peeking
        )
    }

    // MARK: Widths

    /// Redesign 2026-10-15, spec §3.1: two 40 pt wings, not two 52 pt ones.
    func testTheIslandIsTheNotchPlusTwoFortyPointWings() {
        XCTAssertEqual(NotchMetrics.compactMediaExtension, 80)
        XCTAssertEqual(NotchMetrics.compactWing, 40)
        for notch in notchWidths {
            let size = island(notchWidth: notch)
            XCTAssertEqual(size.width, notch + 80, "the island is `notch + 80` on any notch")
            XCTAssertEqual((size.width - notch) / 2, 40, "and each wing is 40")
            XCTAssertEqual(size.height, notchHeight, "the island is the notch's height")
        }
        XCTAssertEqual(island(notchWidth: 220).width, 300, "300 pt on a 14-inch MacBook Pro")
    }

    // MARK: Margins

    /// The cover is 24 pt at radius 6, 8 from the left edge and 7 from the
    /// bottom; the equalizer's last bar ends 8 from the right edge, centred on
    /// the cover.
    func testTheCoverAndTheEqualizerSitOnEightPointMarginsAtEveryNotchWidth() {
        for notch in notchWidths {
            let size = island(notchWidth: notch)
            let cover = CompactIslandLayout.coverFrame(height: size.height)
            let bars = CompactIslandLayout.equalizerFrame(islandWidth: size.width, height: size.height)

            XCTAssertEqual(cover.width, 24)
            XCTAssertEqual(cover.height, 24)
            XCTAssertEqual(CompactIslandLayout.coverRadius, 6)
            XCTAssertEqual(cover.minX, 8, "8 from the island's left edge (notch \(notch))")
            XCTAssertEqual(size.height - cover.maxY, 7, "7 from the bottom (notch \(notch))")
            XCTAssertEqual(cover.minY, 7, "and so 7 from the top")

            XCTAssertEqual(bars.width, 16)
            XCTAssertEqual(size.width - bars.maxX, 8, "the last bar ends 8 from the right edge (notch \(notch))")
            XCTAssertEqual(bars.midY, cover.midY, "centred on the cover")

            XCTAssertLessThanOrEqual(cover.maxX, NotchMetrics.compactWing, "the cover stays in the left wing")
            XCTAssertGreaterThanOrEqual(bars.minX, size.width - NotchMetrics.compactWing, "the bars stay in the right wing")
            XCTAssertEqual(cover.minX, size.width - bars.maxX, "even margins either side")
        }
    }

    func testTheEqualizerIsFourBarsTwoAndAHalfWideTwoApart() {
        XCTAssertEqual(CompactIslandLayout.equalizerBarCount, 4)
        XCTAssertEqual(CompactIslandLayout.equalizerBarWidth, 2.5)
        XCTAssertEqual(CompactIslandLayout.equalizerBarSpacing, 2)
        // The spec says "16.5 in all", which is not what 4 bars of 2.5 with 3 gaps
        // of 2 add up to: 10 + 6 = 16. The rule it exists to state is the last
        // bar ending 8 from the right edge, and that one holds exactly; the
        // generator's own 16.5 left it 8.5 out.
        XCTAssertEqual(CompactIslandLayout.equalizerWidth, 16, "4 × 2.5 + 3 × 2")
        XCTAssertEqual(CompactEqualizerMotion.restingHeights, [3, 3, 3, 3], "at rest the bars are 3 tall")
        XCTAssertEqual(CompactEqualizerMotion.playingHeights.count, 4)
        for (low, high) in zip(CompactEqualizerMotion.lowHeights, CompactEqualizerMotion.highHeights) {
            XCTAssertLessThan(low, high)
            XCTAssertLessThanOrEqual(high, CompactIslandLayout.equalizerHeight, "no bar leaves its box")
        }
    }

    /// "7 from the bottom" is "centred" on the 38 pt notch, and centred is the
    /// rule that survives a notch of another height: at 32 pt a fixed 7 from
    /// the bottom would have put the cover 1 pt from the menu bar's top edge
    /// with the rest of the wing's content on a different row.
    func testTheCoverStaysCentredOnANotchOfAnotherHeight() {
        let cover = CompactIslandLayout.coverFrame(height: 32)
        XCTAssertEqual(cover.minY, 4)
        XCTAssertEqual(32 - cover.maxY, 4)
    }

    func testTheCoverTravelsBetweenTheSizesTheRedesignNames() {
        XCTAssertEqual(Theme.artworkMetrics(isOpen: false).side, 24, "redesign 2026-10-15, spec §3.1: it was 22")
        XCTAssertEqual(Theme.artworkMetrics(isOpen: false).cornerRadius, 6)
        XCTAssertEqual(Theme.peekArtworkMetrics.side, 34)
        XCTAssertEqual(Theme.peekArtworkMetrics.cornerRadius, 8)
        XCTAssertEqual(Theme.collapsedBottomRadius, 12, "redesign 2026-10-15, spec §2.3: it was 9")
        XCTAssertEqual(Theme.peekBottomRadius, 16)
        XCTAssertGreaterThanOrEqual(
            Theme.restingNotchBottomRadius, Theme.collapsedBottomRadius,
            "folding into the notch never gains a corner"
        )
    }

    // MARK: The peek

    func testThePeekIsFiveHundredTwentyWideAndFiftyTall() {
        let size = island(notchWidth: 220, peeking: true)
        XCTAssertEqual(NotchMetrics.sneakPeekExtension, 300, "the peek's width is unchanged")
        XCTAssertEqual(size.width, 520)
        XCTAssertEqual(NotchMetrics.sneakPeekHeight, 50)
        XCTAssertEqual(size.height, 50, "it grows 12 pt below the 38 pt notch")
    }

    /// The window is never resized and the body is the widest it can be, so a
    /// narrow panel setting still caps the peek, and a bar that is already
    /// taller than 50 has nothing to grow.
    func testThePeekNeverOutgrowsThePanelOrShrinksBelowTheNotch() {
        let capped = CompactMediaActivity.playing.bodySize(
            notchSize: CGSize(width: 220, height: 38), peeking: true, bodyWidth: 480
        )
        XCTAssertEqual(capped.width, 480)
        let tall = CompactMediaActivity.playing.bodySize(
            notchSize: CGSize(width: 220, height: 60), peeking: true
        )
        XCTAssertEqual(tall.height, 60)
    }

    func testThePeekFolds() {
        XCTAssertEqual(
            CompactMediaActivity.playing.bodySize(notchSize: CGSize(width: 220, height: 38)),
            CGSize(width: 300, height: 38),
            "back to 300 × the notch's height"
        )
        XCTAssertEqual(NotchMetrics.sneakPeekDuration, 2.2, "it still holds 2.2 s")
    }

    func testThePeekCoverAndTextSitWhereTheBoardPutsThem() {
        let cover = CompactIslandLayout.peekCoverFrame(height: 50)
        XCTAssertEqual(cover, CGRect(x: 8, y: 8, width: 34, height: 34), "34 pt, inset 8 left and 8 top")
        XCTAssertEqual(CompactIslandLayout.peekTextLeading, 52, "title and artist start at x 52")
        let bars = CompactIslandLayout.equalizerFrame(islandWidth: 520, height: 50)
        XCTAssertEqual(bars.midY, 25, "the equalizer is centred at y 25")
        XCTAssertEqual(520 - bars.maxX, 8, "and 8 from the right edge")
    }

    /// Over a real notch the text may not run into the camera housing, so the
    /// two lines end 8 pt short of the cutout; on a display with none they run
    /// the board's whole way to the equalizer. Deliberate difference from the
    /// board, which draws a long title across the cutout.
    func testThePeekTextEndsBeforeTheCutoutOnARealNotchAndBeforeTheBarsWithoutOne() {
        let physical = CompactIslandLayout.peekTextWidth(islandWidth: 520, notchWidth: 220, isPhysical: true)
        XCTAssertEqual(physical, 90, "x 52 to 142 of a 150 pt wing, 8 short of the cutout")
        XCTAssertEqual(CompactIslandLayout.peekTextLeading + physical, 150 - 8)
        let synthetic = CompactIslandLayout.peekTextWidth(islandWidth: 500, notchWidth: 200, isPhysical: false)
        XCTAssertEqual(synthetic, 500 - 52 - 34, "to 34 short of the right edge, clear of the bars")
        let bars = CompactIslandLayout.equalizerFrame(islandWidth: 500, height: 50)
        XCTAssertLessThan(CompactIslandLayout.peekTextLeading + synthetic, bars.minX)
        XCTAssertEqual(
            CompactIslandLayout.peekTextWidth(islandWidth: 220, notchWidth: 220, isPhysical: true), 0,
            "a folded island has no room, and never a negative width"
        )
    }

    // MARK: Moments

    /// Charging fits the 300 pt island; headphones take two 104 pt wings.
    func testChargingIsThreeHundredWideAndHeadphonesFourTwentyEight() {
        let notch = CGSize(width: 220, height: 38)
        let charging = NotchViewModel.ambientBodySize(
            .charging(level: 82, isCharging: true), media: notch, notchSize: notch, bodyWidth: 560
        )
        XCTAssertEqual(charging.width, 300)
        XCTAssertEqual(NotchMetrics.ambientNameExtension, 208, "redesign 2026-10-15, spec §3.6: it was 220")
        let pods = NotchViewModel.ambientBodySize(
            .headphones(name: "AirPods Pro", symbol: "airpods.pro"), media: notch, notchSize: notch, bodyWidth: 560
        )
        XCTAssertEqual(pods.width, 428, "220 + 2 × 104")
        XCTAssertEqual((pods.width - 220) / 2, 104)
        XCTAssertEqual(pods.height, 38, "neither moment changes the island's height")
    }

    func testTheMomentsSitOnTheMusicIslandsMargins() {
        XCTAssertEqual(CompactIslandLayout.momentGlyphCentreX, 20, "where the cover sits")
        XCTAssertEqual(CompactIslandLayout.chargeLevelWidth, 44)
        XCTAssertEqual(CompactIslandLayout.deviceNameWidth(wing: 104), 90, "6 past the notch, 8 short of the edge")
        XCTAssertEqual(CompactIslandLayout.deviceNameWidth(wing: 4), 0)
    }

    /// Green means charging, and only a battery that says how full it is can
    /// be drawn that way; a Mac without one gets a white bolt.
    func testOnlyAChargingBatteryWithALevelIsGreen() {
        XCTAssertTrue(AmbientActivity.charging(level: 82, isCharging: true).usesChargingGreen)
        XCTAssertFalse(AmbientActivity.charging(level: nil, isCharging: true).usesChargingGreen, "no battery: a white bolt alone")
        XCTAssertFalse(AmbientActivity.charging(level: 80, isCharging: false).usesChargingGreen, "held, not charging")
        XCTAssertFalse(AmbientActivity.headphones(name: "AirPods", symbol: "airpods").usesChargingGreen)
        XCTAssertEqual(AmbientActivity.charging(level: nil, isCharging: true).chargeSymbol, "bolt.fill")
    }

    // MARK: A display without a notch

    /// Redesign 2026-10-15, spec §3.8: 200 wide, it was 180; the height rule
    /// (the menu bar's own, never under 24) is unchanged.
    func testTheSyntheticNotchIsTwoHundredWideAtTheMenuBarsHeight() {
        XCTAssertEqual(NotchGeometry.syntheticNotchWidth, 200)
        XCTAssertEqual(NotchGeometry.syntheticNotchSize(menuBarHeight: 24, statusBarThickness: 22), CGSize(width: 200, height: 24))
        XCTAssertEqual(NotchGeometry.syntheticNotchSize(menuBarHeight: 33, statusBarThickness: 22).height, 33, "the bar's own height")
        XCTAssertEqual(NotchGeometry.syntheticNotchSize(menuBarHeight: 0, statusBarThickness: 22).height, 24, "an auto-hidden bar floors at 24")
        XCTAssertEqual(NotchGeometry.syntheticNotchSize(menuBarHeight: 0, statusBarThickness: 30).height, 30)
        let island = CompactMediaActivity.playing.bodySize(
            notchSize: NotchGeometry.syntheticNotchSize(menuBarHeight: 24, statusBarThickness: 22)
        )
        XCTAssertEqual(island.width, 280, "the compact island on it is 200 + 80")
    }

    // MARK: Hit areas

    /// While the peek holds the island is 50 pt tall, and the rects the pointer
    /// and the click are tested against are cut for that — then cut back.
    @MainActor
    func testTheActiveAndHoverRectsFollowThePeeksHeight() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let resting = geometry.collapsedIslandRect(for: 520)
        let peeking = geometry.collapsedIslandRect(for: 520, height: 50)
        XCTAssertEqual(resting.height, geometry.collapsedDepth)
        XCTAssertEqual(peeking.height, max(50, geometry.collapsedDepth))
        XCTAssertEqual(peeking.maxY, resting.maxY, "both hang from the top of the display")
        XCTAssertLessThan(peeking.minY, resting.minY, "the peek reaches further down")

        let target = geometry.collapsedHoverRect(for: 520, height: 50)
        XCTAssertTrue(target.insetBy(dx: -1, dy: -1).contains(peeking), "the open target contains the island")
        let belowTheNotch = CGPoint(x: peeking.midX, y: peeking.minY + 2)
        XCTAssertTrue(geometry.collapsedIslandHoverRect(for: 520, height: 50).contains(belowTheNotch))
        XCTAssertFalse(geometry.collapsedIslandHoverRect(for: 520).contains(belowTheNotch), "the folded rect does not")

        // A height under the notch's can never shrink the target.
        XCTAssertEqual(geometry.collapsedIslandRect(for: 300, height: 4).height, geometry.collapsedDepth)
    }

    /// The gesture rect the SwiftUI click is tested against takes the island's
    /// own height, so the peek's 12 pt below the notch opens the panel too.
    @MainActor
    func testTheClickRectCoversThePeeksFiftyPoints() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current())
        let rect = geometry.compactGestureRect(
            for: CGSize(width: 520, height: 50), topRadius: Theme.collapsedTopRadius
        )
        XCTAssertEqual(rect.height, 50)
        XCTAssertEqual(rect.width, 520 + 2 * Theme.collapsedTopRadius)
    }
}
