import Foundation

/// What Music's and Spotify's own change announcements say, as a state.
///
/// Both players post a distributed notification on every play, pause and
/// track change, from their own window, a media key or Control Center alike,
/// and reading one needs no permission at all. That is what the fallback has
/// left when a player cannot or may not be asked over AppleScript: with
/// Spotify's Automation refused, the refusal came back as -1743, and a
/// playing Spotify was shown as the paused Music track beside it, with
/// play/pause driving Music (J-027). And before the panel first opens, no
/// player may be asked at all (J-003), so the fallback showed nothing over a
/// song that was playing.
///
/// The key names are observed behaviour, not API. An announcement missing
/// them reads as nil, which is exactly what the fallback had before.
enum PlayerAnnouncement {
    /// The song an announcement names, or nil when it names none — a stopped
    /// player, or keys this parser does not recognise.
    ///
    /// The units differ by player and were read off the live notifications:
    /// Spotify's `Duration` is milliseconds and its `Playback Position`
    /// seconds; Music's `Total Time` is milliseconds and Music announces no
    /// position at all, which `positionKnown` says so the island can keep the
    /// place it already had rather than jump the song back to 0:00.
    static func state(from userInfo: [AnyHashable: Any], app: PlayerApp) -> PlayerState? {
        guard let name = text(userInfo["Name"]), !name.isEmpty,
              let playerState = text(userInfo["Player State"]) else { return nil }
        let isPlaying: Bool
        switch playerState.lowercased() {
        case "playing": isPlaying = true
        case "paused": isPlaying = false
        // "Stopped" names no song worth showing, and anything else is a word
        // this parser has never seen.
        default: return nil
        }
        let durationMs = number(userInfo[app == .spotify ? "Duration" : "Total Time"])
        let duration = durationMs.map { $0 / 1000 } ?? 0
        // A negative or non-finite reading would anchor the clock outside the
        // song; it is treated as no reading, like Music's missing one.
        let position = app == .spotify ? number(userInfo["Playback Position"]) : nil
        return PlayerState(
            app: app,
            isPlaying: isPlaying,
            title: name,
            artist: text(userInfo["Artist"]) ?? "",
            album: text(userInfo["Album"]) ?? "",
            duration: duration,
            position: position ?? 0,
            artworkURL: nil,
            positionKnown: position != nil
        )
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A number as either player sends it. A notification arriving from
    /// another process carries an `NSNumber`, which reads as either; a test's
    /// literal is a Swift `Int` or `Double`, which does not cross over.
    private static func number(_ value: Any?) -> Double? {
        let raw: Double?
        switch value {
        case let value as Double: raw = value
        case let value as Int: raw = Double(value)
        case let value as NSNumber: raw = value.doubleValue
        case let value as String: raw = Double(value)
        default: raw = nil
        }
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return raw
    }
}
