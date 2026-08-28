import SwiftUI
import XCTest
@testable import IslaKit

/// Every pane draws inside the one fixed card, and the card is the size the
/// lock window is cut to.
@MainActor
final class LockCardRenderTests: XCTestCase {
    /// Renders each pane for real — store, sweep, palette, layout — and holds
    /// them all to the same box.
    ///
    /// The window above the login shield is cut to `LockScreenCard.size` and is
    /// never resized, so a pane that asked for more room would simply be cut
    /// off there with nothing to say so. Set `SHOT_OUT` to keep the render.
    func testEveryPaneFitsTheFixedCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults.standard
        // Solid for the photograph only. The glass style puts an
        // NSVisualEffectView behind the card, and ImageRenderer cannot snapshot
        // an AppKit view — it substitutes a prohibition glyph across the whole
        // surface. That is the harness, not the card.
        let hadStyle = defaults.object(forKey: NotchViewModel.lockCardStyleKey)
        defaults.set(NotchViewModel.LockCardStyle.solid.rawValue, forKey: NotchViewModel.lockCardStyleKey)
        defer {
            if let hadStyle { defaults.set(hadStyle, forKey: NotchViewModel.lockCardStyleKey) }
            else { defaults.removeObject(forKey: NotchViewModel.lockCardStyleKey) }
        }
        let had = defaults.object(forKey: NotchViewModel.showLyricsKey)
        defaults.set(true, forKey: NotchViewModel.showLyricsKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.showLyricsKey) }
            else { defaults.removeObject(forKey: NotchViewModel.showLyricsKey) }
        }

        let lyrics = LyricsStore(cacheDirectory: root)
        let key = LyricsStore.cacheKey(title: "Test Song", artist: "Test Artist", album: "", duration: 240)
        try JSONSerialization.data(withJSONObject: [
            "times": [2.0, 12.0, 22.0, 32.0, 42.0, 52.0, 62.0],
            "texts": [
                "The line the song already passed",
                "The line just before this one",
                "The line being sung right now",
                "The line that comes next",
                "And the one after that",
                "Something further along",
                "The last one here",
            ],
        ]).write(to: root.appendingPathComponent("\(key).lrc3.json"))
        lyrics.load(title: "Test Song", artist: "Test Artist", album: "", duration: 240)
        for _ in 0..<60 {
            if case .synced = lyrics.state { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let media = MediaController()
        var snap = NowPlayingFeed.Snapshot()
        snap.title = "Test Song"; snap.artist = "Test Artist"; snap.album = ""
        snap.duration = 240; snap.elapsed = 26; snap.rate = 1; snap.isPlaying = true
        snap.takenAt = Date(); snap.playerPID = 4242
        let cover = NSImage(size: NSSize(width: 400, height: 400))
        cover.lockFocus()
        NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.36, alpha: 1),
                   ending: NSColor(calibratedRed: 0.85, green: 0.28, blue: 0.42, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 400, height: 400), angle: 45)
        cover.unlockFocus()
        snap.artwork = NSBitmapImageRep(data: cover.tiffRepresentation!)!
            .representation(using: .png, properties: [:])
        media.apply(snap)
        for _ in 0..<60 {
            if media.artwork != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        for pane in LockScreenCard.Pane.allCases {
            let renderer = ImageRenderer(
                content: LockScreenCard(media: media, lyrics: lyrics, initialPane: pane)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.nsImage, "\(pane.rawValue) must render")
            XCTAssertEqual(
                image.size, LockScreenCard.size,
                "the \(pane.rawValue) pane changed the card's size; the lock window cannot follow it"
            )
        }

        // Optional artifact for eyes, not assertions.
        if let path = ProcessInfo.processInfo.environment["SHOT_OUT"] {
            let sheet = ImageRenderer(content: Sheet(media: media, lyrics: lyrics))
            sheet.scale = 2
            if let image = sheet.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path))
                print("SHOT written to \(path)")
            }
        }
    }
}

private struct Sheet: View {
    let media: MediaController
    let lyrics: LyricsStore

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.17),
                         Color(red: 0.26, green: 0.15, blue: 0.23),
                         Color(red: 0.52, green: 0.29, blue: 0.23)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 26) {
                ForEach(LockScreenCard.Pane.allCases, id: \.rawValue) { pane in
                    VStack(spacing: 10) {
                        LockScreenCard(media: media, lyrics: lyrics, initialPane: pane)
                        Text(pane.rawValue.uppercased()).tracking(2)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .frame(width: 1520, height: 400)
    }
}
