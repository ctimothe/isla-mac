import Foundation
import XCTest
@testable import DynamicIslandKit

final class NowPlayingLifecycleTests: XCTestCase {
    func testBufferPreservesFragmentsAndReturnsEveryCompleteLine() {
        var buffer = NDJSONBuffer()
        XCTAssertEqual(buffer.append(Data(#"{"title":"one""#.utf8)), [])
        XCTAssertEqual(
            buffer.append(Data("}\n{\"title\":\"two\"}\npartial".utf8))
                .map { String(decoding: $0, as: UTF8.self) },
            [#"{"title":"one"}"#, #"{"title":"two"}"#]
        )
        XCTAssertEqual(
            buffer.append(Data("-line\n".utf8))
                .map { String(decoding: $0, as: UTF8.self) },
            ["partial-line"]
        )
    }

    func testThirdConsecutiveFailureFallsBackAndSuccessResetsCount() {
        var policy = NowPlayingFailurePolicy()
        XCTAssertEqual(policy.recordFailure(), .restart(after: 2))
        XCTAssertEqual(policy.recordFailure(), .restart(after: 2))
        XCTAssertEqual(policy.recordFailure(), .fallback)
        policy.recordSuccess()
        XCTAssertEqual(policy.recordFailure(), .restart(after: 2))
    }
}
