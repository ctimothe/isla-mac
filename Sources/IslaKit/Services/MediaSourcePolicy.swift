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
        "com.shiftyjelly.pocketcasts",
        "fm.overcast.overcast",
    ]

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
