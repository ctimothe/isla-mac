import SwiftUI
import XCTest
@testable import IslaKit

/// The glass card lit by its cover, rendered for real.
///
/// With a cover, the glass style no longer lays window vibrancy underneath —
/// the cover is the light — so ImageRenderer can photograph it, which the
/// solid-only harness could not. Set `COVER_IN` to a square image and
/// `SHOT_GLASS_OUT` to a path to keep the photograph.
@MainActor
final class LockCardCoverLightTests: XCTestCase {
    func testTheGlassCardRendersLitByItsCover() async throws {
        let defaults = UserDefaults.standard
        let hadStyle = defaults.object(forKey: NotchViewModel.lockCardStyleKey)
        defaults.set(NotchViewModel.LockCardStyle.glass.rawValue, forKey: NotchViewModel.lockCardStyleKey)
        defer {
            if let hadStyle { defaults.set(hadStyle, forKey: NotchViewModel.lockCardStyleKey) }
            else { defaults.removeObject(forKey: NotchViewModel.lockCardStyleKey) }
        }

        let media = MediaController()
        media.isolateFromPlayers()
        var snap = NowPlayingFeed.Snapshot()
        snap.title = "Waiting Room"; snap.artist = "Phoebe Bridgers"; snap.album = "Lost Ark Studio Vol. 08"
        snap.duration = 238; snap.elapsed = 84; snap.rate = 1; snap.isPlaying = true
        snap.takenAt = Date(); snap.playerPID = 4242
        if let path = ProcessInfo.processInfo.environment["COVER_IN"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            snap.artwork = data
        } else {
            let cover = NSImage(size: NSSize(width: 300, height: 300))
            cover.lockFocus()
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?
                .draw(in: NSRect(x: 0, y: 0, width: 300, height: 300), angle: 60)
            cover.unlockFocus()
            snap.artwork = NSBitmapImageRep(data: cover.tiffRepresentation!)!
                .representation(using: .png, properties: [:])
        }
        media.apply(snap)
        for _ in 0..<80 where media.artwork == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(media.artwork, "the fixture: a cover to light the card")

        let lyrics = LyricsStore()
        lyrics.present(.ready(LyricTimeline(
            lines: [
                .init(at: 60, text: "I get up, get dressed and get out"),
                .init(at: 70, text: "Walk the length of the block and back"),
                .init(at: 80, text: "Sit in the waiting room again"),
                .init(at: 90, text: "Wondering if it's all in my head"),
                .init(at: 100, text: "And the line that comes after that"),
            ],
            granularity: .line
        )))

        for pane in [LockScreenCard.Pane.player, .lyrics] {
            let renderer = ImageRenderer(content: LockScreenCard(media: media, lyrics: lyrics, initialPane: pane))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.nsImage, "\(pane.rawValue) must render")
            XCTAssertEqual(image.size, LockScreenCard.size)
        }

        if let out = ProcessInfo.processInfo.environment["SHOT_GLASS_OUT"] {
            let sheet = ImageRenderer(content: CoverSheet(media: media, lyrics: lyrics))
            sheet.scale = 2
            if let image = sheet.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: out))
                print("SHOT written to \(out)")
            }
        }
    }
}

private struct CoverSheet: View {
    let media: MediaController
    let lyrics: LyricsStore

    var body: some View {
        ZStack {
            // A lock-screen wallpaper's kind of light, for the photograph.
            LinearGradient(
                colors: [Color(red: 0.55, green: 0.58, blue: 0.66), Color(red: 0.36, green: 0.38, blue: 0.47)],
                startPoint: .top, endPoint: .bottom)
            HStack(spacing: 40) {
                LockScreenCard(media: media, lyrics: lyrics, initialPane: .player)
                LockScreenCard(media: media, lyrics: lyrics, initialPane: .lyrics)
            }
        }
        .frame(width: 1080, height: 400)
    }
}
