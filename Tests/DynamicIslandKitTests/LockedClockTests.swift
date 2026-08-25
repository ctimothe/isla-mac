import XCTest
@testable import DynamicIslandKit

/// The clock behind the lock card keeps running.
@MainActor
final class LockedClockTests: XCTestCase {

    /// `NotchStores` builds its own controller, so the test drives that one.
    private func playingStores() -> NotchStores {
        let stores = NotchStores()
        let media = stores.media
        media.setActive(true)
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.album = ""
        snapshot.duration = 240
        snapshot.elapsed = 30
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 8181
        media.apply(snapshot)
        return stores
    }

    /// The reported bug. `screenLocked()` activated media and then called
    /// `suspendForIdleScreen()` five lines later, which switched it back off —
    /// so the position froze the instant the Mac locked. The scrubber stopped
    /// and the lyric stood on whatever line it had reached, for the whole lock.
    func testTheClockSurvivesTheLockWhenTheCardIsShowing() async {
        let stores = playingStores()
        let media = stores.media
        let started = media.position

        stores.suspendForIdleScreen(keepingMediaRunning: true)

        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(
            media.position, started,
            "the position must keep advancing while the lock card is on screen"
        )
    }

    /// With the card switched off there is nothing on screen driven by the
    /// clock, and a shielded Mac has no use for a four-times-a-second timer.
    func testTheClockStopsWhenNothingIsShowing() async {
        let stores = playingStores()
        let media = stores.media
        stores.suspendForIdleScreen()

        try? await Task.sleep(for: .milliseconds(200))
        let settled = media.position
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(
            media.position, settled, accuracy: 0.001,
            "with no card there is nothing to move, and the ticker should be off"
        )
    }
}
