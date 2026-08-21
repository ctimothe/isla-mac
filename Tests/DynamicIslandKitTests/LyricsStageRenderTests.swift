import SwiftUI
import XCTest
@testable import DynamicIslandKit

/// Renders the lyrics stage offscreen with a fabricated track and word-synced
/// lines, so the view is exercised end to end — store, sweep math, layout —
/// without a signed-in player or a pointer.
@MainActor
final class LyricsStageRenderTests: XCTestCase {
    /// The stage must never ask for more height than the body it is given.
    ///
    /// The island's body is 162 pt of content on an ordinary tab. The stage
    /// centres the sung line in the height it believes it has, so a stage that
    /// reports a taller box draws the current line *below the visible edge*:
    /// every line on screen is then one the song has already passed, and
    /// clicking any of them seeks backwards. Square cover art is what did it —
    /// filled to the pane's width it is as tall as it is wide, and a ZStack
    /// takes the tallest child however hard the drawing is clipped afterwards.
    func testStageDoesNotOutgrowItsBodyWhenTheCoverIsSquare() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lyrics = LyricsStore(cacheDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = LyricsStore.cacheKey(title: "Test Song", artist: "Test Artist", album: "", duration: 180)
        let cached: [String: Any] = [
            "times": [1.0, 4.0, 8.0, 12.0, 16.0],
            "texts": ["First line", "Second line", "Third line", "Fourth line", "Fifth line"],
        ]
        try JSONSerialization.data(withJSONObject: cached)
            .write(to: root.appendingPathComponent("\(key).lrc2.json"))
        lyrics.load(title: "Test Song", artist: "Test Artist", album: "", duration: 180)
        for _ in 0..<50 {
            if case .synced = lyrics.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }

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
        // A square cover, which is what every player publishes.
        let cover = NSImage(size: NSSize(width: 600, height: 600))
        cover.lockFocus()
        NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 600, height: 600))
        cover.unlockFocus()
        snapshot.artwork = NSBitmapImageRep(data: cover.tiffRepresentation!)!
            .representation(using: .png, properties: [:])
        media.apply(snapshot)
        for _ in 0..<50 {
            if media.artwork != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(media.artwork, "the cover must be decoded for this test to mean anything")

        let body = CGSize(width: 504, height: 162)
        let host = NSHostingController(rootView: LyricsStage(media: media, lyrics: lyrics, dismiss: {}))
        let wanted = host.sizeThatFits(in: body)
        XCTAssertLessThanOrEqual(
            wanted.height, body.height,
            "the stage asked for \(wanted.height) pt inside a \(body.height) pt body: the sung line lands below the visible edge"
        )
    }

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
