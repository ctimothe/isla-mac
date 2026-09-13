import XCTest
@testable import IslaKit

@MainActor
final class LyricsCoordinatorTests: XCTestCase {
    private final class Resolver: LyricsResolving {
        private(set) var requests: [LyricIdentity] = []

        func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
            requests.append(identity)
            return .available(
                LyricTimeline(
                    lines: [LyricsStore.Line(at: 0, text: "Opening line")],
                    granularity: .line,
                    attribution: "Licensed lyrics",
                    source: "mock",
                    matchConfidence: 1,
                    cacheExpiry: Date().addingTimeInterval(60)
                )
            )
        }
    }

    private final class SequenceResolver: LyricsResolving {
        private(set) var requests: [LyricIdentity] = []
        private var responses: [LyricsResolution]

        init(_ responses: [LyricsResolution]) {
            self.responses = responses
        }

        func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
            requests.append(identity)
            return responses.removeFirst()
        }
    }

    private final class DelayedResolver: LyricsResolving {
        private let delay: Duration
        private let result: LyricsResolution
        private(set) var completions = 0

        init(delay: Duration, result: LyricsResolution) {
            self.delay = delay
            self.result = result
        }

        func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
            try? await Task.sleep(for: delay)
            completions += 1
            return result
        }
    }

    func testPrefetchesWhenNowPlayingArrivesWithoutOpeningALyricSurface() async {
        let media = MediaController()
        let resolver = Resolver()
        let coordinator = LyricsCoordinator(media: media, resolver: resolver, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Song"
        snapshot.artist = "Artist"
        snapshot.album = "Album"
        snapshot.duration = 180
        snapshot.elapsed = 4
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.playerPID = 42
        media.apply(snapshot)

        for _ in 0..<20 where resolver.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(resolver.requests.count, 1)
        XCTAssertEqual(resolver.requests.first?.title, "Song")
        guard case .ready(let timeline) = coordinator.availability else {
            return XCTFail("a prefetched successful result should be ready, got \(coordinator.availability)")
        }
        XCTAssertEqual(timeline.lines.first?.text, "Opening line")
    }

    func testSessionStartOwnsPrefetchInsteadOfAMediaPane() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = Resolver()
        let stores = NotchStores(
            lyricsResolver: resolver,
            lyricsEnabled: { true },
            lyricsCache: LicensedLyricsCache(directory: root)
        )
        stores.start()
        defer { stores.stop() }

        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Session song"
        snapshot.artist = "Session artist"
        snapshot.duration = 120
        snapshot.elapsed = 3
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.playerPID = 12
        stores.media.apply(snapshot)

        for _ in 0..<20 where resolver.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(resolver.requests.map(\.title), ["Session song"])
        guard case .ready = stores.lyricsCoordinator.availability else {
            return XCTFail("the session should own the prefetched result")
        }
    }

    func testLatencyHarnessPublishesACachedTimelineBeforePanelOpenAndNetworkResultsUnderBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LicensedLyricsCache(directory: root)
        let media = MediaController()
        let remote = Resolver()
        let coordinator = LyricsCoordinator(
            media: media,
            resolver: CachedLyricsResolver(cache: cache, remote: remote),
            isEnabled: { true },
            cache: cache
        )
        let identity = LyricIdentity(
            playerID: "other", title: "Song", artist: "Artist", album: "Album", duration: 180
        )
        try cache.writeLicensed(timeline(), for: identity)

        coordinator.start()
        defer { coordinator.stop() }
        let cachedStart = ContinuousClock.now
        media.apply(playingSnapshot())
        XCTAssertFalse(
            LyricsPresentation.compactCaption(for: coordinator.availability, currentLine: nil).isEmpty,
            "the compact surface must have status text synchronously"
        )
        guard let cachedLatency = await waitForReady(coordinator, timeout: .milliseconds(150), from: cachedStart) else {
            return XCTFail("a valid local cache entry must become ready before the panel opens")
        }
        XCTAssertLessThan(cachedLatency, .milliseconds(150))
        XCTAssertTrue(remote.requests.isEmpty, "a valid local cache result must not leave the Mac")

        let networkMedia = MediaController()
        let network = DelayedResolver(delay: .milliseconds(45), result: .available(timeline()))
        let networkCoordinator = LyricsCoordinator(
            media: networkMedia, resolver: network, isEnabled: { true }
        )
        networkCoordinator.start()
        defer { networkCoordinator.stop() }
        networkMedia.apply(playingSnapshot())

        let firstNetworkStart = ContinuousClock.now
        guard let firstNetworkLatency = await waitForReady(
            networkCoordinator, timeout: .seconds(2), from: firstNetworkStart
        ) else {
            return XCTFail("the first validated network result must arrive within two seconds")
        }
        var samples: [Duration] = [firstNetworkLatency]
        for completion in 2...20 {
            let start = ContinuousClock.now
            networkCoordinator.retry()
            guard let latency = await waitForCompletions(
                network, count: completion, timeout: .seconds(2), from: start
            ) else {
                return XCTFail("a validated network result must arrive within two seconds")
            }
            samples.append(latency)
        }
        let p95 = samples.sorted()[Int((Double(samples.count) * 0.95).rounded(.up)) - 1]
        XCTAssertLessThan(p95, .seconds(2), "mocked broker p95 must retain the two-second budget")
    }

    func testMetadataEnrichmentKeepsTheCurrentRequestAndEnrichesRetry() async {
        let media = MediaController()
        let resolver = Resolver()
        let coordinator = LyricsCoordinator(media: media, resolver: resolver, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        media.apply(playingSnapshot())
        for _ in 0..<20 where resolver.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        media.setSpotifyMetadataForTests(
            trackID: "spotify-track", isrc: "US-TEST-26-00001", exactDuration: 180.6
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(resolver.requests.count, 1, "metadata enrichment must not restart a viable lookup")
        guard case .ready = coordinator.availability else {
            return XCTFail("metadata enrichment must not blank the shown lyrics")
        }

        coordinator.retry()
        for _ in 0..<20 where resolver.requests.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(resolver.requests.count, 2)
        XCTAssertEqual(resolver.requests[1].spotifyID, "spotify-track")
        XCTAssertEqual(resolver.requests[1].isrc, "US-TEST-26-00001")
        XCTAssertEqual(resolver.requests[1].duration, 180.6)
    }

    func testNewTrackDoesNotCarryDepartedCatalogueMetadataIntoItsFirstRequest() async {
        let media = MediaController()
        let resolver = Resolver()
        let coordinator = LyricsCoordinator(media: media, resolver: resolver, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        media.apply(playingSnapshot())
        for _ in 0..<20 where resolver.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        media.setSpotifyMetadataForTests(
            trackID: "departed-track", isrc: "US-TEST-26-00001", exactDuration: 180.6
        )

        var next = playingSnapshot()
        next.title = "Next song"
        media.apply(next)
        for _ in 0..<20 where resolver.requests.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(resolver.requests.count, 2)
        XCTAssertEqual(resolver.requests[1].title, "Next song")
        XCTAssertNil(resolver.requests[1].spotifyID)
        XCTAssertNil(resolver.requests[1].isrc)
        XCTAssertEqual(resolver.requests[1].duration, 180)
    }

    func testPublishesAvailabilityToEveryLyricSurfaceStore() async {
        let media = MediaController()
        let resolver = Resolver()
        let presentation = LyricsStore()
        let coordinator = LyricsCoordinator(
            media: media, resolver: resolver, isEnabled: { true }, presentation: presentation
        )
        coordinator.start()
        defer { coordinator.stop() }

        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Shared song"
        snapshot.artist = "Shared artist"
        snapshot.duration = 180
        snapshot.elapsed = 1
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.playerPID = 90
        media.apply(snapshot)

        for _ in 0..<20 {
            if case .ready = presentation.availability { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        guard case .ready(let timeline) = presentation.availability else {
            return XCTFail("the shared lyric presentation should receive the ready state")
        }
        XCTAssertEqual(timeline.lines.map(\.text), ["Opening line"])
    }

    func testEveryAvailabilityHasACompactCaption() {
        let timeline = LyricTimeline(
            lines: [LyricsStore.Line(at: 0, text: "Current line")],
            granularity: .line,
            attribution: "Licensed lyrics",
            source: "mock",
            matchConfidence: 1,
            cacheExpiry: Date().addingTimeInterval(60)
        )
        let states: [LyricsAvailability] = [
            .disabled,
            .settlingPlayback,
            .resolving,
            .ready(timeline),
            .unavailable,
            .failed(LyricsFailure(kind: .connection, retryable: true)),
        ]

        for state in states {
            XCTAssertFalse(
                LyricsPresentation.compactCaption(for: state, currentLine: "Current line").isEmpty,
                "\(state) must never leave the compact lyric caption blank"
            )
        }
        XCTAssertTrue(
            LyricsPresentation.canRetry(.ready(timeline)),
            "the persistent stage retry must remain available for a shown timeline"
        )
    }

    func testOnlyMeasuredWordTimelinesMayUseAWordSweep() {
        let timeline = LyricTimeline(
            lines: [LyricsStore.Line(at: 0, text: "Current line")],
            granularity: .word,
            attribution: "Licensed lyrics",
            source: "mock",
            matchConfidence: 1,
            cacheExpiry: Date().addingTimeInterval(60)
        )
        let presentation = LyricsStore()
        presentation.present(.ready(timeline))

        XCTAssertEqual(presentation.timingGranularity, .word)
        XCTAssertFalse(
            LyricsPresentation.usesWordTiming(
                presentation.timingGranularity, precisionMeasured: false
            ),
            "a browser or other unmeasured player must never fake a word sweep"
        )
        XCTAssertTrue(
            LyricsPresentation.usesWordTiming(
                presentation.timingGranularity, precisionMeasured: true
            )
        )
    }

    func testRetryFromUnavailableStartsANewResolution() async {
        let media = MediaController()
        let resolver = SequenceResolver([.unavailable, .available(timeline())])
        let coordinator = LyricsCoordinator(media: media, resolver: resolver, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        media.apply(playingSnapshot())

        for _ in 0..<20 {
            if case .unavailable = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        coordinator.retry()
        for _ in 0..<20 {
            if case .ready = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(resolver.requests.count, 2)
        guard case .ready = coordinator.availability else {
            return XCTFail("retry should replace unavailable with the new result")
        }
    }

    func testRetryFromRetryableFailureStartsANewResolution() async {
        let media = MediaController()
        let resolver = SequenceResolver([
            .failed(LyricsFailure(kind: .connection, retryable: true)),
            .available(timeline()),
        ])
        let coordinator = LyricsCoordinator(media: media, resolver: resolver, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        media.apply(playingSnapshot())

        for _ in 0..<20 {
            if case .failed = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        coordinator.retry()
        for _ in 0..<20 {
            if case .ready = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(resolver.requests.count, 2)
        guard case .ready = coordinator.availability else {
            return XCTFail("retry should replace a retryable failure with the new result")
        }
    }

    func testRetryNeverReplacesAShownTimelineWithALowerConfidenceMatch() async {
        let media = MediaController()
        let resolver = SequenceResolver([
            .available(timeline(text: "Trusted line", confidence: 0.99)),
            .available(timeline(text: "Weaker line", confidence: 0.9)),
        ])
        let coordinator = LyricsCoordinator(media: media, resolver: resolver, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }
        media.apply(playingSnapshot())
        for _ in 0..<20 {
            if case .ready = coordinator.availability { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        coordinator.retry()
        try? await Task.sleep(for: .milliseconds(30))

        guard case .ready(let timeline) = coordinator.availability else {
            return XCTFail("the existing trusted timeline should stay visible")
        }
        XCTAssertEqual(timeline.lines.map(\.text), ["Trusted line"])
        XCTAssertEqual(resolver.requests.count, 2)
    }

    func testImportingLocalLRCReplacesTheCurrentTimelineWithoutANetworkRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaController()
        let remote = Resolver()
        let cache = LicensedLyricsCache(directory: root)
        let coordinator = LyricsCoordinator(
            media: media,
            resolver: CachedLyricsResolver(cache: cache, remote: remote),
            isEnabled: { true },
            presentation: LyricsStore(),
            cache: cache
        )
        coordinator.start()
        defer { coordinator.stop() }

        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Local song"
        snapshot.artist = "Local artist"
        snapshot.duration = 100
        snapshot.elapsed = 1
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.playerPID = 90
        media.apply(snapshot)
        for _ in 0..<20 where remote.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        try coordinator.importLocalOverride("[00:03.00]Local line")
        for _ in 0..<20 {
            if case .ready(let timeline) = coordinator.availability, timeline.source == "local" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        guard case .ready(let timeline) = coordinator.availability else {
            return XCTFail("the imported local override should be ready")
        }
        XCTAssertEqual(timeline.lines.map(\.text), ["Local line"])
        XCTAssertTrue(coordinator.hasLocalOverride)
        XCTAssertEqual(remote.requests.count, 1)
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
        snapshot.playerPID = 42
        return snapshot
    }

    private func timeline(text: String = "Opening line", confidence: Double = 1) -> LyricTimeline {
        LyricTimeline(
            lines: [LyricsStore.Line(at: 0, text: text)],
            granularity: .line,
            attribution: "Licensed lyrics",
            source: "mock",
            matchConfidence: confidence,
            cacheExpiry: Date().addingTimeInterval(60)
        )
    }

    private func waitForReady(
        _ coordinator: LyricsCoordinator, timeout: Duration, from start: ContinuousClock.Instant
    ) async -> Duration? {
        let clock = ContinuousClock()
        let deadline = start.advanced(by: timeout)
        while clock.now < deadline {
            if case .ready = coordinator.availability {
                return start.duration(to: clock.now)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func waitForCompletions(
        _ resolver: DelayedResolver, count: Int, timeout: Duration, from start: ContinuousClock.Instant
    ) async -> Duration? {
        let clock = ContinuousClock()
        let deadline = start.advanced(by: timeout)
        while clock.now < deadline {
            if resolver.completions >= count {
                return start.duration(to: clock.now)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}
