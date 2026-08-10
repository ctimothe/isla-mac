import Foundation

// Field names per checklist.md's documented mediaremote-adapter NDJSON schema.
// Exact encodings (artworkData/timestamp/shuffleMode/repeatMode) are provisional
// pending the real-capture spike described in the implementation plan, section 3.
public struct NowPlayingInfo: Decodable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artworkData: Data?
    public let artworkMimeType: String?
    public let elapsedTime: Double?
    public let timestamp: Double?
    public let playing: Bool?
    public let shuffleMode: Int?
    public let repeatMode: Int?
}
