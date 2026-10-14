import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The cover, drawn: paused it is 0.8 of itself, and missing it is a quiet well
/// with a note (redesign 2026-10-15, spec §4.2, §4.7). Measured off a bitmap of
/// the pane hosted offscreen — a never-ordered window, nothing on screen.
@MainActor
final class PlayerCoverRenderTests: XCTestCase {
    /// `ImageRenderer` at 1×: it draws SwiftUI's colour multiply, which a hosting
    /// view's `cacheDisplay` does not (a Core Animation filter).
    private func bitmap(of view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    }

    /// The pane drawn into a bitmap.
    private func render(playing: Bool) async throws -> NSBitmapImageRep {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(playing: playing), on: isolated.stores.media)
        let layout = PlayerLayout(bodyWidth: 560, hasLyricBand: false)
        return try bitmap(
            of: MediaPane(
                media: isolated.stores.media, lyrics: isolated.stores.lyrics, morph: nil, audio: MediaPane.quietAudio()
            ).defaultAppStorage(isolated.suite),
            size: layout.paneSize
        )
    }

    private func brightness(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
        let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
    }

    /// Paused, the picture is multiplied by 0.8 — a colour multiply, so a dark
    /// pixel stays dark rather than being lifted. Sampled at the same point of the
    /// same cover, playing and paused.
    func testAPausedCoverIsEightyPercentOfItself() async throws {
        let playing = try await render(playing: true)
        let paused = try await render(playing: false)
        // Inside the cover (132 pt square at the pane's origin), clear of the
        // corners and the hairline, where the lab's gradient is bright enough to
        // measure.
        var compared = 0
        for (x, y) in [(40, 40), (66, 30), (90, 70), (30, 100)] {
            let a = try brightness(playing, x: x, y: y)
            let b = try brightness(paused, x: x, y: y)
            guard a > 0.2 else { continue }
            XCTAssertEqual(b / a, Theme.playerPausedCoverBrightness, accuracy: 0.04, "at (\(x), \(y)): \(a) -> \(b)")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 0, "the cover must be bright somewhere for this to measure anything")
    }

    /// A cover that is not coming: the 132 pt well at white 0.08 — not a shimmer,
    /// not a stretched app icon — with the note on it.
    func testAMissingCoverIsAQuietWell() throws {
        let side = Theme.artworkMetrics(isOpen: true).side
        let bitmap = try bitmap(
            of: MissingCoverWell(cornerRadius: Theme.artworkMetrics(isOpen: true).cornerRadius), size: CGSize(width: side, height: side)
        )
        // A corner of the well, away from the note and the rounded corner.
        let well = try brightness(bitmap, x: 14, y: 40)
        // Against white 0.08 drawn the same way, so the colour space the bitmap
        // is read in cancels out.
        let reference = try brightness(
            try self.bitmap(of: Color.white.opacity(0.08), size: CGSize(width: 10, height: 10)), x: 5, y: 5
        )
        XCTAssertEqual(well, reference, accuracy: 0.005, "white 0.08 over black")
        // The note in its middle is brighter than the well (white 0.30), and
        // nothing in the well is anywhere near white.
        var brightest: CGFloat = 0
        for y in stride(from: 30, to: 100, by: 2) {
            for x in stride(from: 40, to: 95, by: 2) { brightest = max(brightest, try brightness(bitmap, x: x, y: y)) }
        }
        let note = try brightness(
            try self.bitmap(of: Color.white.opacity(0.30), size: CGSize(width: 10, height: 10)), x: 5, y: 5
        )
        XCTAssertGreaterThan(brightest, reference + 0.1, "the note is drawn")
        // White 0.30 laid over the 0.08 well comes out a little over 0.30 alone;
        // what matters is that it is well short of a white glyph.
        XCTAssertGreaterThanOrEqual(brightest, note - 0.03, "the note is at least the quiet 0.30")
        XCTAssertLessThan(brightest, note + 0.12, "and it is the quiet 0.30, not a white glyph")
    }
}
