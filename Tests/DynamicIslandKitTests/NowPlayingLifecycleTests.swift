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

    // MARK: - Seek reading gate

    /// The backwards-bounce on lyric clicks: a correction already in flight
    /// when the seek was issued returns the pre-seek position, and the old
    /// value-proximity rule let it settle the seek and yank the anchor back.
    @MainActor
    func testPreSeekReadingNeverSettlesTheSeek() {
        let issued = Date()
        let askedBefore = issued.addingTimeInterval(-0.1)
        // Stale value 1.8s behind the target — inside the old 2.5s window.
        let verdict = MediaController.judgeSeekReading(
            reading: 100.2, target: 102.0,
            issuedAt: issued, askedAt: askedBefore,
            now: issued.addingTimeInterval(0.3),
            origin: 100.1
        )
        XCTAssertEqual(verdict, .discard)
    }

    @MainActor
    func testPostSeekReadingNearTargetSettles() {
        let issued = Date()
        let verdict = MediaController.judgeSeekReading(
            reading: 102.3, target: 102.0,
            issuedAt: issued, askedAt: issued.addingTimeInterval(0.2),
            now: issued.addingTimeInterval(0.5),
            origin: 90.0
        )
        XCTAssertEqual(verdict, .settleAdopt)
    }

    /// The query can outrun the player applying the jump: post-issue but far
    /// from the target proves nothing yet.
    @MainActor
    func testPostSeekReadingFarFromTargetKeepsWaiting() {
        let issued = Date()
        let verdict = MediaController.judgeSeekReading(
            reading: 100.1, target: 130.0,
            issuedAt: issued, askedAt: issued.addingTimeInterval(0.1),
            now: issued.addingTimeInterval(0.4),
            origin: 100.0
        )
        XCTAssertEqual(verdict, .discard)
    }

    /// Expiry must clear the pending state — left set it disables corrections
    /// for the rest of the track — but a stale reading still gets no say.
    @MainActor
    func testExpiryWithStaleReadingSettlesWithoutAdopting() {
        let issued = Date()
        let verdict = MediaController.judgeSeekReading(
            reading: 100.0, target: 130.0,
            issuedAt: issued, askedAt: issued.addingTimeInterval(-0.2),
            now: issued.addingTimeInterval(2.0),
            origin: 100.1
        )
        XCTAssertEqual(verdict, .settleIgnore)
    }

    @MainActor
    func testExpiryWithPostSeekReadingAdopts() {
        let issued = Date()
        let verdict = MediaController.judgeSeekReading(
            reading: 129.0, target: 130.0,
            issuedAt: issued, askedAt: issued.addingTimeInterval(1.8),
            now: issued.addingTimeInterval(2.0),
            origin: 100.0
        )
        XCTAssertEqual(verdict, .settleAdopt)
    }

    /// The reviewer's walk-through: a short forward click, a slow-applying
    /// player, and a post-issue query that reads the pre-seek position after
    /// it has drifted into the target window. Near the target is not proof —
    /// still on the old trajectory is disproof.
    @MainActor
    func testPreApplicationDriftIntoTargetWindowIsDiscarded() {
        let issued = Date()
        // Click +1.2s: origin 100.0, target 101.2. Queried 0.5s later, the
        // un-applied player answers 100.5 — within 0.8 of the target, and
        // exactly on the pre-seek trajectory.
        let verdict = MediaController.judgeSeekReading(
            reading: 100.5, target: 101.2,
            issuedAt: issued, askedAt: issued.addingTimeInterval(0.5),
            now: issued.addingTimeInterval(0.7),
            origin: 100.0
        )
        XCTAssertEqual(verdict, .discard)
    }

    /// The same drift when the jump is real: reading near the target but far
    /// off the old trajectory settles.
    @MainActor
    func testLandedJumpOffTheOldTrajectorySettles() {
        let issued = Date()
        let verdict = MediaController.judgeSeekReading(
            reading: 130.4, target: 130.0,
            issuedAt: issued, askedAt: issued.addingTimeInterval(0.5),
            now: issued.addingTimeInterval(0.7),
            origin: 100.0
        )
        XCTAssertEqual(verdict, .settleAdopt)
    }

    /// A refused seek: the player never left the old trajectory. After expiry
    /// the reading is the truth and must be adopted, or the bar rides a
    /// phantom position for the rest of the pending window.
    @MainActor
    func testRefusedSeekAdoptsTruthAtExpiry() {
        let issued = Date()
        let verdict = MediaController.judgeSeekReading(
            reading: 101.8, target: 130.0,
            issuedAt: issued, askedAt: issued.addingTimeInterval(1.7),
            now: issued.addingTimeInterval(1.9),
            origin: 100.0
        )
        XCTAssertEqual(verdict, .settleAdopt)
    }

    /// A paused player does not drift: rate 0 pins the phantom at the origin,
    /// so a genuine landing right next to it still settles.
    @MainActor
    func testPausedSeekNearOriginStillSettlesWhenLanded() {
        let issued = Date()
        let verdict = MediaController.judgeSeekReading(
            reading: 102.0, target: 102.0,
            issuedAt: issued, askedAt: issued.addingTimeInterval(0.4),
            now: issued.addingTimeInterval(0.6),
            origin: 100.0, rate: 0
        )
        XCTAssertEqual(verdict, .settleAdopt)
    }
}
