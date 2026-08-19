import Foundation
import XCTest
@testable import DynamicIslandKit

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
}
