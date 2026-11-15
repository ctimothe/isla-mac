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

    private func island(notchWidth: CGFloat, height: CGFloat = 38) -> CGSize {
        CompactMediaActivity.playing.bodySize(
            notchSize: CGSize(width: notchWidth, height: height), bodyWidth: 620
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
        XCTAssertGreaterThanOrEqual(
            Theme.restingNotchBottomRadius, Theme.collapsedBottomRadius,
            "folding into the notch never gains a corner"
        )
    }

    // MARK: Widths

    func testEachCompactActivityIsTheNotchPlusItsOwnDelta() {
        XCTAssertEqual(NotchMetrics.compactMediaExtension, 70)
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
                NotchViewModel.ambientBodySize(charger, notchSize: notchSize, bodyWidth: 620),
                CGSize(width: notch + 180, height: notchHeight), "Charging at nw \(notch)"
            )
        }
        XCTAssertEqual(
            NotchViewModel.shelfBodySize(notchSize: CGSize(width: 240, height: 38), bodyWidth: 300).width, 300,
            "never wider than the panel"
        )
    }

    // MARK: Music

    /// The cover 22 × 22, radius 5: the morph's compact end.
    func testTheCoverIsTheMorphsCompactEnd() {
        XCTAssertEqual(CompactIslandLayout.coverSide(height: 38), 22)
        XCTAssertEqual(CompactIslandLayout.coverRadius(height: 38), 5)
        XCTAssertEqual(CompactIslandLayout.coverLeading, 17.3)
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
        XCTAssertEqual(CompactIslandLayout.batteryBodySize, CGSize(width: 28, height: 16))
        XCTAssertEqual(CompactIslandLayout.batteryCapSize, CGSize(width: 2, height: 6))
        XCTAssertEqual(CompactIslandLayout.batteryCapGap, 1.5)
        XCTAssertEqual(CompactIslandLayout.batteryTrailing, 19.3)
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
        XCTAssertEqual(CompactIslandLayout.coverSide(height: 24), 16)
        XCTAssertEqual(CompactIslandLayout.coverRadius(height: 24), 4)
        XCTAssertEqual(CompactIslandLayout.glyphScale(height: 24), 0.75)
        XCTAssertEqual(CompactIslandLayout.shelfGlyphFrame(height: 24).size, CGSize(width: 19.5, height: 15))
        for height: CGFloat in [32, 38] {
            XCTAssertEqual(CompactIslandLayout.glyphScale(height: height), 1)
            XCTAssertEqual(CompactIslandLayout.coverSide(height: height), 22)
            XCTAssertEqual(CompactIslandLayout.shelfGlyphFrame(height: height).midY, height / 2, "centred in \(height)")
        }
    }

    /// Green means charging, and only a battery that says how full it is can
    /// be drawn that way.
    func testOnlyAChargingBatteryWithALevelIsGreen() {
        XCTAssertTrue(AmbientActivity.charging(level: 82, isCharging: true).chargeTint == .green)
        XCTAssertFalse(AmbientActivity.charging(level: nil, isCharging: true).chargeTint == .green)
        XCTAssertFalse(AmbientActivity.charging(level: 80, isCharging: false).chargeTint == .green, "held, not charging")
        XCTAssertFalse(AmbientActivity.headphones(name: "AirPods", symbol: "airpods").chargeTint == .green)
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

    /// While a new track shows, the island hangs under the notch as the
    /// pop-up does (spec §3.5, amended 2026-11-15), and the rects the pointer
    /// and the click are tested against are cut for that — then cut back.
    @MainActor
    func testTheActiveAndHoverRectsFollowANewTracksHeight() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let alert = NotchViewModel.newTrackBodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
        let resting = geometry.collapsedIslandRect(for: alert.width)
        let showing = geometry.collapsedIslandRect(for: alert.width, height: alert.height)
        XCTAssertEqual(resting.height, geometry.collapsedDepth)
        XCTAssertEqual(showing.height, max(alert.height, geometry.collapsedDepth))
        XCTAssertEqual(showing.maxY, resting.maxY, "both hang from the top of the display")
        XCTAssertLessThan(showing.minY, resting.minY, "the alert reaches further down")

        let target = geometry.collapsedHoverRect(for: alert.width, height: alert.height)
        XCTAssertTrue(target.insetBy(dx: -1, dy: -1).contains(showing), "the open target contains the island")
        let belowTheNotch = CGPoint(x: showing.midX, y: showing.minY + 2)
        XCTAssertTrue(geometry.collapsedIslandHoverRect(for: alert.width, height: alert.height).contains(belowTheNotch))
        XCTAssertFalse(geometry.collapsedIslandHoverRect(for: alert.width).contains(belowTheNotch),
                       "the folded rect does not")

        // A height under the notch's can never shrink the target.
        XCTAssertEqual(geometry.collapsedIslandRect(for: 300, height: 4).height, geometry.collapsedDepth)
    }

    /// The gesture rect the SwiftUI click is tested against takes the island's
    /// own height, so every point of a new track's alert under the notch
    /// opens the panel too, shoulders included.
    @MainActor
    func testTheClickRectCoversANewTracksAlert() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current())
        let alert = NotchViewModel.newTrackBodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width)
        let shoulder = IslandShapeRadii.closed(for: .peek).top
        let rect = geometry.compactGestureRect(for: alert, topRadius: shoulder)
        XCTAssertEqual(rect.height, alert.height)
        XCTAssertEqual(rect.width, alert.width + 2 * shoulder, accuracy: 0.001)
    }
}
