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

    // MARK: - A command no report came for

    /// A pause the player never confirmed, on a route with no heartbeat: the
    /// command stayed in flight for good, and the next tap was coalesced
    /// behind it and never sent.
    func testAnUnconfirmedCommandIsSettledAgainstTheLastReport() {
        let start = Date(timeIntervalSince1970: 1_000)
        var intent = PlaybackIntent(reported: true)
        XCTAssertEqual(intent.toggle(at: start), false)

        XCTAssertNil(intent.settleUnconfirmed(at: start.addingTimeInterval(2.6), took: false))
        XCTAssertFalse(intent.hasInFlightCommand)
        XCTAssertTrue(intent.desired, "nobody confirmed the pause, so the last report stands")
        XCTAssertEqual(intent.toggle(at: start.addingTimeInterval(3)), false, "and the next tap is sent")
    }

    /// Not before the command has had its time: a report may still come.
    func testSettlingEarlyKeepsWaiting() {
        let start = Date(timeIntervalSince1970: 1_000)
        var intent = PlaybackIntent(reported: true)
        _ = intent.toggle(at: start)
        XCTAssertNil(intent.settleUnconfirmed(at: start.addingTimeInterval(0.5), took: false))
        XCTAssertTrue(intent.hasInFlightCommand)
        XCTAssertFalse(intent.desired)
    }

    /// A tap coalesced behind the unconfirmed command gets its one resend
    /// here too, as it does when a report times the command out.
    func testSettlingResendsAQueuedTapOnce() {
        let start = Date(timeIntervalSince1970: 1_000)
        var intent = PlaybackIntent(reported: false)
        XCTAssertEqual(intent.toggle(at: start), true)
        XCTAssertNil(intent.toggle(at: start.addingTimeInterval(0.1)))

        XCTAssertEqual(intent.settleUnconfirmed(at: start.addingTimeInterval(2.6), took: false), false)
        XCTAssertNil(intent.settleUnconfirmed(at: start.addingTimeInterval(5.2), took: false))
        XCTAssertFalse(intent.hasInFlightCommand)
        XCTAssertFalse(intent.desired)
    }

    /// Where nothing can ever report the player, a delivered command counts
    /// as taken: the icon keeps what was asked and the next tap goes out.
    func testACommandNobodyCanConfirmCountsAsTaken() {
        let start = Date(timeIntervalSince1970: 1_000)
        var intent = PlaybackIntent(reported: true)
        XCTAssertEqual(intent.toggle(at: start), false)

        XCTAssertNil(intent.settleUnconfirmed(at: start, took: true))
        XCTAssertFalse(intent.hasInFlightCommand)
        XCTAssertFalse(intent.desired)
        XCTAssertEqual(intent.toggle(at: start.addingTimeInterval(0.2)), true, "the second tap is sent, not queued")
    }

    func testSettlingWithNothingInFlightChangesNothing() {
        var intent = PlaybackIntent(reported: true)
        XCTAssertNil(intent.settleUnconfirmed(at: Date(), took: false))
        XCTAssertNil(intent.settleUnconfirmed(at: Date(), took: true))
        XCTAssertTrue(intent.desired)
    }
}
