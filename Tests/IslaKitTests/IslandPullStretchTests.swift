import XCTest
@testable import IslaKit

/// The pull's stretch reaches the outline at most once per display frame and
/// never a frame late (MR-H18, 2026-10-26): a trackpad sends scroll events
/// faster than the display draws, and each publish re-ran the shell's body
/// and its layout.
@MainActor
final class IslandPullStretchTests: XCTestCase {
    // MARK: The pure coalescer

    func testTheFirstValueOfAFramePublishesAtOnce() {
        var gate = FrameCoalescer<CGFloat>()
        XCTAssertEqual(gate.offer(2), 2, "the fingers are never a frame behind")
    }

    func testLaterValuesInTheSameFrameWaitAndOnlyTheNewestIsPublished() {
        var gate = FrameCoalescer<CGFloat>()
        _ = gate.offer(1)
        XCTAssertNil(gate.offer(2))
        XCTAssertNil(gate.offer(3))
        XCTAssertEqual(gate.frame(), 3, "the next frame shows where the fingers are, not where they were")
        XCTAssertNil(gate.frame(), "nothing new: nothing published")
        XCTAssertTrue(gate.isIdle, "a quiet frame lets the clock stop")
        XCTAssertEqual(gate.offer(4), 4, "after a quiet frame the next value is at once again")
    }

    func testCancelForgetsWhatWaits() {
        var gate = FrameCoalescer<CGFloat>()
        _ = gate.offer(1)
        _ = gate.offer(2)
        gate.cancel()
        XCTAssertTrue(gate.isIdle)
        XCTAssertNil(gate.frame(), "a released pull publishes nothing late over its settle")
    }

    // MARK: The stretch on a clock turned by hand

    func testFourEventsInOneFramePublishTwiceAcrossTwoFrames() {
        let clock = ManualPageClock()
        let stretch = IslandPullStretch(clock: clock)
        stretch.track(1)
        stretch.track(2)
        stretch.track(3)
        stretch.track(4)
        XCTAssertEqual(stretch.points, 1, "the first event of the frame is drawn in it")
        XCTAssertEqual(stretch.publishes, 1)
        clock.advance(1.0 / 120)
        XCTAssertEqual(stretch.points, 4)
        XCTAssertEqual(stretch.publishes, 2, "one publish per frame, never one per event")
        clock.advance(1.0 / 120)
        clock.advance(1.0 / 120)
        XCTAssertFalse(clock.isRunning, "the clock stops once the fingers rest")
    }

    func testSettleDropsAWaitingValueAndStopsTheClock() {
        let clock = ManualPageClock()
        let stretch = IslandPullStretch(clock: clock)
        stretch.track(3)
        stretch.track(5)
        stretch.settle(reduceMotion: true)
        XCTAssertEqual(stretch.points, 0)
        XCTAssertFalse(clock.isRunning)
        clock.advance(1.0 / 120)
        XCTAssertEqual(stretch.points, 0, "the waiting 5 never lands on the settled outline")
    }
}
