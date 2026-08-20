import XCTest
@testable import DynamicIslandKit

@MainActor
final class MediaControllerTests: XCTestCase {
    /// A browser tab never raises the flag at all — it reports
    /// `isPlaying == false` with a positive rate from the very first snapshot.
    /// That shape must read as playing, or such sessions show as paused for
    /// their whole life and their elapsed time never moves.
    func testRateAboveZeroIsTreatedAsPlayingForASessionThatNeverRaisesTheFlag() {
        let controller = MediaController()

        var browserTab = NowPlayingFeed.Snapshot()
        browserTab.title = "Track"
        browserTab.artist = "Artist"
        browserTab.album = "Album"
        browserTab.duration = 200
        browserTab.elapsed = 10
        browserTab.rate = 2.0
        browserTab.isPlaying = false
        browserTab.takenAt = Date().addingTimeInterval(-2)
        browserTab.playerPID = 123
        controller.apply(browserTab)

        XCTAssertTrue(
            controller.isPlaying,
            "rate > 0 must be treated as playing when isPlaying is never set"
        )
        XCTAssertGreaterThan(
            controller.position,
            browserTab.elapsed,
            "elapsed-time interpolation must not freeze when rate > 0"
        )
    }

    /// The counterpart, and the reason the rule is not a plain OR: on a real
    /// pause the flag drops about half a second before the rate does
    /// (measured at 165ms versus 712ms against Spotify). Counting that stale
    /// rate leaves the island animating after the music has stopped.
    func testAFreshPauseIsNotHeldOpenByARateThatHasNotSettled() {
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

        var justPaused = playing
        justPaused.isPlaying = false
        justPaused.rate = 1 // has not caught up yet
        justPaused.takenAt = Date()
        controller.apply(justPaused)

        XCTAssertFalse(
            controller.isPlaying,
            "a flag that has just dropped must win over a rate that has not settled"
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

    /// Pausing must leave the bar exactly where it stood.
    ///
    /// MediaRemote keeps republishing the reading from the last state change,
    /// so right after a pause it still describes where the track was when it
    /// started playing — minutes behind. Adopting that yanks the bar back, and
    /// the next poll yanks it forward again.
    func testAStalePausedReadingDoesNotMoveThePosition() {
        let controller = MediaController()

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 5
        playing.rate = 1
        playing.isPlaying = true
        // Playback began 160s ago, at 0:05. The reading has not moved since.
        playing.takenAt = Date().addingTimeInterval(-160)
        playing.playerPID = 1
        controller.apply(playing)
        XCTAssertEqual(controller.position, 165, accuracy: 3)

        // Paused now, but the payload still carries that same old reading.
        var paused = playing
        paused.isPlaying = false
        paused.rate = 0
        controller.apply(paused)

        XCTAssertEqual(
            controller.position,
            165,
            accuracy: 3,
            "a paused reading older than what is already known must not move the bar"
        )
    }
}
