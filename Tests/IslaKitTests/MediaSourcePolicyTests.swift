import AppKit
import XCTest
@testable import IslaKit

extension MediaController {
    /// Cuts every line from the controller to a real player.
    ///
    /// Holding a song under a film asks the song's player what it is doing, and
    /// finding one asks every running player. Left at their defaults, those
    /// questions went to whatever Spotify was running on the machine running
    /// the tests — and on CI, where Spotify is not installed, the bridge
    /// answered "nothing loaded" at once, let the held song go, and failed
    /// `testAFilmOverAPausedSongKeepsTheSong` on the runner only. Each seam
    /// answers "not asked" here unless a test says otherwise, and the Spotify
    /// track-id lookup is switched off, since the fixtures name Spotify.
    func isolateFromPlayers() {
        heldPlayerState = { (_: PlayerApp, reply: @escaping (PlayerBridge.StateReply) -> Void) in reply(.unknown) }
        loadedSong = { (reply: @escaping (PlayerState?) -> Void) in reply(nil) }
        heldArtwork = { (_: PlayerState, reply: @escaping (NSImage?) -> Void) in reply(nil) }
        sendToPlayer = { _, _ in }
        pidForPlayer = { _ in nil }
        spotifyDisplayForTests = false
    }
}

/// What reaches the island when Music Only is on.
///
/// The media types used here are the ones measured on 2026-09-21: Spotify
/// reported `kMRMediaRemoteNowPlayingInfoTypeAudio`, and a YouTube video in a
/// browser reported no media type at all.
@MainActor
final class MediaSourcePolicyTests: XCTestCase {
    private let audio = MediaSourcePolicy.audioType

    /// A music app is shown whatever it labels the item — a music video in
    /// Apple Music is still music.
    func testMusicAppsAreAlwaysShown() {
        for bundle in ["com.spotify.client", "com.apple.Music", "ru.yandex.desktop.music", "com.apple.podcasts"] {
            XCTAssertTrue(MediaSourcePolicy.allows(bundleIdentifier: bundle, mediaType: nil, artist: ""), bundle)
            XCTAssertTrue(MediaSourcePolicy.allows(bundleIdentifier: bundle, mediaType: "anything", artist: ""), bundle)
        }
    }

    /// The case that asked for this: a YouTube video in a browser says nothing
    /// about what it is, so the browser owning it is what keeps it off.
    func testAVideoInABrowserIsFilteredOut() {
        for browser in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.anthropic.claudefordesktop"] {
            XCTAssertFalse(
                MediaSourcePolicy.allows(bundleIdentifier: browser, mediaType: nil, artist: "Some Channel"),
                browser
            )
        }
    }

    /// Anything the player itself calls audio is shown, from any app — which is
    /// how a music app this list has never heard of still gets through.
    func testAnythingLabelledAudioIsShown() {
        XCTAssertTrue(MediaSourcePolicy.allows(bundleIdentifier: "com.example.unknown", mediaType: audio, artist: ""))
        XCTAssertTrue(MediaSourcePolicy.allows(bundleIdentifier: nil, mediaType: audio, artist: ""))
    }

    /// Telegram plays songs and films. A song sent there carries an artist; a
    /// video does not; and a label, when Telegram gives one, decides outright.
    func testTelegramShowsSongsAndNotVideos() {
        for telegram in ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"] {
            XCTAssertTrue(
                MediaSourcePolicy.allows(bundleIdentifier: telegram, mediaType: nil, artist: "Adrianne Lenker"),
                "\(telegram): an unlabelled song with an artist"
            )
            XCTAssertFalse(
                MediaSourcePolicy.allows(bundleIdentifier: telegram, mediaType: nil, artist: "  "),
                "\(telegram): an unlabelled video, no artist"
            )
            XCTAssertTrue(
                MediaSourcePolicy.allows(bundleIdentifier: telegram, mediaType: audio, artist: ""),
                "\(telegram): labelled audio"
            )
            XCTAssertFalse(
                MediaSourcePolicy.allows(bundleIdentifier: telegram, mediaType: "kMRMediaRemoteNowPlayingInfoTypeVideo", artist: "Someone"),
                "\(telegram): labelled as something other than audio"
            )
        }
    }

    /// An app nobody named, saying nothing about what it plays, stays off.
    func testAnUnknownAppSayingNothingIsFilteredOut() {
        XCTAssertFalse(MediaSourcePolicy.allows(bundleIdentifier: "com.colliderli.iina", mediaType: nil, artist: ""))
        XCTAssertFalse(MediaSourcePolicy.allows(bundleIdentifier: nil, mediaType: nil, artist: "x"))
    }

    // MARK: - The seam

    private func snapshot(pid: pid_t, mediaType: String? = nil, artist: String = "Artist") -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = "Title"
        s.artist = artist
        s.duration = 200
        s.isPlaying = true
        s.rate = 1
        s.takenAt = Date()
        s.playerPID = pid
        s.mediaType = mediaType
        return s
    }

    /// A film is "nothing playing" to the island: the seam hands `apply` an
    /// empty snapshot, which clears the track and folds the island to the notch.
    func testAFilteredSourceReachesApplyAsNothingPlaying() {
        let controller = MediaController()
        controller.isolateFromPlayers()
        controller.musicOnly = { true }
        controller.bundleIdentifierForPID = { $0 == 1 ? "com.google.Chrome" : "com.spotify.client" }

        controller.isProcessRunning = { _ in false }
        XCTAssertEqual(controller.admission(for: snapshot(pid: 1)), .clear, "a browser video is filtered out")
        XCTAssertEqual(controller.admission(for: snapshot(pid: 2)), .accept, "Spotify is let through untouched")

        controller.receive(snapshot(pid: 2))
        XCTAssertNotNil(controller.track)
        controller.receive(snapshot(pid: 1))
        XCTAssertNil(controller.track, "with Spotify gone, a video is nothing playing")
    }

    /// Off means everything, as before.
    func testWithMusicOnlyOffEverythingIsShown() {
        let controller = MediaController()
        controller.isolateFromPlayers()
        controller.musicOnly = { false }
        controller.bundleIdentifierForPID = { _ in "com.google.Chrome" }
        XCTAssertEqual(controller.admission(for: snapshot(pid: 1)), .accept)
    }

    /// On by default: the island is a music surface.
    func testMusicOnlyIsOnByDefault() {
        UserDefaults.standard.removeObject(forKey: NotchViewModel.musicOnlyKey)
        XCTAssertTrue(NotchViewModel.musicOnlyEnabled)
    }

    /// The helper's new field survives the decoder.
    func testTheDecoderCarriesTheMediaType() {
        let line = #"{"playing":true,"title":"T","artist":"A","album":"","duration":10,"elapsed":1,"rate":1,"timestamp":1760000000.0,"pid":42,"mediaType":"kMRMediaRemoteNowPlayingInfoTypeAudio"}"#
        guard case .some(.snapshot(let decoded)) = NowPlayingPayloadDecoder.decode(Data(line.utf8)) else {
            return XCTFail("a well-formed line decodes to a snapshot")
        }
        XCTAssertEqual(decoded.mediaType, MediaSourcePolicy.audioType)
    }
}

/// The session the owner hit on 2026-09-21: a song paused in Spotify, then a
/// film started in a browser tab. The island must keep the paused song.
@MainActor
final class HeldSongTests: XCTestCase {
    private func snapshot(pid: pid_t, title: String, playing: Bool) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "Artist"
        s.duration = 200
        s.elapsed = 40
        s.isPlaying = playing
        s.rate = playing ? 1 : 0
        s.takenAt = Date()
        s.playerPID = pid
        return s
    }

    private func controller(running: Set<pid_t>) -> MediaController {
        let controller = MediaController()
        controller.isolateFromPlayers()
        controller.musicOnly = { true }
        controller.bundleIdentifierForPID = { $0 == 1 ? "com.spotify.client" : "com.google.Chrome" }
        controller.isProcessRunning = { running.contains($0) }
        return controller
    }

    /// Pause Spotify, start a film: the film owns Now Playing now, and Music
    /// Only rightly keeps it off the island — but it used to clear the paused
    /// song too, so opening the panel said "Nothing is playing" while a song
    /// sat paused in Spotify.
    func testAFilmOverAPausedSongKeepsTheSong() {
        let controller = controller(running: [1, 2])
        controller.receive(snapshot(pid: 1, title: "Song", playing: true))
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: true))

        XCTAssertEqual(controller.track?.title, "Song", "the paused song is still what the island is about")
        XCTAssertFalse(controller.isPlaying, "and it is still paused")
    }

    /// But a song whose player has quit is not held: there is nothing to go
    /// back to, and a stale title would be a lie.
    func testASongWhosePlayerQuitIsNotHeld() {
        let controller = controller(running: [2])
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: true))
        XCTAssertNil(controller.track)
    }

    /// With nothing held, a film is simply nothing playing.
    func testAFilmWithNoSongHeldIsNothingPlaying() {
        let controller = controller(running: [2])
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: true))
        XCTAssertNil(controller.track)
    }

    /// Music Only switched on while a film is what the island shows: the film
    /// is not a song to hold. It used to be kept, because holding asked only
    /// whether the displayed player was still running — and the film's own
    /// browser was.
    func testTurningMusicOnlyOnDoesNotHoldTheFilmItself() {
        let controller = controller(running: [1, 2])
        var musicOnly = false
        controller.musicOnly = { musicOnly }
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: true))
        XCTAssertEqual(controller.track?.title, "Some Film", "the fixture: Music Only off shows the film")

        musicOnly = true
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: true))
        XCTAssertNil(controller.track)
        XCTAssertFalse(controller.isHolding)
    }

    /// A report with nothing in it — the helper caught between two sessions,
    /// or a film's tab closed — is no reason to drop a song still loaded in a
    /// running player. It cleared the island to "Nothing is playing", and the
    /// song came back on the next report as a new track, lyrics and all.
    func testAnEmptyReportDoesNotDropASongWhosePlayerRuns() {
        let controller = controller(running: [1, 2])
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(NowPlayingFeed.Snapshot())
        XCTAssertEqual(controller.track?.title, "Song")
    }

    /// Only a song whose player can be asked is kept over an empty report. A
    /// Tidal song held there could never be checked again: its pill kept
    /// animating after the music stopped, until Tidal quit.
    func testAnEmptyReportDoesNotHoldASongNothingCanCheck() {
        let controller = MediaController()
        controller.isolateFromPlayers()
        controller.musicOnly = { true }
        controller.bundleIdentifierForPID = { _ in "com.tidal.desktop" }
        controller.isProcessRunning = { _ in true }
        controller.receive(snapshot(pid: 7, title: "Song", playing: true))
        XCTAssertEqual(controller.track?.title, "Song", "the fixture: Tidal is a music source")
        controller.receive(NowPlayingFeed.Snapshot())
        XCTAssertNil(controller.track)
        XCTAssertFalse(controller.isHolding)
    }

    /// With the player gone, an empty report is nothing playing, as before.
    func testAnEmptyReportAfterThePlayerQuitClears() {
        let controller = controller(running: [2])
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(NowPlayingFeed.Snapshot())
        XCTAssertNil(controller.track)
    }

    /// A film starting under Music Only is announced, so a paused song's pill
    /// can fold at once instead of lingering over the film; a film that is
    /// paused, or a music source, is not.
    func testAFilmStartingIsAnnounced() {
        let controller = controller(running: [1, 2])
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        XCTAssertFalse(controller.otherMediaIsPlaying)
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: false))
        XCTAssertFalse(controller.otherMediaIsPlaying, "a paused film is not news")
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: true))
        XCTAssertTrue(controller.otherMediaIsPlaying)
        controller.receive(snapshot(pid: 1, title: "Song", playing: true))
        XCTAssertFalse(controller.otherMediaIsPlaying, "the song taking Now Playing back ends it")
    }

    /// And the song coming back — resumed, or a new one — takes over at once.
    func testTheSongResumingTakesOverAgain() {
        let controller = controller(running: [1, 2])
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(snapshot(pid: 2, title: "Some Film", playing: true))
        controller.receive(snapshot(pid: 1, title: "Song", playing: true))
        XCTAssertEqual(controller.track?.title, "Song")
        XCTAssertTrue(controller.isPlaying)
    }
}

/// A held song learns its player's real state, because MediaRemote no longer
/// reports it.
///
/// Filmed by the owner on 2026-09-21: Spotify paused under a film in Firefox,
/// panel open, and the paused song's clock ran forward to 1:23 and snapped back
/// to 1:21 every two seconds, the lyric line and the play button flipping with
/// it. While the film owned Now Playing the helper described only the film, so
/// the pause was never seen: the song stayed "playing", the ticker ran it
/// forward, and the precision poll — which asks Spotify directly — kept
/// dragging it back to the real, paused position.
@MainActor
final class HeldSongTruthTests: XCTestCase {
    private func snapshot(pid: pid_t, title: String, playing: Bool, elapsed: TimeInterval = 40) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "Artist"
        s.album = "Album"
        s.duration = 248
        s.elapsed = elapsed
        s.isPlaying = playing
        s.rate = playing ? 1 : 0
        s.takenAt = Date()
        s.playerPID = pid
        return s
    }

    private func controller(held: PlayerBridge.StateReply) -> (MediaController, () -> Int) {
        let controller = MediaController()
        controller.isolateFromPlayers()
        controller.musicOnly = { true }
        controller.bundleIdentifierForPID = { $0 == 1 ? "com.spotify.client" : "org.mozilla.firefox" }
        controller.isProcessRunning = { _ in true }
        var asked = 0
        controller.heldPlayerState = { (_: PlayerApp, reply: @escaping (PlayerBridge.StateReply) -> Void) in
            asked += 1
            reply(held)
        }
        return (controller, { asked })
    }

    /// The owner's case: the song was playing when the film took over, then
    /// was paused where MediaRemote could not see it. Asking Spotify settles it.
    func testTakingOverAsksTheHeldPlayerForItsRealState() {
        let paused = PlayerState(
            app: .spotify, isPlaying: false, title: "Child Psychology", artist: "Artist",
            album: "Album", duration: 248, position: 80.8
        )
        let (controller, asked) = controller(held: .loaded(paused))
        controller.receive(snapshot(pid: 1, title: "Child Psychology", playing: true))
        XCTAssertTrue(controller.isPlaying, "the fixture: it was playing")

        controller.receive(snapshot(pid: 2, title: "Watch The Count of Monte Cristo", playing: true))

        XCTAssertEqual(asked(), 1, "the takeover asks the held player once")
        XCTAssertFalse(controller.isPlaying, "and learns it is paused, so the clock stops")
        XCTAssertEqual(controller.position, 80.8, accuracy: 0.05, "at the position the player reports")
        XCTAssertEqual(controller.track?.title, "Child Psychology")
    }

    /// Once asked, the film's heartbeat every two seconds does not ask again;
    /// only the player's own change announcement does.
    func testTheFilmsHeartbeatDoesNotKeepAsking() {
        let paused = PlayerState(
            app: .spotify, isPlaying: false, title: "Song", artist: "Artist",
            album: "Album", duration: 248, position: 10
        )
        let (controller, asked) = controller(held: .loaded(paused))
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        for _ in 0..<5 {
            controller.receive(snapshot(pid: 2, title: "Film", playing: true))
        }
        XCTAssertEqual(asked(), 1)

        controller.heldPlayerChanged(.spotify)
        XCTAssertEqual(asked(), 2, "the held player announcing a change is worth asking about")

        controller.heldPlayerChanged(.music)
        XCTAssertEqual(asked(), 2, "another player's announcement is not about the held song")
    }

    /// The held player answering that it has nothing loaded — its queue
    /// emptied, or it stopped — means there is no song to hold.
    func testAHeldPlayerWithNothingLoadedIsLetGo() {
        let (controller, _) = controller(held: .empty)
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(snapshot(pid: 2, title: "Film", playing: true))
        XCTAssertNil(controller.track)
    }

    /// A player that cannot be asked — Automation consent withheld — has said
    /// nothing about the song. Letting it go on that would put "Nothing is
    /// playing" over a song sitting paused, the very report this work fixes.
    func testAHeldPlayerThatCannotBeAskedKeepsTheSong() {
        let (controller, asked) = controller(held: .unknown)
        controller.receive(snapshot(pid: 1, title: "Song", playing: false, elapsed: 61))
        controller.receive(snapshot(pid: 2, title: "Film", playing: true))
        XCTAssertEqual(asked(), 1)
        XCTAssertEqual(controller.track?.title, "Song")
        XCTAssertTrue(controller.isHolding)
        XCTAssertEqual(controller.position, 61, accuracy: 0.05, "as it was last known")
    }

    /// The helper reaches the song's player only if it has seen that player
    /// own Now Playing; otherwise a tap lands on the film. A held song in a
    /// scriptable player takes its commands directly.
    func testAHeldSongsTransportGoesToItsOwnPlayer() {
        let paused = PlayerState(
            app: .spotify, isPlaying: false, title: "Song", artist: "Artist",
            album: "Album", duration: 248, position: 10
        )
        let (controller, _) = controller(held: .loaded(paused))
        var sent: [String] = []
        controller.sendToPlayer = { action, app in sent.append("\(app.rawValue) \(action)") }
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(snapshot(pid: 2, title: "Film", playing: true))
        XCTAssertTrue(controller.isHolding)

        controller.togglePlayPause()
        controller.next()
        controller.previous()
        controller.seek(to: 30)

        XCTAssertEqual(sent, [
            "spotify play", "spotify next", "spotify previous", "spotify seek(seconds: 30.0)",
        ])
    }

    /// A report `apply` refuses — a paused stranger, held off for a while —
    /// must not end the hold on the song still on screen. It used to: Music
    /// taking Now Playing with a paused song dropped the hold, and the next
    /// play tap for the Spotify song went through the helper, which handed it
    /// to Music.
    func testARefusedReportKeepsTapsOnTheSongOnScreen() {
        let paused = PlayerState(
            app: .spotify, isPlaying: false, title: "Song", artist: "Artist",
            album: "Album", duration: 248, position: 10
        )
        let (controller, _) = controller(held: .loaded(paused))
        controller.bundleIdentifierForPID = {
            switch $0 {
            case 1: return "com.spotify.client"
            case 3: return "com.apple.Music"
            default: return "org.mozilla.firefox"
            }
        }
        var sent: [String] = []
        controller.sendToPlayer = { action, app in sent.append("\(app.rawValue) \(action)") }
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(snapshot(pid: 2, title: "Film", playing: true))
        controller.receive(snapshot(pid: 3, title: "Other Song", playing: false))

        XCTAssertEqual(controller.track?.title, "Song", "the fixture: the stranger is held off")
        XCTAssertTrue(controller.isHolding)
        controller.togglePlayPause()
        XCTAssertEqual(sent, ["spotify play"])
    }

    /// With no film in the way, the helper carries the command as before.
    func testASongThatOwnsNowPlayingIsNotScripted() {
        let (controller, _) = controller(held: .unknown)
        var sent: [String] = []
        controller.sendToPlayer = { action, app in sent.append("\(app.rawValue) \(action)") }
        controller.receive(snapshot(pid: 1, title: "Song", playing: true))
        controller.togglePlayPause()
        controller.next()
        XCTAssertFalse(controller.isHolding)
        XCTAssertEqual(sent, [])
    }

    /// Spotify and Music announce every play, pause and track change the
    /// moment it happens, while the helper only notices on its two-second
    /// poll. An announcement asks the helper for a fresh report at once.
    func testAPlayerAnnouncementAsksForAFreshReport() {
        let (controller, _) = controller(held: .unknown)
        controller.receive(snapshot(pid: 1, title: "Song", playing: true))
        let before = controller.freshReportsAskedForTests
        controller.playerAnnouncedChange(.spotify)
        XCTAssertGreaterThan(controller.freshReportsAskedForTests, before)
    }

    /// Accepting a music source again ends the hold, so the next takeover asks
    /// afresh rather than trusting an answer from before.
    func testEndingTheHoldMeansTheNextTakeoverAsksAgain() {
        let paused = PlayerState(
            app: .spotify, isPlaying: false, title: "Song", artist: "Artist",
            album: "Album", duration: 248, position: 10
        )
        let (controller, asked) = controller(held: .loaded(paused))
        controller.receive(snapshot(pid: 1, title: "Song", playing: false))
        controller.receive(snapshot(pid: 2, title: "Film", playing: true))
        controller.receive(snapshot(pid: 1, title: "Song", playing: true))
        controller.receive(snapshot(pid: 2, title: "Film", playing: true))
        XCTAssertEqual(asked(), 2)
    }
}

/// Isla never having seen the song is not the same as there being none.
@MainActor
final class LoadedSongSearchTests: XCTestCase {
    private func film() -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = "Watch The Count of Monte Cristo"
        s.duration = 9000
        s.elapsed = 1626
        s.isPlaying = true
        s.rate = 1
        s.takenAt = Date()
        s.playerPID = 2
        return s
    }

    private func controller(found: PlayerState?) -> (MediaController, () -> Int) {
        let controller = MediaController()
        controller.isolateFromPlayers()
        controller.musicOnly = { true }
        controller.bundleIdentifierForPID = { $0 == 1 ? "com.spotify.client" : "org.mozilla.firefox" }
        controller.isProcessRunning = { _ in true }
        controller.pidForPlayer = { $0 == .spotify ? 1 : nil }
        controller.heldArtwork = { (_: PlayerState, reply: @escaping (NSImage?) -> Void) in reply(nil) }
        var searches = 0
        controller.loadedSong = { (reply: @escaping (PlayerState?) -> Void) in
            searches += 1
            reply(found)
        }
        controller.heldPlayerState = { (_: PlayerApp, reply: @escaping (PlayerBridge.StateReply) -> Void) in
            reply(found.map { .loaded($0) } ?? .empty)
        }
        return (controller, { searches })
    }

    /// The owner's first report, after a relaunch: a song paused in Spotify, a
    /// film in a tab, and the island said "Nothing is playing".
    func testAFilmWithASongPausedInSpotifyShowsTheSong() {
        let paused = PlayerState(
            app: .spotify, isPlaying: false, title: "Child Psychology", artist: "Black Box Recorder",
            album: "England Made Me", duration: 248, position: 80.8
        )
        let (controller, _) = controller(found: paused)
        controller.receive(film())

        XCTAssertEqual(controller.track?.title, "Child Psychology")
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.position, 80.8, accuracy: 0.05)
        XCTAssertTrue(controller.isHolding, "and it is now held, with its player as the source of truth")
    }

    /// The case that made direct commands necessary: the helper has never seen
    /// Spotify own Now Playing in this run, so it has no way to reach it, and
    /// play would have gone to the film.
    func testPlayOnAFoundSongGoesToItsPlayer() {
        let paused = PlayerState(
            app: .spotify, isPlaying: false, title: "Child Psychology", artist: "Black Box Recorder",
            album: "England Made Me", duration: 248, position: 80.8
        )
        let (controller, _) = controller(found: paused)
        var sent: [String] = []
        controller.sendToPlayer = { action, app in sent.append("\(app.rawValue) \(action)") }
        controller.receive(film())
        controller.togglePlayPause()
        XCTAssertEqual(sent, ["spotify play"])
    }

    /// Once per film: its heartbeat does not send the players a question every
    /// two seconds when none of them has anything loaded.
    func testTheSearchRunsOncePerFilm() {
        let (controller, searches) = controller(found: nil)
        for _ in 0..<5 { controller.receive(film()) }
        XCTAssertNil(controller.track)
        XCTAssertEqual(searches(), 1)

        // A player changing under the film is worth one more look.
        controller.heldPlayerChanged(.spotify)
        XCTAssertEqual(searches(), 2)
    }
}
