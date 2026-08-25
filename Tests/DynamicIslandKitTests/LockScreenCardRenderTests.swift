import SwiftUI
import XCTest
@testable import DynamicIslandKit

/// Renders the lock card over a stand-in wallpaper, so its glass can be judged
/// without locking the Mac — the one surface that cannot be screenshotted in
/// place, because the shield owns the screen while it is up.
@MainActor
final class LockScreenCardRenderTests: XCTestCase {
    func testCardRendersOverAWallpaper() async throws {
        let media = MediaController()
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Ripcurl - Original Mix"
        snapshot.artist = "Jesse Bru"
        snapshot.album = "Bassment"
        snapshot.duration = 423
        snapshot.elapsed = 108
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        snapshot.artwork = Self.cover()
        media.apply(snapshot)
        for _ in 0..<50 {
            if media.artwork != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let card = ZStack {
            // Something with light and dark in it, like the desk photo any
            // lock screen actually sits on.
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.29, blue: 0.36),
                    Color(red: 0.55, green: 0.62, blue: 0.66),
                    Color(red: 0.13, green: 0.17, blue: 0.22),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            LockScreenCard(media: media, lyrics: LyricsStore(cacheDirectory: root))
        }
        .frame(width: LockScreenCard.size.width + 120, height: LockScreenCard.size.height + 120)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the lock card must render")
        // The window is cut to exactly this, so the number is a contract and
        // not a detail. It grew from 222 when the card took the system's
        // layout: a header, a changing middle, transport and a foot rail.
        XCTAssertEqual(LockScreenCard.size, CGSize(width: 460, height: 300),
                       "the lock window's frame is cut from this size")

        // Artifact for eyes, not assertions.
        if let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/lock-card.png"))
        }
    }

    /// A square cover with two strong colours, so the palette has something to
    /// pull an accent from.
    private static func cover() -> Data {
        let image = NSImage(size: NSSize(width: 600, height: 600))
        image.lockFocus()
        NSColor(red: 0.10, green: 0.36, blue: 0.62, alpha: 1).drawSwatch(in: NSRect(x: 0, y: 0, width: 600, height: 600))
        NSColor(red: 0.85, green: 0.42, blue: 0.22, alpha: 1).drawSwatch(in: NSRect(x: 0, y: 0, width: 600, height: 300))
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
    }
}
