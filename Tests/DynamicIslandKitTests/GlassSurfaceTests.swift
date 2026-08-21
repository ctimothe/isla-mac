import AppKit
import SwiftUI
import XCTest
@testable import DynamicIslandKit

@MainActor
final class GlassSurfaceTests: XCTestCase {
    /// The grain is what stops the pane reading as a flat fill, so it has to be
    /// noise and not a solid tile — and the same noise every launch, or the
    /// surface would shimmer differently each time the app starts.
    func testTheGrainIsNoiseAndAlwaysTheSameNoise() throws {
        let tile = GlassSurface.grainTile(side: 16)
        let again = GlassSurface.grainTile(side: 16)
        let samples = try Self.luminances(of: tile)
        let repeated = try Self.luminances(of: again)

        XCTAssertEqual(samples, repeated, "the tile must be identical from one build to the next")
        XCTAssertGreaterThan(
            Set(samples).count, 8,
            "a tile with almost no distinct values is a flat fill, not grain"
        )
        let mean = samples.reduce(0, +) / Double(samples.count)
        XCTAssertGreaterThan(mean, 0.2)
        XCTAssertLessThan(mean, 0.8, "grain sits around mid-grey so it can lighten and darken alike")
    }

    /// The surface is a background. A background that asks for more room than
    /// the thing it sits behind is the bug that put the lyrics stage's sung
    /// line below the island's edge — it must never size anything.
    func testTheSurfaceNeverAsksForRoom() {
        let host = NSHostingController(
            rootView: GlassSurface(elevation: .card, samplesBackdrop: false)
        )
        let offered = CGSize(width: 500, height: 222)
        let wanted = host.sizeThatFits(in: offered)
        XCTAssertLessThanOrEqual(wanted.width, offered.width)
        XCTAssertLessThanOrEqual(wanted.height, offered.height)
    }

    /// Elevations differ, and differ in the right direction: the further a
    /// surface is from the wallpaper the less it has to darken to carry type.
    func testAPopoverIsDarkerThanACardAndACardCatchesMoreLight() {
        XCTAssertGreaterThan(
            GlassSurface.Elevation.popover.base.leading,
            GlassSurface.Elevation.card.base.leading
        )
        XCTAssertGreaterThan(
            GlassSurface.Elevation.card.rimOpacity.top,
            GlassSurface.Elevation.popover.rimOpacity.top
        )
    }

    private static func luminances(of image: NSImage) throws -> [Double] {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        var values: [Double] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                values.append(Double(colour.brightnessComponent))
            }
        }
        return values
    }
}
