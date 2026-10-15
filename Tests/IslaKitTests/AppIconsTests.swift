import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Music apps show their real icons, everywhere the app names one.
///
/// Settings drew its own Spotify disc and it read as a fake; the owner wants
/// the icons of the apps on his Mac. These tests hold the lookup, the cache,
/// the order and the optical size with injected lookups: nothing here depends
/// on which apps the machine running them has installed, and no brand's
/// artwork is read from anywhere.
@MainActor
final class AppIconsTests: XCTestCase {
    /// A Mac with exactly the apps in `installed` (bundle id -> Finder name),
    /// counting every question put to it.
    private final class FakeMac {
        var installed: [String: String]
        var urlAsks = 0, iconAsks = 0, nameAsks = 0
        init(_ installed: [String: String]) { self.installed = installed }

        func url(for id: String) -> URL? {
            installed[id].map { _ in URL(fileURLWithPath: "/Applications/\(id).app") }
        }
        var lookups: AppIcons.Lookups {
            AppIcons.Lookups(
                applicationURL: { [self] in self.urlAsks += 1; return self.url(for: $0) },
                icon: { [self] _ in self.iconAsks += 1; return NSImage(size: NSSize(width: 4, height: 4)) },
                displayName: { [self] url in
                    self.nameAsks += 1
                    return self.installed[url.deletingPathExtension().lastPathComponent] ?? "?"
                }
            )
        }
    }

    private func installed(_ id: String, _ name: String) -> AppIcons.Installed {
        AppIcons.Installed(
            bundleID: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), name: name,
            icon: NSImage(size: NSSize(width: 4, height: 4))
        )
    }

    // MARK: - The lookup

    func testAnInstalledAppIsFoundWithItsFinderNameAndIcon() throws {
        let mac = FakeMac(["ru.yandex.desktop.music": "Яндекс Музыка"])
        let icons = AppIcons(lookups: mac.lookups)
        let app = try XCTUnwrap(icons.app("ru.yandex.desktop.music"))
        XCTAssertEqual(app.name, "Яндекс Музыка", "the owner sees the Finder's name, not the bundle id")
        XCTAssertEqual(app.url, URL(fileURLWithPath: "/Applications/ru.yandex.desktop.music.app"))
        XCTAssertEqual(app.icon.size, NSSize(width: 4, height: 4))
        XCTAssertNotNil(icons.icon("ru.yandex.desktop.music"))
    }

    func testAnAppThatIsNotInstalledHasNoIconAndNoName() {
        let icons = AppIcons(lookups: FakeMac([:]).lookups)
        XCTAssertNil(icons.app("com.spotify.client"))
        XCTAssertNil(icons.icon("com.spotify.client"), "the caller draws its fallback")
    }

    /// Apple Music is «Music» on disk and «Музыка» on a Russian Mac; every other
    /// line of Isla says Apple Music, and one app must not carry two names on a
    /// screen.
    func testTheTwoPlayersIslaDrivesKeepIslasNames() throws {
        let mac = FakeMac(["com.apple.Music": "Музыка", "com.spotify.client": "Spotify"])
        let icons = AppIcons(lookups: mac.lookups)
        XCTAssertEqual(try XCTUnwrap(icons.app("com.apple.Music")).name, "Apple Music")
        XCTAssertEqual(try XCTUnwrap(icons.app("com.spotify.client")).name, "Spotify")
        XCTAssertEqual(mac.nameAsks, 0, "a name Isla already has is not looked up")
    }

    func testAFinderNameKeepsNoAppExtension() {
        XCTAssertEqual(AppIcons.cleaned("Yandex Music.app"), "Yandex Music")
        XCTAssertEqual(AppIcons.cleaned("Яндекс Музыка"), "Яндекс Музыка")
        XCTAssertEqual(AppIcons.cleaned("Tidal"), "Tidal")
    }

    // MARK: - The cache

    /// LaunchServices is an IPC; a body that redraws must not make it each time.
    func testEachAppIsAskedAboutOncePerRefresh() {
        let mac = FakeMac(["com.tidal.desktop": "TIDAL"])
        let icons = AppIcons(lookups: mac.lookups)
        for _ in 0..<50 { _ = icons.app("com.tidal.desktop") }
        XCTAssertEqual(mac.urlAsks, 1)
        XCTAssertEqual(mac.iconAsks, 1)
        XCTAssertEqual(mac.nameAsks, 1)
    }

    /// "Not installed" is the common answer and costs the same IPC to learn.
    func testNotInstalledIsRememberedToo() {
        let mac = FakeMac([:])
        let icons = AppIcons(lookups: mac.lookups)
        for _ in 0..<50 { _ = icons.app("com.deezer.deezer-desktop") }
        XCTAssertEqual(mac.urlAsks, 1)
    }

    /// An app installed or removed while Isla runs shows up at the next
    /// refresh, and not before.
    func testRefreshForgetsEverythingAndSeesANewInstall() {
        let mac = FakeMac([:])
        let icons = AppIcons(lookups: mac.lookups)
        XCTAssertNil(icons.app("com.deezer.deezer-desktop"))
        mac.installed["com.deezer.deezer-desktop"] = "Deezer"
        XCTAssertNil(icons.app("com.deezer.deezer-desktop"), "still the old answer until a refresh")
        let before = icons.generation
        icons.refresh()
        XCTAssertEqual(icons.generation, before + 1, "observing views redraw")
        XCTAssertEqual(icons.app("com.deezer.deezer-desktop")?.name, "Deezer")
        mac.installed.removeValue(forKey: "com.deezer.deezer-desktop")
        icons.refresh()
        XCTAssertNil(icons.app("com.deezer.deezer-desktop"), "and a removal")
    }

    func testInstalledKeepsTheOrderGivenAndSkipsWhatIsMissing() {
        let icons = AppIcons(lookups: FakeMac(["a": "A", "c": "C"]).lookups)
        XCTAssertEqual(icons.installed(["c", "b", "a"]).map(\.bundleID), ["c", "a"])
    }

    // MARK: - Which players, in what order

    /// Apple Music, Spotify, then the rest by the name the person sees — in
    /// Finder order, so a Cyrillic name sorts among the Cyrillic ones and
    /// "Deezer" is not after "Yandex".
    func testPlayersAreAppleMusicThenSpotifyThenTheRestByName() {
        let shuffled = [
            installed("ru.yandex.desktop.music", "Яндекс Музыка"),
            installed("com.tidal.desktop", "TIDAL"),
            installed("com.spotify.client", "Spotify"),
            installed("com.deezer.deezer-desktop", "Deezer"),
            installed("com.apple.Music", "Apple Music"),
            installed("ru.keepcoder.Telegram", "Telegram"),
        ]
        XCTAssertEqual(
            AppIcons.order(shuffled).map(\.name),
            ["Apple Music", "Spotify", "Deezer", "Telegram", "TIDAL", "Яндекс Музыка"]
        )
        XCTAssertEqual(AppIcons.order(shuffled.reversed()).map(\.name), AppIcons.order(shuffled).map(\.name), "stable")
    }

    func testSpotifyLeadsWhenAppleMusicIsNotInstalled() {
        let apps = [installed("com.deezer.deezer-desktop", "Deezer"), installed("com.spotify.client", "Spotify")]
        XCTAssertEqual(AppIcons.order(apps).map(\.name), ["Spotify", "Deezer"])
    }

    /// Both Telegram builds are different apps; on a Mac that has both they get
    /// a row each, in a stable order.
    func testBothTelegramBuildsAreRowsWhenBothAreInstalled() {
        let mac = FakeMac(["ru.keepcoder.Telegram": "Telegram", "com.tdesktop.Telegram": "Telegram Desktop"])
        let players = AppIcons(lookups: mac.lookups).installedPlayers()
        XCTAssertEqual(Set(players.map(\.bundleID)), ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"])
        XCTAssertEqual(players.map(\.name), ["Telegram", "Telegram Desktop"])
        let twins = AppIcons.order([installed("com.tdesktop.Telegram", "Telegram"), installed("ru.keepcoder.Telegram", "Telegram")])
        XCTAssertEqual(twins.map(\.bundleID), ["com.tdesktop.Telegram", "ru.keepcoder.Telegram"], "same name: by bundle id")
    }

    /// Players on This Mac is every installed app of `musicApps ∪ mixedApps`;
    /// the empty player's offer is the songs-only ones.
    func testPlayersAreMusicAndMixedAppsAndTheEmptyOfferIsSongsOnly() {
        let all = Dictionary(
            uniqueKeysWithValues: MediaSourcePolicy.musicApps.union(MediaSourcePolicy.mixedApps).map { ($0, $0) }
        )
        let icons = AppIcons(lookups: FakeMac(all.merging(["com.example.browser": "Browser"]) { a, _ in a }).lookups)
        XCTAssertEqual(
            Set(icons.installedPlayers().map(\.bundleID)),
            MediaSourcePolicy.musicApps.union(MediaSourcePolicy.mixedApps),
            "a browser is not a player"
        )
        let offered = Set(icons.installedMusicApps().map(\.bundleID))
        XCTAssertEqual(offered, MediaSourcePolicy.musicApps.subtracting(MediaSourcePolicy.podcastApps))
        XCTAssertTrue(offered.isDisjoint(with: MediaSourcePolicy.mixedApps), "Telegram is not offered")
        XCTAssertFalse(offered.contains("com.apple.podcasts"))
        XCTAssertEqual(icons.installedMusicApps().prefix(2).map(\.bundleID), ["com.apple.Music", "com.spotify.client"])
    }

    // MARK: - The icon's optical size

    /// 824 / 1024: the Big Sur grid's squircle in its canvas.
    func testTheOpticalScaleIsTheBigSurGrid() {
        XCTAssertEqual(Theme.appIconOpticalScale, 1024.0 / 824.0, accuracy: 1e-9)
        XCTAssertEqual(18 * Theme.appIconOpticalScale, 22.37, accuracy: 0.01, "an 18 pt tile draws a 22.4 pt canvas")
    }

    /// The layout box is the tile's side, whatever the canvas is drawn at.
    func testAnIconTakesItsTilesSpaceAndNoMore() {
        for side: CGFloat in [16, 18, 40, 56] {
            let host = NSHostingView(rootView: AppIconImage(image: NSImage(size: NSSize(width: 64, height: 64)), side: side))
            XCTAssertEqual(host.fittingSize.width, side, accuracy: 0.5, "\(side)")
            XCTAssertEqual(host.fittingSize.height, side, accuracy: 0.5, "\(side)")
        }
    }
}
