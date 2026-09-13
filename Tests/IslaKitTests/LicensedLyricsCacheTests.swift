import XCTest
@testable import IslaKit

final class LicensedLyricsCacheTests: XCTestCase {
    private let identity = LyricIdentity(
        playerID: "music",
        title: "Song",
        artist: "Artist",
        album: "Album",
        duration: 180,
        locale: "en"
    )

    @MainActor
    func testExpiredLicensedEntryIsNotReturnedAndIsPruned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LicensedLyricsCache(directory: root)
        let timeline = LyricTimeline(
            lines: [LyricsStore.Line(at: 1, text: "Expired")],
            granularity: .line,
            attribution: "Provider",
            source: "licensed",
            matchConfidence: 1,
            cacheExpiry: Date().addingTimeInterval(-1)
        )
        try cache.writeLicensed(timeline, for: identity)

        XCTAssertNil(cache.read(for: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.licensedURL(for: identity).path))
    }

    @MainActor
    func testLocalOverrideWinsUntilRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LicensedLyricsCache(directory: root)
        let licensed = LyricTimeline(
            lines: [LyricsStore.Line(at: 1, text: "Licensed")],
            granularity: .line,
            attribution: "Provider",
            source: "licensed",
            matchConfidence: 1,
            cacheExpiry: Date().addingTimeInterval(60)
        )
        try cache.writeLicensed(licensed, for: identity)
        try cache.writeLocalOverride("[00:02.00]Local line", for: identity)

        XCTAssertEqual(cache.read(for: identity)?.lines.map(\.text), ["Local line"])

        try cache.removeLocalOverride(for: identity)
        XCTAssertEqual(cache.read(for: identity)?.lines.map(\.text), ["Licensed"])
    }

    @MainActor
    func testLocalOverrideKeepsItsStableKeyAfterMetadataEnrichment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LicensedLyricsCache(directory: root)
        try cache.writeLocalOverride("[00:01.00]Local line", for: identity)

        let enriched = identity.enriched(
            spotifyID: "spotify-track", isrc: "US-TEST-26-00001", exactDuration: 180.6
        )

        XCTAssertEqual(cache.read(for: enriched)?.source, "local")
        XCTAssertTrue(cache.hasLocalOverride(for: enriched))
    }

    @MainActor
    func testLocalOverridePreventsAnOutboundResolution() async throws {
        final class Remote: LyricsResolving {
            private(set) var calls = 0

            func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
                calls += 1
                return .unavailable
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LicensedLyricsCache(directory: root)
        try cache.writeLocalOverride("[00:02.00]Private local line", for: identity)
        let remote = Remote()
        let resolver = CachedLyricsResolver(cache: cache, remote: remote)

        let resolution = await resolver.resolve(identity)

        guard case .available(let timeline) = resolution else {
            return XCTFail("a local override must resolve without a network result")
        }
        XCTAssertEqual(timeline.source, "local")
        let calls = remote.calls
        XCTAssertEqual(calls, 0)
    }
}
