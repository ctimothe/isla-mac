import XCTest
@testable import IslaKit

/// The player's Favourite star (spec §19.6): drawn only when something can
/// act on it — Music through the scripting bridge, or Spotify through a
/// connected account's library — and absent otherwise, never a star that
/// does nothing.
@MainActor
final class PlayerFavouriteTests: XCTestCase {
    typealias Favourite = MediaPane.Favourite

    /// Music answered the favourite question: its star, in the state it said.
    func testMusicAnswersWithItsOwnStar() {
        XCTAssertEqual(
            Favourite.resolve(musicFavorite: true, spotifyTrackID: nil, spotifyCanSave: false, saved: [:]),
            .music(isOn: true)
        )
        XCTAssertEqual(
            Favourite.resolve(musicFavorite: false, spotifyTrackID: nil, spotifyCanSave: false, saved: [:]),
            .music(isOn: false)
        )
    }

    /// Spotify's star needs a connected account that can write the library
    /// and the song's id; the library's answer is its state, and "not yet
    /// answered" draws it off.
    func testSpotifyNeedsAnAccountThatCanSave() {
        XCTAssertEqual(
            Favourite.resolve(musicFavorite: nil, spotifyTrackID: "abc", spotifyCanSave: true, saved: ["abc": true]),
            .spotify(trackID: "abc", isOn: true)
        )
        let unanswered = Favourite.resolve(musicFavorite: nil, spotifyTrackID: "abc", spotifyCanSave: true, saved: [:])
        XCTAssertEqual(unanswered, .spotify(trackID: "abc", isOn: nil))
        XCTAssertEqual(unanswered?.isOn, false)
        XCTAssertNil(Favourite.resolve(musicFavorite: nil, spotifyTrackID: "abc", spotifyCanSave: false, saved: ["abc": true]))
        XCTAssertNil(Favourite.resolve(musicFavorite: nil, spotifyTrackID: nil, spotifyCanSave: true, saved: [:]))
    }

    /// A browser, or any player that answers neither, has no star.
    func testNoBridgeNoStar() {
        XCTAssertNil(Favourite.resolve(musicFavorite: nil, spotifyTrackID: nil, spotifyCanSave: false, saved: [:]))
    }

    /// Music's answer rides on the playback-modes round trip: "true",
    /// "false", or "none" when there was no current track to ask.
    func testTheBridgeReadsMusicsAnswer() {
        XCTAssertEqual(PlayerBridge.favorite("true"), true)
        XCTAssertEqual(PlayerBridge.favorite("false"), false)
        XCTAssertNil(PlayerBridge.favorite("none"))
        XCTAssertNil(PlayerBridge.favorite(""))
    }

    /// The write goes to Music's own property; Spotify's scripting has none,
    /// and its body does nothing.
    func testTheBridgeWritesOnlyMusicsProperty() {
        XCTAssertEqual(
            PlayerBridge.Transport.favorite(true).body(for: .music), "set favorited of current track to true"
        )
        XCTAssertEqual(
            PlayerBridge.Transport.favorite(false).body(for: .music), "set favorited of current track to false"
        )
        XCTAssertEqual(PlayerBridge.Transport.favorite(true).body(for: .spotify), "return")
    }

    // MARK: - A tap held until Music agrees

    typealias Hold = MusicFavoriteHold
    private let tapped: TimeInterval = 100

    /// Filmed on 2026-10-28: a catalogue song starred in the player. Music
    /// sent the favourite to its library agent as a cloud edit and answered
    /// "false" for the 3.05 s that took; the one read-back, 0.4 s after the
    /// tap, believed it and emptied the star. Two more taps, two more cloud
    /// edits, before one landed late enough to stick.
    func testMusicsStaleAnswerDoesNotUndoTheTap() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: true, at: tapped)
        XCTAssertEqual(hold.shown(answer: false, trackKey: "song", at: tapped + 0.4), true)
        XCTAssertEqual(hold.shown(answer: false, trackKey: "song", at: tapped + 3.0), true)
        XCTAssertNotNil(hold.tap)
    }

    /// The other way round holds the same: an unstarred song stays unstarred
    /// while Music still says it is a favourite.
    func testTheHoldWorksBothWays() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: false, at: tapped)
        XCTAssertEqual(hold.shown(answer: true, trackKey: "song", at: tapped + 0.4), false)
    }

    /// Music saying what the tap said ends the hold, and from then on Music's
    /// answer is the star again — a change made in Music itself included.
    func testMusicsAgreementEndsTheHold() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: true, at: tapped)
        XCTAssertEqual(hold.shown(answer: true, trackKey: "song", at: tapped + 3.05), true)
        XCTAssertNil(hold.tap)
        XCTAssertEqual(hold.shown(answer: false, trackKey: "song", at: tapped + 4), false)
    }

    /// A tap Music never took — offline, the cloud edit refused — is not held
    /// for ever: once the window has run out, Music's answer is the star.
    func testMusicIsBelievedOnceTheWindowRunsOut() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: true, at: tapped)
        XCTAssertEqual(hold.shown(answer: false, trackKey: "song", at: tapped + Hold.window), false)
        XCTAssertNil(hold.tap)
    }

    /// No answer — a poll skipped for a tap behind it, or Music between songs
    /// for an instant — says nothing about the write.
    func testNoAnswerKeepsTheTap() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: true, at: tapped)
        XCTAssertEqual(hold.shown(answer: nil, trackKey: "song", at: tapped + 1), true)
        XCTAssertNotNil(hold.tap)
    }

    /// The tap was about one song; another song's answer is that song's own.
    func testAnotherSongsAnswerEndsTheHold() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: true, at: tapped)
        XCTAssertEqual(hold.shown(answer: false, trackKey: "next", at: tapped + 0.4), false)
        XCTAssertNil(hold.tap)
    }

    /// A second tap replaces the first: the star goes where the latest tap
    /// put it, and a refusal of the earlier one releases nothing.
    func testTheLatestTapWins() {
        var hold = Hold()
        let first = hold.tapped(trackKey: "song", wants: true, at: tapped)
        let second = hold.tapped(trackKey: "song", wants: false, at: tapped + 0.2)
        XCTAssertFalse(hold.refused(first))
        XCTAssertFalse(hold.expired(first))
        XCTAssertEqual(hold.tap, second)
        XCTAssertEqual(hold.shown(answer: true, trackKey: "song", at: tapped + 0.6), false)
        XCTAssertTrue(hold.refused(second))
        XCTAssertNil(hold.tap)
    }

    /// "On", then "off" 0.2 s later, on a catalogue song: at 0.4 s Music says
    /// "off" only because the first tap's cloud edit has not landed, and at
    /// 3 s it lands and Music says "on". Ended on the early agreement, the
    /// star said off while Music had the song as a favourite, with no read
    /// left to notice (found in review, 2026-10-28). A tap that reverses a
    /// held one runs the whole window, and then Music's answer is the star.
    func testATapReversingAHeldOneIsHeldToTheEndOfTheWindow() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: true, at: tapped)
        let reversal = hold.tapped(trackKey: "song", wants: false, at: tapped + 0.2)
        XCTAssertTrue(reversal.overtook)
        XCTAssertEqual(hold.shown(answer: false, trackKey: "song", at: tapped + 0.6), false)
        XCTAssertEqual(hold.tap, reversal)
        XCTAssertEqual(hold.shown(answer: true, trackKey: "song", at: tapped + 3.2), false)
        XCTAssertEqual(hold.shown(answer: true, trackKey: "song", at: tapped + 0.2 + Hold.window), true)
        XCTAssertNil(hold.tap)
    }

    /// A tap after the hold is over overtakes nothing: a library song's
    /// local write agrees at once and ends its own hold.
    func testATapAfterAnEndedHoldOvertakesNothing() {
        var hold = Hold()
        hold.tapped(trackKey: "song", wants: true, at: tapped)
        _ = hold.shown(answer: true, trackKey: "song", at: tapped + 0.4)
        XCTAssertFalse(hold.tapped(trackKey: "song", wants: false, at: tapped + 1).overtook)
        XCTAssertFalse(hold.tapped(trackKey: "next", wants: true, at: tapped + 2).overtook)
    }

    /// The window's end releases only the tap it was set for.
    func testTheWindowEndsOnlyItsOwnTap() {
        var hold = Hold()
        let tap = hold.tapped(trackKey: "song", wants: true, at: tapped)
        XCTAssertTrue(hold.expired(tap))
        XCTAssertNil(hold.tap)
        XCTAssertFalse(hold.expired(tap))
    }

    /// The read-backs start where the single one did, ask again while Music's
    /// measured catch-up is under way, and all come before the window ends.
    func testTheReadBacksFallInsideTheWindow() {
        XCTAssertEqual(Hold.readBacks.first, 0.4)
        XCTAssertEqual(Hold.readBacks, Hold.readBacks.sorted())
        XCTAssertLessThan(Hold.readBacks.last ?? .infinity, Hold.window)
        XCTAssertTrue(Hold.readBacks.contains { $0 > 3.05 && $0 < 5 })
    }

    /// A failed command answers nil, not an empty descriptor: Swift's
    /// `executeAndReturnError` hands back one even when the script threw,
    /// and the star's refusal reads the difference.
    func testAFailedScriptAnswersNothing() {
        var error: NSDictionary?
        let thrown = NSAppleScript(source: "error number -10006")?.executeAndReturnError(&error)
        XCTAssertNil(PlayerBridge.answer(thrown, error: error))
        error = nil
        let fine = NSAppleScript(source: "return")?.executeAndReturnError(&error)
        XCTAssertNotNil(PlayerBridge.answer(fine, error: error))
    }
}

/// The star's wiring in `MediaController`: the tap, the read-backs, Music's
/// answers and the end of the hold, against a Music that answers what each
/// test says and a clock and timer the test moves by hand.
@MainActor
final class MusicFavoriteWiringTests: XCTestCase {
    /// What Music answers, what it was told, and the timers the star set.
    private final class FakeMusic {
        var favorite: Bool? = false
        var accepts = true
        var writes: [Bool] = []
        var reads = 0
        /// Replies held back by a test that answers them itself, late.
        var heldReplies: [(PlayerBridge.PlaybackModes?) -> Void] = []
        var holdReplies = false
        var timers: [(at: TimeInterval, work: () -> Void)] = []
        var now: TimeInterval = 100
    }

    private func controller() -> (MediaController, FakeMusic) {
        let media = MediaController()
        let music = FakeMusic()
        media.isolateFromPlayers()
        media.musicOnly = { true }
        media.lyricsShown = { false }
        media.bundleIdentifierForPID = { _ in PlayerApp.music.bundleID }
        media.isProcessRunning = { _ in true }
        media.pidForPlayer = { $0 == .music ? 3 : nil }
        media.monotonicNow = { music.now }
        media.playbackModesReader = { _, reply in
            music.reads += 1
            if music.holdReplies { return music.heldReplies.append(reply) }
            reply((shuffle: false, repeatMode: .off, favorite: music.favorite))
        }
        media.favoriteWriter = { _, isFavorite, reply in
            music.writes.append(isFavorite)
            reply(music.accepts)
        }
        media.favoriteTimer = { delay, work in music.timers.append((music.now + delay, work)) }
        return (media, music)
    }

    private func play(_ title: String, pid: pid_t = 3, on media: MediaController) {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "Radiohead"
        s.album = "OK Computer"
        s.duration = 264
        s.elapsed = 95
        s.isPlaying = true
        s.rate = 1
        s.takenAt = Date()
        s.playerPID = pid
        media.apply(s)
    }

    /// The star the player and the lock card would draw, with a Spotify
    /// account connected and able to save: the harshest case, since a
    /// Spotify id left behind would then draw a star of its own.
    private func star(_ media: MediaController) -> MediaPane.Favourite? {
        MediaPane.Favourite.resolve(
            musicFavorite: media.musicFavorite, spotifyTrackID: media.spotifyTrackID,
            spotifyCanSave: true, saved: [:]
        )
    }

    /// Run-sheet MR-H3, the half a test can hold: the star is absent for
    /// Yandex Music and a browser. The same song moving from Music to them is
    /// the hard case — the track is unchanged, so only the change of player
    /// can take Music's answer away — and Music is never asked about a song
    /// another player is playing.
    func testTheStarGoesWithMusicWhenYandexMusicOrABrowserPlays() {
        let (media, music) = controller()
        media.musicOnly = { false }
        music.favorite = true
        play("Exit Music (For a Film)", on: media)
        media.refreshPlaybackModes()
        XCTAssertEqual(media.musicFavorite, true)
        XCTAssertEqual(star(media), .music(isOn: true))
        let asked = music.reads

        for (pid, bundle) in [(pid_t(7), "ru.yandex.desktop.music"), (pid_t(9), "com.apple.Safari")] {
            media.bundleIdentifierForPID = { $0 == pid ? bundle : PlayerApp.music.bundleID }
            play("Exit Music (For a Film)", pid: pid, on: media)
            XCTAssertNil(star(media), "gone with the snapshot, before anything asks again: \(bundle)")
            media.refreshPlaybackModes()
            XCTAssertNil(media.musicFavorite, bundle)
            XCTAssertNil(media.spotifyTrackID, bundle)
            XCTAssertNil(star(media), "no star for \(bundle)")
            XCTAssertEqual(music.reads, asked, "Music is not asked about \(bundle)'s song")
        }
    }

    /// Moves the clock to `seconds` after the start and runs every timer due
    /// by then, in order.
    private func advance(to seconds: TimeInterval, _ music: FakeMusic) {
        music.now = 100 + seconds
        let due = music.timers.filter { $0.at <= music.now }.sorted { $0.at < $1.at }
        music.timers.removeAll { $0.at <= music.now }
        due.forEach { $0.work() }
    }

    /// The recorded case end to end: Music answers "false" for 3.05 s after
    /// the tap, and the star stays filled through every read-back until Music
    /// agrees. One tap, one write.
    func testTheStarStaysFilledWhileMusicCatchesUp() {
        let (media, music) = controller()
        play("Exit Music (For a Film)", on: media)
        media.refreshPlaybackModes()
        XCTAssertEqual(media.musicFavorite, false)

        media.toggleMusicFavorite()
        XCTAssertEqual(media.musicFavorite, true)
        for second in [0.4, 1, 2, 3] {
            advance(to: second, music)
            XCTAssertEqual(media.musicFavorite, true, "emptied at \(second) s")
        }
        music.favorite = true
        advance(to: 4, music)
        XCTAssertEqual(media.musicFavorite, true)
        XCTAssertNil(media.favoriteHold.tap)
        XCTAssertEqual(music.writes, [true])

        // The hold is over: the reads still scheduled ask nothing.
        let reads = music.reads
        advance(to: MusicFavoriteHold.window + 1, music)
        XCTAssertEqual(music.reads, reads)
    }

    /// Music refusing the command puts the star back at once.
    func testARefusedWritePutsTheStarBack() {
        let (media, music) = controller()
        play("Exit Music (For a Film)", on: media)
        media.refreshPlaybackModes()
        music.accepts = false
        media.toggleMusicFavorite()
        XCTAssertEqual(media.musicFavorite, false)
        XCTAssertNil(media.favoriteHold.tap)
    }

    /// Music never catching up: at the window's end the hold is over and
    /// Music's answer is the star.
    func testTheWindowsEndBelievesMusic() {
        let (media, music) = controller()
        play("Exit Music (For a Film)", on: media)
        media.refreshPlaybackModes()
        media.toggleMusicFavorite()
        advance(to: 11, music)
        XCTAssertEqual(media.musicFavorite, true)
        advance(to: MusicFavoriteHold.window, music)
        XCTAssertEqual(media.musicFavorite, false)
        XCTAssertNil(media.favoriteHold.tap)
    }

    /// An answer asked about one song and landing after the next began is
    /// not the new song's star.
    func testAnAnswerAboutTheLastSongIsDropped() {
        let (media, music) = controller()
        play("Exit Music (For a Film)", on: media)
        music.holdReplies = true
        music.favorite = true
        media.refreshPlaybackModes()
        play("Let Down", on: media)
        music.heldReplies.forEach { $0((shuffle: false, repeatMode: .off, favorite: true)) }
        XCTAssertNil(media.musicFavorite)
    }

    /// A new song ends the last one's hold: its star is its own.
    func testANewSongEndsTheHold() {
        let (media, music) = controller()
        play("Exit Music (For a Film)", on: media)
        media.refreshPlaybackModes()
        media.toggleMusicFavorite()
        play("Let Down", on: media)
        XCTAssertNil(media.favoriteHold.tap)
        media.refreshPlaybackModes()
        XCTAssertEqual(media.musicFavorite, false)
        _ = music
    }
}
