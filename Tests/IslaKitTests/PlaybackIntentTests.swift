import Foundation
import XCTest
@testable import IslaKit

final class PlaybackIntentTests: XCTestCase {
    func testRapidDoubleTapQueuesOnlyTheLatestIntentWithoutIconRollback() {
        let start = Date(timeIntervalSince1970: 1_000)
        var intent = PlaybackIntent(reported: true)

        XCTAssertEqual(intent.toggle(at: start), false)
        XCTAssertFalse(intent.desired)

        XCTAssertNil(intent.reconcile(reported: true, at: start.addingTimeInterval(0.01)))
        XCTAssertFalse(intent.desired, "a stale pre-pause snapshot must not flip the icon back")

        XCTAssertNil(intent.toggle(at: start.addingTimeInterval(0.02)))
        XCTAssertTrue(intent.desired)

        XCTAssertEqual(
            intent.reconcile(reported: false, at: start.addingTimeInterval(0.04)),
            true,
            "pause confirmation must dispatch the queued play intent"
        )
        XCTAssertTrue(intent.desired, "pause confirmation must not roll back the latest play icon")

        XCTAssertNil(intent.reconcile(reported: true, at: start.addingTimeInterval(0.08)))
        XCTAssertTrue(intent.desired)
        XCTAssertFalse(intent.hasInFlightCommand)
    }

    func testUnconfirmedIntentEventuallyReturnsToReportedState() {
        let start = Date(timeIntervalSince1970: 1_000)
        var intent = PlaybackIntent(reported: true)

        XCTAssertEqual(intent.toggle(at: start), false)
        XCTAssertNil(intent.reconcile(reported: true, at: start.addingTimeInterval(0.25)))
        XCTAssertFalse(intent.desired)

        XCTAssertNil(intent.reconcile(reported: true, at: start.addingTimeInterval(2.1)))
        XCTAssertTrue(intent.desired)
        XCTAssertFalse(intent.hasInFlightCommand)
    }

    /// A tap coalesced behind an unconfirmed command must not be thrown away.
    ///
    /// Press play then pause on a slow player: the pause is queued behind the
    /// play, the play is never confirmed, and adopting the reported state on
    /// timeout silently discarded the pause — the music kept going.
    func testACoalescedTapIsResentWhenTheFirstCommandTimesOut() {
        let start = Date()
        var intent = PlaybackIntent(reported: false)

        XCTAssertEqual(intent.toggle(at: start), true)      // play, sent
        XCTAssertNil(intent.toggle(at: start))              // pause, coalesced
        XCTAssertEqual(intent.desired, false)

        // The player still reports the pre-command state past the timeout.
        let resent = intent.reconcile(reported: false, at: start.addingTimeInterval(2))
        XCTAssertEqual(resent, false, "the queued pause must be sent rather than discarded")
        XCTAssertEqual(intent.desired, false)
    }

    /// A player that never answers must not be retried forever.
    func testAnUnansweredCommandIsResentOnlyOnce() {
        let start = Date()
        var intent = PlaybackIntent(reported: false)

        _ = intent.toggle(at: start)
        XCTAssertNil(intent.toggle(at: start))

        XCTAssertEqual(intent.reconcile(reported: false, at: start.addingTimeInterval(2)), false)
        // Still disagreeing after the retry: give up rather than resend again.
        XCTAssertNil(
            intent.reconcile(reported: true, at: start.addingTimeInterval(4)),
            "a second failure gives up instead of resending forever"
        )
        XCTAssertTrue(intent.desired, "giving up adopts what the player reports")
    }
}
