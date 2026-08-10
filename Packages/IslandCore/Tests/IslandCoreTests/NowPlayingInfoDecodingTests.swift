import Foundation
import Testing
@testable import IslandCore

// NOTE: These fixtures are synthetic, built from checklist.md's documented field
// NAMES only (bundleIdentifier/title/artist/album/artworkData/artworkMimeType/
// elapsedTime/timestamp/playing/shuffleMode/repeatMode). The exact ENCODING of
// artworkData/timestamp/shuffleMode/repeatMode is still an open spike per the
// plan (section 3) — run the real adapter against a real playing track before
// shipping and replace this fixture with the captured output.
struct NowPlayingInfoDecodingTests {
    @Test func decodesAFullyPopulatedLine() throws {
        let json = """
        {
            "bundleIdentifier": "com.apple.Music",
            "title": "Test Song",
            "artist": "Test Artist",
            "album": "Test Album",
            "artworkData": "aGVsbG8=",
            "artworkMimeType": "image/jpeg",
            "elapsedTime": 12.5,
            "timestamp": 1754800000.0,
            "playing": true,
            "shuffleMode": 0,
            "repeatMode": 0
        }
        """
        let info = try JSONDecoder().decode(NowPlayingInfo.self, from: Data(json.utf8))

        #expect(info.bundleIdentifier == "com.apple.Music")
        #expect(info.title == "Test Song")
        #expect(info.artist == "Test Artist")
        #expect(info.playing == true)
    }

    @Test func decodesALineWithMissingOptionalFieldsToNilWithoutThrowing() throws {
        let json = """
        { "title": "Only Title" }
        """
        let info = try JSONDecoder().decode(NowPlayingInfo.self, from: Data(json.utf8))

        #expect(info.title == "Only Title")
        #expect(info.artist == nil)
        #expect(info.playing == nil)
    }
}
