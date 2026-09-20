import XCTest
@testable import IslaKit

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

    private func writeLRC() throws -> URL {
        let url = root.appendingPathComponent("song.lrc")
        try Data("[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Local opening".utf8)
            .write(to: url, options: .atomic)
        return url
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
