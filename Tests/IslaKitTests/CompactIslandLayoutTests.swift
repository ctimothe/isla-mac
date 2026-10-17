import AppKit
import CoreGraphics
import XCTest
@testable import IslaKit

/// The compact island's measurements (spec §19.4, which replaced §3.1's 300 pt
/// island and its 40 pt wings on 2026-10-17), stated as numbers so a change to
/// any of them is a decision made in a test rather than a drift read off a
/// board.
///
/// The spec writes positions from the *shape's* edge — the outline with its
/// 8.67 pt shoulders, as the reference screenshots were measured — and
/// `CompactIslandLayout` lays out from the *body's*, the island between the
/// shoulders. `shape(_:)` turns one into the other, so each assertion reads as
/// the spec's own number. Run at every notch width §19.12 names.
final class CompactIslandLayoutTests: XCTestCase {
    private let notchHeight: CGFloat = 38
    private let notchWidths: [CGFloat] = [180, 185, 200, 220, 240]
    private let shoulder = Theme.collapsedTopRadius

    private func island(notchWidth: CGFloat, height: CGFloat = 38, peeking: Bool = false) -> CGSize {
        CompactMediaActivity.playing.bodySize(
            notchSize: CGSize(width: notchWidth, height: height), peeking: peeking, bodyWidth: 620
        )
    }

    /// A body-local x as the spec writes it, from the shape's left edge.
    private func shape(_ x: CGFloat) -> CGFloat { x + shoulder }
    /// How far a body-local right edge ends from the shape's right edge.
    private func right(_ maxX: CGFloat, islandWidth: CGFloat) -> CGFloat { islandWidth - maxX + shoulder }

    // MARK: The outline

    func testTheCompactOutlineIsTheReferences() {
        XCTAssertEqual(Theme.collapsedTopRadius, 8.67, "shoulders 8.67")
        XCTAssertEqual(Theme.collapsedBottomRadius, 12.67, "bottom corners 12.67")
        XCTAssertEqual(Theme.peekBottomRadius, 16, "the peek keeps its 16 on this outline")
        XCTAssertGreaterThanOrEqual(
            Theme.restingNotchBottomRadius, Theme.collapsedBottomRadius,
            "folding into the notch never gains a corner"
        )
    }

    // MARK: Widths

    func testEachCompactActivityIsTheNotchPlusItsOwnDelta() {
        XCTAssertEqual(NotchMetrics.compactMediaExtension, 70)
        XCTAssertEqual(NotchMetrics.compactWing, 35)
        XCTAssertEqual(NotchMetrics.compactShelfExtension, 75)
        XCTAssertEqual(NotchMetrics.compactChargingExtension, 180)
        let charger = AmbientActivity.charging(level: 67, isCharging: true)
        for notch in notchWidths {
            let notchSize = CGSize(width: notch, height: notchHeight)
            let music = island(notchWidth: notch)
            XCTAssertEqual(music, CGSize(width: notch + 70, height: notchHeight), "Music at nw \(notch)")
            XCTAssertEqual(
                NotchViewModel.shelfBodySize(notchSize: notchSize, bodyWidth: 620),
                CGSize(width: notch + 75, height: notchHeight), "the Shelf at nw \(notch)"
            )
            XCTAssertEqual(
                NotchViewModel.ambientBodySize(charger, media: music, notchSize: notchSize, bodyWidth: 620),
                CGSize(width: notch + 180, height: notchHeight), "Charging at nw \(notch)"
            )
        }
        XCTAssertEqual(
            NotchViewModel.shelfBodySize(notchSize: CGSize(width: 240, height: 38), bodyWidth: 300).width, 300,
            "never wider than the panel"
        )
    }

    // MARK: Music

    /// The cover 22 × 22, radius 5, at (17.3, 8); the equalizer 18 × 18, top
    /// 10, ending right 19.3 — at every notch width, so the wings' content sits
    /// where it does on the reference whatever the camera's span.
    func testTheCoverAndTheEqualizerSitWhereTheReferenceDoesAtEveryNotchWidth() {
        for notch in notchWidths {
            let size = island(notchWidth: notch)
            let cover = CompactIslandLayout.coverFrame(height: size.height)
            let bars = CompactIslandLayout.equalizerFrame(islandWidth: size.width, height: size.height)

            XCTAssertEqual(cover.size, CGSize(width: 22, height: 22))
            XCTAssertEqual(CompactIslandLayout.coverRadius(height: size.height), 5)
            XCTAssertEqual(shape(cover.minX), 17.3, accuracy: 0.001, "x 17.3 (nw \(notch))")
            XCTAssertEqual(cover.minY, 8, "y 8: centred in 38")

            XCTAssertEqual(bars.size, CGSize(width: 18, height: 18))
            XCTAssertEqual(bars.minY, 10, "top 10: centred in 38")
            XCTAssertEqual(right(bars.maxX, islandWidth: size.width), 19.3, accuracy: 0.001, "ending right 19.3 (nw \(notch))")

            XCTAssertLessThanOrEqual(cover.maxX, NotchMetrics.compactWing, "the cover stays in the left wing")
            XCTAssertGreaterThanOrEqual(bars.minX, size.width - NotchMetrics.compactWing, "the bars stay in the right wing")
        }
        XCTAssertEqual(Theme.artworkMetrics(isOpen: false).side, 22, "the morph's compact end is the cover's")
        XCTAssertEqual(Theme.artworkMetrics(isOpen: false).cornerRadius, 5)
    }

    func testTheEqualizerIsSixBarsTwoPointTwoWideAcrossEighteen() {
        XCTAssertEqual(CompactIslandLayout.equalizerBarCount, 6)
        XCTAssertEqual(CompactIslandLayout.equalizerBarWidth, 2.2)
        XCTAssertEqual(CompactIslandLayout.equalizerSide, 18)
        XCTAssertEqual(
            6 * CompactIslandLayout.equalizerBarWidth + 5 * CompactIslandLayout.equalizerBarSpacing, 18,
            accuracy: 0.0001, "six bars and five gaps fill the 18 pt box"
        )
        XCTAssertEqual(CompactEqualizerMotion.restingHeights, Array(repeating: 3, count: 6), "at rest the bars are 3 tall")
        for heights in [
            CompactEqualizerMotion.playingHeights, CompactEqualizerMotion.lowHeights,
            CompactEqualizerMotion.highHeights,
        ] {
            XCTAssertEqual(heights.count, 6)
        }
        XCTAssertEqual(CompactEqualizerMotion.durations.count, 6)
        for (low, high) in zip(CompactEqualizerMotion.lowHeights, CompactEqualizerMotion.highHeights) {
            XCTAssertLessThan(low, high)
            XCTAssertLessThanOrEqual(high, CompactIslandLayout.equalizerSide, "no bar leaves its box")
        }
    }

    /// The bars are the cover's tint as a gradient, 16 % lighter at the top
    /// (spec §19.2's table note); paused they are tertiary and flat, so the
    /// one colour on the island is still the one that moves.
    func testThePlayingBarsAreAGradientOfTheTintAndThePausedOnesAreFlat() throws {
        let red = NSColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        let playing = CompactEqualizerMotion.colors(isPlaying: true, tint: red, increaseContrast: false)
        XCTAssertEqual(playing.bottom, red)
        let top = try XCTUnwrap(playing.top.usingColorSpace(.sRGB))
        XCTAssertEqual(top.redComponent, 0.8 + 0.2 * 0.16, accuracy: 0.001)
        XCTAssertEqual(top.greenComponent, 0.2 + 0.8 * 0.16, accuracy: 0.001)
        let paused = CompactEqualizerMotion.colors(isPlaying: false, tint: red, increaseContrast: false)
        XCTAssertEqual(paused.top, paused.bottom, "flat at rest")
    }

    // MARK: The Shelf

    /// `tray.full.fill` 26 × 20 at (17.3, 9); the count, SF Pro Rounded 16,
    /// ending right 18.3.
    func testTheShelfsTrayAndCountSitWhereTheReferenceDoes() {
        for notch in notchWidths {
            let width = notch + NotchMetrics.compactShelfExtension
            let tray = CompactIslandLayout.shelfGlyphFrame(height: notchHeight)
            XCTAssertEqual(tray.size, CGSize(width: 26, height: 20))
            XCTAssertEqual(shape(tray.minX), 17.3, accuracy: 0.001)
            XCTAssertEqual(tray.minY, 9)
            XCTAssertEqual(
                right(width - CompactIslandLayout.shelfCountTrailingInset, islandWidth: width), 18.3, accuracy: 0.001
            )
        }
        XCTAssertEqual(CompactIslandLayout.shelfCountFontSize, 16)
    }

    // MARK: Charging

    /// "Charging" from 18.5; the level, 6 pt, a drawn battery — body 28 × 16
    /// radius 6, 1.5 pt, a cap 2 × 6 radius 1.5 — ending right 19.3.
    func testChargingsWordLevelAndBatterySitWhereTheReferenceDoes() {
        XCTAssertEqual(CompactIslandLayout.chargingTextLeading, 18.5)
        XCTAssertEqual(shape(CompactIslandLayout.chargingTextInset), 18.5, accuracy: 0.001)
        XCTAssertEqual(CompactIslandLayout.chargingTextSize, 14)
        XCTAssertEqual(CompactIslandLayout.levelToBatteryGap, 6)
        for notch in notchWidths {
            let width = notch + NotchMetrics.compactChargingExtension
            let battery = CompactIslandLayout.batteryFrame(islandWidth: width, height: notchHeight)
            XCTAssertEqual(battery.body.size, CGSize(width: 28, height: 16))
            XCTAssertEqual(battery.cap.size, CGSize(width: 2, height: 6))
            XCTAssertEqual(battery.cap.minX - battery.body.maxX, 1.5, accuracy: 0.001)
            XCTAssertEqual(right(battery.cap.maxX, islandWidth: width), 19.3, accuracy: 0.001)
            XCTAssertEqual(battery.body.midY, notchHeight / 2, "vertically centred")
            XCTAssertEqual(battery.cap.midY, battery.body.midY)
        }
        XCTAssertEqual(CompactIslandLayout.batteryRadius, 6)
        XCTAssertEqual(CompactIslandLayout.batteryCapRadius, 1.5)
    }

    func testTheBatteryFillsToItsLevel() {
        XCTAssertEqual(CompactIslandLayout.batteryFillWidth(level: 67, bodyWidth: 28), 28 * 0.67, accuracy: 0.001)
        XCTAssertEqual(CompactIslandLayout.batteryFillWidth(level: 0, bodyWidth: 28), 0)
        XCTAssertEqual(CompactIslandLayout.batteryFillWidth(level: 140, bodyWidth: 28), 28, "never past the body")
        XCTAssertEqual(CompactIslandLayout.batteryFillWidth(level: -3, bodyWidth: 28), 0)
    }

    /// Charging is the island's word since §19.14, «Зарядка»; the Settings
    /// row it used to name is "Charger Connected", so one key is never both.
    @MainActor
    func testChargingIsTheIslandsWordAndTheSettingsRowHasItsOwn() {
        XCTAssertEqual(SettingsRowID.charging.title, localized("Charger Connected"))
        XCTAssertNotEqual(SettingsRowID.charging.title, localized("Charging"))
    }

    /// A Mac with no battery shows no Charging activity (§19.4): there is no
    /// level for the battery to draw.
    func testAMacWithNoBatteryShowsNoCharging() {
        XCTAssertTrue(AmbientActivity.charging(level: 67, isCharging: true).showsOnIsland)
        XCTAssertTrue(AmbientActivity.charging(level: 80, isCharging: false).showsOnIsland, "held, but a level")
        XCTAssertFalse(AmbientActivity.charging(level: nil, isCharging: true).showsOnIsland)
        XCTAssertTrue(AmbientActivity.headphones(name: "AirPods", symbol: "airpods").showsOnIsland)
    }

    // MARK: Other heights

    /// On a display Isla draws the notch for (`H` 24) the cover is 16 and the
    /// glyphs are 0.75 of their size; at 32 and 38 everything is full size and
    /// centred.
    func testTheShortIslandsCoverIsSixteenAndItsGlyphsThreeQuarters() {
        let short = CompactIslandLayout.coverFrame(height: 24)
        XCTAssertEqual(short.size, CGSize(width: 16, height: 16))
        XCTAssertEqual(short.minY, 4, "centred in 24")
        XCTAssertEqual(CompactIslandLayout.glyphScale(height: 24), 0.75)
        XCTAssertEqual(CompactIslandLayout.equalizerFrame(islandWidth: 270, height: 24).size, CGSize(width: 13.5, height: 13.5))
        XCTAssertEqual(CompactIslandLayout.shelfGlyphFrame(height: 24).size, CGSize(width: 19.5, height: 15))
        XCTAssertEqual(CompactIslandLayout.batteryFrame(islandWidth: 380, height: 24).body.size, CGSize(width: 21, height: 12))
        for height: CGFloat in [32, 38] {
            XCTAssertEqual(CompactIslandLayout.glyphScale(height: height), 1)
            let cover = CompactIslandLayout.coverFrame(height: height)
            XCTAssertEqual(cover.size.width, 22)
            XCTAssertEqual(cover.midY, height / 2, "centred in \(height)")
            XCTAssertEqual(CompactIslandLayout.equalizerFrame(islandWidth: 290, height: height).midY, height / 2)
        }
        XCTAssertEqual(CompactIslandLayout.coverFrame(height: 32).minY, 5)
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
            CGSize(width: 290, height: 38),
            "back to the notch plus 70, at the notch's height"
        )
        XCTAssertEqual(NotchMetrics.sneakPeekDuration, 2.2, "it still holds 2.2 s")
    }

    /// The peek keeps its content (§19.4): a 34 pt cover 8 from the top, on the
    /// resting cover's own left edge so nothing jumps sideways as it grows,
    /// and the title 10 past it; the equalizer centred, on the resting bars'
    /// right edge.
    func testThePeekCoverAndTextSitWhereTheBoardPutsThem() {
        let cover = CompactIslandLayout.peekCoverFrame(height: 50)
        XCTAssertEqual(cover.size, CGSize(width: 34, height: 34))
        XCTAssertEqual(cover.minY, 8)
        XCTAssertEqual(cover.minX, CompactIslandLayout.coverFrame(height: 38).minX, "the resting cover's left edge")
        XCTAssertEqual(CompactIslandLayout.peekTextLeading, cover.maxX + 10, accuracy: 0.001)
        let bars = CompactIslandLayout.equalizerFrame(islandWidth: 520, height: 50)
        XCTAssertEqual(bars.midY, 25, "the equalizer is centred at y 25")
        XCTAssertEqual(right(bars.maxX, islandWidth: 520), 19.3, accuracy: 0.001)
    }

    /// Over a real notch the text may not run into the camera housing, so the
    /// two lines end 8 pt short of the cutout; on a display with none they run
    /// the board's whole way to the equalizer. Deliberate difference from the
    /// board, which draws a long title across the cutout.
    func testThePeekTextEndsBeforeTheCutoutOnARealNotchAndBeforeTheBarsWithoutOne() {
        let leading = CompactIslandLayout.peekTextLeading
        let physical = CompactIslandLayout.peekTextWidth(islandWidth: 520, notchWidth: 220, isPhysical: true)
        XCTAssertEqual(leading + physical, 150 - 8, accuracy: 0.001, "8 short of the cutout, in a 150 pt wing")
        let synthetic = CompactIslandLayout.peekTextWidth(islandWidth: 500, notchWidth: 200, isPhysical: false)
        let bars = CompactIslandLayout.equalizerFrame(islandWidth: 500, height: 50)
        XCTAssertLessThan(CompactIslandLayout.peekTextLeading + synthetic, bars.minX)
        XCTAssertEqual(
            CompactIslandLayout.peekTextWidth(islandWidth: 220, notchWidth: 220, isPhysical: true), 0,
            "a folded island has no room, and never a negative width"
        )
    }

    // MARK: Headphones

    /// Headphones keep §3.6's compact form until R7's Task 5 restyles them
    /// (spec §19.5 c): two 104 pt wings.
    func testHeadphonesStillTakeTwoHundredAndEightUntilTheyAreRestyled() {
        let notch = CGSize(width: 220, height: 38)
        XCTAssertEqual(NotchMetrics.ambientNameExtension, 208)
        let pods = NotchViewModel.ambientBodySize(
            .headphones(name: "AirPods Pro", symbol: "airpods.pro"), media: notch, notchSize: notch, bodyWidth: 560
        )
        XCTAssertEqual(pods.width, 428, "220 + 2 × 104")
        XCTAssertEqual(pods.height, 38)
        XCTAssertEqual(CompactIslandLayout.deviceNameWidth(wing: 104), 104 - 6 - CompactIslandLayout.coverFrame(height: 38).minX, accuracy: 0.001)
        XCTAssertEqual(CompactIslandLayout.deviceNameWidth(wing: 4), 0)
    }

    /// Green means charging, and only a battery that says how full it is can
    /// be drawn that way.
    func testOnlyAChargingBatteryWithALevelIsGreen() {
        XCTAssertTrue(AmbientActivity.charging(level: 82, isCharging: true).usesChargingGreen)
        XCTAssertFalse(AmbientActivity.charging(level: nil, isCharging: true).usesChargingGreen)
        XCTAssertFalse(AmbientActivity.charging(level: 80, isCharging: false).usesChargingGreen, "held, not charging")
        XCTAssertFalse(AmbientActivity.headphones(name: "AirPods", symbol: "airpods").usesChargingGreen)
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
        XCTAssertEqual(island.width, 270, "the compact island on it is 200 + 70")
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
