import AppKit
import XCTest
@testable import IslaKit

/// Music's and Spotify's own announcements keep the fallback truthful when a
/// player cannot or may not be asked (J-027).
///
/// With Spotify's Automation refused, a playing Spotify was shown as the
/// paused Music track beside it, and play/pause drove Music: the refusal came
/// back as -1743, the bridge turned that into "no state", and the only answer
/// left was Music's. And with no player that may be asked yet, the fallback
/// showed nothing at all until the panel opened. Both players broadcast the
/// song and whether it plays in a distributed notification that needs no
/// permission, so the island listens to that where it may not ask.
@MainActor
final class PlayerAnnouncementTests: XCTestCase {
    // MARK: - Reading an announcement

    func testSpotifysAnnouncementReadsAsAState() throws {
        let state = try XCTUnwrap(PlayerAnnouncement.state(from: [
            "Name": "A", "Artist": "B", "Album": "C",
            "Duration": 200000, "Player State": "Playing", "Playback Position": 12.5,
        ], app: .spotify))
        XCTAssertEqual(state.app, .spotify)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.title, "A")
        XCTAssertEqual(state.artist, "B")
        XCTAssertEqual(state.album, "C")
        XCTAssertEqual(state.duration, 200, accuracy: 0.001, "Spotify's duration is in milliseconds")
        XCTAssertEqual(state.position, 12.5, accuracy: 0.001, "and its position in seconds")
        XCTAssertTrue(state.positionKnown)
    }

    func testMusicsAnnouncementReadsAsAState() throws {
        let state = try XCTUnwrap(PlayerAnnouncement.state(from: [
            "Name": "A", "Artist": "B", "Album": "C",
            "Total Time": 215000, "Player State": "Paused",
        ], app: .music))
        XCTAssertEqual(state.duration, 215, accuracy: 0.001)
        XCTAssertFalse(state.isPlaying)
        XCTAssertFalse(state.positionKnown, "Music announces no position")
    }

    /// The key names are observed behaviour, not API: an announcement missing
    /// them says nothing, and nothing is what the fallback had before.
    func testAnAnnouncementWithoutASongSaysNothing() {
        XCTAssertNil(PlayerAnnouncement.state(from: ["Player State": "Stopped"], app: .music))
        XCTAssertNil(PlayerAnnouncement.state(from: ["Name": "A"], app: .spotify))
        XCTAssertNil(PlayerAnnouncement.state(from: [:], app: .spotify))
    }

    // MARK: - Which player

    private func song(_ title: String, playing: Bool, app: PlayerApp) -> PlayerState {
        PlayerState(app: app, isPlaying: playing, title: title, artist: "B", album: "C", duration: 200, position: 10)
    }

    /// The owner's J-027 case: Spotify plays with its Automation refused, and
    /// Music sits paused. The refusal used to drop Spotify from the answers.
    func testARefusedSpotifyThatAnnouncedPlayingBeatsAPausedMusic() {
        let chosen = PlayerBridge.choose(
            replies: [.music: .loaded(song("M", playing: false, app: .music)), .spotify: .unknown],
            announced: [.spotify: song("S", playing: true, app: .spotify)],
            prefer: nil
        )
        XCTAssertEqual(chosen?.app, .spotify)
        XCTAssertEqual(chosen?.title, "S")
    }

    /// A player that could not be asked and has said nothing is unknown, not
    /// a song: it shows nothing rather than a guess.
    func testAnUnknownPlayerWithNoAnnouncementDoesNotWin() {
        XCTAssertNil(PlayerBridge.choose(replies: [.spotify: .unknown], announced: [:], prefer: .spotify))
    }

    /// An answer beats an announcement for the same player: the player that
    /// was asked has said what it is doing now.
    func testAnAnsweredPlayerIsNotOverruledByItsOwnAnnouncement() {
        let chosen = PlayerBridge.choose(
            replies: [.spotify: .loaded(song("Now", playing: false, app: .spotify))],
            announced: [.spotify: song("Before", playing: true, app: .spotify)],
            prefer: nil
        )
        XCTAssertEqual(chosen?.title, "Now")
        XCTAssertNil(
            PlayerBridge.choose(
                replies: [.spotify: .empty],
                announced: [.spotify: song("Before", playing: true, app: .spotify)],
                prefer: nil
            ),
            "a player that answered 'nothing loaded' has nothing loaded"
        )
    }

    /// With nothing playing, the shown player still keeps the island, as it
    /// does among answers alone.
    func testWithNothingPlayingTheShownPlayerKeepsTheIslandOverAnAnnouncement() {
        let replies: [PlayerApp: PlayerBridge.StateReply] = [
            .music: .loaded(song("M", playing: false, app: .music)), .spotify: .unknown,
        ]
        let announced = [PlayerApp.spotify: song("S", playing: false, app: .spotify)]
        XCTAssertEqual(PlayerBridge.choose(replies: replies, announced: announced, prefer: .spotify)?.title, "S")
        XCTAssertEqual(PlayerBridge.choose(replies: replies, announced: announced, prefer: nil)?.title, "M")
    }

    // MARK: - The fallback

    private final class Counter {
        var loaded = 0
    }

    /// A fallback cut off from every real player, with no player that may be
    /// asked: Spotify is pid 77, Apple Music pid 88.
    private func fallback() -> (MediaController, Counter) {
        let media = MediaController()
        media.isolateFromPlayers()
        media.automationConsent = { _ in .notAsked }
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
        let counter = Counter()
        media.loadedSong = { (_: @escaping (PlayerState?) -> Void) in counter.loaded += 1 }
        media.switchToScriptingFallback(.readerRefused)
        return (media, counter)
    }

    /// J-003's display half: the fallback asked nothing before the panel
    /// opened, and so showed nothing either, over a song that was playing.
    func testTheFallbackShowsAnAnnouncedSongWithoutAsking() {
        let (media, counter) = fallback()
        XCTAssertNil(media.track)

        media.fallbackHeard(.spotify, [
            "Name": "A", "Artist": "B", "Album": "C",
            "Duration": 200000, "Player State": "Playing", "Playback Position": 12.5,
        ])

        XCTAssertEqual(media.track?.title, "A")
        XCTAssertEqual(media.track?.key, "77|A|B|C", "keyed like every other route")
        XCTAssertTrue(media.isPlaying)
        XCTAssertEqual(media.position, 12.5, accuracy: 0.6)
        XCTAssertEqual(media.lyricPlayerID, "spotify")
        XCTAssertEqual(counter.loaded, 0, "no Apple Event: the panel has not opened")
        media.stop()
    }

    /// Music says nothing of where it is. A pause of the song on screen keeps
    /// the song's place; a new song starts at its beginning.
    func testAMusicAnnouncementKeepsTheShownSongsPlace() {
        let (media, _) = fallback()
        var clock: TimeInterval = 1000
        media.monotonicNow = { clock }
        var info: [AnyHashable: Any] = [
            "Name": "A", "Artist": "B", "Album": "C", "Total Time": 215000, "Player State": "Playing",
        ]
        media.fallbackHeard(.music, info)
        XCTAssertEqual(media.track?.title, "A")
        XCTAssertEqual(media.position, 0, accuracy: 0.01, "a song first heard starts at 0")

        clock += 30
        info["Player State"] = "Paused"
        media.fallbackHeard(.music, info)
        XCTAssertFalse(media.isPlaying)
        XCTAssertEqual(media.position, 30, accuracy: 0.6, "paused where the clock had carried it")

        info["Name"] = "Next"
        info["Player State"] = "Playing"
        media.fallbackHeard(.music, info)
        XCTAssertEqual(media.track?.title, "Next")
        XCTAssertEqual(media.position, 0, accuracy: 0.6, "a new song starts at its own beginning")
        media.stop()
    }

    /// An announcement is kept for when another player's announcement brings
    /// the next refresh, and by then a playing song has moved on.
    func testAKeptAnnouncementIsAgedToNow() {
        let (media, _) = fallback()
        var clock: TimeInterval = 1000
        media.monotonicNow = { clock }
        media.fallbackHeard(.spotify, [
            "Name": "A", "Artist": "B", "Album": "C",
            "Duration": 200000, "Player State": "Playing", "Playback Position": 12.5,
        ])
        clock += 20
        media.fallbackHeard(.music, [
            "Name": "M", "Artist": "B", "Album": "C", "Total Time": 215000, "Player State": "Paused",
        ])
        XCTAssertEqual(media.track?.title, "A", "the playing Spotify keeps the island")
        XCTAssertEqual(media.position, 32.5, accuracy: 0.6)
        media.stop()
    }

    /// A player that quit takes its announcement with it.
    func testAQuitPlayersAnnouncementIsForgotten() {
        let (media, _) = fallback()
        media.fallbackHeard(.spotify, [
            "Name": "A", "Artist": "B", "Album": "C",
            "Duration": 200000, "Player State": "Playing", "Playback Position": 12.5,
        ])
        XCTAssertEqual(media.track?.title, "A")

        media.pidForPlayer = { $0 == .spotify ? nil : 88 }
        media.isProcessRunning = { $0 != 77 }
        media.fallbackHeard(.music, [
            "Name": "M", "Artist": "B", "Album": "C", "Total Time": 215000, "Player State": "Paused",
        ])
        XCTAssertEqual(media.track?.title, "M")
        XCTAssertEqual(media.lyricPlayerID, "music")
        media.stop()
    }
}
