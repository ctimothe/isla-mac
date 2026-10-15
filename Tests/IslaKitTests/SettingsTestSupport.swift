import SwiftUI
import XCTest
@testable import IslaKit

/// A Settings pane over an isolated world, on the section a test names (redesign
/// 2026-10-15, spec §10).
///
/// The pane shows one section at a time, so every test that looks for a control
/// says which section it is in. Everything the pane reads or writes that a
/// test could leak into the owner's machine is the probe's: a private defaults
/// suite for the switches, a lyric store over that suite, a hot-key centre that
/// registers nothing, an update check that cannot reach the network and a fresh
/// Automation record, so nothing a pane draws depends on what the runner's Mac
/// has granted or the owner has chosen.
@MainActor
enum SettingsFixture {
    static func pane(
        _ isolated: ProbeStores,
        section: SettingsSection,
        lyrics: LyricsStore? = nil,
        automation: AutomationAccess? = nil,
        updates: UpdateCheck? = nil,
        icons: AppIcons? = nil,
        headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight
    ) -> SettingsPane {
        let stores = isolated.stores
        let lyricStore = lyrics ?? LyricsStore(
            offsetsDirectory: isolated.temp.appendingPathComponent("settings-offsets", isDirectory: true),
            defaults: isolated.suite
        )
        return SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: lyricStore,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: updates ?? UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) }),
            automation: automation ?? AutomationAccess(),
            icons: icons ?? Self.macWithApps([:]),
            selection: .constant(section),
            headerHeight: headerHeight,
            settingsDefaults: isolated.suite
        )
    }

    /// A Mac that has exactly these apps (bundle id to the name the Finder
    /// shows), so no pane a test draws depends on what the runner has installed.
    /// No brand artwork: every icon is a blank 4 pt image.
    static func macWithApps(_ apps: [String: String]) -> AppIcons {
        AppIcons(lookups: AppIcons.Lookups(
            applicationURL: { id in apps[id].map { _ in URL(fileURLWithPath: "/Applications/\(id).app") } },
            icon: { _ in NSImage(size: NSSize(width: 4, height: 4)) },
            displayName: { url in apps[url.deletingPathExtension().lastPathComponent] ?? "?" }
        ))
    }

    /// The pane's own size in the panel at a body width: `bw − 72` wide (the
    /// rail, its gap and the padding take 72) and 348 tall in the 400 body, or
    /// the height asked for where a test wants every row on screen at once.
    static func paneSize(bodyWidth: CGFloat = 560, height: CGFloat = 348) -> CGSize {
        CGSize(width: PlayerLayout.paneWidth(bodyWidth: bodyWidth), height: height)
    }

    /// The section as an assistive client reads it, at `bodyWidth`.
    static func tree(
        _ isolated: ProbeStores, section: SettingsSection, bodyWidth: CGFloat = 560, height: CGFloat = 1400,
        lyrics: LyricsStore? = nil, automation: AutomationAccess? = nil, updates: UpdateCheck? = nil,
        icons: AppIcons? = nil
    ) async -> AXNode {
        await AXProbe.tree(
            of: pane(isolated, section: section, lyrics: lyrics, automation: automation, updates: updates, icons: icons),
            size: paneSize(bodyWidth: bodyWidth, height: height)
        )
    }
}
