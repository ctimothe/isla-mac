import Foundation

/// Which Now Playing sessions the island shows when **Music Only** is on.
///
/// macOS reports one Now Playing session, whatever owns it — a YouTube tab, a
/// film in QuickTime, a video in Telegram — and the island used to draw every
/// one of them as if it were a song. It is a music surface: an artwork wing, an
/// equalizer, lyrics. A film on the island is noise.
///
/// Two signals, measured on 2026-09-21 rather than assumed:
///
/// * **Which app owns the session.** Always known — the helper reports the
///   owner's pid. This is what catches video: a YouTube video in a browser
///   reported *no* media type at all, so the kind of media cannot be the rule
///   for browsers; the owner has to be.
/// * **What the player says it is**, through MediaRemote's
///   `kMRMediaRemoteNowPlayingInfoMediaType`. Spotify reported
///   `kMRMediaRemoteNowPlayingInfoTypeAudio`. Present only when the player
///   chose to say, so its *absence* means "unknown", never "video".
///
/// The rule, in order:
///
/// 1. A dedicated music or podcast app is always shown — including a music
///    video in Apple Music, which is still music.
/// 2. Anything the player itself labels audio is shown, from any app. That is
///    what admits a music app this list has never heard of.
/// 3. An app that plays both songs and films — Telegram — is shown when it
///    labels the item audio, or, unlabelled, when the item carries an artist:
///    a song sent in Telegram has one, a video does not.
/// 4. Everything else is filtered out: browsers, video players, unknown apps
///    that say nothing about what they are playing.
enum MediaSourcePolicy {
    /// Players whose whole purpose is music or spoken audio.
    ///
    /// The identifiers added on 2026-10-15 (Qobuz, YouTube Music, Audirvana,
    /// both Pocket Casts builds) are the ones Homebrew's casks list in their
    /// `zap` and `quit` stanzas, which are the vendors' own. A player missing
    /// from here is still admitted whenever it labels what it plays as audio
    /// (rule 2); the list only decides which apps are *always* shown, and which
    /// ones Settings and the empty player name.
    static let musicApps: Set<String> = [
        "com.apple.Music",
        "com.apple.podcasts",
        "com.spotify.client",
        "ru.yandex.desktop.music",       // Yandex Music
        "com.tidal.desktop",
        "com.deezer.deezer-desktop",
        "com.amazon.music",
        "com.soundcloud.desktop",
        "com.pandora.desktop",
        "tv.plex.plexamp",
        "com.electron.cider",            // Cider (Apple Music client)
        "co.brushedtype.doppler-macos",  // Doppler
        "com.coppertino.Vox",
        "com.swinsian.Swinsian",
        "com.audirvana.Audirvana-Origin",
        "com.audirvana.Audirvana-Studio",
        "com.audirvana.Audirvana",       // Audirvana (the original, pre-Studio build)
        "com.qobuz.QobuzDesktop",        // Qobuz
        "com.github.th-ch.youtube-music", // YouTube Music desktop (Pear)
        "com.shiftyjelly.pocketcasts",   // Pocket Casts (older identifier, not verified; harmless)
        "com.electron.pocket-casts",     // Pocket Casts (desktop wrapper)
        "au.com.shiftyjelly.PocketCasts", // Pocket Casts (Mac app)
        "fm.overcast.overcast",
    ]

    /// The members of `musicApps` that play spoken audio, not songs. They are
    /// shown like any music app, but the empty Music tab does not offer to open
    /// them as "a player to start a song in".
    static let podcastApps: Set<String> = [
        "com.apple.podcasts",
        "com.shiftyjelly.pocketcasts",
        "com.electron.pocket-casts",
        "au.com.shiftyjelly.PocketCasts",
        "fm.overcast.overcast",
    ]

    /// The players a person starts a song in: `musicApps` less the podcast apps.
    ///
    /// A stored constant, not a computed set: the empty player asks on every
    /// layout pass, and a set rebuilt per pass is work for an answer that
    /// cannot change.
    static let songApps: Set<String> = musicApps.subtracting(podcastApps)

    /// Every app Settings › Music › Players on This Mac lists: the dedicated
    /// players and the ones that play songs and films. Stored for the same
    /// reason as `songApps`.
    static let listedPlayers: Set<String> = musicApps.union(mixedApps)

    /// Listed first wherever Isla names players: Apple Music, then Spotify —
    /// the two it can control, not just read.
    static let leadingApps = ["com.apple.Music", "com.spotify.client"]

    /// Apps that play songs *and* films, where the item decides.
    static let mixedApps: Set<String> = [
        "ru.keepcoder.Telegram",   // Telegram (App Store)
        "com.tdesktop.Telegram",   // Telegram Desktop
    ]

    static let audioType = "kMRMediaRemoteNowPlayingInfoTypeAudio"

    static func allows(
        bundleIdentifier: String?, mediaType: String?, artist: String
    ) -> Bool {
        if let bundleIdentifier, musicApps.contains(bundleIdentifier) { return true }
        if mediaType == audioType { return true }
        if let bundleIdentifier, mixedApps.contains(bundleIdentifier) {
            // Labelled as something else is a definite no; unlabelled, a song
            // carries an artist and a video does not.
            guard mediaType == nil else { return false }
            return !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
}
