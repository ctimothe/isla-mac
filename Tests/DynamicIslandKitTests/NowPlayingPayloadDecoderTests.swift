import Foundation
import XCTest
@testable import DynamicIslandKit

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
}
