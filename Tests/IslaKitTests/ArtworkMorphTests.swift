import SwiftUI
import XCTest
@testable import IslaKit

/// The cover is one object that travels between the pill and the panel.
///
/// It used to be two: a 22 pt cover in the compact header and a 118 pt cover in
/// the media pane, each fading independently, so the same album crossfaded past
/// itself on every open. No unit test can watch an interpolation, so what is
/// pinned here is the contract that makes one possible — a single shared
/// geometry identity, and both ends agreeing on it.
@MainActor
final class ArtworkMorphTests: XCTestCase {

    /// Both ends of the travel are described by one function, not by two
    /// hardcoded pairs. The pill hardcoded 22pt/r6 in `NotchContentView` and the
    /// pane hardcoded 118pt/r14 in `MediaPane` — two descriptions of one object,
    /// which is the same mistake as two views of one cover, one level down. A
    /// matched geometry effect interpolates the frame for you; what it cannot do
    /// is notice that the two ends disagree about what they are.
    func testOneFunctionDescribesBothEndsOfTheTravel() {
        let compact = Theme.artworkMetrics(isOpen: false)
        let open = Theme.artworkMetrics(isOpen: true)

        XCTAssertLessThan(compact.side, open.side, "the pill's cover is the smaller end")
        XCTAssertLessThan(compact.cornerRadius, open.cornerRadius)

        // The corner stays proportional across the travel, so the silhouette is
        // the same shape at both ends rather than two different roundnesses
        // that happen to meet.
        let compactRatio = compact.cornerRadius / compact.side
        let openRatio = open.cornerRadius / open.side
        XCTAssertEqual(compactRatio, openRatio, accuracy: 0.02,
                       "the cover keeps its proportions while it travels")
    }

    /// The proportion is the one the lock card already draws its cover at
    /// (`side / 5.5`), so the same album is the same shape on all three
    /// surfaces. Stated as a value and not just as a ratio between the two ends,
    /// because two ends can agree with each other and still disagree with the
    /// card.
    func testTheProportionIsTheOneTheLockCardAlreadyUses() {
        for isOpen in [false, true] {
            let metrics = Theme.artworkMetrics(isOpen: isOpen)
            XCTAssertEqual(metrics.cornerRadius, metrics.side / 5.5, accuracy: 0.001)
        }
    }

    /// Reduce Motion must not leave the cover mid-flight: with travel switched
    /// off the two ends still have to resolve to one of them, not to a frozen
    /// interpolation. `Theme.open(reduceMotion:)` is what decides that, and it
    /// must stay a real animation rather than `nil`.
    func testReduceMotionStillAnimatesTheOpen() {
        XCTAssertNotNil(Theme.open(reduceMotion: true))
        XCTAssertNotNil(Theme.open(reduceMotion: false))
    }

    /// The two ends must not answer to the same identity as each other's
    /// neighbour: the cover and the equalizer travel at the same time, and one
    /// id shared between them would make each end pick the wrong partner.
    func testTheTwoTravellingObjectsHaveDifferentIdentities() {
        XCTAssertNotEqual(NotchContentView.MorphID.artwork, NotchContentView.MorphID.equalizer)
    }

    /// The pane still renders without a namespace, so the existing render
    /// tests and the lock card keep working.
    func testTheMediaPaneRendersWithoutANamespace() {
        let pane = MediaPane(media: playingController(), lyrics: LyricsStore(), morph: nil)
        let image = ImageRenderer(content: pane.frame(width: 560, height: 157)).nsImage
        XCTAssertNotNil(image, "MediaPane must render with morph: nil")
    }

    /// A cover wider than it is tall stays inside its tile.
    ///
    /// This is a test about modifier order, which is the part of the morph that
    /// cannot be read off the screenshot. The cover's box has to *accept* the
    /// size it is offered rather than state one — a stated size is a size the
    /// matched geometry effect cannot change, and the cover would then slide
    /// between the pill and the panel without ever growing. What that flexible
    /// box must not cost is the clip: `aspectRatio(.fill)` reports a 16:9
    /// thumbnail — what a video in a browser tab publishes — as 211 pt wide in
    /// this 118 pt slot, and 46 pt of it used to hang over the tab rail on each
    /// side and eat the pointer (#22).
    func testAWideCoverStaysInsideItsTile() throws {
        let media = playingController()
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.duration = 180
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        // Magenta rather than white: the pane's own title and artist are white
        // on black a few points to the right of the tile's edge, and a test that
        // cannot tell ink from overflow reports whichever it sees first.
        snapshot.artwork = try Self.wideMagenta()
        media.apply(snapshot)

        // The decode is deliberately off the main thread, so the cover is not
        // there the instant the snapshot is applied.
        let deadline = Date().addingTimeInterval(3)
        while media.artwork == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let cover = try XCTUnwrap(media.artwork, "the cover has to decode for this to test anything")
        XCTAssertGreaterThan(cover.size.width, cover.size.height, "a wide cover is the whole point")

        let pane = MediaPane(media: media, lyrics: LyricsStore(), morph: nil)
            .frame(width: 560, height: 157)
            .background(Color.black)
        let renderer = ImageRenderer(content: pane)
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(rendered.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        let side = Theme.artworkMetrics(isOpen: true).side
        var strays = 0
        // From a little past the tile's edge to well past where a 16:9 cover
        // would reach if nothing clipped it.
        for x in stride(from: Int(side) + 6, to: min(bitmap.pixelsWide, Int(side) + 60), by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                if colour.redComponent > 0.5, colour.blueComponent > 0.5, colour.greenComponent < 0.25 {
                    strays += 1
                }
            }
        }
        XCTAssertEqual(strays, 0, "the cover overflowed its tile by \(strays) sampled pixels")
    }

    // MARK: - Helpers

    private func playingController() -> MediaController {
        let media = MediaController()
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.album = ""
        snapshot.duration = 180
        snapshot.elapsed = 9.2
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        media.apply(snapshot)
        return media
    }

    /// 16:9, the shape a video publishes, in a colour nothing else here draws.
    private static func wideMagenta() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 320,
            pixelsHigh: 180,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
