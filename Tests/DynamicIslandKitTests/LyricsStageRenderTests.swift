import SwiftUI
import XCTest
@testable import DynamicIslandKit

/// Renders the lyrics stage offscreen with a fabricated track and word-synced
/// lines, so the view is exercised end to end — store, sweep math, layout —
/// without a signed-in player or a pointer.
@MainActor
final class LyricsStageRenderTests: XCTestCase {
    func testStageRendersLinesFromTheCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lyrics = LyricsStore(cacheDirectory: root)

        // A cached word-synced payload, planted where the store will find it.
        let key = LyricsStore.cacheKey(title: "Test Song", artist: "Test Artist", album: "", duration: 180)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cached: [String: Any] = [
            "times": [1.0, 4.0, 8.0, 12.0, 16.0],
            "texts": ["First line of the song", "Second line arrives", "The current line sweeping now", "A later line waiting", "The final line"],
            "wordTimes": [[1.0, 1.5], [4.0, 4.6], [8.0, 8.5, 9.0, 9.5], [12.0], [16.0]],
            "wordTexts": [["First line", " of the song"], ["Second", " line arrives"], ["The", " current", " line", " sweeping now"], ["A later line waiting"], ["The final line"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: cached)
        try data.write(to: root.appendingPathComponent("\(key).lrc2.json"))

        lyrics.load(title: "Test Song", artist: "Test Artist", album: "", duration: 180)
        // The cache read hops off the main actor; give it a beat.
        for _ in 0..<50 {
            if case .synced = lyrics.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .synced(let lines) = lyrics.state else {
            return XCTFail("cached lyrics did not load: \(lyrics.state)")
        }
        XCTAssertEqual(lines.count, 5)

        // A controller mid-song, driven through the same entry point the feed
        // uses, so `position` sits inside the third line.
        let media = MediaController()
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.duration = 180
        snapshot.elapsed = 9.2
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        media.apply(snapshot)

        let stage = LyricsStage(media: media, lyrics: lyrics, dismiss: {})
            .frame(width: 620, height: 208)
            .background(Color.black)
        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        let image = renderer.nsImage
        XCTAssertNotNil(image, "the stage must render")

        // Artifact for eyes, not assertions.
        if let image, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let out = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-ctimothe-code-projects-dynamic-island/518a0e07-9288-4a58-8703-b43facaf658f/scratchpad/stage_render.png")
            try? png.write(to: out)
        }
    }
}
