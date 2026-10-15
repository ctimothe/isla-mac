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

    /// Remove Local Binding is drawn from `hasLocalOverride`, which used to be
    /// set only by an import or a choice made in this session and was reset by
    /// every track change. After a skip back or a relaunch, a song still bound
    /// to its file had no way to unbind it from the page. The flag is read
    /// from the library's saved binding on every resolve now.
    func testTheRemoveButtonSurvivesARelaunch() throws {
        // First launch: the song is bound to an imported file.
        do {
            let library = LocalLyricsLibrary(directory: root)
            let media = MediaController()
            media.isolateFromPlayers()
            let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
            coordinator.start()
            media.apply(playingSnapshot())
            try coordinator.importLocalFile(at: try writeLRC(), for: coordinator.currentLocalTrackIdentity)
            XCTAssertTrue(coordinator.hasLocalOverride, "the fixture: the import binds the song")
            coordinator.stop()
        }

        // The next launch: a new library and a new coordinator, nothing
        // remembered from the session that made the binding.
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let store = LyricsStore(offsetsDirectory: root)
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true }, presentation: store
        )
        coordinator.start()
        defer { coordinator.stop() }

        media.apply(playingSnapshot())
        let identity = try XCTUnwrap(coordinator.currentLocalTrackIdentity)
        XCTAssertTrue(library.hasBinding(for: identity), "the fixture: the binding was saved")
        XCTAssertTrue(coordinator.hasLocalOverride, "a saved binding offers its remove button")
        XCTAssertTrue(store.hasLocalOverride)

        coordinator.removeLocalBinding()
        XCTAssertFalse(coordinator.hasLocalOverride)
        XCTAssertFalse(store.hasLocalOverride)
    }

    /// The coordinator tells the store which file is showing, so a nudge made
    /// against one import does not shift a better-timed one imported over it
    /// for the same song (J-024). Before, the store only ever heard the song.
    func testImportingABetterTimedFileStartsItUncorrected() throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let suite = "LyricsCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LyricsStore(offsetsDirectory: root.appendingPathComponent("offsets"), defaults: defaults)
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true }, presentation: store
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.apply(playingSnapshot())
        let identity = try XCTUnwrap(coordinator.currentLocalTrackIdentity)

        try coordinator.importLocalFile(at: try writeUntaggedLRC(), for: identity)
        guard case .ready(let first) = coordinator.availability else {
            return XCTFail("the fixture: the bound import is showing")
        }
        store.nudgeTrackOffset(by: 0.5)
        XCTAssertEqual(store.trackOffset, 0.5, accuracy: 1e-9)

        try coordinator.importLocalFile(at: try writeLRC(), for: identity)
        guard case .ready(let second) = coordinator.availability else {
            return XCTFail("the fixture: the second import is showing")
        }
        XCTAssertNotEqual(first.documentID, second.documentID, "the fixture: another file")
        XCTAssertEqual(store.trackOffset, 0, accuracy: 1e-9, "the new file starts uncorrected")
    }

    /// Import binds the song that was playing when Import was pressed, not
    /// the one playing when the open panel returns. The identity used to be
    /// read after `runModal`, so browsing through a track change bound song
    /// B to song A's words for good (G-013). The file here carries no tags,
    /// so only the binding can make either song find it.
    func testImportBindsTheSongPlayingWhenImportWasPressed() throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        media.apply(playingSnapshot())
        let pressedFor = try XCTUnwrap(coordinator.currentLocalTrackIdentity)

        var next = playingSnapshot()
        next.title = "The Next Song"
        next.takenAt = Date()
        media.apply(next)
        let nowPlaying = try XCTUnwrap(coordinator.currentLocalTrackIdentity)
        XCTAssertNotEqual(nowPlaying, pressedFor, "the fixture: the track changed while the panel was up")

        try coordinator.importLocalFile(at: try writeUntaggedLRC(), for: pressedFor)

        guard case .ready(let candidate) = library.lookup(identity: pressedFor) else {
            return XCTFail("the song Import was pressed for is the one bound")
        }
        XCTAssertEqual(candidate.timeline.lines.first?.text, "Untagged opening")
        XCTAssertEqual(library.lookup(identity: nowPlaying), .noMatch, "the song playing now is untouched")
        XCTAssertFalse(coordinator.hasLocalOverride, "and the page on screen offers no remove for it")
    }

    /// With nothing playing, Import used to return without a word and keep
    /// nothing. The file is kept now, bound to no song, and matches by its
    /// own tags when its song plays.
    func testWithNothingPlayingAnImportIsKeptAndMatchesByItsTags() throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        XCTAssertNil(coordinator.currentLocalTrackIdentity, "the fixture: nothing is playing")

        try coordinator.importLocalFile(at: try writeLRC(), for: nil)
        media.apply(playingSnapshot())

        guard case .ready(let candidate) = coordinator.localLookup else {
            return XCTFail("the file imported with nothing playing matches its song by its tags")
        }
        XCTAssertEqual(candidate.timeline.lines.first?.text, "Local opening")
        XCTAssertFalse(coordinator.hasLocalOverride, "matched by tags, not bound")
    }

    /// The failure is said once, in the section that asked, in words. Every
    /// import, folder and rescan error used to be dropped with `try?`, so a
    /// file Isla could not read closed the panel and nothing happened.
    func testAnImportFailureIsReportedOnceWhereItWasAsked() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let url = root.appendingPathComponent("broken.lrc")
        try Data("[00:01.00]a\n[00:7x.00]b".utf8).write(to: url, options: .atomic)
        let revision = vm.localLyricsLibrary.revision

        vm.importLocalLyricsFile(at: url, for: nil, from: .stage)

        XCTAssertEqual(vm.lyricsNotice, NotchViewModel.LyricsNotice(
            origin: .stage, text: localized("Line %d of this file has a time Isla can't read.", 2)
        ))
        XCTAssertEqual(vm.localLyricsLibrary.revision, revision, "and nothing else: no document, no binding")

        // The next action starts clean: a good file from Settings clears it.
        vm.importLocalLyricsFile(at: try writeLRC(), for: nil, from: .settings)
        XCTAssertNil(vm.lyricsNotice)

        // Each reason in its own words, said where it was asked.
        let empty = root.appendingPathComponent("empty.lrc")
        try Data("[ti:Song]\nno stamps here".utf8).write(to: empty, options: .atomic)
        vm.importLocalLyricsFile(at: empty, for: nil, from: .settings)
        XCTAssertEqual(vm.lyricsNotice, NotchViewModel.LyricsNotice(
            origin: .settings, text: localized("This file has no timed lyrics.")
        ))
        let noise = root.appendingPathComponent("noise.lrc")
        try Data([0x98, 0x81, 0xFF]).write(to: noise, options: .atomic)
        vm.importLocalLyricsFile(at: noise, for: nil, from: .stage)
        XCTAssertEqual(vm.lyricsNotice, NotchViewModel.LyricsNotice(
            origin: .stage, text: localized("Couldn't read this file as text.")
        ))
    }

    /// A notice is about the song it was raised over. A track change takes
    /// it away, so it never sits under the next song's lyrics as if it were
    /// about that one.
    func testATrackChangeClearsTheNotice() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let url = root.appendingPathComponent("broken.lrc")
        try Data("[00:01.00]a\n[00:7x.00]b".utf8).write(to: url, options: .atomic)
        vm.importLocalLyricsFile(at: url, for: nil, from: .stage)
        XCTAssertNotNil(vm.lyricsNotice, "the fixture: a notice is up")

        vm.media.apply(playingSnapshot())
        XCTAssertNil(vm.lyricsNotice)
    }

    private func writeUntaggedLRC() throws -> URL {
        let url = root.appendingPathComponent("untagged.lrc")
        try Data("[00:01.00]Untagged opening\n[00:05.00]Second".utf8).write(to: url, options: .atomic)
        return url
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

    // MARK: - Too many requests

    /// A coordinator on a real `MediaController` whose catalogue answers with
    /// `answer`, recording every song it is asked about.
    private func limitedCoordinator(
        cache: OnlineLyricsCache? = nil,
        hold: @escaping (Int) -> TimeInterval = { _ in 0 },
        answer: @escaping (Int) -> OnlineLyrics.Outcome,
        asked: @escaping (LocalTrackIdentity) -> Void
    ) -> (LyricsCoordinator, MediaController) {
        let media = MediaController()
        var count = 0
        let coordinator = LyricsCoordinator(
            media: media, library: LocalLyricsLibrary(directory: root), isEnabled: { true },
            isOnlineEnabled: { true },
            onlineCache: cache ?? OnlineLyricsCache(directory: root),
            onlineLookUp: { identity in
                count += 1
                asked(identity)
                let held = hold(count)
                // A request on the wire for `held` seconds; a cancel ends it.
                if held > 0 { try? await Task.sleep(for: .seconds(held)) }
                return answer(count)
            }
        )
        return (coordinator, media)
    }

    private func play(_ title: String, on media: MediaController) {
        var snapshot = playingSnapshot()
        snapshot.title = title
        snapshot.takenAt = Date()
        media.apply(snapshot)
    }

    /// The catalogue's 429 is about this address, not about the song that met
    /// it, so the next song does not ask. On 2026-10-15 LRCLIB's gateway
    /// answered 429 for hours and this address was banned: every new song
    /// started again from its first request.
    func testALimitedAnswerPausesEveryLookUp() async throws {
        var calls: [LocalTrackIdentity] = []
        let (coordinator, media) = limitedCoordinator(
            answer: { _ in .limited(retryAfter: 60) }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.count, 1)

        play("Two", on: media)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.count, 1, "the second song does not ask while the service has said stop")
        XCTAssertEqual(coordinator.availability, .noLocalLyrics, "the failed state, quietly: no spinner, no new text")
    }

    /// A failed lookup retries the same song after 5 s, 30 s and 2 min. A
    /// limited one must not: that ladder was the bug, three more requests per
    /// song against a gateway that had asked for quiet.
    func testNoRetryLadderRunsWhilePaused() async throws {
        LyricsCoordinator.retryDelays = [0.05]
        defer { LyricsCoordinator.retryDelays = [5, 30, 120] }
        var calls = 0
        let (coordinator, media) = limitedCoordinator(
            answer: { _ in .limited(retryAfter: 60) }, asked: { _ in calls += 1 }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, 1, "no per-song retry while the whole client is paused")
    }

    /// The pause stops requests, not memory. A song the cache knows still
    /// shows, with no call, because nothing about it needs the service.
    func testCachedLyricsStillShowWhilePaused() async throws {
        let cache = OnlineLyricsCache(directory: root)
        let cached = LocalTrackIdentity(
            playerID: "any", title: "Cached", artist: "Artist", album: "Album", duration: 180, recordingID: nil
        )
        cache.remember(.found(LyricTimeline(
            lines: [LyricsStore.Line(at: 2, text: "From the cache", end: 5)], granularity: .line
        )), for: cached)
        var calls: [LocalTrackIdentity] = []
        let (coordinator, media) = limitedCoordinator(
            cache: cache, answer: { _ in .limited(retryAfter: 60) }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.count, 1)

        play("Cached", on: media)
        try? await Task.sleep(for: .milliseconds(100))
        guard case .ready(let timeline) = coordinator.availability else {
            return XCTFail("a remembered hit shows while the service is paused")
        }
        XCTAssertEqual(timeline.lines.first?.text, "From the cache")
        XCTAssertEqual(calls.count, 1, "and costs no request")
    }

    /// A 429 says nothing about the recording, so it is never cached: a miss
    /// remembered from it would have hidden the song's words for a fortnight.
    func testALimitedAnswerIsNeverRememberedAsAMiss() async throws {
        let cache = OnlineLyricsCache(directory: root)
        var calls = 0
        let (coordinator, media) = limitedCoordinator(
            cache: cache, answer: { _ in .limited(retryAfter: 60) }, asked: { _ in calls += 1 }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("Song", on: media)
        for _ in 0..<50 where calls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        let identity = try XCTUnwrap(coordinator.currentLocalTrackIdentity)
        XCTAssertTrue(cache.cached(identity) == nil)
    }

    /// When the pause ends the app asks about the song playing then, not the
    /// one that met the 429, and does not go back to that one. Song One is
    /// skipped during the pause; asking about it afterwards would spend the
    /// first request of a fresh window on words nobody is looking at.
    func testThePauseEndingAsksOnlyTheSongPlaying() async throws {
        var calls: [LocalTrackIdentity] = []
        let (coordinator, media) = limitedCoordinator(
            answer: { $0 == 1 ? .limited(retryAfter: 0.5) : .none }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        play("Two", on: media)
        // Long enough for a lookup Task to have started had one been made,
        // and well inside the half-second pause. Asserted at once it would
        // run before any such Task could, and pass for nothing.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.count, 1, "nothing asked during the pause")

        for _ in 0..<100 where calls.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(calls.map(\.title), ["One", "Two"], "the wake asks the song playing now")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(calls.map(\.title), ["One", "Two"], "and the song that was skipped is never asked again")
    }

    /// The pause is a time, read from the clock when a song asks: a song that
    /// starts after it has passed is asked about at once, with no wake needed.
    func testAPauseThatHasPassedLetsTheNextSongAsk() async throws {
        var skew: TimeInterval = 0
        LyricsCoordinator.now = { Date().addingTimeInterval(skew) }
        defer { LyricsCoordinator.now = { Date() } }
        var calls: [LocalTrackIdentity] = []
        let (coordinator, media) = limitedCoordinator(
            answer: { $0 == 1 ? .limited(retryAfter: 60) : .none }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        play("Two", on: media)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.count, 1)

        skew = 61
        play("Three", on: media)
        for _ in 0..<50 where calls.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.map(\.title), ["One", "Three"])
    }

    /// With no Retry-After the pause is the backoff, drawn through the
    /// coordinator's jitter seam, so a test can pin the dice.
    func testALimitedAnswerWithNoRetryAfterUsesTheBackoff() async throws {
        var drawn: [ClosedRange<Double>] = []
        LyricsCoordinator.jitter = { range in drawn.append(range); return range.upperBound }
        defer { LyricsCoordinator.jitter = { Double.random(in: $0) } }
        var calls = 0
        let (coordinator, media) = limitedCoordinator(
            answer: { _ in .limited(retryAfter: nil) }, asked: { _ in calls += 1 }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(drawn, [30...60])
    }

    /// The drawn ranges for a 429, then an answer `gap` seconds later, then
    /// another 429 with no Retry-After: what the jitter seam is asked for each.
    private func backoffDraws(answerAfter gap: TimeInterval) async throws -> [ClosedRange<Double>] {
        var skew: TimeInterval = 0
        LyricsCoordinator.now = { Date().addingTimeInterval(skew) }
        defer { LyricsCoordinator.now = { Date() } }
        var drawn: [ClosedRange<Double>] = []
        LyricsCoordinator.jitter = { range in drawn.append(range); return range.upperBound }
        defer { LyricsCoordinator.jitter = { Double.random(in: $0) } }
        var calls = 0
        let (coordinator, media) = limitedCoordinator(
            answer: { $0 == 2 ? .none : .limited(retryAfter: nil) }, asked: { _ in calls += 1 }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls < 1 { try? await Task.sleep(for: .milliseconds(10)) }
        skew = gap
        play("Two", on: media)
        for _ in 0..<50 where calls < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        play("Three", on: media)
        for _ in 0..<50 where calls < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        return drawn
    }

    /// A song the service answers about, after a quiet half hour, ends the
    /// streak: the next 429 is a first step again. Seen through the jitter
    /// seam, which is handed the range of whichever step it is.
    func testASuccessResetsTheBackoff() async throws {
        let drawn = try await backoffDraws(answerAfter: 31 * 60)
        XCTAssertEqual(drawn, [30...60, 30...60], "the second 429 is a first step again, not 60...120")
    }

    /// And an answer soon after a 429 does not: the 2026-10-15 ban let a
    /// probe through now and then, and the backoff has to keep climbing.
    func testAnAnswerSoonAfterALimitKeepsTheBackoffStreak() async throws {
        let drawn = try await backoffDraws(answerAfter: 61)
        XCTAssertEqual(drawn, [30...60, 60...120], "the second 429 continues the streak")
    }

    /// A lookup that starts after the pause has ended, by the wall clock,
    /// retires the wake. The wake runs on the continuous clock and can lag
    /// the wall clock; it used to fire into the request already on the wire,
    /// cancel it, and send it again.
    func testALookUpThatStartsAfterThePauseCancelsTheWake() async throws {
        var skew: TimeInterval = 0
        LyricsCoordinator.now = { Date().addingTimeInterval(skew) }
        defer { LyricsCoordinator.now = { Date() } }
        var calls: [LocalTrackIdentity] = []
        // Times are generous on purpose: at least half a second of slack
        // between each step, so a stalled main actor cannot fail this for a
        // reason that has nothing to do with the wake.
        let (coordinator, media) = limitedCoordinator(
            hold: { $0 == 2 ? 2.2 : 0 },
            answer: { $0 == 1 ? .limited(retryAfter: 1.0) : .none }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<100 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        // The wall clock is past the pause; the wake still has ~1 s to sleep.
        skew = 2
        play("Two", on: media)
        // 0.6 s past the moment the wake was set for, with Two's request
        // still on the wire for another 0.6 s.
        try? await Task.sleep(for: .milliseconds(1550))
        XCTAssertEqual(calls.map(\.title), ["One", "Two"], "Two is asked once, and not again by the wake")
    }

    /// A retry that was waiting when the 429 came does not become an ask. Song
    /// One's first answer fails and a retry is scheduled for 0.6 s; before it
    /// fires, Retry runs the same song's lookup again (`retry()` does not
    /// touch the pending retry), and that one meets a 429. When the old retry
    /// fires into the pause it must send nothing, and neither may a later skip.
    func testARetryScheduledBeforeA429DoesNotAsk() async throws {
        LyricsCoordinator.retryDelays = [0.6]
        defer { LyricsCoordinator.retryDelays = [5, 30, 120] }
        var calls: [LocalTrackIdentity] = []
        let (coordinator, media) = limitedCoordinator(
            answer: { $0 == 1 ? .failed : .limited(retryAfter: 60) }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<100 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        coordinator.retry()
        for _ in 0..<100 where calls.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.count, 2, "the failure, and the retry that met the 429")

        // Well past the 0.6 s the first failure's retry was waiting for.
        try? await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(calls.count, 2, "the old retry fired into the pause and asked nothing")

        play("Two", on: media)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.count, 2, "a later skip asks nothing while the pause stands")
    }

    /// A hit cached before line ends is refreshed once, in the background, and
    /// that refresh is a request like any other: not while paused. The old
    /// words stay up.
    func testAnOldHitIsNotRefreshedWhilePaused() async throws {
        let online = root.appendingPathComponent("online", isDirectory: true)
        try fileManager.createDirectory(at: online, withIntermediateDirectories: true)
        let old = LocalTrackIdentity(
            playerID: "any", title: "Cached", artist: "Artist", album: "Album", duration: 180, recordingID: nil
        )
        let oldLines = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([LyricsStore.Line(at: 2, text: "Cached before ends")])
        )
        try JSONSerialization.data(withJSONObject: [
            OnlineLyricsCache.key(old): ["lines": oldLines, "checkedAt": Date().timeIntervalSinceReferenceDate],
        ]).write(to: online.appendingPathComponent("cache.json"))
        var calls: [LocalTrackIdentity] = []
        let (coordinator, media) = limitedCoordinator(
            cache: OnlineLyricsCache(directory: online),
            answer: { _ in .limited(retryAfter: 60) }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }

        play("Cached", on: media)
        try? await Task.sleep(for: .milliseconds(150))
        guard case .ready(let shown) = coordinator.availability else {
            return XCTFail("the old hit still shows while paused")
        }
        XCTAssertEqual(shown.lines.first?.text, "Cached before ends")
        XCTAssertEqual(calls.map(\.title), ["One"], "and is not refreshed until the pause ends")
    }

    /// A moment with no length forgets the track, which cancels the wake. The
    /// next song looked up during the pause schedules it again, and the end
    /// of the pause then asks that song.
    func testAForgottenTrackRearmsTheWakeOnTheNextSong() async throws {
        var calls: [LocalTrackIdentity] = []
        let (coordinator, media) = limitedCoordinator(
            answer: { $0 == 1 ? .limited(retryAfter: 0.5) : .none }, asked: { calls.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.setActive(true)
        defer { media.setActive(false) }

        play("One", on: media)
        for _ in 0..<50 where calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        var live = playingSnapshot()
        live.title = "Radio"
        live.duration = 0
        live.takenAt = Date()
        media.apply(live)
        try? await Task.sleep(for: .milliseconds(50))
        play("Two", on: media)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.map(\.title), ["One"], "still paused")

        for _ in 0..<100 where calls.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(calls.map(\.title), ["One", "Two"], "the wake the forgotten track cancelled is back")
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
