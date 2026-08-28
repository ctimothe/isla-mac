import XCTest
@testable import IslaKit

/// The words stay on screen while a better source is asked for.
@MainActor
final class LyricsRetentionTests: XCTestCase {

    private func store() throws -> (LyricsStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LyricsStore(cacheDirectory: root), root)
    }

    private func writeCache(
        _ root: URL, title: String, artist: String, duration: TimeInterval
    ) throws {
        let key = LyricsStore.cacheKey(title: title, artist: artist, album: "", duration: duration)
        let cached: [String: Any] = [
            "times": [1.0, 4.0, 8.0],
            "texts": ["First line", "Second line", "Third line"],
        ]
        try JSONSerialization.data(withJSONObject: cached)
            .write(to: root.appendingPathComponent("\(key).lrc3.json"))
    }

    private func waitForSynced(_ store: LyricsStore) async -> [LyricsStore.Line]? {
        for _ in 0..<60 {
            if case .synced(let lines) = store.state { return lines }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// A Spotify track resolves twice: once on its metadata, then again when the
    /// catalogue id arrives and unlocks the word-synced source. The second pass
    /// used to set `.loading`, which emptied the caption mid-song for as long as
    /// a network round trip took — the music kept playing and the words went
    /// away. They are the same track's words either way.
    func testTheSecondLookupForTheSameTrackNeverBlanksTheFirst() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCache(root, title: "Bags", artist: "Clairo", duration: 261)

        store.load(title: "Bags", artist: "Clairo", album: "", duration: 261)
        let first = await waitForSynced(store)
        XCTAssertEqual(first?.count, 3, "the cached lyric has to load for this test to mean anything")

        // The id arrives a beat later and re-fires the load.
        store.load(title: "Bags", artist: "Clairo", album: "", duration: 261, spotifyID: "abc123")

        guard case .synced(let during) = store.state else {
            return XCTFail("the words vanished the moment a better source was asked for")
        }
        XCTAssertEqual(during.map(\.text), first?.map(\.text))
    }

    /// A different song does blank, because those words are not this song's.
    func testADifferentTrackDoesNotKeepTheLastOnesWords() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCache(root, title: "Bags", artist: "Clairo", duration: 261)

        store.load(title: "Bags", artist: "Clairo", album: "", duration: 261)
        _ = await waitForSynced(store)

        store.load(title: "Sofia", artist: "Clairo", album: "", duration: 189)
        if case .synced = store.state {
            XCTFail("one song's words must never stand in for another's")
        }
    }

    /// Clearing forgets everything, so a stale line cannot survive into the next
    /// session.
    func testClearingForgetsTheRetainedWords() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCache(root, title: "Bags", artist: "Clairo", duration: 261)

        store.load(title: "Bags", artist: "Clairo", album: "", duration: 261)
        _ = await waitForSynced(store)
        store.clear()
        XCTAssertEqual(store.state, .idle)
    }
}
