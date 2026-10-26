import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Every page's header glyph and every tool beside one another on the
/// panel's black (`HeaderIcon`, spec §19.8, amended 2026-10-26), so the one
/// size can be judged in one picture rather than across five. The playing
/// app is Spotify's icon read from its bundle when it is installed, else
/// Music's: an icon is read from disk, and no app is launched.
@MainActor
final class VisualLabHeaderIconsTests: VisualLabCase {
    private static func appIcon() -> (String, NSImage) {
        let spotify = "/Applications/Spotify.app"
        if FileManager.default.fileExists(atPath: spotify) {
            return ("Spotify", NSWorkspace.shared.icon(forFile: spotify))
        }
        return ("Music", NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app"))
    }

    private static func sheet() -> some View {
        let (name, icon) = appIcon()
        let row: CGFloat = 38
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 22) {
                SurfaceHeaderTitle(glyph: .app(icon), title: name)
                SurfaceHeaderTitle(glyph: .symbol("music.note"), title: localized("Music"))
                SurfaceHeaderTitle(glyph: .symbol("tray.full.fill"), title: "4")
                SurfaceHeaderTitle(symbol: "list.clipboard.fill", title: localized("Clipboard"))
            }
            .frame(height: row)
            HStack(spacing: 22) {
                SurfaceHeaderTitle(symbol: "character.bubble.fill", title: localized("Translate"))
                SurfaceHeaderTitle(symbol: "gearshape.fill", title: localized("Settings"))
            }
            .frame(height: row)
            HStack(spacing: 8) {
                HeaderToolButton(symbol: "gearshape", label: "Settings") {}
                HeaderToolButton(symbol: "xmark", label: "Close Settings") {}
                HeaderToolButton(symbol: "clock.arrow.circlepath", label: "History", isOn: true) {}
                ShelfRemoveAllButton {}
                IconWordButton(symbol: "doc.on.clipboard", word: localized("Paste")) {}
            }
            .frame(height: row)
            HStack(spacing: 6) {
                HeaderIconButton(symbol: "ellipsis", label: "More") {}
                HeaderIconButton(symbol: "speaker.wave.2", label: "Output") {}
                HeaderIconButton(symbol: "quote.bubble.fill", label: "Hide Lyrics", isOn: true) {}
                HeaderIconButton(symbol: "arrow.left.arrow.right", label: "Swap") {}
                HeaderIconButton(symbol: "speaker.wave.2.fill", label: "Speak") {}
                HeaderIconButton(symbol: "doc.on.doc", label: "Copy") {}
            }
            .frame(height: row)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(width: 560, height: 4 * row + 16, alignment: .topLeading)
        .background(Color.black)
    }

    func testHeaderIcons() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "header-icons")
        try await shoot.shoot("one-size", variants: [.base, .russian], size: CGSize(width: 560, height: 4 * 38 + 16)) { _ in
            AnyView(Self.sheet())
        }
    }
}
