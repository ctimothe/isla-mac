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
        // Backoff doubles: a helper that cannot start is usually a macOS
        // release that closed the route, and asking again every two seconds
        // spends battery to learn the same thing.
        XCTAssertEqual(policy.recordFailure(), .restart(after: 2))
        XCTAssertEqual(policy.recordFailure(), .restart(after: 4))
        XCTAssertEqual(policy.recordFailure(), .fallback)
        policy.recordSuccess()
        XCTAssertEqual(policy.recordFailure(), .restart(after: 16))
    }

    /// The failure mode the consecutive counter alone cannot see: a helper that
    /// starts, emits a line, and dies. Each success reset the count, so it
    /// never reached the fallback threshold and the app relaunched perl every
    /// two seconds for as long as it ran.
    func testRepeatedCrashesAfterSuccessEventuallyFallBack() {
        var policy = NowPlayingFailurePolicy(window: 300, maximumRestartsInWindow: 4)
        for _ in 0..<4 {
            let action = policy.recordFailure()
            XCTAssertNotEqual(action, .fallback)
            policy.recordSuccess()
        }
        XCTAssertEqual(policy.recordFailure(), .fallback)
    }

    /// A helper that survives long enough is forgiven, so an unlucky day does
    /// not disable the feed for the rest of the session.
    func testRestartBudgetResetsAfterTheWindow() {
        var policy = NowPlayingFailurePolicy(window: 60, maximumRestartsInWindow: 2)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = policy.recordFailure(now: start)
        policy.recordSuccess()
        _ = policy.recordFailure(now: start.addingTimeInterval(1))
        policy.recordSuccess()
        XCTAssertEqual(policy.recordFailure(now: start.addingTimeInterval(2)), .fallback)

        var fresh = NowPlayingFailurePolicy(window: 60, maximumRestartsInWindow: 2)
        _ = fresh.recordFailure(now: start)
        fresh.recordSuccess()
        _ = fresh.recordFailure(now: start.addingTimeInterval(1))
        fresh.recordSuccess()
        XCTAssertEqual(fresh.recordFailure(now: start.addingTimeInterval(120)), .restart(after: 2))
    }

    /// An oversized record used to poison the stream twice over: its buffered
    /// prefix was dropped, and the tail still arriving was then handed out as
    /// if it were a line.
    func testOversizedRecordIsDroppedWholeAndTheStreamResynchronizes() {
        var buffer = NDJSONBuffer(maximumPendingBytes: 64)
        // The notification is deferred off the mutating call — a handler that
        // touched the buffer it was called from would trap on overlapping
        // exclusive access — so it is awaited rather than read synchronously.
        let reported = expectation(description: "oversized record reported")
        buffer.onOversizedRecord = { reported.fulfill() }

        XCTAssertEqual(buffer.append(Data(String(repeating: "x", count: 200).utf8)), [])
        // The tail of the giant record, then a real line after it.
        let lines = buffer.append(Data("tail-of-giant\n{\"title\":\"next\"}\n".utf8))
            .map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(lines, [#"{"title":"next"}"#])
        wait(for: [reported], timeout: 1)
    }
}
