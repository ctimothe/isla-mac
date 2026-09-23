import XCTest
@testable import IslaKit

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

    /// The staleness guard must not be able to lock the player out.
    ///
    /// Keyed against our own clock it could: any local tap or seek pushed the
    /// baseline past the player's last publish, and a player that had not
    /// published since was then refused forever, freezing the bar for the
    /// whole paused period.
    func testAFreshReadingIsStillAcceptedAfterALocalAction() {
        let controller = MediaController()
        let start = Date()

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 10
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = start
        playing.playerPID = 1
        controller.apply(playing)

        // A local action — this is what used to poison the baseline.
        controller.togglePlayPause()

        // The player then publishes a genuinely newer reading.
        var paused = playing
        paused.isPlaying = false
        paused.rate = 0
        paused.elapsed = 42
        paused.takenAt = start.addingTimeInterval(1)
        controller.apply(paused)

        XCTAssertEqual(
            controller.position,
            42,
            accuracy: 1,
            "a reading newer than the last one accepted must still be adopted"
        )
    }

    /// Sessions that publish no timestamp also report elapsed as a plain zero.
    /// Taken literally while paused, every poll dragged the bar back to the
    /// start of the track.
    func testAPausedReadingWithNoTimestampIsIgnored() {
        let controller = MediaController()

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 90
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)

        var paused = playing
        paused.isPlaying = false
        paused.rate = 0
        paused.elapsed = 0
        paused.takenAt = nil
        controller.apply(paused)

        XCTAssertEqual(controller.position, 90, accuracy: 2, "a stampless paused zero must not reset the bar")
    }

    /// The playing counterpart of the stampless zero, and a worse one.
    ///
    /// MediaRemote republishes the reading from the session's last state
    /// change, and Spotify's is routinely a plain zero carrying a *fresh*
    /// timestamp. Playing, that sails past the staleness guard: the reading
    /// looks current, the jump backwards is larger than the seek threshold, so
    /// it was taken whole and the clock landed at the start of the track while
    /// the music kept playing a minute in. Everything keyed off the position
    /// followed it — the lyrics stage then showed the song's opening lines, and
    /// clicking one seeked the player back there, which is what the bug reads
    /// as from the outside: every lyric click jumps the song backwards.
    func testAPlayingZeroWithAFreshStampDoesNotResetTheClock() {
        let controller = MediaController()
        let start = Date()

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 60
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = start
        playing.playerPID = 1
        controller.apply(playing)

        var republishedZero = playing
        republishedZero.elapsed = 0
        republishedZero.takenAt = start.addingTimeInterval(1)
        controller.apply(republishedZero)

        XCTAssertEqual(
            controller.position,
            61,
            accuracy: 2,
            "a republished zero must not drag the bar back to the start of the track"
        )
    }

    /// The other side of that rule: a rewind the player really made must still
    /// land, or seeking inside Spotify would leave the island stuck ahead of
    /// the music. Corroboration is what separates the two — a real jump is
    /// still there on the next reading, a phantom is not.
    func testARewindConfirmedByASecondReadingIsAdopted() {
        let controller = MediaController()
        let start = Date()

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 60
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = start
        playing.playerPID = 1
        controller.apply(playing)

        var rewound = playing
        rewound.elapsed = 12
        rewound.takenAt = start.addingTimeInterval(1)
        controller.apply(rewound)

        var confirming = playing
        confirming.elapsed = 12.4
        confirming.takenAt = start.addingTimeInterval(1.4)
        controller.apply(confirming)

        XCTAssertEqual(
            controller.position,
            12.4,
            accuracy: 1.5,
            "a rewind two readings agree on is real and must be taken"
        )
    }

    /// A track change starts the new song at zero, and that must not wait for a
    /// second reading — a skip has to move the bar in the same beat.
    func testANewTrackStartsAtZeroImmediately() {
        let controller = MediaController()
        let start = Date()

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 200
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = start
        playing.playerPID = 1
        controller.apply(playing)

        var nextTrack = playing
        nextTrack.title = "Another Track"
        nextTrack.elapsed = 0
        nextTrack.takenAt = start.addingTimeInterval(0.2)
        controller.apply(nextTrack)

        XCTAssertEqual(
            controller.position,
            0,
            accuracy: 1,
            "the next song must start at its own beginning, not the old one's position"
        )
    }

    // MARK: - Focus-follows displacement

    private func snapshot(
        title: String, pid: pid_t, playing: Bool, rate: Double
    ) -> NowPlayingFeed.Snapshot {
        var s = NowPlayingFeed.Snapshot()
        s.title = title
        s.artist = "Artist"
        s.album = "Album"
        s.duration = 200
        s.elapsed = 10
        s.rate = rate
        s.isPlaying = playing
        s.takenAt = Date()
        s.playerPID = pid
        return s
    }

    /// macOS's "active" session follows app focus: focusing a browser with a
    /// paused video displaces the player that is actually making sound. The
    /// island must not follow — a session that is not playing never takes the
    /// display from one that is.
    func testAPausedSessionDoesNotDisplaceAPlayingOne() {
        let controller = MediaController()
        controller.foreignHoldWindow = 3600

        controller.apply(snapshot(title: "Song", pid: 100, playing: true, rate: 1))
        XCTAssertEqual(controller.track?.title, "Song")

        controller.apply(snapshot(title: "Some Video", pid: 200, playing: false, rate: 0))
        XCTAssertEqual(controller.track?.title, "Song", "a paused stranger must not take the display")
        XCTAssertTrue(controller.isPlaying, "and the playing state must survive it")
    }

    /// A stranger that is actually playing is new audio — it wins at once.
    func testAPlayingSessionDisplacesImmediately() {
        let controller = MediaController()
        controller.foreignHoldWindow = 3600

        controller.apply(snapshot(title: "Song", pid: 100, playing: true, rate: 1))
        controller.apply(snapshot(title: "New Audio", pid: 200, playing: true, rate: 1))
        XCTAssertEqual(controller.track?.title, "New Audio")
    }

    /// The hold cannot be forever: the displayed player may genuinely be gone
    /// — quit, or its session expired — and then the stranger is all there is.
    func testAPersistentForeignSessionIsEventuallyAdopted() {
        let controller = MediaController()
        controller.foreignHoldWindow = 0

        controller.apply(snapshot(title: "Song", pid: 100, playing: true, rate: 1))
        controller.apply(snapshot(title: "Some Video", pid: 200, playing: false, rate: 0))
        // Window elapsed (zero for the test): the next foreign report lands.
        controller.apply(snapshot(title: "Some Video", pid: 200, playing: false, rate: 0))
        XCTAssertEqual(controller.track?.title, "Some Video")
    }

    /// The displayed player's own reports always land — pausing your own
    /// music is not displacement.
    func testTheDisplayedPlayersOwnPauseStillLands() {
        let controller = MediaController()
        controller.foreignHoldWindow = 3600

        controller.apply(snapshot(title: "Song", pid: 100, playing: true, rate: 1))
        controller.apply(snapshot(title: "Song", pid: 100, playing: false, rate: 0))
        XCTAssertFalse(controller.isPlaying)
    }

    /// The lyric line must not be chosen from a stale extrapolation: opening
    /// the panel marks the position unsettled until a real reading lands.
    func testPositionSettlesOnlyOnARealReading() {
        let controller = MediaController()
        controller.setActive(true)
        defer { controller.setActive(false) }
        XCTAssertFalse(controller.positionSettled, "opening the panel must unsettle the position")

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 200
        playing.elapsed = 50
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)

        XCTAssertTrue(controller.positionSettled, "a real reading settles it")
    }

    /// Opening the panel on a paused track must not unsettle the clock.
    ///
    /// `positionSettled` means "an authoritative reading has landed" (it no
    /// longer gates any lyric surface, but the trail and the precision loop
    /// still read it), and it is cleared whenever the panel opens. But while paused
    /// nothing can set it again — MediaRemote republishes the reading it
    /// already gave, which is judged stale, and the precision loop runs only
    /// while playing. So the panel opened on a paused song and the lyric never
    /// appeared until the track was nudged, which is exactly how it presented:
    /// "the lyrics come back if I pause and play".
    func testOpeningOnAPausedTrackKeepsTheSettledPosition() {
        let controller = MediaController()
        defer { controller.setActive(false) }
        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.duration = 200
        playing.elapsed = 42
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 501
        controller.apply(playing)
        XCTAssertTrue(controller.positionSettled, "a live reading settles the clock")

        var paused = playing
        paused.isPlaying = false
        paused.rate = 0
        paused.takenAt = Date()
        controller.apply(paused)

        controller.setActive(false)
        controller.setActive(true)
        XCTAssertTrue(
            controller.positionSettled,
            "a paused track cannot have moved, so what we already know is still authoritative"
        )
    }

    // MARK: - Lyric boundaries

    /// The clock wakes on the frame a line is due, not on its quarter-second
    /// grid. The arithmetic is pure: given the boundaries, the lead and where
    /// the clock stands, the next wake is the first boundary ahead, less the
    /// lead, scaled by the rate.
    func testTheNextLyricWakeIsTheFirstBoundaryAheadLessTheLead() {
        let boundaries: [TimeInterval] = [10, 12.5, 20]
        XCTAssertEqual(
            MediaController.nextLyricWake(boundaries: boundaries, lead: 0.2, position: 11, rate: 1)!,
            1.3, accuracy: 0.0001, "12.5 less the lead, from 11"
        )
        XCTAssertEqual(
            MediaController.nextLyricWake(boundaries: boundaries, lead: 0.2, position: 11, rate: 2)!,
            0.65, accuracy: 0.0001, "double speed halves the wait"
        )
        XCTAssertNil(
            MediaController.nextLyricWake(boundaries: boundaries, lead: 0.2, position: 19.8, rate: 1),
            "past the last boundary there is nothing left to wake for"
        )
        XCTAssertNil(
            MediaController.nextLyricWake(boundaries: boundaries, lead: 0.2, position: 11, rate: 0),
            "a paused clock never wakes"
        )
        // A wake that fired exactly on a boundary must arm the one after it,
        // not itself again.
        XCTAssertEqual(
            MediaController.nextLyricWake(boundaries: boundaries, lead: 0.2, position: 12.3, rate: 1)!,
            7.5, accuracy: 0.0001
        )
    }

    /// End to end: registering a line due ahead arms a timer for exactly that
    /// moment — checked on the timer's own fire date, not by waiting for it.
    ///
    /// This used to sleep 180ms and assert the first published position landed
    /// within 30ms of the boundary. That is a claim about how promptly a shared
    /// CI machine runs a timer, not about this code: it passed on one branch
    /// and failed on the next for the same commit, 57ms late. It had also gone
    /// stale — written against a 250ms tick, it raced a 100ms one after
    /// `positionTickInterval` moved, so the grid tick usually won the race the
    /// test existed to lose. The fire date is computed when the timer is armed,
    /// so it says exactly what was scheduled and no scheduler can make it late.
    func testRegisteringALineArmsAWakeForTheMomentItIsDue() {
        let controller = MediaController()
        controller.setActive(true)
        defer { controller.setActive(false) }
        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.duration = 200
        playing.elapsed = 50
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 7
        controller.apply(playing)
        let start = controller.position

        let armedAt = Date()
        controller.setLyricBoundaries([start + 0.14], lead: { 0.02 })

        guard let wake = controller.lyricWakeDateForTests else {
            return XCTFail("a line ahead of the clock must arm a wake")
        }
        // Due 0.12s out: the boundary at +0.14, less the 0.02 lead. The only
        // slack is the few microseconds between reading `start` and arming.
        XCTAssertEqual(wake.timeIntervalSince(armedAt), 0.12, accuracy: 0.01)

        // And nothing is armed once there is no line left to turn.
        controller.setLyricBoundaries([start - 5], lead: { 0.02 })
        XCTAssertNil(controller.lyricWakeDateForTests, "a line already passed arms nothing")
    }

    /// And a player that publishes nothing at all still gives up its lyrics.
    ///
    /// The reset is right while playing — the position really may have moved
    /// since the panel last closed — but it cannot be allowed to wait forever
    /// on a player that never answers.
    func testAnUnansweredPlayingTrackSettlesOnItsOwn() async throws {
        let controller = MediaController()
        defer { controller.setActive(false) }
        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.duration = 200
        playing.elapsed = 42
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 501
        controller.apply(playing)

        MediaController.settleGrace = 0.15
        defer { MediaController.settleGrace = 1.2 }
        controller.setActive(false)
        controller.setActive(true)
        XCTAssertFalse(controller.positionSettled, "the reset itself still happens")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(
            controller.positionSettled,
            "no player answered, and the extrapolated position is what there is"
        )
    }

    /// A new track must not wear the previous track's catalogue identity.
    /// Published via the real adoption path, then cleared by a track change
    /// driven through `apply` like every other controller test.
    func testTrackChangeClearsPublishedSpotifyMetadata() async {
        let controller = MediaController()
        controller.spotifyMetadataProvider = { _ in
            SpotifyAccount.TrackMetadata(isrc: "USRC12345678", durationMs: 213456)
        }

        var first = NowPlayingFeed.Snapshot()
        first.title = "First"
        first.artist = "Artist"
        first.album = "Album"
        first.isPlaying = true
        first.playerPID = 111
        controller.apply(first)
        guard let key = controller.track?.key else {
            return XCTFail("apply must publish a track")
        }
        controller.setSpotifyTrackIDForTests("track-one")
        await controller.requestSpotifyMetadata(trackID: "track-one", forKey: key)
        XCTAssertEqual(controller.spotifyISRC, "USRC12345678")
        XCTAssertEqual(controller.spotifyExactDuration ?? -1, 213.456, accuracy: 0.001)

        var second = first
        second.title = "Second"
        controller.apply(second)

        XCTAssertNil(
            controller.spotifyISRC,
            "a new track must not wear the previous track's ISRC"
        )
        XCTAssertNil(
            controller.spotifyExactDuration,
            "a new track must not wear the previous track's exact duration"
        )
    }

    /// An empty snapshot clears the session — the published identity, which
    /// only ever describes the displayed track, goes with it.
    func testClearResetsPublishedSpotifyMetadata() async {
        let controller = MediaController()
        controller.spotifyMetadataProvider = { _ in
            SpotifyAccount.TrackMetadata(isrc: "USRC12345678", durationMs: 213456)
        }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.isPlaying = true
        playing.playerPID = 111
        controller.apply(playing)
        guard let key = controller.track?.key else {
            return XCTFail("apply must publish a track")
        }
        controller.setSpotifyTrackIDForTests("track-one")
        await controller.requestSpotifyMetadata(trackID: "track-one", forKey: key)
        XCTAssertEqual(controller.spotifyISRC, "USRC12345678")

        controller.apply(NowPlayingFeed.Snapshot())

        XCTAssertNil(controller.spotifyISRC)
        XCTAssertNil(controller.spotifyExactDuration)
    }

    /// The lookup is a network round-trip: the track may have moved on before
    /// the answer lands, and a late answer must not pin the previous song's
    /// identity onto the new one.
    func testStaleSpotifyMetadataAnswerIsDropped() async {
        let controller = MediaController()
        controller.spotifyMetadataProvider = { _ in
            SpotifyAccount.TrackMetadata(isrc: "USRC12345678", durationMs: 213456)
        }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.isPlaying = true
        playing.playerPID = 111
        controller.apply(playing)

        await controller.requestSpotifyMetadata(trackID: "track-one", forKey: "a-track-no-longer-shown")

        XCTAssertNil(controller.spotifyISRC, "an answer for a departed track must not publish")
        XCTAssertNil(controller.spotifyExactDuration)
    }

    /// C2: same key, different catalogue IDs. A late answer for the departed
    /// ID must not publish onto the track the new ID now owns.
    func testStaleMetadataWithSameKeyButNewIDIsDropped() async {
        let controller = MediaController()
        controller.spotifyMetadataProvider = { id in
            if id == "id-old" {
                try? await Task.sleep(for: .milliseconds(200))
                return SpotifyAccount.TrackMetadata(isrc: "USRC-OLD", durationMs: 100000)
            }
            return SpotifyAccount.TrackMetadata(isrc: "USRC-NEW", durationMs: 200000)
        }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.isPlaying = true
        playing.playerPID = 111
        controller.apply(playing)
        guard let key = controller.track?.key else {
            return XCTFail("apply must publish a track")
        }
        // The old ID resolves first, its metadata fetch starts; before it
        // lands the catalogue resolves a different ID for the same key.
        controller.setSpotifyTrackIDForTests("id-old")
        async let old: Void = controller.requestSpotifyMetadata(trackID: "id-old", forKey: key)
        controller.setSpotifyTrackIDForTests("id-new")
        await controller.requestSpotifyMetadata(trackID: "id-new", forKey: key)
        await old
        XCTAssertEqual(
            controller.spotifyISRC, "USRC-NEW",
            "the departed ID's late answer must not overwrite the current ID"
        )
        XCTAssertEqual(controller.spotifyExactDuration ?? -1, 200, accuracy: 0.001)
    }

    /// I3: a rate change discontinues the regression line. Origins measured
    /// at 1× recomputed at 2× lean the mean, so the window must flush when
    /// the value changes — and only then.
    func testRateChangeFlushesCorrectionWindow() {
        let controller = MediaController()
        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 50
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)

        controller.correctionWindow = [
            (atMono: 1000, position: 50),
            (atMono: 1001, position: 51),
            (atMono: 1002, position: 52),
        ]
        var faster = playing
        faster.rate = 2
        faster.takenAt = Date()
        controller.apply(faster)
        XCTAssertTrue(
            controller.correctionWindow.isEmpty,
            "a rate change must flush the regression window built at the old rate"
        )

        controller.correctionWindow = [
            (atMono: 2000, position: 60),
            (atMono: 2001, position: 62),
        ]
        var sameRate = playing
        sameRate.rate = 2
        sameRate.takenAt = Date()
        sameRate.elapsed = 60
        controller.apply(sameRate)
        XCTAssertEqual(
            controller.correctionWindow.count, 2,
            "the same rate is no discontinuity and must keep the window"
        )
    }

    /// The catalogue does not always carry an ISRC for a track it otherwise
    /// knows — the exact duration is still worth publishing for the
    /// duration-gated matching the lyric tiers do.
    func testSpotifyMetadataWithoutISRCStillPublishesDuration() async {
        let controller = MediaController()
        controller.spotifyMetadataProvider = { _ in
            SpotifyAccount.TrackMetadata(isrc: nil, durationMs: 180000)
        }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.isPlaying = true
        playing.playerPID = 111
        controller.apply(playing)
        guard let key = controller.track?.key else {
            return XCTFail("apply must publish a track")
        }

        controller.setSpotifyTrackIDForTests("track-one")
        await controller.requestSpotifyMetadata(trackID: "track-one", forKey: key)

        XCTAssertNil(controller.spotifyISRC)
        XCTAssertEqual(controller.spotifyExactDuration ?? -1, 180.0, accuracy: 0.001)
    }

    // MARK: - Precision clock (Task 3: 1s monotonic regression clock)

    /// The correction loop polls Spotify's own clock every second, not every
    /// two: the 2s cadence stair-stepped the lyric sweep on the beat of the
    /// poll. The tolerance stays tight so a coalesced timer cannot reintroduce it.
    func testPrecisionPollCadenceIsOneSecond() {
        XCTAssertEqual(MediaController.precisionPollInterval, 1.0, accuracy: 0.0001)
        XCTAssertEqual(MediaController.precisionPollTolerance, 0.1, accuracy: 0.0001)
    }

    /// Apple Music is scriptable too.  Its measured player clock earns the
    /// same precision path as Spotify; browser and other MediaRemote sessions
    /// must remain line-only because they have no equivalent reading.
    func testAppleMusicStartsPrecisionPolling() async {
        let controller = MediaController()
        controller.precisionPlayerForTests = .music
        controller.lyricsShown = { true }
        controller.precisionPositionFetcher = { next in
            Task { @MainActor in next(42.3) }
        }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 40
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)
        controller.setActive(true)

        for _ in 0..<200 {
            if controller.positionSettled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(controller.precisionSync,
                      "Apple Music must use its own measured playback position")
        XCTAssertTrue(controller.positionSettled,
                      "the Apple Music correction must settle the lyric clock")
        controller.setActive(false)
    }

    /// Five RTT-aged corrections, not one snap: a single AppleScript answer
    /// carries ±80ms of scheduling jitter, and anchoring on it whole moved the
    /// sweep by that jitter on every poll. The mean origin converges.
    func testDriftRegressionConvergesUnderJitter() {
        let rate = 1.0
        // Truth: position = 100 + t. Each correction carries fixed jitter.
        let jitter: [TimeInterval] = [0.08, -0.08, 0.05, -0.05, 0.03]
        let corrections = jitter.enumerated().map { index, j in
            (atMono: TimeInterval(index), position: 100 + TimeInterval(index) * rate + j)
        }
        let regressed = MediaController.regressedAnchorPosition(
            corrections: corrections, rate: rate, nowMono: 4
        )
        XCTAssertEqual(regressed, 104, accuracy: 0.04,
                       "five jittered corrections must average out to near-truth")
        // One sample is a snap, by construction: the regression only helps
        // once there is a window to regress over.
        let single = MediaController.regressedAnchorPosition(
            corrections: [(atMono: 0, position: 100.08)], rate: rate, nowMono: 0
        )
        XCTAssertEqual(single, 100.08, accuracy: 0.0001)
    }

    /// The anchor runs on a monotonic clock, not the wall: an NTP step or a
    /// sleep/wake that moves `Date` by seconds must not move the position.
    func testMonotonicAnchorIgnoresWallClockJump() {
        let controller = MediaController()
        controller.monotonicNow = { 1_000 }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 50
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)

        controller.monotonicNow = { 1_005 }
        controller.tick()
        XCTAssertEqual(controller.position, 55, accuracy: 0.5,
                       "the position must follow the monotonic clock")

        // The wall kept moving under the frozen monotonic clock (the NTP
        // step); the position must not follow it.
        Thread.sleep(forTimeInterval: 0.1)
        controller.tick()
        XCTAssertEqual(controller.position, 55, accuracy: 0.02,
                       "a wall-clock jump with the monotonic clock frozen must not move the bar")
    }

    /// A Spotify play/pause/track-change broadcast re-anchors at once: the
    /// reading is unsettled until the authoritative correction lands, and the
    /// correction is asked for immediately rather than on the next poll.
    func testSpotifyNotificationReanchorsAndUnsettles() async {
        let controller = MediaController()
        controller.monotonicNow = { 2_000 }
        controller.spotifyDisplayForTests = true
        // Far past the settle grace, so only the fresh correction — never the
        // watchdog — can settle what the notification below unsettles.
        MediaController.settleGrace = 30
        defer { MediaController.settleGrace = 1.2 }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 40
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)

        var fetches = 0
        controller.precisionPositionFetcher = { next in
            fetches += 1
            Task { @MainActor in next(42.3) }
        }
        controller.setActive(true)

        // Let the loop-start correction the panel-open above triggered land
        // first: it holds the in-flight flag, and the notification's own
        // correction would rightly yield to it.
        for _ in 0..<200 {
            if controller.positionSettled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fetches = 0

        controller.handleSpotifyPlaybackState(position: 42)

        XCTAssertEqual(controller.position, 42, accuracy: 0.0001,
                       "the broadcast's millisecond reading anchors immediately")
        XCTAssertFalse(controller.positionSettled,
                       "the position is unsettled until the fresh correction lands")
        XCTAssertTrue(fetches == 1, "the notification must trigger a correction at once")

        // Suspended, never blocked: the delivery above needs the main actor,
        // which `wait(for:)` would hold.
        for _ in 0..<200 {
            if controller.positionSettled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.positionSettled,
                      "the fresh reading settles the position")
        // Leave no timers or watchdogs running into the next test: the panel
        // is closed, so the loop and the ticker stop with it.
        controller.setActive(false)
    }

    /// Five corrections are regressed, not one snapped: the window the
    /// estimator keeps is exactly five deep.
    func testCorrectionWindowHoldsFiveSamples() {
        XCTAssertEqual(MediaController.correctionWindowSize, 5)
    }

    /// An event-scale correction is a seek, not drift: it snaps at once
    /// instead of dragging the old line through the window for five polls.
    func testEventScaleCorrectionSnapsInsteadOfRegressing() async {
        let controller = MediaController()
        controller.monotonicNow = { 3_000 }
        controller.spotifyDisplayForTests = true
        MediaController.settleGrace = 30
        defer { MediaController.settleGrace = 1.2 }

        var playing = NowPlayingFeed.Snapshot()
        playing.title = "Track"
        playing.artist = "Artist"
        playing.album = "Album"
        playing.duration = 300
        playing.elapsed = 40
        playing.rate = 1
        playing.isPlaying = true
        playing.takenAt = Date()
        playing.playerPID = 1
        controller.apply(playing)
        controller.precisionPositionFetcher = { next in
            Task { @MainActor in next(70) }
        }
        controller.setActive(true)

        for _ in 0..<200 {
            if controller.positionSettled, controller.position > 60 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.position, 70, accuracy: 0.5,
                       "a +30s correction is a seek in the player and must land at once")
        controller.setActive(false)
    }
}
