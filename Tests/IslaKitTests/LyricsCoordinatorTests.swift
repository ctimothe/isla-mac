import Combine
import XCTest
@testable import IslaKit

/// A count a cancelled task may safely bump from wherever it is torn down.
private final class CancelCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class LyricsCoordinatorTests: XCTestCase {
    nonisolated(unsafe) private let fileManager = FileManager.default
    nonisolated(unsafe) private var root = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    func testPrefetchesLocalLyricsWhenNowPlayingArrivesWithoutOpeningASurface() throws {
        var lookups: [LocalTrackIdentity] = []
        let library = LocalLyricsLibrary(directory: root, onLookup: { lookups.append($0) })
        _ = try library.importDocument(at: try writeLRC(), binding: nil)
        let media = MediaController()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())

        XCTAssertEqual(lookups.count, 1)
        XCTAssertEqual(lookups.first?.title, "Song")
        guard case .ready(let candidate) = coordinator.localLookup else {
            return XCTFail("a prefetched local result should be available before any lyric surface opens")
        }
        XCTAssertEqual(candidate.timeline.lines.first?.text, "Local opening")
    }

    /// The lyric is there the instant the panel opens. It used to wait for the
    /// clock to settle — "Syncing playback…" on every open, for up to the 1.2s
    /// grace — to avoid a wrong line that a fresh anchor almost never gives.
    func testLyricsAreReadyBeforeTheClockSettles() throws {
        let library = LocalLyricsLibrary(directory: root)
        _ = try library.importDocument(at: try writeLRC(), binding: nil)
        let media = MediaController()
        let store = LyricsStore(offsetsDirectory: root)
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true }, presentation: store
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }
        media.apply(playingSnapshot())

        // Opening the panel again unsettles the clock; the lyric must not care.
        media.setActive(false)
        media.setActive(true)
        XCTAssertFalse(media.positionSettled, "the fixture: a fresh open is unsettled")
        guard case .ready = coordinator.availability else {
            return XCTFail("lyrics must be ready while the clock is still settling")
        }
        guard case .synced = store.state else {
            return XCTFail("and the store must present them, not a loading state")
        }
    }

    func testMetadataEnrichmentDoesNotStartAnotherLocalLookupOrBlankLyrics() throws {
        var lookups: [LocalTrackIdentity] = []
        let library = LocalLyricsLibrary(directory: root, onLookup: { lookups.append($0) })
        _ = try library.importDocument(at: try writeLRC(), binding: nil)
        let media = MediaController()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())
        media.setSpotifyMetadataForTests(
            trackID: "spotify-track", isrc: "US-TEST-26-00001", exactDuration: 180.6
        )

        XCTAssertEqual(lookups.count, 1)
        guard case .ready(let candidate) = coordinator.localLookup else {
            return XCTFail("metadata enrichment must not blank validated local lyrics")
        }
        XCTAssertEqual(candidate.timeline.lines.first?.text, "Local opening")
    }

    func testAppleMusicNowPlayingPrefetchesTheSameLocalTimelineWithoutASurface() throws {
        var lookups: [LocalTrackIdentity] = []
        let library = LocalLyricsLibrary(directory: root, onLookup: { lookups.append($0) })
        _ = try library.importDocument(at: try writeLRC(), binding: nil)
        let media = MediaController()
        media.precisionPlayerForTests = .music
        media.lyricsShown = { true }
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())

        XCTAssertEqual(lookups.count, 1)
        guard case .ready(let candidate) = coordinator.localLookup else {
            return XCTFail("Apple Music playback should prefetch the local document")
        }
        XCTAssertEqual(candidate.timeline.lines.first?.text, "Local opening")
    }

    func testNoLocalMatchPublishesAnActionableLocalState() {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())
        guard case .noMatch = coordinator.localLookup else {
            return XCTFail("a missing local document must remain actionable")
        }
        XCTAssertFalse(
            LyricsPresentation.compactCaption(for: coordinator.availability, currentLine: nil).isEmpty
        )
    }

    /// Off by default, and off means no request is ever made.
    ///
    /// The switch is the whole privacy claim. A coordinator built without an
    /// opinion — which is every other test in this file — must never reach the
    /// network, so the default is proved here rather than assumed.
    func testNothingReachesTheNetworkWhileTheSwitchIsOff() throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        var asked = 0
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { _ in asked += 1; return .none }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())

        XCTAssertEqual(asked, 0, "the default must not reach the network")
        XCTAssertEqual(coordinator.availability, .noLocalLyrics)
    }

    /// A file the listener chose outranks anything a catalogue could offer, so
    /// a local match means the network is never asked at all.
    func testALocalMatchIsNeverSecondGuessedOnline() throws {
        let library = LocalLyricsLibrary(directory: root)
        _ = try library.importDocument(at: try writeLRC(), binding: nil)
        let media = MediaController()
        var asked = 0
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { _ in asked += 1; return .none }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())

        XCTAssertEqual(asked, 0, "a local file answers; nothing else is consulted")
        guard case .ready(let timeline) = coordinator.availability else {
            return XCTFail("the local file is what shows")
        }
        XCTAssertEqual(timeline.lines.first?.text, "Local opening")
    }

    /// A lookup that could not reach the catalogue reads as a quiet miss and
    /// asks again by itself. It used to leave "Finding lyrics…" up for the
    /// whole song, with a Retry button the lock card could not fit.
    func testAFailedLookupShowsAMissAndAsksAgainByItself() async throws {
        LyricsCoordinator.retryDelays = [0.05]
        defer { LyricsCoordinator.retryDelays = [5, 30, 120] }
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        let fetched = LyricTimeline(
            lines: [LyricsStore.Line(at: 2, text: "Found on the second ask")], granularity: .line
        )
        var asked = 0
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { _ in
                asked += 1
                return asked == 1 ? .failed : .found(fetched)
            }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())
        for _ in 0..<50 where asked < 1 || coordinator.availability == .resolving {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.availability, .noLocalLyrics, "a quiet miss, not a spinner")

        for _ in 0..<100 {
            if case .ready = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready(let timeline) = coordinator.availability else {
            return XCTFail("the retry found the words")
        }
        XCTAssertEqual(timeline.lines.first?.text, "Found on the second ask")
        XCTAssertEqual(asked, 2)
    }

    /// And with nothing local and the switch on, the words arrive from LRCLIB.
    func testWithNoLocalFileTheWordsComeFromTheService() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        let fetched = LyricTimeline(
            lines: [LyricsStore.Line(at: 2, text: "From the catalogue")], granularity: .line
        )
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { _ in .found(fetched) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())
        // The lookup is a task; give it the one hop it needs to land.
        for _ in 0..<50 {
            if case .ready = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        guard case .ready(let timeline) = coordinator.availability else {
            return XCTFail("an answer from the service is what shows when nothing local matches")
        }
        XCTAssertEqual(timeline.lines.first?.text, "From the catalogue")
        XCTAssertEqual(timeline.granularity, .line, "never a word sweep from a line timeline")
    }

    /// A hit cached before line ends existed shows at once, from the cache,
    /// and is asked about exactly once more in the background; the answer
    /// with ends replaces it on screen. The next play reads the cache alone.
    func testAnOldCachedHitShowsAtOnceAndIsRefreshedOnce() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        let online = root.appendingPathComponent("online", isDirectory: true)
        try fileManager.createDirectory(at: online, withIntermediateDirectories: true)
        let identity = LocalTrackIdentity(
            playerID: "any", title: "Song", artist: "Artist", album: "Album", duration: 180, recordingID: nil
        )
        let oldLines = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([LyricsStore.Line(at: 2, text: "Cached before ends")])
        )
        try JSONSerialization.data(withJSONObject: [
            OnlineLyricsCache.key(identity): ["lines": oldLines, "checkedAt": Date().timeIntervalSinceReferenceDate],
        ]).write(to: online.appendingPathComponent("cache.json"))
        let fresh = LyricTimeline(
            lines: [LyricsStore.Line(at: 2, text: "With an end", end: 5)], granularity: .line
        )
        var asked = 0
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: online),
            onlineLookUp: { _ in asked += 1; return .found(fresh) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())
        guard case .ready(let shown) = coordinator.availability else {
            return XCTFail("the old hit shows at once, not after the network")
        }
        XCTAssertEqual(shown.lines.first?.text, "Cached before ends")

        for _ in 0..<50 {
            if case .ready(let timeline) = coordinator.availability, timeline.lines.first?.end != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready(let refreshed) = coordinator.availability else { return XCTFail("still ready") }
        XCTAssertEqual(refreshed.lines.first?.text, "With an end")
        XCTAssertEqual(asked, 1)

        // The next play is served by the cache alone.
        coordinator.refreshVisibility()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(asked, 1, "refreshed once, not once per play")
    }

    /// A length that arrives after the title corrects the identity.
    ///
    /// The player publishes the title before it knows the length, so the first
    /// reconcile carries the *previous* track's duration. Keyed on the title
    /// alone that stale value stuck for the whole song, and duration is what
    /// identifies a recording to both the local matcher and the catalogue — so
    /// the song had no lyrics until it was played again.
    func testALateArrivingDurationReopensTheLookup() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        var asked: [LocalTrackIdentity] = []
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { identity in asked.append(identity); return .none }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        var snapshot = playingSnapshot()
        snapshot.title = "Dragon Eyes"
        snapshot.duration = 250          // the previous song's length
        media.apply(snapshot)

        var corrected = snapshot
        corrected.duration = 191         // what this one actually is
        corrected.takenAt = Date()
        media.apply(corrected)

        // The lookup is a task; give it the hops it needs to land.
        for _ in 0..<50 {
            if asked.last?.duration == 191 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            asked.last?.duration, 191,
            "the corrected length must re-open the lookup, not be ignored as the same track"
        )
    }

    /// A skip shows no loading state at all while the answer is quick.
    ///
    /// Every track change used to publish "Finding lyrics…" immediately, so a
    /// cached hit flashed a spinner for one frame and a run of skips strobed.
    /// The slot holds its height either way, so staying quiet for a moment is
    /// invisible — and an answer inside the grace is simply instant.
    func testAQuickAnswerNeverDrawsALoadingState() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { _ in
                .found(LyricTimeline(
                    lines: [LyricsStore.Line(at: 1, text: "Quick")], granularity: .line
                ))
            }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())
        XCTAssertEqual(
            coordinator.availability, .resolving,
            "a track change is quiet until the wait is worth admitting to"
        )

        for _ in 0..<50 {
            if case .ready = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready = coordinator.availability else {
            return XCTFail("and then the words arrive, with no spinner in between")
        }
    }

    /// A wait that is real is admitted to, rather than leaving a blank slot
    /// that reads as broken.
    func testAWaitThatLastsIsAdmittedTo() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        LyricsCoordinator.quietGrace = 0.05
        defer { LyricsCoordinator.quietGrace = 0.6 }
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { _ in
                try? await Task.sleep(for: .seconds(5))
                return .none
            }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        media.apply(playingSnapshot())
        for _ in 0..<50 {
            if coordinator.availability == .findingLocalLyrics { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(coordinator.availability, .findingLocalLyrics)
    }

    /// A skip cancels the request the last one started, so a run of skips does
    /// not leave a run of requests against a free service.
    func testASkipCancelsTheRequestBeforeIt() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        let cancelled = CancelCount()
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: OnlineLyricsCache(directory: root),
            onlineLookUp: { _ in
                do { try await Task.sleep(for: .seconds(5)) } catch { cancelled.bump() }
                return .none
            }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        var first = playingSnapshot(); first.title = "One"
        media.apply(first)
        var second = playingSnapshot(); second.title = "Two"; second.takenAt = Date()
        media.apply(second)

        for _ in 0..<50 {
            if cancelled.value > 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(cancelled.value, 0, "the superseded request must be cancelled, not merely ignored")
    }

    /// A line going dark is a change of line like any other, so the clock
    /// wakes for it: an end it honours is a boundary beside every start. Left
    /// to the quarter-second ticker, the line would linger up to 250 ms past
    /// the voice at random. A breath-length end is not honoured, so it does
    /// not wake anything.
    func testLineEndsAreBoundaries() throws {
        let url = root.appendingPathComponent("ends.lrc")
        try Data("""
        [ti:Song]
        [ar:Artist]
        [al:Album]
        [length:03:00]
        [00:10.00]One
        [00:15.00]
        [00:26.30]Two
        [00:30.00]
        [00:30.80]Three
        [00:40.00]
        """.utf8).write(to: url, options: .atomic)
        let library = LocalLyricsLibrary(directory: root)
        _ = try library.importDocument(at: url, binding: nil)
        let media = MediaController()
        media.isolateFromPlayers()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        media.apply(playingSnapshot())

        guard case .ready = coordinator.availability else {
            return XCTFail("the fixture: the local file is the answer, got \(coordinator.availability)")
        }
        XCTAssertEqual(media.lyricBoundariesForTests, [10, 15, 26.3, 30.8, 40])
    }

    private func writeLRC() throws -> URL {
        let url = root.appendingPathComponent("song.lrc")
        try Data("[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Local opening".utf8)
            .write(to: url, options: .atomic)
        return url
    }

    /// The same song moving from Music to Spotify is keyed to Spotify. The
    /// track used to be published before the player playing it was adopted,
    /// so the identity was built for the player the last song came from — and
    /// with the length unchanged nothing ever rebuilt it: a timing nudge or a
    /// binding made while the song played in Spotify was saved under Music.
    func testTheSameSongMovingToAnotherPlayerIsKeyedToThatPlayer() {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        // Never activated, and cut off from every real player: the fixture
        // names Music and Spotify, and nothing here may script either.
        media.isolateFromPlayers()
        media.bundleIdentifierForPID = { pid in
            switch pid {
            case 42: return PlayerApp.music.bundleID
            case 43: return PlayerApp.spotify.bundleID
            default: return nil
            }
        }
        media.isProcessRunning = { _ in true }
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        media.apply(playingSnapshot())
        XCTAssertEqual(coordinator.currentLocalTrackIdentity?.playerID, PlayerApp.music.rawValue)

        var inSpotify = playingSnapshot()
        inSpotify.playerPID = 43
        media.apply(inSpotify)
        XCTAssertEqual(
            coordinator.currentLocalTrackIdentity?.playerID, PlayerApp.spotify.rawValue,
            "the identity belongs to the player the song is playing in now"
        )
    }

    /// A stream, a radio station or a browser tab publishes no length, and
    /// every such track used to say "Lyrics are off." with a Show Lyrics
    /// button that rewrote an already-true switch and could not work: the
    /// guard that meant "the switch is off" also swallowed "this track has no
    /// length". It now says what is true, and offers nothing it cannot do.
    func testATrackWithNoLengthSaysSoAndOffersNothingThatCannotWork() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        LyricsCoordinator.noLengthGrace = 0.05
        defer { LyricsCoordinator.noLengthGrace = 1.5 }
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        var live = playingSnapshot()
        live.title = "Radio"
        live.artist = "Station"
        live.album = ""
        live.duration = 0
        media.apply(live)
        XCTAssertEqual(coordinator.availability, .resolving, "quiet first: the length may yet arrive")

        for _ in 0..<50 {
            if coordinator.availability == .cannotLookUp(.noLength) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(coordinator.availability, .cannotLookUp(.noLength))
        XCTAssertNil(LyricsPresentation.offer(
            for: coordinator.availability, localLookup: coordinator.localLookup, onlineEnabled: false
        ))
        XCTAssertNil(LyricsPresentation.offer(
            for: coordinator.availability, localLookup: coordinator.localLookup, onlineEnabled: true
        ))
        XCTAssertEqual(
            LyricsPresentation.compactCaption(for: coordinator.availability, currentLine: nil),
            localized("No lyrics for live audio.")
        )
        XCTAssertFalse(LyricsPresentation.canRetry(coordinator.availability))
        XCTAssertFalse(LyricsPresentation.canOpenLocalActions(coordinator.availability))
    }

    /// The player publishes the title before the length, so a real song
    /// passes through "no length" on its way in. That moment must never be
    /// drawn as live audio: the grace holds the slot quiet, and a length
    /// arriving inside it resolves the track as any other.
    func testADurationThatArrivesInsideTheGraceNeverShowsTheLiveState() async throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        // Wide enough that a busy machine cannot let the grace run out
        // before the length lands at 20ms; the wait after it outlasts the
        // grace, so a timer that was not cancelled would have fired.
        LyricsCoordinator.noLengthGrace = 0.3
        defer { LyricsCoordinator.noLengthGrace = 1.5 }
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        var published: [LyricsAvailability] = []
        let watch = coordinator.$availability.sink { published.append($0) }
        defer { watch.cancel() }
        coordinator.start()
        defer { coordinator.stop() }

        var early = playingSnapshot()
        early.duration = 0
        media.apply(early)
        try? await Task.sleep(for: .milliseconds(20))

        var known = early
        known.duration = 180
        known.takenAt = Date()
        media.apply(known)
        try? await Task.sleep(for: .milliseconds(450))

        XCTAssertFalse(
            published.contains { (state: LyricsAvailability) -> Bool in
                if case .cannotLookUp = state { return true }
                return false
            },
            "published \(published)"
        )
        XCTAssertEqual(coordinator.availability, .noLocalLyrics)
    }

    /// No title is nothing to look a song up by, which is not the switch
    /// being off either. A truly empty title never becomes a track (the feed
    /// reads it as nothing playing); a blank one does, and used to be sent to
    /// the matcher and the catalogue as a title.
    func testATrackWithNoTitleSaysItCannotBeLookedUp() {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        var untitled = playingSnapshot()
        untitled.title = "   "
        media.apply(untitled)

        XCTAssertNotNil(media.track, "the fixture: a blank title is still a track")
        XCTAssertEqual(coordinator.availability, .cannotLookUp(.noTitle))
        XCTAssertEqual(
            LyricsPresentation.compactCaption(for: coordinator.availability, currentLine: nil),
            localized("This track has no title to look up.")
        )
    }

    /// Off is the only state that says off.
    func testWithLyricsOffANoLengthTrackStillSaysOff() {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { false })
        coordinator.start()
        defer { coordinator.stop() }

        var live = playingSnapshot()
        live.duration = 0
        media.apply(live)
        XCTAssertEqual(coordinator.availability, .disabled)
    }

    /// The output-latency listener is a lyrics concern: it runs while Show
    /// Lyrics is on and nowhere else, so a listener who never turned lyrics
    /// on never has a CoreAudio listener installed on their behalf.
    func testTheOutputLatencyWatchRunsOnlyWhileLyricsAreOn() {
        let saved = LyricSweep.model
        defer { LyricSweep.model = saved }
        var enabled = false
        var installs = 0, removals = 0
        let monitor = OutputLatencyMonitor(
            read: { 0.0273 }, installListener: { installs += 1 }, removeListener: { removals += 1 }
        )
        let coordinator = LyricsCoordinator(
            media: MediaController(), library: LocalLyricsLibrary(directory: root),
            isEnabled: { enabled }, outputLatency: monitor
        )
        coordinator.start()
        XCTAssertEqual(installs, 0, "lyrics are off: nothing to listen for")

        enabled = true
        coordinator.refreshVisibility()
        XCTAssertEqual(installs, 1)
        XCTAssertTrue(monitor.isRunning)

        enabled = false
        coordinator.refreshVisibility()
        XCTAssertEqual(removals, 1)
        XCTAssertFalse(monitor.isRunning)

        enabled = true
        coordinator.refreshVisibility()
        coordinator.stop()
        XCTAssertEqual(removals, 2, "stopping the coordinator takes the listener with it")
    }

    /// A route's reported latency reaches the lead model, where the DI_MEDIA
    /// trail can show it — and, until the owner's live session says how each
    /// player treats it, leaves the lead exactly where it was.
    func testAReportedOutputLatencyReachesTheModelButNotTheLead() {
        let saved = LyricSweep.model
        defer { LyricSweep.model = saved }
        var route: TimeInterval? = 0.0273
        let monitor = OutputLatencyMonitor(read: { route }, installListener: {}, removeListener: {})
        let coordinator = LyricsCoordinator(
            media: MediaController(), library: LocalLyricsLibrary(directory: root),
            isEnabled: { true }, outputLatency: monitor
        )
        coordinator.start()
        defer { coordinator.stop() }
        let before = LyricSweep.lead(precisionSync: false, userOffset: 0)

        route = 0.200
        monitor.defaultOutputChanged()

        XCTAssertEqual(LyricSweep.model.outputLatency, 0.200, accuracy: 1e-12)
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), before, accuracy: 1e-12)

        route = nil
        monitor.defaultOutputChanged()
        XCTAssertEqual(
            LyricSweep.model.outputLatency, LyricLeadModel.referenceOutputLatency, accuracy: 1e-12,
            "an unknown route falls back to the reference the model was calibrated on"
        )
    }

    private func playingSnapshot() -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Song"
        snapshot.artist = "Artist"
        snapshot.album = "Album"
        snapshot.duration = 180
        snapshot.elapsed = 4
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 42
        return snapshot
    }
}
