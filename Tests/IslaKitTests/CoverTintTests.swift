import AppKit
import XCTest
@testable import IslaKit

/// The one colour a cover lends the island (redesign spec §3.4): the most
/// saturated of its bright colours, lifted to 0.65 brightness, white 0.82 for a
/// greyscale or missing cover.
final class CoverTintTests: XCTestCase {
    // MARK: Fixtures

    /// `side × side` premultiplied RGBA with each pixel from `pixel(x, y)`.
    private func pixels(side: Int = 24, _ pixel: (Int, Int) -> (CGFloat, CGFloat, CGFloat)) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<side {
            for x in 0..<side {
                let (r, g, b) = pixel(x, y)
                bytes += [UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), 255]
            }
        }
        return bytes
    }

    private func cgImage(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func hsb(_ tint: CoverTint) -> (hue: Double, saturation: Double, brightness: Double) {
        CoverTint.hsb(red: tint.red, green: tint.green, blue: tint.blue)
    }

    // MARK: Saturated

    /// A grey cover with one coral patch: the tint is the coral, not the mean.
    func testTheTintIsTheMostSaturatedBrightColour() {
        let coral: (CGFloat, CGFloat, CGFloat) = (1.0, 0.54, 0.45)
        let tint = CoverTint.tint(fromRGBA: pixels { x, _ in x >= 20 ? coral : (0.5, 0.5, 0.5) })
        XCTAssertEqual(tint.red, 1.0, accuracy: 0.02)
        XCTAssertEqual(tint.green, 0.54, accuracy: 0.02)
        XCTAssertEqual(tint.blue, 0.45, accuracy: 0.02)
    }

    /// The most saturated of several, not the commonest: a mostly-teal cover
    /// with a few saturated orange pixels draws its bars orange.
    func testTheMostSaturatedWinsOverTheMostCommon() {
        let tint = CoverTint.tint(fromRGBA: pixels { x, y in
            (x < 3 && y < 3) ? (1.0, 0.45, 0.0) : (0.35, 0.6, 0.62)
        })
        XCTAssertEqual(hsb(tint).hue, CoverTint.hsb(red: 1, green: 0.45, blue: 0).hue, accuracy: 0.01)
        XCTAssertEqual(hsb(tint).saturation, 1.0, accuracy: 0.02)
    }

    /// A dark saturated colour keeps its hue and saturation and is lifted so it
    /// reads on black.
    func testADarkSaturatedColourIsLiftedToSixtyFivePercentBrightness() {
        let navy: (CGFloat, CGFloat, CGFloat) = (0.05, 0.10, 0.40)
        let tint = CoverTint.tint(fromRGBA: pixels { _, _ in navy })
        let original = CoverTint.hsb(red: 0.05, green: 0.10, blue: 0.40)
        XCTAssertEqual(CoverTint.liftedBrightness, 0.65)
        XCTAssertEqual(hsb(tint).brightness, 0.65, accuracy: 0.01, "lifted to the floor")
        XCTAssertEqual(hsb(tint).hue, original.hue, accuracy: 0.01, "the hue is the cover's")
        XCTAssertEqual(hsb(tint).saturation, original.saturation, accuracy: 0.01, "so is the saturation")
    }

    /// Already bright enough is left as it is; the floor never darkens.
    func testABrightColourIsNotDarkened() {
        let tint = CoverTint.tint(fromRGBA: pixels { _, _ in (0.2, 0.9, 0.3) })
        XCTAssertEqual(hsb(tint).brightness, 0.9, accuracy: 0.01)
    }

    // MARK: Greyscale and missing

    func testAGreyscaleCoverFallsBackToWhiteZeroPointEightTwo() {
        for grey in [CGFloat(0.1), 0.5, 0.95] {
            let tint = CoverTint.tint(fromRGBA: pixels { _, _ in (grey, grey, grey) })
            XCTAssertEqual(tint, CoverTint.fallback, "grey \(grey)")
        }
        XCTAssertEqual(CoverTint.fallback, CoverTint(red: 0.82, green: 0.82, blue: 0.82))
        // Near-grey — a warm paper — is grey too.
        let paper = CoverTint.tint(fromRGBA: pixels { _, _ in (0.93, 0.91, 0.88) })
        XCTAssertEqual(paper, CoverTint.fallback)
    }

    /// A cover whose only colour is a shadow is not "bright colours".
    func testAColourThatIsOnlyShadowFallsBack() {
        let tint = CoverTint.tint(fromRGBA: pixels { _, _ in (0.0, 0.0, 0.2) })
        XCTAssertEqual(tint, CoverTint.fallback)
    }

    func testAMissingCoverFallsBack() {
        XCTAssertEqual(CoverTint.tint(of: nil), CoverTint.fallback)
        XCTAssertEqual(CoverTint.tint(fromRGBA: []), CoverTint.fallback)
        XCTAssertEqual(CoverTint.cachedTint(for: nil), CoverTint.fallback, "no cover is answered on the spot")
    }

    // MARK: From a real bitmap

    /// The whole path — an image, downsampled to 24 × 24 — not just the pure
    /// half. A 200 × 100 cover with a saturated red third.
    func testABitmapIsDownsampledAndRead() throws {
        let image = try cgImage(width: 200, height: 100) { context in
            context.setFillColor(CGColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 70, height: 100))
        }
        let tint = CoverTint.tint(of: image)
        XCTAssertEqual(CoverTint.sampleSide, 24)
        XCTAssertGreaterThan(tint.red, 0.8)
        XCTAssertLessThan(tint.green, 0.25)
        XCTAssertLessThan(tint.blue, 0.25)
    }

    // MARK: Once per artwork, off the main actor

    func testAnArtworkIsReadOnceAndThenAnsweredFromTheCache() async throws {
        let bitmap = try cgImage(width: 64, height: 64) { context in
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let artwork = NSImage(cgImage: bitmap, size: NSSize(width: 64, height: 64))
        XCTAssertNil(CoverTint.cachedTint(for: artwork), "not read yet")
        let tint = await CoverTint.resolve(artwork)
        XCTAssertEqual(hsb(tint).hue, CoverTint.hsb(red: 0.1, green: 0.8, blue: 0.9).hue, accuracy: 0.02)
        XCTAssertEqual(CoverTint.cachedTint(for: artwork), tint, "now it is")
        let again = await CoverTint.resolve(artwork)
        XCTAssertEqual(again, tint)
    }

    /// The view model reads a cover when it arrives and falls back when it goes.
    @MainActor
    func testTheViewModelsTintFollowsTheArtwork() async throws {
        let stores = NotchStores()
        stores.media.isolateFromPlayers()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: stores)
        XCTAssertEqual(vm.coverTint, CoverTint.fallback)

        let red = LabFixtures.solidCover(NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        await LabFixtures.play(.init(elapsed: 5, cover: red), on: stores.media)
        let deadline = Date().addingTimeInterval(5)
        while vm.coverTint == CoverTint.fallback, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(vm.coverTint.red, 0.8, "the cover's red")
        XCTAssertLessThan(vm.coverTint.blue, 0.3)

        stores.media.apply(NowPlayingFeed.Snapshot())
        let gone = Date().addingTimeInterval(5)
        while vm.coverTint != CoverTint.fallback, Date() < gone {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(vm.coverTint, CoverTint.fallback, "no cover, no stale colour")
    }

    // MARK: Colour

    func testThePlayingEqualizerIsTheTintAndThePausedOneIsTertiaryWhite() throws {
        let tint = CoverTint(red: 1, green: 0.54, blue: 0.45)
        let playing = try XCTUnwrap(CompactEqualizerMotion.color(isPlaying: true, tint: tint, increaseContrast: false).usingColorSpace(.sRGB))
        XCTAssertEqual(playing.greenComponent, 0.54, accuracy: 0.005)
        XCTAssertEqual(playing.alphaComponent, 1)
        let paused = try XCTUnwrap(CompactEqualizerMotion.color(isPlaying: false, tint: tint, increaseContrast: false).usingColorSpace(.sRGB))
        XCTAssertEqual(paused.redComponent, 1, accuracy: 0.005, "white")
        XCTAssertEqual(paused.blueComponent, 1, accuracy: 0.005)
        XCTAssertEqual(paused.alphaComponent, Theme.tertiaryOpacity(increaseContrast: false), accuracy: 0.005)
        let held = try XCTUnwrap(CompactEqualizerMotion.color(isPlaying: false, tint: tint, increaseContrast: true).usingColorSpace(.sRGB))
        XCTAssertEqual(held.alphaComponent, Theme.tertiaryOpacity(increaseContrast: true), accuracy: 0.005, "Increase Contrast steps it up")
        XCTAssertEqual(CompactEqualizerMotion.stillHeights(isPlaying: false), [3, 3, 3, 3])
        XCTAssertEqual(CompactEqualizerMotion.stillHeights(isPlaying: true), CompactEqualizerMotion.playingHeights)
    }

    func testHsbRoundTrips() {
        for (r, g, b) in [(1.0, 0.0, 0.0), (0.2, 0.9, 0.3), (0.1, 0.2, 0.8), (0.9, 0.6, 0.1), (0.4, 0.4, 0.4)] {
            let hsb = CoverTint.hsb(red: r, green: g, blue: b)
            let back = CoverTint.rgb(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
            XCTAssertEqual(back.red, r, accuracy: 1e-9)
            XCTAssertEqual(back.green, g, accuracy: 1e-9)
            XCTAssertEqual(back.blue, b, accuracy: 1e-9)
        }
    }
}
