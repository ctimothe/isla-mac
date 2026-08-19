import XCTest
@testable import DynamicIslandKit

@MainActor
final class MediaControllerTests: XCTestCase {
    func testRateAboveZeroIsTreatedAsPlayingEvenWhenIsPlayingReportsFalse() {
        let controller = MediaController()

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 200
        playing.elapsed = 5
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 123
        controller.apply(playing)
        XCTAssertTrue(controller.isPlaying)

        // A browser tab: MediaRemote reports `isPlaying == false` while the
        // playback rate is still positive (#see MediaController.swift).
        var browserTab = playing
        browserTab.isPlaying = false
        browserTab.rate = 2.0
        browserTab.elapsed = 10
        browserTab.takenAt = Date().addingTimeInterval(-2)
        controller.apply(browserTab)

        XCTAssertTrue(
            controller.isPlaying,
            "rate > 0 must be treated as playing even when isPlaying reports false"
        )
        XCTAssertGreaterThan(
            controller.position,
            browserTab.elapsed,
            "elapsed-time interpolation must not freeze when rate > 0"
        )
    }

    func testTrackIdentityIncludesPlayerPIDSoTwoPlayersSharingATitleDoNotShareArtwork() {
        let controller = MediaController()

        var fromPlayerOne = NowPlayingFeed.Snapshot()
        fromPlayerOne.title = "Same Title"
        fromPlayerOne.artist = "Same Artist"
        fromPlayerOne.album = "Same Album"
        fromPlayerOne.isPlaying = true
        fromPlayerOne.playerPID = 100
        controller.apply(fromPlayerOne)
        let keyForPlayerOne = controller.track?.key

        // The OS switched its active Now Playing session to a different
        // player that happens to report the exact same title/artist/album.
        var fromPlayerTwo = fromPlayerOne
        fromPlayerTwo.playerPID = 200
        controller.apply(fromPlayerTwo)
        let keyForPlayerTwo = controller.track?.key

        XCTAssertNotEqual(
            keyForPlayerOne,
            keyForPlayerTwo,
            "same title/artist/album from a different player PID must not share track identity"
        )
    }
}
