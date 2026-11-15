import CoreGraphics
import Foundation
import XCTest
@testable import IslaKit

/// islandcn's icons (plan 2026-11-15-islandcn-identical, slice S1): the SVG
/// reader, the recipe renderer against islandcn's own numbers, and the rule
/// that nothing Isla draws is an SF Symbol any more.
final class IslandGlyphTests: XCTestCase {
    // MARK: - SVG path data

    func testAbsoluteAndRelativeCommandsDrawTheSameRectangle() throws {
        let absolute = try XCTUnwrap(SVGPath.parse("M4 7H10V17H4Z"))
        let relative = try XCTUnwrap(SVGPath.parse("m4 7h6v10h-6z"))
        XCTAssertEqual(absolute.boundingBoxOfPath, CGRect(x: 4, y: 7, width: 6, height: 10))
        XCTAssertEqual(relative.boundingBoxOfPath, absolute.boundingBoxOfPath)
    }

    func testNumbersFollowSVGGrammar() throws {
        // "-.5.5" is two numbers, a bare pair after M is a line, 1e1 is ten.
        let path = try XCTUnwrap(SVGPath.parse("M-.5.5 1e1,2"))
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: -0.5, y: 0.5, width: 10.5, height: 1.5))
    }

    func testCurvesReachTheirEndPoint() throws {
        let path = try XCTUnwrap(SVGPath.parse("M2 12C2 6 22 6 22 12"))
        XCTAssertEqual(path.currentPoint, CGPoint(x: 22, y: 12))
    }

    func testACommandItCannotDrawFailsInsteadOfDroppingAPiece() {
        // An arc would otherwise vanish from a glyph without a sound.
        XCTAssertNil(SVGPath.parse("M2 12A10 10 0 0 1 22 12"))
        XCTAssertNil(SVGPath.parse("M2 12Q5 5 22 12"))
        XCTAssertNil(SVGPath.parse("12 12"))
        XCTAssertNil(SVGPath.parse("M2"))
    }

    func testEveryVendoredDrawingReads() {
        // Mirrors the vendoring script's own check, on the data as shipped.
        for glyph in IslandGlyph.allCases {
            for layer in glyph.recipe.layers {
                for case .path(let d, _) in layer.icon {
                    XCTAssertNotNil(SVGPath.parse(d), "\(glyph): \(d.prefix(40))")
                }
            }
        }
    }

    // MARK: - islandcn's numbers

    func testOutlineWeightMatchesIslandcnToTheHundredth() {
        // islandcn: 2 units at 22, about 2.5 at 12, about 1.6 at 44
        // (`strokeAt`); the values are JavaScript's own output.
        XCTAssertEqual(GlyphRecipe.stroke(atBox: 22), 2)
        XCTAssertEqual(GlyphRecipe.stroke(atBox: 12), 2.47)
        XCTAssertEqual(GlyphRecipe.stroke(atBox: 44), 1.57)
        XCTAssertEqual(GlyphRecipe.stroke(atBox: 24), 1.94)
    }

    func testCentredViewsMatchIslandcn() {
        // The player's windows, as `centredView` computes them in JavaScript.
        XCTAssertEqual(GlyphRecipe.centredView(ink: 16, share: 27.6 / 30), CGRect(x: 3.31, y: 3.31, width: 17.39, height: 17.39))
        XCTAssertEqual(GlyphRecipe.centredView(ink: 17.5, share: 31.5 / 34), CGRect(x: 2.55, y: 2.55, width: 18.89, height: 18.89))
        XCTAssertEqual(GlyphRecipe.centredView(ink: 21, share: 21 / 27.5), CGRect(x: -1.75, y: -1.75, width: 27.5, height: 27.5))
    }

    // MARK: - Parts

    func testFillDrawsSolidAndLeavesTheGapBetweenBars() {
        let pause = IslandGlyph.pause.path(size: 24)
        XCTAssertTrue(pause.contains(CGPoint(x: 7, y: 12)), "inside a bar")
        XCTAssertFalse(pause.contains(CGPoint(x: 12, y: 12)), "between the bars")
    }

    func testLineDrawsAtTheIslandWeightNotHugeiconsOwn() {
        // At a 24 pt box the weight is 1.94 units, so the X's strokes reach
        // 0.97 units either side of their centre line.
        let close = IslandGlyph.close.path(size: 24)
        XCTAssertTrue(close.contains(CGPoint(x: 12.9, y: 12)), "0.64 units off the stroke's centre")
        XCTAssertFalse(close.contains(CGPoint(x: 13.6, y: 12)), "1.13 units off: outside the weight")
        XCTAssertFalse(close.contains(CGPoint(x: 12, y: 4)))
    }

    func testCutPunchesAClosedShapeOutOfTheSolid() {
        let cleared = IslandGlyph.closeCircleFilled.path(size: 24)
        XCTAssertTrue(cleared.contains(CGPoint(x: 12, y: 5)), "the solid disc")
        XCTAssertFalse(cleared.contains(CGPoint(x: 12, y: 12)), "the X, cut out")
    }

    func testGapCutsAroundAnOutlineAndStillDrawsIt() {
        // A line across a solid square: drawn the weight wide, with a channel
        // three times the weight wide cut around it in the solid.
        let recipe = GlyphRecipe(layers: [
            GlyphLayer([.rect(x: 2, y: 2, width: 20, height: 20)], .fill),
            GlyphLayer([.path("M2 12H22")], .gap),
        ])
        let drawn = recipe.path(size: 24)
        let weight = GlyphRecipe.stroke(atBox: 24)
        XCTAssertTrue(drawn.contains(CGPoint(x: 12, y: 12)), "the line")
        XCTAssertFalse(drawn.contains(CGPoint(x: 12, y: 12 + weight)), "the channel")
        XCTAssertTrue(drawn.contains(CGPoint(x: 12, y: 12 + weight * 2)), "the solid past it")
    }

    func testCutsFromALaterLayerCutEveryLayersSolids() {
        // islandcn keeps one mask for the whole glyph.
        let recipe = GlyphRecipe(layers: [
            GlyphLayer([.rect(x: 2, y: 2, width: 20, height: 20)], .fill),
            GlyphLayer([.circle(cx: 12, cy: 12, r: 4)], .cut),
        ])
        let drawn = recipe.path(size: 24)
        XCTAssertFalse(drawn.contains(CGPoint(x: 12, y: 12)))
        XCTAssertTrue(drawn.contains(CGPoint(x: 4, y: 4)))
    }

    func testHeavyFillsAndOutlinesTheStopwatch() {
        let timer = IslandGlyph.timer.path(size: 24)
        XCTAssertTrue(timer.contains(CGPoint(x: 8, y: 16)), "the solid face")
        XCTAssertFalse(timer.contains(CGPoint(x: 13.75, y: 11.75)), "the hand, cut out")
    }

    func testInlaySetsTheWheelsInWithAGap() {
        let car = IslandGlyph.car.path(size: 24)
        XCTAssertTrue(car.contains(CGPoint(x: 12, y: 13)), "the body")
        XCTAssertFalse(car.contains(CGPoint(x: 5.5, y: 7.5)), "the rear window")
    }

    // MARK: - Placement

    func testPlayPointsRightAtPausesHeight() {
        let play = IslandGlyph.play.path(size: 24).boundingBoxOfPath
        let pause = IslandGlyph.pause.path(size: 24).boundingBoxOfPath
        XCTAssertEqual(play.height, pause.height, accuracy: 0.6, "scaled to Pause's 16 units")
        XCTAssertLessThan(play.width, play.height, "turned to point right")
        XCTAssertEqual(play.midY, 12, accuracy: 0.05)
    }

    func testPreviousIsNextMirrored() {
        let next = IslandGlyph.nextTrack.path(size: 24).boundingBoxOfPath
        let previous = IslandGlyph.previousTrack.path(size: 24).boundingBoxOfPath
        XCTAssertEqual(previous.minX, 24 - next.maxX, accuracy: 0.001)
        XCTAssertEqual(previous.width, next.width, accuracy: 0.001)
    }

    func testStretchedLayerKeepsItsWeight() {
        // islandcn strokes a stretched layer in screen space
        // (`non-scaling-stroke`), so a line across the stretch keeps the
        // weight rather than growing with it; the output glyph's waves rely on it.
        let recipe = GlyphRecipe([.path("M4 12H20")], place: GlyphPlacement(stretch: 2))
        let thickness = recipe.path(size: 24).boundingBoxOfPath.height
        XCTAssertEqual(thickness, GlyphRecipe.stroke(atBox: 24), accuracy: 0.01)
    }

    func testScaledLayerKeepsItsWeight() {
        // A layer scaled to 0.3 (islandcn's record dot in a screen) draws its
        // outlines the glyph's weight, not 0.3 of it.
        let recipe = GlyphRecipe([.path("M4 12H20")], place: GlyphPlacement(scale: 0.3))
        let thickness = recipe.path(size: 24).boundingBoxOfPath.height
        XCTAssertEqual(thickness, GlyphRecipe.stroke(atBox: 24), accuracy: 0.01)
    }

    // MARK: - Every glyph

    func testEveryGlyphDrawsInkInsideItsBox() {
        for glyph in IslandGlyph.allCases {
            let bounds = glyph.path(size: 24).boundingBoxOfPath
            XCTAssertFalse(bounds.isEmpty, "\(glyph) draws nothing")
            // islandcn draws with overflow visible; the output glyph's view is
            // wider than the grid on purpose, everything else stays near it.
            XCTAssertTrue(CGRect(x: -2, y: -2, width: 28, height: 28).contains(bounds), "\(glyph): \(bounds)")
        }
    }

    func testInkFitFillsTheFrameAsAResizableSymbolDid() {
        let rect = CGRect(x: 10, y: 20, width: 35, height: 22)
        let placed = GlyphCache.shared.placed(.nextTrack, fit: .ink, in: rect).boundingBoxOfPath
        XCTAssertTrue(abs(placed.width - 35) < 0.01 || abs(placed.height - 22) < 0.01, "\(placed)")
        XCTAssertLessThanOrEqual(placed.width, 35.01)
        XCTAssertLessThanOrEqual(placed.height, 22.01)
        XCTAssertEqual(placed.midX, rect.midX, accuracy: 0.01)
        XCTAssertEqual(placed.midY, rect.midY, accuracy: 0.01)
    }

    func testBoxFitCentresTheWholeGrid() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        let placed = GlyphCache.shared.placed(.pause, fit: .box, in: rect).boundingBoxOfPath
        let alone = IslandGlyph.pause.path(size: 20).boundingBoxOfPath
        XCTAssertEqual(placed.minX, alone.minX + 10, accuracy: 0.001)
        XCTAssertEqual(placed.height, alone.height, accuracy: 0.001)
    }

    func testTemplateImageIsTheGlyphsSize() {
        let image = IslandGlyph.music.nsImage(size: 16)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        XCTAssertTrue(image.isTemplate)
    }

    func testGlyphInTextStaysInsideTheLine() {
        // An image in a run of text sits on the baseline; taller than the
        // font's ascent (about 0.95 of the point size) it would grow the line
        // and move every lyric row measured by its type (the lock card's).
        let image = IslandGlyph.music.nsImage(inkHeight: 13 * 0.85)
        XCTAssertEqual(image.size.height, 13 * 0.85, accuracy: 0.01)
        XCTAssertLessThan(image.size.height, 13 * 0.95)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testSymbolBoxIsTheInkOfASymbolAtThatPointSize() {
        XCTAssertEqual(IslandGlyph.symbolBox(pointSize: 10), 12)
        XCTAssertEqual(IslandGlyph.symbolBox(pointSize: 13), 15.5)
    }

    // MARK: - No SF Symbols left

    func testNothingIslaDrawsIsAnSFSymbol() throws {
        // Owner, 2026-11-15: islandcn's icons replace every SF Symbol Isla
        // draws. App Intents' `systemImageName` stays: Shortcuts and
        // Spotlight draw those, not Isla.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IslaKit")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains("Image(systemName:") || code.contains("systemSymbolName:")
                    || code.contains("Label(") && code.contains("systemImage:") {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
