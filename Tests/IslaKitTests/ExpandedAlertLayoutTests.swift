import CoreGraphics
import XCTest
@testable import IslaKit

/// The two expanded alerts R7 restyles (spec §19.5 c and d): headphones
/// connected, 370.3 × 95 at radii 20 / 38, and volume or brightness, 245.4 × 103
/// at 18.67 / 22.67.
///
/// The spec writes each shape as measured — shoulders included, on the
/// reference's 38 pt notch — and every position from the shape's left edge or
/// as `right n` from its right. `ExpandedAlertShape` turns those into the
/// body-local frame the island lays out in; these tests read the numbers back
/// in the spec's terms, at `nw` 180 and 240 (§19.12) and on a 32 pt notch.
final class ExpandedAlertLayoutTests: XCTestCase {
    private let notches: [CGFloat] = [180, 240]

    // MARK: The shapes

    func testTheShapesAreTheReferences() {
        let pods = ExpandedAlertShape.headphones
        XCTAssertEqual(pods.reference, CGSize(width: 370.3, height: 95))
        XCTAssertEqual(pods.topRadius, 20)
        XCTAssertEqual(pods.bottomRadius, 38)
        let hud = ExpandedAlertShape.volume
        XCTAssertEqual(hud.reference, CGSize(width: 245.4, height: 103))
        XCTAssertEqual(hud.topRadius, 18.67)
        XCTAssertEqual(hud.bottomRadius, 22.67)
    }

    /// The measured width, never narrower than the notch plus 20, never wider
    /// than the panel; the notch's height plus the reference's depth below it.
    func testAnExpandedAlertKeepsItsWidthUnlessTheNotchNeedsMore() {
        let hud = ExpandedAlertShape.volume
        let narrow = hud.bodySize(notchSize: CGSize(width: 180, height: 38), bodyWidth: 560)
        XCTAssertEqual(narrow.width + 2 * hud.topRadius, 245.4, accuracy: 0.001, "the reference's shape at nw 180")
        XCTAssertEqual(narrow.height, 103)
        let wide = hud.bodySize(notchSize: CGSize(width: 240, height: 38), bodyWidth: 560)
        XCTAssertEqual(wide.width, 260, "floored at nw + 20")
        let pods = ExpandedAlertShape.headphones
        for notch in notches {
            let size = pods.bodySize(notchSize: CGSize(width: notch, height: 38), bodyWidth: 560)
            XCTAssertEqual(size.width + 2 * pods.topRadius, 370.3, accuracy: 0.001, "nw \(notch)")
            XCTAssertEqual(size.height, 95)
        }
        XCTAssertEqual(pods.bodySize(notchSize: CGSize(width: 180, height: 38), bodyWidth: 300).width, 300)
        let short = hud.bodySize(notchSize: CGSize(width: 200, height: 32), bodyWidth: 560)
        XCTAssertEqual(short.height, 32 + 65, "the depth below the notch is kept, not the total")
    }

    func testTheViewModelSizesTheAlertsByTheirShapes() {
        let notch = CGSize(width: 180, height: 38)
        let hud = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        XCTAssertEqual(
            NotchViewModel.hudBodySize(hud, notchSize: notch, bodyWidth: 560),
            ExpandedAlertShape.volume.bodySize(notchSize: notch, bodyWidth: 560)
        )
        XCTAssertEqual(
            NotchViewModel.ambientBodySize(.headphones(name: "AirPods Pro", symbol: "airpods.pro"),
                                           notchSize: notch, bodyWidth: 560),
            ExpandedAlertShape.headphones.bodySize(notchSize: notch, bodyWidth: 560)
        )
    }

    /// Radii by what the island shows: each alert its own, the compact
    /// activities the reference's 8.67 / 12.67, the peek's bottom 16.
    func testTheOutlineTakesTheRadiiOfWhatItShows() {
        let hud = HUDMoment(HUDReading(kind: .display, level: 0.5, muted: false, deviceSymbol: nil))
        XCTAssertEqual(IslandShapeRadii.closed(for: .hud(hud)).top, 18.67)
        XCTAssertEqual(IslandShapeRadii.closed(for: .hud(hud)).bottom, 22.67)
        let pods = IslandActivity.ambient(.headphones(name: "AirPods", symbol: "airpods"))
        XCTAssertEqual(IslandShapeRadii.closed(for: pods).top, 20)
        XCTAssertEqual(IslandShapeRadii.closed(for: pods).bottom, 38)
        for compact in [IslandActivity.music, .shelf(count: 3), .ambient(.charging(level: 50, isCharging: true)), .none] {
            XCTAssertEqual(IslandShapeRadii.closed(for: compact).top, Theme.collapsedTopRadius)
            XCTAssertEqual(IslandShapeRadii.closed(for: compact).bottom, Theme.collapsedBottomRadius)
        }
        XCTAssertEqual(IslandShapeRadii.closed(for: .peek).bottom, Theme.peekBottomRadius)
    }

    // MARK: Volume and brightness (§19.5 d)

    private func shapeX(_ x: CGFloat) -> CGFloat { x + ExpandedAlertShape.volume.topRadius }
    private func right(_ maxX: CGFloat, width: CGFloat) -> CGFloat { width - maxX + ExpandedAlertShape.volume.topRadius }

    /// The name at x 34, baseline 58, truncating at right 34; the symbol
    /// 22 × 16 at (35.5, 72.5); the bar 107 × 8 at (69.5, 76.5); the number
    /// ending right 34.5, on the bar's centre line.
    func testThePopUpsPartsSitWhereTheReferenceDoes() {
        let size = ExpandedAlertShape.volume.bodySize(notchSize: CGSize(width: 180, height: 38), bodyWidth: 560)
        let track = HUDLayout.trackFrame(islandWidth: size.width, notchHeight: 38)
        XCTAssertEqual(shapeX(track.minX), 69.5, accuracy: 0.001)
        XCTAssertEqual(track.minY, 76.5)
        XCTAssertEqual(track.width, 107, accuracy: 0.001)
        XCTAssertEqual(track.height, 8)
        XCTAssertEqual(HUDLayout.barRadius, 4)
        XCTAssertEqual(HUDLayout.trackOpacity, 0.18)

        let symbol = HUDLayout.symbolFrame(notchHeight: 38)
        XCTAssertEqual(shapeX(symbol.minX), 35.5, accuracy: 0.001)
        XCTAssertEqual(symbol.minY, 72.5)
        XCTAssertEqual(symbol.size, CGSize(width: 22, height: 16))

        XCTAssertEqual(shapeX(HUDLayout.titleLeading), 34, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.titleBaseline(notchHeight: 38), 58)
        XCTAssertEqual(
            right(HUDLayout.titleLeading + HUDLayout.titleWidth(islandWidth: size.width), width: size.width), 34,
            accuracy: 0.001
        )
        XCTAssertEqual(HUDLayout.titleSize, 15)

        XCTAssertEqual(HUDLayout.numberTrailingInset + ExpandedAlertShape.volume.topRadius, 34.5, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.numberSize, 14)
    }

    /// Wider than the reference — a 240 pt notch — the leading content stays
    /// where it was and the trailing moves with the edge: the bar keeps its
    /// start and its distance from the right, and grows between.
    func testOnAWiderPopUpTheBarGrowsAndTheTrailingContentFollowsTheEdge() {
        let size = ExpandedAlertShape.volume.bodySize(notchSize: CGSize(width: 240, height: 38), bodyWidth: 560)
        let track = HUDLayout.trackFrame(islandWidth: size.width, notchHeight: 38)
        XCTAssertEqual(shapeX(track.minX), 69.5, accuracy: 0.001)
        XCTAssertEqual(right(track.maxX, width: size.width), 245.4 - 69.5 - 107, accuracy: 0.001)
        XCTAssertGreaterThan(track.width, 107)
    }

    func testOnAShorterNotchThePartsKeepTheirPlaceBelowIt() {
        XCTAssertEqual(HUDLayout.trackFrame(islandWidth: 208.06, notchHeight: 32).minY, 76.5 - 6)
        XCTAssertEqual(HUDLayout.symbolFrame(notchHeight: 32).minY, 72.5 - 6)
        XCTAssertEqual(HUDLayout.titleBaseline(notchHeight: 32), 52)
    }

    func testTheFillIsTheLevelOfTheTrackAndMutedKeepsIt() {
        let width: CGFloat = 208.06
        let track = HUDLayout.trackFrame(islandWidth: width, notchHeight: 38)
        XCTAssertEqual(HUDLayout.fillFrame(level: 0.5, islandWidth: width, notchHeight: 38).width, track.width / 2, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.fillFrame(level: 0, islandWidth: width, notchHeight: 38).width, 0)
        XCTAssertEqual(HUDLayout.fillFrame(level: 1.4, islandWidth: width, notchHeight: 38).width, track.width, accuracy: 0.001)
        XCTAssertEqual(HUDLayout.mutedFillOpacity, 0.32)
        // Flat white, no amber and no glow (owner's review, 2026-10-18).
        XCTAssertEqual(HUDLayout.levelOpacity, 0.92)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = (try? String(contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/NotchContentView.swift"), encoding: .utf8)) ?? ""
        XCTAssertFalse(shell.contains("hudAmber"))
        XCTAssertFalse(shell.contains("glowRadius"))
    }

    /// The output's name, or what is being brightened.
    func testThePopUpNamesWhatItChanges() {
        func moment(_ kind: HUDKind, name: String? = nil) -> HUDMoment {
            HUDMoment(HUDReading(kind: kind, level: 0.5, muted: false, deviceSymbol: nil, deviceName: name))
        }
        XCTAssertEqual(moment(.volume, name: "MacBook Pro Speakers").title, "MacBook Pro Speakers")
        XCTAssertEqual(moment(.volume).title, localized("Volume"), "no name found: what is being changed")
        XCTAssertEqual(moment(.display).title, localized("Display Brightness"))
        XCTAssertEqual(moment(.keyboard).title, localized("Keyboard Brightness"))
        XCTAssertEqual(moment(.display, name: "Studio Display").title, localized("Display Brightness"),
                       "only the volume names a device")
    }

    // MARK: Headphones (§19.5 c)

    private func podsX(_ x: CGFloat) -> CGFloat { x + ExpandedAlertShape.headphones.topRadius }

    /// The device's symbol 43 × 34 at (40.6, 38.75); "Connected" at x 102.4,
    /// baseline 54; the name below it at baseline 75, running — with no ring
    /// in R7 — to right 37.7, where the ring would end.
    func testTheHeadphonesPartsSitWhereTheReferenceDoes() {
        for notch in notches {
            let size = ExpandedAlertShape.headphones.bodySize(notchSize: CGSize(width: notch, height: 38), bodyWidth: 560)
            let glyph = HeadphonesAlertLayout.glyphFrame(notchHeight: 38)
            XCTAssertEqual(podsX(glyph.minX), 40.6, accuracy: 0.001)
            XCTAssertEqual(glyph.minY, 38.75)
            XCTAssertEqual(glyph.size, CGSize(width: 43, height: 34))
            XCTAssertEqual(podsX(HeadphonesAlertLayout.textLeading), 102.4, accuracy: 0.001)
            XCTAssertEqual(HeadphonesAlertLayout.connectedBaseline(notchHeight: 38), 54)
            XCTAssertEqual(HeadphonesAlertLayout.nameBaseline(notchHeight: 38), 75)
            let end = HeadphonesAlertLayout.textLeading + HeadphonesAlertLayout.nameWidth(islandWidth: size.width)
            XCTAssertEqual(size.width - end + ExpandedAlertShape.headphones.topRadius, 37.7, accuracy: 0.001)
        }
        XCTAssertEqual(HeadphonesAlertLayout.glyphOpacity, 0.85)
        XCTAssertEqual(HeadphonesAlertLayout.connectedSize, 13)
        XCTAssertEqual(HeadphonesAlertLayout.connectedOpacity, 0.40)
        XCTAssertEqual(HeadphonesAlertLayout.nameSize, 15)
        XCTAssertEqual(HeadphonesAlertLayout.nameOpacity, 0.82)
    }

    func testTheHeadphonesKeepTheirPlaceBelowAShorterNotch() {
        XCTAssertEqual(HeadphonesAlertLayout.glyphFrame(notchHeight: 32).minY, 38.75 - 6)
        XCTAssertEqual(HeadphonesAlertLayout.nameBaseline(notchHeight: 32), 69)
    }

    /// Both alerts are taller than 68, so both cast the shadow (§19.2).
    func testBothAlertsCastTheShadow() {
        XCTAssertTrue(IslandStroke.castsShadow(height: 95))
        XCTAssertTrue(IslandStroke.castsShadow(height: 103))
    }
}
