import AppKit
import XCTest
@testable import IslaKit

/// What a second filmed session of skips still showed, read frame by frame on
/// 2026-09-21: a skip made two seconds in carried 0:02 into the next song; the
/// next song on the same album dropped its cover to the placeholder and got
/// the same one back; and a seek's first correction stepped the label back a
/// second.
@MainActor
final class SkipPolishTests: XCTestCase {
    private func report(
        _ title: String, album: String = "Album", elapsed: TimeInterval,
        duration: TimeInterval = 200, artwork: Data? = nil
    ) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "Artist"
        s.album = album
        s.duration = duration
        s.elapsed = elapsed
        s.isPlaying = true
        s.rate = 1
        s.takenAt = Date()
        s.playerPID = 1
        s.artwork = artwork
        return s
    }

    private func controller() -> MediaController {
        let controller = MediaController()
        controller.isolateFromPlayers()
        return controller
    }

    private func png() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Skipped two seconds in: the next song starts at 0, not at 0:02.
    func testASkipMadeInTheFirstSecondsStartsTheNextSongAtZero() {
        let c = controller()
        c.apply(report("One", elapsed: 2.0))
        c.apply(report("Two", elapsed: 2.1))
        XCTAssertLessThan(c.position, 1)
    }

    /// The next song on the same album keeps the cover on screen; it used to
    /// blank to the placeholder and come back.
    func testTheNextSongOnTheSameAlbumKeepsTheCover() async {
        let c = controller()
        c.apply(report("dragon eyes", album: "songs", elapsed: 10, artwork: png()))
        await waitUntil { c.artwork != nil }
        XCTAssertNotNil(c.artwork, "the fixture: the first song's cover")

        c.apply(report("my angel", album: "songs", elapsed: 0.1))
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertNotNil(c.artwork, "still the album's cover, not the placeholder")
    }

    /// Another album still clears the old cover, so a different song never
    /// wears the last one's picture.
    func testAnotherAlbumStillClearsTheOldCover() async {
        let c = controller()
        c.apply(report("One", album: "First", elapsed: 10, artwork: png()))
        await waitUntil { c.artwork != nil }
        c.apply(report("Two", album: "Second", elapsed: 0.1))
        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertNil(c.artwork)
    }

    /// A correction nudging the clock back across a second does not step the
    /// label back; a real seek back does.
    func testTheLabelNeverStepsBackASecondForASmallCorrection() {
        let c = controller()
        c.apply(report("Song", elapsed: 50.6))
        XCTAssertEqual(Int(c.labelPosition.rounded()), 51)

        c.handleSpotifyPlaybackState(position: 50.3)
        XCTAssertEqual(Int(c.labelPosition.rounded()), 51, "held at the second already shown")

        c.handleSpotifyPlaybackState(position: 40)
        XCTAssertEqual(Int(c.labelPosition.rounded()), 40, "a real jump back is shown")
    }
}
