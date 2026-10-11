import AppKit
import Combine
import XCTest
@testable import IslaKit

/// The scripting fallback shows a player the way the helper route does.
///
/// It is the route every DMG user lands on whose helper Gatekeeper refuses,
/// and it used to build its track by hand: no pid, so no shuffle or repeat,
/// no heart, no precision sync and lyric nudges saved under "other"; its own
/// `app|…` key, so every hand-over re-announced an unchanged song; no
/// track-change branch, so a skip in Apple Music kept the old song's clock
/// under the new title; and a cover that failed once was never asked for
/// again. Every reply now goes through `apply`, as a snapshot.
@MainActor
final class FallbackRouteTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func song(
        _ title: String, album: String = "C", playing: Bool = true,
        at position: TimeInterval = 10, duration: TimeInterval = 240, app: PlayerApp = .spotify
    ) -> PlayerState {
        // A scripted Spotify state names its cover's address, as the real
        // one does; one without an address is not fetched at all.
        PlayerState(
            app: app, isPlaying: playing, title: title, artist: "B", album: album,
            duration: duration, position: position,
            artworkURL: app == .spotify ? URL(string: "https://i.scdn.co/image/\(title)") : nil
        )
    }

    /// A controller cut off from every real player, answering for Spotify as
    /// pid 77 and Apple Music as pid 88. `replies` is consumed one per
    /// question; the last one repeats.
    private func controller(replies: [PlayerState?]) -> (MediaController, () -> Int) {
        let media = MediaController()
        media.isolateFromPlayers()
        media.musicOnly = { false }
        media.lyricsShown = { false }
        media.bundleIdentifierForPID = { pid in
            switch pid {
            case 77: return PlayerApp.spotify.bundleID
            case 88: return PlayerApp.music.bundleID
            default: return nil
            }
        }
        media.pidForPlayer = { $0 == .spotify ? 77 : 88 }
        media.isProcessRunning = { _ in true }
        var queue = replies
        var asked = 0
        media.loadedSong = { (reply: @escaping (PlayerState?) -> Void) in
            asked += 1
            let next = queue.count > 1 ? queue.removeFirst() : queue.first ?? nil
            reply(next)
        }
        return (media, { asked })
    }

    /// Lets anything the route hopped onto the main queue land.
    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    // MARK: - Which player

    func testTheFallbackKnowsWhichPlayerItShows() {
        let (media, _) = controller(replies: [song("A")])
        media.switchToScriptingFallback(.keptStopping)
        drainMain()

        XCTAssertEqual(media.track?.key, "77|A|B|C", "keyed like the helper route: pid, title, artist, album")
        XCTAssertEqual(media.lyricPlayerID, "spotify", "lyric nudges belong to Spotify, not 'other'")
        XCTAssertEqual(media.sourceName, "Spotify")
        media.stop()
    }

    /// Two paused players used to trade places on every announcement, since
    /// whichever answered first in `allCases` order won.
    func testWithNothingPlayingTheShownPlayerKeepsTheIsland() {
        let music = song("M", playing: false, app: .music)
        let spotify = song("S", playing: false, app: .spotify)
        XCTAssertEqual(PlayerBridge.choose(among: [music, spotify], prefer: .spotify)?.title, "S")
        XCTAssertEqual(PlayerBridge.choose(among: [music, spotify], prefer: nil)?.title, "M")
        // Sound still outranks the preference.
        let playingMusic = song("M", playing: true, app: .music)
        XCTAssertEqual(PlayerBridge.choose(among: [playingMusic, spotify], prefer: .spotify)?.title, "M")
        XCTAssertNil(PlayerBridge.choose(among: [], prefer: .spotify))
    }

    // MARK: - A skip

    /// Next in Apple Music, two minutes into a song: the new title used to run
    /// on at 2:00, the rewind held for a second reading that never came.
    func testAFallbackSkipStartsTheNewSongAtItsOwnPosition() {
        let (media, _) = controller(replies: [
            song("A", at: 120, app: .music),
            song("Next", album: "Other", at: 0.5, duration: 200, app: .music),
        ])
        media.switchToScriptingFallback(.keptStopping)
        drainMain()
        XCTAssertEqual(media.position, 120, accuracy: 0.6)

        media.refreshFromPlayers()
        drainMain()
        XCTAssertEqual(media.track?.title, "Next")
        XCTAssertEqual(media.position, 0.5, accuracy: 0.6, "the new song starts at its own time")
        media.stop()
    }

    // MARK: - Hand-overs

    /// A wake retry handing the route back to the helper over the same song
    /// used to re-announce it: the pill peeked, the lyrics re-resolved and
    /// the cover blinked.
    func testAHandOverToTheHelperKeepsAnUnchangedSong() {
        let (media, _) = controller(replies: [song("A")])
        var keys: [String] = []
        media.$track.map { $0?.key }.removeDuplicates().compactMap { $0 }
            .sink { keys.append($0) }
            .store(in: &cancellables)

        media.switchToScriptingFallback(.keptStopping)
        drainMain()
        XCTAssertEqual(media.track?.key, "77|A|B|C")

        media.retryNowPlaying(userAsked: true)
        var helper = NowPlayingFeed.Snapshot()
        helper.title = "A"
        helper.artist = "B"
        helper.album = "C"
        helper.duration = 240
        helper.elapsed = 10
        helper.isPlaying = true
        helper.rate = 1
        helper.takenAt = Date()
        helper.playerPID = 77
        media.feedDelivered(helper)

        XCTAssertEqual(keys, ["77|A|B|C"], "one song, announced once")
        media.stop()
    }

    /// A scripted reply that lands after the helper is back describes a route
    /// no longer in charge.
    func testALateScriptedReplyIsDroppedOnceTheFeedIsBack() {
        let media = MediaController()
        media.isolateFromPlayers()
        media.musicOnly = { false }
        media.lyricsShown = { false }
        media.bundleIdentifierForPID = { $0 == 77 ? PlayerApp.spotify.bundleID : nil }
        media.pidForPlayer = { _ in 77 }
        var held: ((PlayerState?) -> Void)?
        media.loadedSong = { (reply: @escaping (PlayerState?) -> Void) in held = reply }

        media.switchToScriptingFallback(.keptStopping)
        XCTAssertNotNil(held, "the fallback asks through the loaded-song seam")

        media.retryNowPlaying(userAsked: true)
        var helper = NowPlayingFeed.Snapshot()
        helper.title = "From the helper"
        helper.artist = "B"
        helper.isPlaying = true
        helper.rate = 1
        helper.takenAt = Date()
        helper.playerPID = 77
        media.feedDelivered(helper)

        held?(song("Late"))
        drainMain()
        XCTAssertEqual(media.track?.title, "From the helper")
        media.stop()
    }

    /// With the display on Spotify, a quit Spotify used to leave its song on
    /// the island: the paused Music that answered next was held off as a
    /// stranger, and on this route nothing ever asks again to end the hold.
    func testAQuitPlayerHandsTheFallbackToTheOtherOne() {
        let (media, _) = controller(replies: [
            song("A", playing: false, app: .spotify),
            song("M", playing: false, app: .music),
        ])
        media.switchToScriptingFallback(.keptStopping)
        drainMain()
        XCTAssertEqual(media.track?.title, "A")

        media.isProcessRunning = { $0 != 77 }
        media.refreshFromPlayers()
        drainMain()
        XCTAssertEqual(media.track?.title, "M")
        XCTAssertEqual(media.lyricPlayerID, "music")
        media.stop()
    }

    // MARK: - Covers

    private func image() -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4))
    }

    /// One failed CDN fetch used to cost the song its cover for good, because
    /// the key was recorded before the fetch. Two tries per song: a cover that
    /// truly does not exist is not polled.
    func testAFailedFallbackCoverIsAskedForAgainOnce() {
        let (media, _) = controller(replies: [song("A")])
        let cover = image()
        var answers: [NSImage?] = [nil, cover]
        var asked = 0
        media.heldArtwork = { (_: PlayerState, reply: @escaping (NSImage?) -> Void) in
            asked += 1
            reply(answers.isEmpty ? nil : answers.removeFirst())
        }
        media.switchToScriptingFallback(.keptStopping)
        drainMain()
        XCTAssertNil(media.artwork)

        media.refreshFromPlayers()
        drainMain()
        XCTAssertTrue(media.artwork === cover, "the second refresh asked again and got it")
        XCTAssertEqual(asked, 2)

        media.refreshFromPlayers()
        drainMain()
        XCTAssertEqual(asked, 2, "a cover on screen is not asked for again")
        media.stop()
    }

    func testACoverThatNeverComesIsAskedForTwiceOnly() {
        let (media, _) = controller(replies: [song("A")])
        var asked = 0
        media.heldArtwork = { (_: PlayerState, reply: @escaping (NSImage?) -> Void) in
            asked += 1
            reply(nil)
        }
        media.switchToScriptingFallback(.keptStopping)
        for _ in 0..<3 {
            media.refreshFromPlayers()
            drainMain()
        }
        XCTAssertEqual(asked, 2)
        media.stop()
    }

    /// The helper route waits 180 ms before blanking a skipped song's cover,
    /// so a cover arriving in that gap is one swap rather than two. The
    /// fallback blanked at once, every skip.
    func testAFallbackSkipKeepsTheOldCoverForAMoment() async throws {
        let (media, _) = controller(replies: [song("A", album: "First"), song("Next", album: "Second")])
        let first = image()
        media.heldArtwork = { (state: PlayerState, reply: @escaping (NSImage?) -> Void) in
            // The new song's cover is still on its way.
            if state.title == "A" { reply(first) }
        }
        media.switchToScriptingFallback(.keptStopping)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(media.artwork === first)

        media.refreshFromPlayers()
        XCTAssertEqual(media.track?.title, "Next")
        XCTAssertTrue(media.artwork === first, "the old cover stands while the new one is fetched")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(media.artwork, "and gives way once the grace has run out")
        media.stop()
    }

    /// The next song on the same album keeps the cover on screen.
    func testAFallbackSkipWithinAnAlbumKeepsTheCover() async throws {
        let (media, _) = controller(replies: [song("A", album: "Album"), song("Next", album: "Album")])
        let cover = image()
        media.heldArtwork = { (state: PlayerState, reply: @escaping (NSImage?) -> Void) in
            if state.title == "A" { reply(cover) }
        }
        media.switchToScriptingFallback(.keptStopping)
        try await Task.sleep(for: .milliseconds(20))
        media.refreshFromPlayers()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(media.track?.title, "Next")
        XCTAssertTrue(media.artwork === cover)
        media.stop()
    }
}
