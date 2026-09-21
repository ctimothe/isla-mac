import SwiftUI
import XCTest
@testable import IslaKit

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
        let lyrics = LyricsStore()
        lyrics.present(.ready(LyricTimeline(
            lines: [
                .init(at: 1, text: "First line"), .init(at: 4, text: "Second line"),
                .init(at: 8, text: "Third line"), .init(at: 12, text: "Fourth line"),
                .init(at: 16, text: "Fifth line"),
            ],
            granularity: .line
        )))

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

    func testStageRendersLinesFromLocalTimeline() async throws {
        let lyrics = LyricsStore()
        lyrics.present(.ready(LyricTimeline(
            lines: [
                .init(at: 1, text: "First line of the song", words: [.init(at: 1, text: "First"), .init(at: 1.5, text: "line")]),
                .init(at: 4, text: "Second line arrives", words: [.init(at: 4, text: "Second"), .init(at: 4.6, text: "line")]),
                .init(at: 8, text: "The current line sweeping now", words: [.init(at: 8, text: "The"), .init(at: 8.5, text: "current")]),
                .init(at: 12, text: "A later line waiting", words: [.init(at: 12, text: "later")]),
                .init(at: 16, text: "The final line", words: [.init(at: 16, text: "final")]),
            ],
            granularity: .word
        )))
        guard case .synced(let lines) = lyrics.state else {
            return XCTFail("local timeline did not load: \(lyrics.state)")
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
