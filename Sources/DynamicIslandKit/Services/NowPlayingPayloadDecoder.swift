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
            snapshot.source = sourceName(pid_t(pid))
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

    private static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let scalars = string.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !bidiControls.contains($0)
        }
        return String(String.UnicodeScalarView(scalars.prefix(maxTextLength)))
    }
}
