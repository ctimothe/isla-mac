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

        // The corner grows with the cover, but more slowly than the cover does.
        //
        // This started out asserting a *constant* ratio, on the reasoning that
        // one object should keep its proportions while it travels. That is
        // wrong, and it is wrong in the direction that shows: a thumbnail wants
        // to read as a rounded chip and a large cover wants to read as a
        // picture, so Apple's small artwork is proportionally far rounder than
        // its large artwork, never the same. Holding the ratio constant took
        // the open cover from radius 14 to 21.45 on a 118pt side — 18% — which
        // is a chip the size of a postcard.
        let compactRatio = compact.cornerRadius / compact.side
        let openRatio = open.cornerRadius / open.side
        XCTAssertGreaterThan(compactRatio, openRatio,
                             "the small end is the proportionally rounder one")
        XCTAssertGreaterThan(open.cornerRadius, compact.cornerRadius,
                             "and it still grows in absolute terms, or the travel would shrink it")
    }

    /// The lock card draws its own cover at `side / 5.5`, and this deliberately
    /// does not follow it.
    ///
    /// That ratio was set on a 42–62pt cover, where 18% reads as a rounded
    /// thumbnail. The panel's cover is 118pt, and the same 18% there is 21.45pt
    /// — visibly a chip rather than a picture. The rule the card and the panel
    /// actually share is the shape (`.continuous`) and the direction, not the
    /// number.
    func testTheOpenCoverIsNotAsRoundAsTheLockCardsThumbnail() {
        let open = Theme.artworkMetrics(isOpen: true)
        XCTAssertLessThan(open.cornerRadius, open.side / 5.5,
                          "the largest cover in the app is a picture, not a chip")
        XCTAssertGreaterThanOrEqual(open.cornerRadius, 12)
        XCTAssertLessThanOrEqual(open.cornerRadius, 16)
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
