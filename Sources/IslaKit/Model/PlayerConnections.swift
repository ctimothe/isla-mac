import Foundation

/// Settings › Connections: the music services Isla plays through, one row
/// each, and what the player's star can do with each (2026-10-25, owner: "a
/// Connect section with all supported apps like Apple Music, Spotify, Yandex
/// Music and so on, the top 10 on the market").
///
/// It replaces the Spotify section, which was the only service with anything
/// to connect and so the only one Settings named. Every row says only what is
/// true, in a few words: Apple Music's star works through the Music app with no
/// sign-in; Spotify's through a Spotify account; every other service plays,
/// skips and shows lyrics through Now Playing and has no star, because none
/// offers a sanctioned way for an app like Isla to add to a library
/// (`docs/development/research/2026-10-25-favourites-per-player.md`).
///
/// Pure: the list is `rows(in:)` over an `AppIcons`, so a test decides what is
/// installed. Icons come only from the installed app at runtime — the
/// `AppIcons` rule; no brand asset ships.
enum PlayerConnections {
    /// What the star can do for a service.
    enum Favourite: Equatable {
        /// Through the app itself, with no sign-in (Apple Music's AppleScript
        /// `favorited`).
        case local
        /// Through an account connected here (Spotify's Web API).
        case signIn
        /// No sanctioned way; the star stays hidden for this player.
        case none
    }

    struct Service: Equatable {
        let bundleID: String
        let favourite: Favourite
    }

    static let appleMusic = Service(bundleID: "com.apple.Music", favourite: .local)
    static let spotify = Service(bundleID: "com.spotify.client", favourite: .signIn)

    /// The other major services that have a Mac app, listed only while it is
    /// installed. Each is in `MediaSourcePolicy.musicApps`, so the island
    /// always shows what it plays. A web player has no app to find, and
    /// SoundCloud has none at all (research §4), so neither is here.
    static let others: [Service] = [
        Service(bundleID: "com.github.th-ch.youtube-music", favourite: .none),
        Service(bundleID: "com.amazon.music", favourite: .none),
        Service(bundleID: "com.deezer.deezer-desktop", favourite: .none),
        Service(bundleID: "com.tidal.desktop", favourite: .none),
        Service(bundleID: "ru.yandex.desktop.music", favourite: .none),
        Service(bundleID: "com.pandora.desktop", favourite: .none),
        Service(bundleID: "com.qobuz.QobuzDesktop", favourite: .none),
    ]

    /// One row: the service and, when it is installed, the app (its icon and
    /// the name the Finder shows).
    struct Row: Equatable, Identifiable {
        let service: Service
        let installed: AppIcons.Installed?
        var id: String { service.bundleID }
    }

    /// Apple Music and Spotify always, first, in that order — the two Isla
    /// drives, and Spotify's row is where its account is connected, which is
    /// worth offering before the app is installed — then every other service
    /// whose app is on this Mac, sorted as the Finder sorts.
    @MainActor
    static func rows(in icons: AppIcons) -> [Row] {
        [Row(service: appleMusic, installed: icons.app(appleMusic.bundleID)),
         Row(service: spotify, installed: icons.app(spotify.bundleID))]
            + installedOthers(in: icons)
    }

    @MainActor
    static func installedOthers(in icons: AppIcons) -> [Row] {
        let byID = Dictionary(uniqueKeysWithValues: others.map { ($0.bundleID, $0) })
        return AppIcons.order(icons.installed(others.map(\.bundleID))).compactMap { app in
            byID[app.bundleID].map { Row(service: $0, installed: app) }
        }
    }

    /// The row's second line, as System Settings' Internet Accounts lists what
    /// an account is used for: a few words, never a paragraph.
    static func detail(_ favourite: Favourite) -> String {
        switch favourite {
        case .local: return localized("Favorites, no sign-in")
        case .signIn: return localized("Liked Songs")
        case .none: return localized("Controls and lyrics, no favorites")
        }
    }

    static func spotifyDetail(connected: Bool) -> String {
        connected ? localized("Liked Songs") : localized("Sign in for Liked Songs")
    }
}
