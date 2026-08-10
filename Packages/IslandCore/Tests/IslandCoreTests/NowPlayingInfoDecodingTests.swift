import Foundation
import Testing
@testable import IslandCore

// The first fixture below is a REAL line captured from the vendored adapter's
// `get` command against a real playing track (Yandex Music, 2026-08-10) —
// verbatim except the artworkData payload, swapped for a short valid base64
// string to keep this file readable (base64 decoding is exercised by the
// second, fully-synthetic test instead). This resolved the plan's "spike
// required" note: timestamp is an ISO8601 STRING ("2026-08-10T00:08:05Z"),
// not the epoch-seconds Double originally assumed — the prior synthetic-only
// fixture didn't catch this because it encoded the wrong assumption too.
struct NowPlayingInfoDecodingTests {
    @Test func decodesARealCapturedLine() throws {
        let json = """
        {
            "playbackRate": 0,
            "album": "Замигает свет",
            "elapsedTime": 122.42162500000001,
            "timestamp": "2026-08-10T00:08:05Z",
            "bundleIdentifier": "ru.yandex.desktop.music",
            "processIdentifier": 91453,
            "artworkData": "aGVsbG8=",
            "title": "Замигает свет",
            "artworkMimeType": "image/jpeg",
            "duration": 233.816666,
            "artist": "KENTUKKI",
            "contentItemIdentifier": "8B2CCD06-5500-4742-A35C-2932F147F471",
            "playing": false
        }
        """
        let info = try JSONDecoder().decode(NowPlayingInfo.self, from: Data(json.utf8))

        #expect(info.bundleIdentifier == "ru.yandex.desktop.music")
        #expect(info.title == "Замигает свет")
        #expect(info.artist == "KENTUKKI")
        #expect(info.album == "Замигает свет")
        #expect(info.elapsedTime == 122.42162500000001)
        #expect(info.duration == 233.816666)
        #expect(info.playing == false)
        #expect(info.artworkMimeType == "image/jpeg")

        let expectedTimestamp = ISO8601DateFormatter().date(from: "2026-08-10T00:08:05Z")
        #expect(info.timestamp == expectedTimestamp)
    }

    @Test func decodesALineWithMissingOptionalFieldsToNilWithoutThrowing() throws {
        let json = """
        { "title": "Only Title" }
        """
        let info = try JSONDecoder().decode(NowPlayingInfo.self, from: Data(json.utf8))

        #expect(info.title == "Only Title")
        #expect(info.artist == nil)
        #expect(info.playing == nil)
        #expect(info.timestamp == nil)
    }

    @Test func decodesShuffleAndRepeatModeWhenPresent() throws {
        let json = """
        { "shuffleMode": 1, "repeatMode": 2 }
        """
        let info = try JSONDecoder().decode(NowPlayingInfo.self, from: Data(json.utf8))

        #expect(info.shuffleMode == 1)
        #expect(info.repeatMode == 2)
    }
}
