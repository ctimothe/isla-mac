import AppKit
import XCTest
@testable import IslaKit

/// Settings › Connections (2026-10-25, owner: "a Connect section with all
/// supported apps … the top 10 on the market"): which players are listed, in
/// what order, with which icon and which one-line answer about the star.
/// Nothing here asks the runner's LaunchServices or IconServices: the Mac is a
/// fake that has exactly the apps a test names.
@MainActor
final class ConnectionsTests: XCTestCase {
    private func mac(_ apps: [String: String]) -> AppIcons {
        AppIcons(lookups: AppIcons.Lookups(
            applicationURL: { id in apps[id].map { _ in URL(fileURLWithPath: "/Applications/\(id).app") } },
            icon: { _ in NSImage(size: NSSize(width: 4, height: 4)) },
            displayName: { url in apps[url.deletingPathExtension().lastPathComponent] ?? "?" }
        ))
    }

    /// The two players Isla drives head the list whether or not they are
    /// installed: Apple Music ships with macOS, and Spotify's row is where its
    /// account is connected, which is worth showing before the app is.
    func testAppleMusicAndSpotifyAreAlwaysListedFirst() {
        let rows = PlayerConnections.rows(in: mac([:]))
        XCTAssertEqual(rows.map(\.service.bundleID), ["com.apple.Music", "com.spotify.client"])
        XCTAssertNil(rows[1].installed, "no icon is invented for an app that is not there")
    }

    /// Every other service is listed only when its app is installed, with the
    /// name the Finder shows, sorted the way the Finder sorts.
    func testOtherServicesAppearOnlyWhenInstalled() {
        let icons = mac([
            "com.apple.Music": "Music",
            "ru.yandex.desktop.music": "Яндекс Музыка",
            "com.tidal.desktop": "TIDAL",
            "com.deezer.deezer-desktop": "Deezer",
            // A player Isla shows on the island but that is not a streaming
            // service with an account: not a connection.
            "com.coppertino.Vox": "VOX",
        ])
        let rows = PlayerConnections.rows(in: icons)
        XCTAssertEqual(
            rows.map(\.service.bundleID),
            ["com.apple.Music", "com.spotify.client", "com.deezer.deezer-desktop", "com.tidal.desktop", "ru.yandex.desktop.music"]
        )
        XCTAssertEqual(rows.dropFirst(2).map { $0.installed?.name }, ["Deezer", "TIDAL", "Яндекс Музыка"])
        XCTAssertEqual(PlayerConnections.installedOthers(in: icons).count, 3)
    }

    /// The catalogue is the major services with a Mac app; a web player has
    /// no app to find, and SoundCloud has none (research 2026-10-25 §4).
    func testTheCatalogueIsTheMajorServicesWithAMacApp() {
        XCTAssertEqual(
            Set(PlayerConnections.others.map(\.bundleID)),
            [
                "com.github.th-ch.youtube-music", "com.amazon.music", "com.deezer.deezer-desktop",
                "com.tidal.desktop", "ru.yandex.desktop.music", "com.pandora.desktop", "com.qobuz.QobuzDesktop",
            ]
        )
        XCTAssertFalse(PlayerConnections.others.contains { $0.bundleID.contains("soundcloud") })
        for service in PlayerConnections.others {
            XCTAssertTrue(MediaSourcePolicy.musicApps.contains(service.bundleID),
                          "\(service.bundleID) is listed but the island would not always show it")
        }
    }

    /// The star: through the Music app with no sign-in, through a Spotify
    /// account, and nowhere else — no other service has a sanctioned way
    /// (research 2026-10-25). Each says so in a few words, never a paragraph.
    func testEachRowSaysOnlyWhatIsTrueAboutTheStar() {
        XCTAssertEqual(PlayerConnections.appleMusic.favourite, .local)
        XCTAssertEqual(PlayerConnections.spotify.favourite, .signIn)
        XCTAssertTrue(PlayerConnections.others.allSatisfy { $0.favourite == .none })

        XCTAssertEqual(PlayerConnections.detail(.local), localized("Favorites, no sign-in"))
        XCTAssertEqual(PlayerConnections.detail(.none), localized("Controls and lyrics, no favorites"))
        XCTAssertEqual(PlayerConnections.spotifyDetail(connected: true), localized("Liked Songs"))
        XCTAssertEqual(PlayerConnections.spotifyDetail(connected: false), localized("Sign in for Liked Songs"))
        for text in [PlayerConnections.detail(.local), PlayerConnections.detail(.none),
                     PlayerConnections.spotifyDetail(connected: false)] {
            XCTAssertLessThanOrEqual(text.split(separator: " ").count, 5, "\(text) is helper text, not a value")
        }
    }

    /// "No favorites" is what the player does too: a service with no
    /// sanctioned star reports neither a Music favourite nor a Spotify track,
    /// so neither the player nor the lock card draws a star that does nothing.
    func testAServiceWithNoFavouriteGetsNoStar() {
        XCTAssertNil(MediaPane.Favourite.resolve(musicFavorite: nil, spotifyTrackID: nil, spotifyCanSave: true, saved: [:]))
        XCTAssertNil(LockScreenCard.favourite(
            musicFavorite: nil, spotifyTrackID: nil, spotifyConnected: true, apiBlocked: false,
            tokenUnavailable: false, saved: [:]
        ))
        // A Spotify account Spotify refused draws no star either.
        XCTAssertNil(LockScreenCard.favourite(
            musicFavorite: nil, spotifyTrackID: "abc", spotifyConnected: true, apiBlocked: true,
            tokenUnavailable: false, saved: ["abc": true]
        ))
    }

    /// Russian, as the person reads it.
    func testTheDetailsAreRussianToo() {
        LabLocalization.use("ru")
        defer { LabLocalization.use("en") }
        XCTAssertEqual(SettingsSection.connections.title, "Сервисы")
        XCTAssertNotEqual(PlayerConnections.detail(.none), "Controls and lyrics, no favorites")
        XCTAssertNotEqual(PlayerConnections.spotifyDetail(connected: false), "Sign in for Liked Songs")
    }

    /// The system pane icons come from the injected lookup, once per refresh,
    /// and a lookup that has none leaves the drawn tile to draw.
    func testSystemPaneIconsAreAskedOnceAndMayBeMissing() {
        var asks = 0
        let icon = NSImage(size: NSSize(width: 8, height: 8))
        let icons = AppIcons(lookups: AppIcons.Lookups(
            applicationURL: { _ in nil },
            icon: { _ in NSImage() },
            displayName: { _ in "" },
            systemIcon: { source in
                asks += 1
                return source == .graphicIcon("com.apple.graphic-icon.gear") ? icon : nil
            }
        ))
        XCTAssertTrue(icons.systemIcon(.graphicIcon("com.apple.graphic-icon.gear")) === icon)
        XCTAssertTrue(icons.systemIcon(.graphicIcon("com.apple.graphic-icon.gear")) === icon)
        XCTAssertNil(icons.systemIcon(.graphicIcon("com.apple.graphic-icon.nope")))
        XCTAssertNil(icons.systemIcon(.graphicIcon("com.apple.graphic-icon.nope")))
        XCTAssertEqual(asks, 2, "one question per source between refreshes")
        icons.refresh()
        _ = icons.systemIcon(.graphicIcon("com.apple.graphic-icon.gear"))
        XCTAssertEqual(asks, 3)
    }

    /// An extension is trusted only when the bundle at the path is the one
    /// named: a moved or replaced bundle must not lend Isla its icon.
    func testASettingsExtensionMustBeTheBundleItClaims() {
        XCTAssertFalse(AppIcons.extensionMatches(path: "/nonexistent/LockScreen.appex", bundleID: "com.apple.Lock-Screen-Settings.extension"))
        XCTAssertFalse(AppIcons.graphicIconTypeExists("com.apple.graphic-icon.this-is-not-a-type"))
    }
}
