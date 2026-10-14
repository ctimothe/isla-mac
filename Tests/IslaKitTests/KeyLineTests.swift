import SwiftUI
import XCTest
@testable import IslaKit

/// The key line (redesign spec §3.3): when the island draws its 1 pt edge, in
/// which colour, and where it never goes.
final class KeyLineTests: XCTestCase {
    // MARK: When

    /// The decision table. Shown on a dark wallpaper; on every wallpaper while
    /// Increase Contrast is on; never because a wallpaper could not be read.
    func testTheKeyLineShowsOnADarkWallpaperAndAlwaysUnderIncreaseContrast() {
        XCTAssertTrue(KeyLine.isShown(tone: .dark, increaseContrast: false))
        XCTAssertFalse(KeyLine.isShown(tone: .light, increaseContrast: false))
        XCTAssertFalse(KeyLine.isShown(tone: .unknown, increaseContrast: false),
                       "a wallpaper that could not be read is not dark: absent rather than wrong")
        XCTAssertTrue(KeyLine.isShown(tone: .dark, increaseContrast: true))
        XCTAssertTrue(KeyLine.isShown(tone: .light, increaseContrast: true), "on every wallpaper")
        XCTAssertTrue(KeyLine.isShown(tone: .unknown, increaseContrast: true), "even when the wallpaper is unknown")
    }

    // MARK: Which

    /// Music round a music island or panel, neutral for every other tab and
    /// moment.
    func testTheStyleIsMusicOnlyWhileTheIslandOrPanelShowsMusic() {
        func style(
            open: Bool = false, music: Bool = false, track: Bool = true, pill: Bool = false, moment: Bool = false
        ) -> KeyLine.Style {
            KeyLine.style(isOpen: open, onMusicTab: music, hasTrack: track, pillShowsMusic: pill, momentShowing: moment)
        }
        XCTAssertEqual(style(pill: true), .music, "the compact island showing a song")
        XCTAssertEqual(style(pill: true, moment: true), .neutral, "a charger or headphones over it")
        XCTAssertEqual(style(pill: false), .neutral, "nothing to show")
        XCTAssertEqual(style(open: true, music: true), .music, "the open Music tab with a song")
        XCTAssertEqual(style(open: true, music: true, track: false), .neutral, "an empty player")
        XCTAssertEqual(style(open: true, music: false), .neutral, "every other tab")
        XCTAssertEqual(style(open: true, music: false, pill: true), .neutral, "the pill's music does not tint another tab")
    }

    func testTheColoursAreTheCoversTintAtHalfAndWhiteAtTwentySixPercent() {
        XCTAssertEqual(Theme.keyLineMusicOpacity, 0.50)
        XCTAssertEqual(Theme.keyLineNeutralOpacity, 0.26)
        XCTAssertEqual(Theme.keyLineWidth, 1)
        XCTAssertEqual(KeyLine.opacity(for: .music), 0.50)
        XCTAssertEqual(KeyLine.opacity(for: .neutral), 0.26)

        let coral = CoverTint(red: 1, green: 0.54, blue: 0.45)
        let music = NSColor(KeyLine.color(for: .music, tint: coral)).usingColorSpace(.sRGB)
        XCTAssertEqual(try XCTUnwrap(music).alphaComponent, 0.50, accuracy: 0.005)
        XCTAssertEqual(try XCTUnwrap(music).greenComponent, 0.54, accuracy: 0.01, "the cover's own colour")
        let neutral = NSColor(KeyLine.color(for: .neutral, tint: coral)).usingColorSpace(.sRGB)
        XCTAssertEqual(try XCTUnwrap(neutral).alphaComponent, 0.26, accuracy: 0.005)
        XCTAssertEqual(try XCTUnwrap(neutral).redComponent, 1, accuracy: 0.005, "white, whatever the cover")
        XCTAssertEqual(try XCTUnwrap(neutral).blueComponent, 1, accuracy: 0.005)
    }

    // MARK: Where

    /// A 1 pt line along the shoulders, both sides and the bottom — never the
    /// top edge, which is the bezel. The shape is stroked at twice the width
    /// wanted under the black, so a point in the stroke's outer half is what
    /// shows.
    func testTheKeyLineNeverTouchesTheTopEdge() {
        let rect = CGRect(x: 0, y: 0, width: 312, height: 38)
        let shape = KeyLineShape(topRadius: 6, bottomRadius: 12)
        let stroke = shape.path(in: rect).strokedPath(StrokeStyle(lineWidth: 2))

        XCTAssertTrue(stroke.contains(CGPoint(x: 156, y: 38.5)), "the bottom edge, just outside")
        XCTAssertTrue(stroke.contains(CGPoint(x: 5.5, y: 20)), "the left side, just outside")
        XCTAssertTrue(stroke.contains(CGPoint(x: 306.5, y: 20)), "the right side, just outside")
        XCTAssertTrue(stroke.contains(CGPoint(x: 4.5, y: 1.5)), "the left shoulder's fillet, halfway down its curve")
        // Along the top, between the two shoulders' inner corners.
        for x in stride(from: CGFloat(14), through: 298, by: 14) {
            XCTAssertFalse(stroke.contains(CGPoint(x: x, y: 0.5)), "no line along the top at x \(x)")
            XCTAssertFalse(stroke.contains(CGPoint(x: x, y: -0.5)), "or above it at x \(x)")
        }
    }

    /// The line is built from the island's own outline, so it cannot drift from
    /// the shape it frames.
    func testTheKeyLineFollowsTheIslandsOwnOutline() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 50)
        let island = NotchShape(topRadius: 6, bottomRadius: 16)
        XCTAssertEqual(
            KeyLineShape(topRadius: 6, bottomRadius: 16).path(in: rect).boundingRect,
            island.path(in: rect).boundingRect
        )
        XCTAssertEqual(
            KeyLineShape(topRadius: 6, bottomRadius: 16).path(in: rect).boundingRect,
            island.openPath(in: rect).boundingRect
        )
        var animated = KeyLineShape(topRadius: 6, bottomRadius: 12)
        animated.animatableData = AnimatablePair(12, 26)
        XCTAssertEqual(animated.topRadius, 12)
        XCTAssertEqual(animated.bottomRadius, 26, "it springs with the body as it grows")
    }
}
