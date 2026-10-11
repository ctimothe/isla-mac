import Foundation

enum NowPlayingPayloadDecoder {
    enum Event {
        case snapshot(NowPlayingFeed.Snapshot)
        case unavailable
    }

    static func decode(
        _ line: Data,
        sourceName: (pid_t) -> String? = { _ in nil }
    ) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        if object["error"] != nil { return .unavailable }
        guard object["playing"] is Bool,
              object["duration"] is NSNumber,
              object["elapsed"] is NSNumber,
              object["rate"] is NSNumber,
              object["timestamp"] is NSNumber else { return nil }

        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.isPlaying = object["playing"] as? Bool ?? false
        snapshot.title = text(object["title"])
        snapshot.artist = text(object["artist"])
        snapshot.album = text(object["album"])
        snapshot.duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        snapshot.elapsed = (object["elapsed"] as? NSNumber)?.doubleValue ?? 0
        snapshot.rate = (object["rate"] as? NSNumber)?.doubleValue ?? 0
        if let seconds = (object["timestamp"] as? NSNumber)?.doubleValue, seconds > 0 {
            snapshot.takenAt = Date(timeIntervalSince1970: seconds)
        }
        if let base64 = object["artwork"] as? String,
           base64.count <= maxArtworkBytes / 3 * 4 + 4,
           let artwork = Data(base64Encoded: base64),
           artwork.count <= maxArtworkBytes {
            snapshot.artwork = artwork
        }
        if let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 {
            snapshot.playerPID = pid_t(pid)
            snapshot.source = sourceName(pid_t(pid))
        }
        if let mediaType = object["mediaType"] as? String, !mediaType.isEmpty {
            snapshot.mediaType = mediaType
        }
        if let commands = object["commands"] as? [Int] {
            snapshot.commands = Set(commands)
        }
        return .snapshot(snapshot)
    }

    private static let maxTextLength = 512
    private static let maxArtworkBytes = 4 * 1024 * 1024
    private static let bidiControls = CharacterSet(
        charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
    )

    /// The C0 and C1 control codes (general category Cc) and nothing else.
    /// This used to be `CharacterSet.controlCharacters`, which Apple defines as
    /// Cc *plus* Cf — so it also ate the zero-width joiner ('❤️‍🔥' drew as a
    /// heart beside a fire, a family emoji as four people), the zero-width
    /// non-joiner of a Persian half-space, soft hyphens and the tag characters
    /// of a subdivision flag, and the altered title was what LRCLIB was asked
    /// for. The format characters that can actually reorder what the island
    /// shows are the bidi overrides, which `bidiControls` names one by one.
    private static let c0AndC1Controls = CharacterSet(charactersIn: "\u{0000}"..."\u{001F}")
        .union(CharacterSet(charactersIn: "\u{007F}"..."\u{009F}"))

    private static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let scalars = string.unicodeScalars.filter {
            !c0AndC1Controls.contains($0) && !bidiControls.contains($0)
        }
        return String(String.UnicodeScalarView(scalars.prefix(maxTextLength)))
    }
}
