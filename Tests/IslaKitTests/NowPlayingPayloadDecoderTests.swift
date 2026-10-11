import Foundation
import XCTest
@testable import IslaKit

final class NowPlayingPayloadDecoderTests: XCTestCase {
    func testDecodesTheHelpersFlatSnapshotContract() {
        let line = Data(#"{"playing":true,"title":"Track","artist":"Artist","album":"Album","duration":240.0,"elapsed":12.5,"rate":1.0,"timestamp":1760000000.0,"pid":42,"commands":[0,1,4,5]}"#.utf8)

        let event = NowPlayingPayloadDecoder.decode(line) { pid in
            pid == 42 ? "Player" : nil
        }

        guard case .some(.snapshot(let value)) = event else {
            return XCTFail("expected snapshot")
        }
        XCTAssertTrue(value.isPlaying)
        XCTAssertEqual(value.title, "Track")
        XCTAssertEqual(value.artist, "Artist")
        XCTAssertEqual(value.album, "Album")
        XCTAssertEqual(value.duration, 240)
        XCTAssertEqual(value.elapsed, 12.5)
        XCTAssertEqual(value.rate, 1)
        XCTAssertEqual(value.playerPID, 42)
        XCTAssertEqual(value.source, "Player")
        XCTAssertEqual(value.commands, Set([0, 1, 4, 5]))
    }

    func testRejectsPrototypeEnvelopeAndRecognizesHelperError() {
        let envelope = Data(#"{"type":"update","payload":{"playing":true}}"#.utf8)
        XCTAssertNil(NowPlayingPayloadDecoder.decode(envelope))

        let error = Data(#"{"error":"media route closed"}"#.utf8)
        guard case .some(.unavailable) = NowPlayingPayloadDecoder.decode(error) else {
            return XCTFail("expected unavailable")
        }
    }

    func testBoundsAndSanitizesUntrustedMetadata() throws {
        let longTitle = "before\u{202E}" + String(repeating: "a", count: 600)
        let data = try JSONSerialization.data(withJSONObject: [
            "playing": false,
            "title": longTitle,
            "duration": 0.0,
            "elapsed": 0.0,
            "rate": 0.0,
            "timestamp": 1.0,
        ])

        guard case .some(.snapshot(let value)) = NowPlayingPayloadDecoder.decode(data) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(value.title.count, 512)
        XCTAssertFalse(value.title.unicodeScalars.contains("\u{202E}"))
    }

    /// `CharacterSet.controlCharacters` is Cc *and* Cf, so the decoder used to
    /// strip the zero-width joiner out of '❤️‍🔥' (a heart beside a fire), the
    /// zero-width non-joiner out of a Persian half-space, soft hyphens and the
    /// tag characters of a subdivision flag — and that altered title is what
    /// LRCLIB was then asked for. Only Cc and the bidi overrides are unsafe.
    func testJoinersSurviveAndControlsDoNot() throws {
        func title(_ raw: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "playing": true,
                "title": raw,
                "duration": 1.0,
                "elapsed": 0.0,
                "rate": 1.0,
                "timestamp": 1.0,
            ])
            guard case .some(.snapshot(let value)) = NowPlayingPayloadDecoder.decode(data) else {
                XCTFail("expected snapshot")
                return ""
            }
            return value.title
        }

        let joined = "❤️\u{200D}🔥 می\u{200C}خواهم"
        XCTAssertEqual(try title(joined), joined)
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        XCTAssertEqual(try title(family), family)
        let softHyphen = "Donau\u{00AD}dampf\u{00AD}schiff"
        XCTAssertEqual(try title(softHyphen), softHyphen)
        let england = "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        XCTAssertEqual(try title(england), england)

        XCTAssertEqual(try title("\u{202E}abc"), "abc")
        XCTAssertEqual(try title("a\u{0007}b"), "ab")
        XCTAssertEqual(try title("a\u{0000}b\u{001F}c\u{007F}d\u{0085}e\u{009F}f"), "abcdef")
        XCTAssertEqual(try title("a\nb\tc"), "abc")
    }
}
