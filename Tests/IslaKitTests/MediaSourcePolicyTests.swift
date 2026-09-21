import XCTest
@testable import IslaKit

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
