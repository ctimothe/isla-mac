import AppKit
import XCTest
@testable import IslaKit

/// Isla sends no Apple Event while nothing is open, unless macOS already
/// allows it.
///
/// Isla launches at login with Spotify playing and the panel closed, and the
/// "Isla wants to control Spotify" dialog used to appear unprompted: the
/// track-id lookup ran on every Spotify track, the fallback read every
/// player's state at launch, and the search under a film asked the players —
/// all with nothing on screen to say why. Every ad-hoc update resets the grant
/// (J-002), so the unprompted dialog came back after each one. The first
/// prompt now arrives only when the panel opens, which is the one moment the
/// question is in context, and never over the lock screen, where it cannot be
/// answered.
@MainActor
final class AutomationConsentTests: XCTestCase {
    /// Counts questions a test pretended to ask a player.
    private final class Counter {
        var lookups = 0
        var positions = 0
        var heldStates = 0
        var loaded = 0
        var catalogue = 0
        /// What the next Spotify id lookup answers; nil leaves it unanswered.
        var answer: PlayerBridge.SpotifyTrackLookup?
    }

    private func snapshot(
        _ title: String, pid: pid_t = 1, playing: Bool = true, elapsed: TimeInterval = 10
    ) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "B"
        s.album = "C"
        s.duration = 200
        s.elapsed = elapsed
        s.isPlaying = playing
        s.rate = playing ? 1 : 0
        s.takenAt = Date()
        s.playerPID = pid
        return s
    }

    /// A controller cut off from every real player. Pid 1 is Spotify and
    /// pid 2 a browser playing a film; every question a player could be asked
    /// is counted instead of sent.
    private func controller(
        consent: AutomationConsent, connected: Bool = true
    ) -> (MediaController, Counter) {
        let media = MediaController()
        media.isolateFromPlayers()
        media.spotifyDisplayForTests = nil
        media.musicOnly = { true }
        media.lyricsShown = { true }
        media.bundleIdentifierForPID = { $0 == 1 ? PlayerApp.spotify.bundleID : "org.mozilla.firefox" }
        media.isProcessRunning = { _ in true }
        media.pidForPlayer = { $0 == .spotify ? 1 : nil }
        media.automationConsent = { _ in consent }
        media.spotifyAccountConnected = { connected }
        let counter = Counter()
        media.spotifyTrackIDLookup = { reply in
            counter.lookups += 1
            if let answer = counter.answer { reply(answer) }
        }
        media.precisionPositionFetcher = { _ in counter.positions += 1 }
        media.heldPlayerState = { (_: PlayerApp, _: @escaping (PlayerBridge.StateReply) -> Void) in
            counter.heldStates += 1
        }
        media.loadedSong = { (_: @escaping (PlayerState?) -> Void) in counter.loaded += 1 }
        media.spotifyMetadataProvider = { _ in
            counter.catalogue += 1
            return nil
        }
        return (media, counter)
    }

    /// The owner's case: Spotify playing at login, the panel closed, the grant
    /// reset by an update. Nothing may ask Spotify until the panel opens.
    func testASpotifyTrackOnAClosedPanelAsksSpotifyNothing() {
        let (media, counter) = controller(consent: .notAsked)
        media.apply(snapshot("A"))
        XCTAssertEqual(counter.lookups, 0, "a closed panel raises no Automation prompt")
        XCTAssertEqual(counter.positions, 0)

        media.setActive(true)
        XCTAssertEqual(counter.lookups, 1, "the panel opening on Spotify is the moment to ask")
    }

    /// The heart is the id's only reader, and it is drawn only for a
    /// connected account. With none, the lookup buys nothing.
    func testNoAccountMeansNoTrackIDLookup() {
        let (media, counter) = controller(consent: .allowed, connected: false)
        media.apply(snapshot("A"))
        media.setActive(true)
        XCTAssertEqual(counter.lookups, 0)
    }

    /// A Mac that already allows Isla loses nothing: the heart's id is looked
    /// up with everything closed, exactly as before.
    func testAnAllowedConsentLooksUpWithEverythingClosed() {
        let (media, counter) = controller(consent: .allowed)
        media.apply(snapshot("A"))
        XCTAssertEqual(counter.lookups, 1)
    }

    /// The lock card activates the clock too, and a prompt raised there sits
    /// under the shield where nobody can answer it.
    func testTheLockCardNeverRaisesTheFirstPrompt() {
        let (media, counter) = controller(consent: .notAsked)
        media.receive(snapshot("A"))
        media.setActive(true, surface: .lockCard)
        // A film takes Now Playing over the song, which would ask Spotify for
        // the held song's state.
        media.receive(snapshot("Film", pid: 2))
        media.heldPlayerChanged(.spotify)
        // And Spotify's own announcement, which asks for a fresh position.
        media.receiveSpotifyBroadcast(["Name": "A", "Playback Position": 10.0])

        XCTAssertEqual(counter.positions, 0, "no position poll over the shield")
        XCTAssertEqual(counter.heldStates, 0, "no held-player question over the shield")
        XCTAssertEqual(counter.lookups, 0, "no id lookup over the shield")
        XCTAssertFalse(media.precisionSync)
    }

    /// A film taking over a song with the panel shut skips the question about
    /// the held song; the panel opening puts it, so the song does not open
    /// still claiming to play after it was paused under the film.
    func testAHeldSongIsAskedAboutWhenThePanelOpens() {
        let (media, counter) = controller(consent: .notAsked)
        media.receive(snapshot("A"))
        media.receive(snapshot("Film", pid: 2))
        XCTAssertTrue(media.isHolding)
        XCTAssertEqual(counter.heldStates, 0)

        media.setActive(true)
        XCTAssertEqual(counter.heldStates, 1)
    }

    /// The read-only check at launch finding a grant is what gives a Mac that
    /// already allows Isla its heart without opening anything.
    func testAGrantFoundLaterAsksWhatWasHeldBack() {
        var consent = AutomationConsent.unknown
        let (media, counter) = controller(consent: .unknown)
        media.automationConsent = { _ in consent }
        media.apply(snapshot("A"))
        XCTAssertEqual(counter.lookups, 0)

        consent = .allowed
        media.automationConsentChanged()
        XCTAssertEqual(counter.lookups, 1)
    }

    /// J-003: a DMG user whose helper Gatekeeper refuses falls back at launch.
    /// The fallback used to read every running player there and then, with no
    /// panel to explain the prompt.
    func testTheFallbackAtLaunchSendsNoAppleEvent() {
        let (media, counter) = controller(consent: .notAsked)
        media.switchToScriptingFallback(.readerRefused)
        XCTAssertEqual(counter.loaded, 0)

        media.setActive(true)
        XCTAssertEqual(counter.loaded, 1, "opening the panel is where the fallback first asks")
    }

    /// Spotify's own announcement names the track, so the heart can get its
    /// id without a single Apple Event.
    func testASpotifyAnnouncementSuppliesTheTrackID() {
        let (media, counter) = controller(consent: .notAsked)
        media.apply(snapshot("A"))
        media.receiveSpotifyBroadcast([
            "Name": "A", "Track ID": "spotify:track:XYZ", "Playback Position": 10.0,
        ])
        XCTAssertEqual(media.spotifyTrackID, "XYZ")
        XCTAssertEqual(counter.lookups, 0)
    }

    /// On a skip the announcement arrives before any report names the new
    /// song, so it is remembered and taken when the report catches up.
    func testAnAnnouncementAheadOfTheReportStillSuppliesTheID() {
        let (media, counter) = controller(consent: .allowed)
        counter.answer = nil
        media.apply(snapshot("A"))
        let askedForA = counter.lookups
        media.receiveSpotifyBroadcast([
            "Name": "Next", "Track ID": "spotify:track:NEXT", "Playback Position": 0.2,
        ])
        XCTAssertNil(media.spotifyTrackID, "not pinned onto the song still on screen")

        media.apply(snapshot("Next", elapsed: 0.3))
        XCTAssertEqual(media.spotifyTrackID, "NEXT")
        XCTAssertEqual(counter.lookups, askedForA, "the announcement made the lookup unnecessary")
    }

    /// An announcement about another song never lends it its id.
    func testAnAnnouncementForAnotherSongSuppliesNoID() {
        let (media, _) = controller(consent: .notAsked)
        media.apply(snapshot("A"))
        media.receiveSpotifyBroadcast([
            "Name": "Other", "Track ID": "spotify:track:OTHER", "Playback Position": 10.0,
        ])
        XCTAssertNil(media.spotifyTrackID)
    }

    /// G-005: a catalogue request went to api.spotify.com for every track,
    /// and its answer had no reader.
    func testNoCatalogueLookupFollowsATrackID() async throws {
        let (media, counter) = controller(consent: .allowed)
        counter.answer = .track(id: "XYZ", name: "A", artist: "B")
        media.apply(snapshot("A"))
        XCTAssertEqual(media.spotifyTrackID, "XYZ")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counter.catalogue, 0)
    }

    /// K-016: MediaRemote trails Spotify by about a second, so right after a
    /// skip the script can name the next song while the island still shows
    /// the last one. That id must not attach to the song on screen, or the
    /// lock-card heart likes the wrong track.
    func testATrackIDForAnotherSongIsRefused() {
        let (media, counter) = controller(consent: .allowed)
        counter.answer = .track(id: "NEW", name: "Next Song", artist: "B")
        media.apply(snapshot("A"))
        XCTAssertNil(media.spotifyTrackID)

        counter.answer = .track(id: "OURS", name: "a", artist: "b")
        media.setActive(true)
        XCTAssertEqual(media.spotifyTrackID, "OURS", "a match is case-insensitive")
    }

    /// K-014: an episode, an ad or a local file has no catalogue track id.
    /// Read as "no answer", it was asked again at 1, 2, 4 and 8 seconds.
    func testAnEpisodeIsAskedAboutOnce() async throws {
        let (media, counter) = controller(consent: .allowed)
        counter.answer = .notATrack
        media.apply(snapshot("Episode 12"))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(counter.lookups, 1)
    }

    /// K-014: with Automation refused, the once-a-second position poll kept
    /// sending Apple Events and logging -1743 every second.
    func testARefusedConsentStopsThePositionPoll() {
        let (media, counter) = controller(consent: .denied)
        media.apply(snapshot("A"))
        media.setActive(true)
        XCTAssertFalse(media.precisionSync)
        XCTAssertEqual(counter.positions, 0)
        XCTAssertEqual(counter.lookups, 0)
    }

    /// Every script outcome teaches the consent: an answer of any kind means
    /// macOS let the event through.
    func testAScriptOutcomeTeachesTheConsent() {
        XCTAssertEqual(AutomationAccess.consent(for: OSStatus(noErr)), .allowed)
        XCTAssertEqual(AutomationAccess.consent(for: -1743), .denied)
        // -1744 is "would need to ask". Read as a refusal, the first panel
        // open would never raise the prompt at all.
        XCTAssertEqual(AutomationAccess.consent(for: -1744), .notAsked)
        XCTAssertEqual(AutomationAccess.consent(for: -600), .unknown)
        // No current track: the player answered, so the event got through.
        XCTAssertEqual(AutomationAccess.consent(for: -1728), .allowed)
    }

    /// What is learnt sticks until macOS says otherwise, and an outcome that
    /// says nothing about consent changes nothing.
    func testLearningKeepsTheLastWordThatMeantSomething() {
        let access = AutomationAccess()
        XCTAssertEqual(access.status(.spotify), .unknown)
        access.learn(.spotify, outcome: -1743)
        XCTAssertEqual(access.status(.spotify), .denied)
        access.learn(.spotify, outcome: -600)
        XCTAssertEqual(access.status(.spotify), .denied, "a player that quit says nothing about consent")
        XCTAssertEqual(access.status(.music), .unknown, "consent is per player")
        access.learn(.spotify, outcome: 0)
        XCTAssertEqual(access.status(.spotify), .allowed)
    }

    /// The state scripts catch their own errors and return them as text, so
    /// a refusal arrives as a string, not as an AppleScript error.
    func testARefusalCaughtInsideAScriptIsStillHeard() {
        XCTAssertEqual(PlayerBridge.outcome(errorNumber: nil, result: "error\u{1}-1743"), -1743)
        XCTAssertEqual(PlayerBridge.outcome(errorNumber: -1743, result: nil), -1743)
        XCTAssertEqual(PlayerBridge.outcome(errorNumber: nil, result: "playing\u{1}A"), 0)
    }

    /// The id script says "not a track" apart from "no answer".
    func testTheTrackIDAnswerIsRead() {
        XCTAssertEqual(
            PlayerBridge.SpotifyTrackLookup.parse("spotify:track:XYZ\u{1}A\u{1}B"),
            .track(id: "XYZ", name: "A", artist: "B")
        )
        XCTAssertEqual(PlayerBridge.SpotifyTrackLookup.parse("spotify:episode:E1\u{1}Ep\u{1}Show"), .notATrack)
        XCTAssertEqual(PlayerBridge.SpotifyTrackLookup.parse("spotify:ad:1\u{1}\u{1}"), .notATrack)
        XCTAssertEqual(PlayerBridge.SpotifyTrackLookup.parse(nil), .noAnswer)
        XCTAssertEqual(PlayerBridge.SpotifyTrackLookup.parse(""), .noAnswer)
    }
}
