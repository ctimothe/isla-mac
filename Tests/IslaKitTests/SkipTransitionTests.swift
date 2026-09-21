import XCTest
@testable import IslaKit

/// What a skip shows while the player and its reports disagree about which
/// song it is.
///
/// Filmed on 2026-09-21 and read frame by frame: on eleven skips the new song's
/// clock ran under the old song's title — 0:00, sometimes 0:01 — for 50 to
/// 700ms; once the new title arrived at the old song's position, 2:15 of 2:15,
/// with its last lyric line for 1.2s; and song lengths ticked by a second a
/// moment after they appeared.
@MainActor
final class SkipTransitionTests: XCTestCase {
    private func report(
        _ title: String, elapsed: TimeInterval, duration: TimeInterval = 240, playing: Bool = true
    ) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "Artist"
        s.album = "Album"
        s.duration = duration
        s.elapsed = elapsed
        s.isPlaying = playing
        s.rate = playing ? 1 : 0
        s.takenAt = Date()
        s.playerPID = 1
        return s
    }

    private func controller() -> MediaController {
        let controller = MediaController()
        controller.isolateFromPlayers()
        return controller
    }

    /// The first half of a skip — the song on screen back at its start, with
    /// no new name — is held; the report naming the next song lands at its
    /// own start.
    func testASkipHalfReportedKeepsTheOldSongWhereItWas() {
        let c = controller()
        c.apply(report("Old", elapsed: 90))
        // Two readings that agree: the old rewind rule alone would take the
        // second, and show the new song's 0:00 under the old title.
        c.apply(report("Old", elapsed: 0.1))
        c.apply(report("Old", elapsed: 0.15))
        XCTAssertEqual(c.track?.title, "Old")
        XCTAssertGreaterThan(c.position, 89, "the old song does not show the new one's 0:00")

        c.apply(report("New", elapsed: 0.2))
        XCTAssertEqual(c.track?.title, "New")
        XCTAssertEqual(c.position, 0.2, accuracy: 0.2)
    }

    /// With no new name inside the grace, it was a restart after all.
    func testTheStartOfTheSameSongIsBelievedOnceTheGraceRunsOut() async {
        MediaController.trackChangeGrace = 0.05
        defer { MediaController.trackChangeGrace = 1.2 }
        let c = controller()
        c.apply(report("Song", elapsed: 90))
        c.apply(report("Song", elapsed: 0.1))
        XCTAssertGreaterThan(c.position, 89)
        try? await Task.sleep(for: .milliseconds(80))
        c.apply(report("Song", elapsed: 0.2))
        XCTAssertLessThan(c.position, 1)
    }

    /// A new song's first report carrying the old song's position — past the
    /// new song's end — starts at 0, not at its last line.
    func testANewSongReportedPastItsEndStartsAtZero() {
        let c = controller()
        c.apply(report("Suzanne", elapsed: 192, duration: 294))
        c.apply(report("womb", elapsed: 192.1, duration: 135))
        XCTAssertEqual(c.track?.title, "womb")
        XCTAssertLessThan(c.position, 1)
    }

    /// The same when the stale reading still fits inside the new song.
    func testANewSongReportedAtTheOldPositionStartsAtZero() {
        let c = controller()
        c.apply(report("One", elapsed: 150, duration: 300))
        c.apply(report("Two", elapsed: 150.3, duration: 280))
        XCTAssertLessThan(c.position, 1)
    }

    /// A new song resumed part-way through is not taken for a stale reading.
    func testANewSongPartWayThroughKeepsItsPosition() {
        let c = controller()
        c.apply(report("One", elapsed: 40, duration: 300))
        c.apply(report("Two", elapsed: 95, duration: 280))
        XCTAssertEqual(c.position, 95, accuracy: 0.3)
    }

    /// Spotify announcing another song does not anchor the old title to it.
    func testAnAnnouncementOfAnotherSongDoesNotMoveTheOldOne() {
        let c = controller()
        c.apply(report("Old", elapsed: 90))
        // Set only now: the flag also sends the track-id lookup to the real
        // Spotify, which a report applied under it would.
        c.spotifyDisplayForTests = true
        c.receiveSpotifyBroadcast(["Name": "New", "Playback Position": 0.0])
        XCTAssertGreaterThan(c.position, 89)
    }

    /// One song's length reported twice a fraction apart keeps the first, so
    /// the label does not tick from 4:07 to 4:08; a real correction lands.
    func testALengthReportedTwiceStaysPut() {
        let c = controller()
        c.apply(report("Song", elapsed: 1, duration: 247.4))
        c.apply(report("Song", elapsed: 1.4, duration: 247.6))
        XCTAssertEqual(c.duration, 247.4)
        c.apply(report("Song", elapsed: 1.8, duration: 250))
        XCTAssertEqual(c.duration, 250)
    }

    /// Repeat-one: a song that ran to its end starting over is not held for a
    /// new name. It follows the ordinary rewind rule — a second reading that
    /// agrees — and nothing more.
    func testASongStartingOverAtItsEndIsNotHeldForANewName() {
        let c = controller()
        c.apply(report("Song", elapsed: 238.5, duration: 240))
        c.apply(report("Song", elapsed: 0.1, duration: 240))
        c.apply(report("Song", elapsed: 0.15, duration: 240))
        XCTAssertLessThan(c.position, 1)
    }

    /// Previous a few seconds in is a restart, and shows as one at once.
    func testPreviousShowsTheRestartAtOnce() {
        let c = controller()
        c.apply(report("Song", elapsed: 90))
        c.previous()
        c.apply(report("Song", elapsed: 0.1))
        XCTAssertLessThan(c.position, 1)
    }
}

/// What the lyric caption says when a song has none.
final class LyricCaptionCopyTests: XCTestCase {
    /// With LRCLIB asked too, a miss says nothing was found. "No local
    /// lyrics." read as though the catalogue had never been tried.
    func testAMissWithOnlineLyricsOnSaysNothingWasFound() {
        XCTAssertEqual(
            LyricsPresentation.compactCaption(for: .noLocalLyrics, currentLine: nil, onlineEnabled: true),
            localized("No lyrics found.")
        )
        XCTAssertEqual(
            LyricsPresentation.compactCaption(for: .noLocalLyrics, currentLine: nil),
            localized("No local lyrics."),
            "with only the local library searched, local is the honest word"
        )
    }
}
