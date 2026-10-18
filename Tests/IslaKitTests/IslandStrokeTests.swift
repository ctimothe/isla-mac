import SwiftUI
import XCTest
@testable import IslaKit

/// The island's stroke and shadow (redesign spec §19.2): when the 2 pt line is
/// drawn, in which colour, where it never goes, and which shapes cast a shadow.
/// It replaced §3.3's 1 pt key line, which was drawn only on a dark wallpaper.
final class IslandStrokeTests: XCTestCase {
    // MARK: When

    /// On every wallpaper whenever the shape is out of the notch — an activity,
    /// a surface, or the notch woken under the pointer — and never on the bare
    /// notch. Nothing about the desktop picture is asked any more.
    func testTheStrokeIsDrawnWheneverTheShapeIsOutOfTheNotchAndNeverOnTheBareNotch() {
        func shown(open: Bool = false, activity: Bool = false, awake: Bool = false) -> Bool {
            IslandStroke.isShown(isOpen: open, activityShowing: activity, notchAwake: awake)
        }
        XCTAssertFalse(shown(), "the bare notch is the notch")
        XCTAssertTrue(shown(activity: true), "a compact activity or an alert")
        XCTAssertTrue(shown(open: true), "a surface")
        XCTAssertTrue(shown(awake: true), "the notch nudged out under the pointer is wider than the notch")
        XCTAssertTrue(shown(open: true, activity: true))
    }

    // MARK: Which

    /// The activity's tint at 0.21, white at 0.14 where it has none; Increase
    /// Contrast raises them to 0.42 and 0.30.
    func testTheStrengthsAreTheSpecs() {
        XCTAssertEqual(Theme.islandStrokeWidth, 2)
        XCTAssertEqual(IslandStroke.opacity(tinted: true, increaseContrast: false), 0.21)
        XCTAssertEqual(IslandStroke.opacity(tinted: false, increaseContrast: false), 0.14)
        XCTAssertEqual(IslandStroke.opacity(tinted: true, increaseContrast: true), 0.42)
        XCTAssertEqual(IslandStroke.opacity(tinted: false, increaseContrast: true), 0.30)
    }

    func testTheColourIsTheFlatTintOrWhite() throws {
        let green = try XCTUnwrap(NSColor(IslandStroke.color(tint: Theme.chargingGreen, increaseContrast: false)).usingColorSpace(.sRGB))
        XCTAssertEqual(green.alphaComponent, 0.21, accuracy: 0.005)
        XCTAssertEqual(green.redComponent, 48.0 / 255, accuracy: 0.01, "#30D158, flat — no gradient on the stroke")
        XCTAssertEqual(green.greenComponent, 209.0 / 255, accuracy: 0.01)
        XCTAssertEqual(green.blueComponent, 88.0 / 255, accuracy: 0.01)

        let white = try XCTUnwrap(NSColor(IslandStroke.color(tint: nil, increaseContrast: false)).usingColorSpace(.sRGB))
        XCTAssertEqual(white.alphaComponent, 0.14, accuracy: 0.005)
        XCTAssertEqual(white.redComponent, 1, accuracy: 0.005)
        XCTAssertEqual(white.blueComponent, 1, accuracy: 0.005)

        let contrast = try XCTUnwrap(NSColor(IslandStroke.color(tint: nil, increaseContrast: true)).usingColorSpace(.sRGB))
        XCTAssertEqual(contrast.alphaComponent, 0.30, accuracy: 0.005)
        let contrastGreen = try XCTUnwrap(NSColor(IslandStroke.color(tint: Theme.chargingGreen, increaseContrast: true)).usingColorSpace(.sRGB))
        XCTAssertEqual(contrastGreen.alphaComponent, 0.42, accuracy: 0.005)
    }

    /// In R7 only Charging carries a tint: Music, the Shelf, headphones, the
    /// volume pop-up, the peek and every surface are white (§19.4, §19.5 c, d).
    /// The cover's colour no longer reaches the stroke.
    func testOnlyAChargingIslandIsTintedGreen() {
        let charging = AmbientActivity.charging(level: 67, isCharging: true)
        XCTAssertEqual(IslandStroke.tint(for: .ambient(charging), isOpen: false), Theme.chargingGreen)
        XCTAssertNil(IslandStroke.tint(for: .ambient(charging), isOpen: true), "a surface over it is white")
        XCTAssertNil(
            IslandStroke.tint(for: .ambient(.charging(level: 80, isCharging: false)), isOpen: false),
            "a charge only held is drawn white, and so is its line"
        )
        XCTAssertNil(IslandStroke.tint(for: .ambient(.charging(level: nil, isCharging: true)), isOpen: false), "no battery, no green")
        XCTAssertNil(IslandStroke.tint(for: .ambient(.headphones(name: "AirPods Pro", symbol: "airpods.pro")), isOpen: false))
        XCTAssertNil(IslandStroke.tint(for: .peek, isOpen: false))
        XCTAssertNil(IslandStroke.tint(for: .none, isOpen: false), "Music and the Shelf")
    }

    // MARK: Where

    /// 2 pt centred on the outline — a point either side of it is in the line —
    /// along both shoulders, both sides and the bottom, and never along the top
    /// edge, which is the bezel.
    func testTheStrokeIsCentredAndNeverTouchesTheTopEdge() {
        let rect = CGRect(x: 0, y: 0, width: 225.4, height: 38)
        let shape = IslandStrokeShape(topRadius: 8.67, bottomRadius: 12.67)
        let stroke = shape.path(in: rect).strokedPath(StrokeStyle(lineWidth: Theme.islandStrokeWidth))

        XCTAssertTrue(stroke.contains(CGPoint(x: 112.7, y: 38.5)), "the bottom edge, outside")
        XCTAssertTrue(stroke.contains(CGPoint(x: 112.7, y: 37.5)), "the bottom edge, inside: centred, over the black")
        XCTAssertTrue(stroke.contains(CGPoint(x: 8.17, y: 20)), "the left side, outside")
        XCTAssertTrue(stroke.contains(CGPoint(x: 9.17, y: 20)), "the left side, inside")
        XCTAssertTrue(stroke.contains(CGPoint(x: 216.73 + 0.5, y: 20)), "the right side, outside")
        XCTAssertFalse(stroke.contains(CGPoint(x: 112.7, y: 20)), "not across the middle")
        // Along the top, between the two shoulders' inner ends.
        for x in stride(from: CGFloat(20), through: 205, by: 15) {
            XCTAssertFalse(stroke.contains(CGPoint(x: x, y: 0.5)), "no line along the top at x \(x)")
            XCTAssertFalse(stroke.contains(CGPoint(x: x, y: -0.5)), "or above it at x \(x)")
        }
    }

    /// The line is built from the island's own outline, so it cannot drift from
    /// the shape it frames, and springs with it.
    func testTheStrokeFollowsTheIslandsOwnOutline() {
        let rect = CGRect(x: 0, y: 0, width: 425.4, height: 198)
        let island = NotchShape(topRadius: 34, bottomRadius: 44)
        XCTAssertEqual(
            IslandStrokeShape(topRadius: 34, bottomRadius: 44).path(in: rect).boundingRect,
            island.openPath(in: rect).boundingRect
        )
        var animated = IslandStrokeShape(topRadius: 8.67, bottomRadius: 12.67)
        animated.animatableData = AnimatablePair(34, 44)
        XCTAssertEqual(animated.topRadius, 34)
        XCTAssertEqual(animated.bottomRadius, 44, "it springs with the shape as it grows")
    }

    // MARK: Shadow

    /// A shape taller than 68 casts black 0.22, radius 14, no offset, so a
    /// surface separates from a busy window under it. A compact activity, the
    /// 50 pt peek and the resting notch cast none.
    func testOnlyAShapeTallerThanSixtyEightCastsAShadow() {
        XCTAssertEqual(Theme.islandShadowThreshold, 68)
        XCTAssertEqual(Theme.islandShadowOpacity, 0.22)
        XCTAssertEqual(Theme.islandShadowRadius, 14)
        XCTAssertFalse(IslandStroke.castsShadow(height: 38), "a compact activity")
        XCTAssertFalse(IslandStroke.castsShadow(height: 50), "the peek")
        XCTAssertFalse(IslandStroke.castsShadow(height: 68), "taller than, not as tall as")
        XCTAssertTrue(IslandStroke.castsShadow(height: 68.5))
        XCTAssertTrue(IslandStroke.castsShadow(height: 95), "the headphones alert")
        XCTAssertTrue(IslandStroke.castsShadow(height: 198), "the player")
    }
}
