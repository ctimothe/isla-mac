import Foundation

// Field encodings confirmed against a REAL captured mediaremote-adapter line
// (see NowPlayingInfoDecodingTests) — notably `timestamp` is an ISO8601
// string, not epoch-seconds as originally assumed from field names alone.
public struct NowPlayingInfo: Decodable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkData: Data?
    public let artworkMimeType: String?
    public let elapsedTime: Double?
    public let duration: Double?
    public let timestamp: Date?
    public let playing: Bool?
    public let shuffleMode: Int?
    public let repeatMode: Int?

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, title, artist, album, artworkData, artworkMimeType
        case elapsedTime, duration, timestamp, playing, shuffleMode, repeatMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        artworkData = try container.decodeIfPresent(Data.self, forKey: .artworkData)
        artworkMimeType = try container.decodeIfPresent(String.self, forKey: .artworkMimeType)
        elapsedTime = try container.decodeIfPresent(Double.self, forKey: .elapsedTime)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        playing = try container.decodeIfPresent(Bool.self, forKey: .playing)
        shuffleMode = try container.decodeIfPresent(Int.self, forKey: .shuffleMode)
        repeatMode = try container.decodeIfPresent(Int.self, forKey: .repeatMode)

        if let timestampString = try container.decodeIfPresent(String.self, forKey: .timestamp) {
            timestamp = ISO8601DateFormatter().date(from: timestampString)
        } else {
            timestamp = nil
        }
    }
}
