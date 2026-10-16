import AppKit
import XCTest
@testable import IslaKit

/// When a scroll on the lyric stage means "I am reading", and when the page goes
/// back to the song by itself (owner, 2026-10-16: a slip of the hand lost the
/// synchronization for good). The gate is a value and the clock is handed in, so
/// every case here is a list of numbers.
final class LyricFollowGateTests: XCTestCase {
    private func vertical(
        _ dy: CGFloat, dx: CGFloat = 0, phase: ScrollSample.Phase = .changed,
        momentum: ScrollSample.Phase = .none
    ) -> ScrollSample {
        ScrollSample(deltaX: dx, deltaY: dy, phase: phase, momentumPhase: momentum)
    }

    // MARK: - Where and which way

    /// An event while the pointer is anywhere but the stage decides nothing and
    /// leaves no trace — not even the start of a gesture.
    func testAScrollOutsideTheStageIsIgnored() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(80), overStage: false, following: true, at: 0), .ignored)
        XCTAssertEqual(gate, LyricFollowGate(), "no state moved")
        XCTAssertNil(gate.settleIn(following: true, at: 0), "and nothing is waiting")
    }

    func testAMostlySidewaysSwipeIsIgnored() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(5, dx: 40), overStage: true, following: true, at: 0), .ignored)
        XCTAssertEqual(gate.handle(vertical(30, dx: -31), overStage: true, following: true, at: 0.01), .ignored)
        XCTAssertEqual(gate.travelled, 0, "no sideways travel is counted")
        // A diagonal that is more down than across is a scroll.
        XCTAssertEqual(gate.handle(vertical(30, dx: 29), overStage: true, following: true, at: 0.02), .stoppedFollowing)
    }

    /// The zero-delta events that open and close every trackpad phase are not
    /// scrolls.
    func testAZeroDistanceEventIsIgnored() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(0, phase: .mayBegin), overStage: true, following: true, at: 0), .ignored)
        XCTAssertEqual(gate.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 0.2), .ignored)
        XCTAssertNil(gate.settleIn(following: true, at: 0))
    }

    // MARK: - Distance, not a touch

    func testALightBrushDoesNotStopFollowing() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(1, phase: .began), overStage: true, following: true, at: 0), .nudged)
        XCTAssertEqual(gate.handle(vertical(3), overStage: true, following: true, at: 0.01), .nudged)
        XCTAssertEqual(gate.handle(vertical(-4), overStage: true, following: true, at: 0.02), .nudged, "either way counts")
        XCTAssertEqual(gate.travelled, 8)
    }

    func testTheGestureStopsFollowingOnceItReachesTwelvePoints() {
        XCTAssertEqual(LyricFollowGate.stopDistance, 12)
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(5, phase: .began), overStage: true, following: true, at: 0), .nudged)
        XCTAssertEqual(gate.handle(vertical(6), overStage: true, following: true, at: 0.01), .nudged, "11")
        XCTAssertEqual(gate.handle(vertical(1), overStage: true, following: true, at: 0.02), .stoppedFollowing, "12 exactly")
    }

    /// Two short gestures are not one long one: a new gesture starts on
    /// `began`, and after half a second of silence.
    func testEachGestureCountsFromZero() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(8, phase: .began), overStage: true, following: true, at: 0), .nudged)
        // A new touch: 8 + 8 would be 16, but this is a fresh gesture.
        XCTAssertEqual(gate.handle(vertical(8, phase: .began), overStage: true, following: true, at: 0.1), .nudged)
        XCTAssertEqual(gate.travelled, 8)

        // The same for the silence: no `began`, as a notched wheel sends none.
        var wheel = LyricFollowGate()
        XCTAssertEqual(wheel.handle(vertical(8, phase: .none), overStage: true, following: true, at: 0), .nudged)
        XCTAssertEqual(wheel.handle(vertical(8, phase: .none), overStage: true, following: true, at: 0.5), .stoppedFollowing,
                       "0.5 s is still the same gesture")
        var later = LyricFollowGate()
        XCTAssertEqual(later.handle(vertical(8, phase: .none), overStage: true, following: true, at: 0), .nudged)
        XCTAssertEqual(later.handle(vertical(8, phase: .none), overStage: true, following: true, at: 0.51), .nudged,
                       "past 0.5 s it is a new gesture")
        XCTAssertEqual(later.travelled, 8)
    }

    /// The glide after the fingers lift belongs to the gesture that flicked it,
    /// however long since the last event the pause looked.
    func testMomentumIsTheSameGesture() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(7, phase: .changed), overStage: true, following: true, at: 0), .nudged)
        XCTAssertEqual(gate.handle(vertical(7, phase: .ended), overStage: true, following: true, at: 0.01), .stoppedFollowing)
        var slow = LyricFollowGate()
        XCTAssertEqual(slow.handle(vertical(7, phase: .changed), overStage: true, following: true, at: 0), .nudged)
        XCTAssertEqual(
            slow.handle(vertical(7, phase: .none, momentum: .began), overStage: true, following: true, at: 0.8),
            .stoppedFollowing, "the glide began late, and is still the flick's"
        )
    }

    func testAWheelNotchIsDeliberate() throws {
        // `ScrollSample(NSEvent)` scales a notched wheel's lines to points; one
        // line reaches the stop distance on its own.
        XCTAssertGreaterThanOrEqual(LyricFollowGate.wheelLinePoints, LyricFollowGate.stopDistance)
    }

    // MARK: - Coming back

    func testItFollowsAgainFourSecondsAfterTheLastScroll() {
        XCTAssertEqual(LyricFollowGate.resumeDelay, 4)
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 10), .stoppedFollowing)
        let wait = { (now: TimeInterval) in gate.settleIn(following: false, at: now) }
        XCTAssertEqual(try XCTUnwrap(wait(10)), 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(wait(13.5)), 0.5, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wait(14)), 0, "due at 14 s")
    }

    /// Momentum arrives after the fingers have gone, and holds the page back
    /// the same: the four seconds run from the last event of any kind.
    func testMomentumPostponesTheResume() throws {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertEqual(gate.handle(vertical(15, phase: .none, momentum: .changed), overStage: true, following: false, at: 1.2), .kept)
        XCTAssertEqual(try XCTUnwrap(gate.settleIn(following: false, at: 1.2)), 4, accuracy: 1e-9)
    }

    func testANewScrollPostponesTheResume() throws {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertEqual(try XCTUnwrap(gate.settleIn(following: false, at: 3)), 1, accuracy: 1e-9)
        // The reader scrolls again at 3 s — any vertical movement over the
        // stage, however small: they are plainly still reading.
        XCTAssertEqual(gate.handle(vertical(1, phase: .began), overStage: true, following: false, at: 3), .kept)
        XCTAssertEqual(try XCTUnwrap(gate.settleIn(following: false, at: 3)), 4, accuracy: 1e-9, "four seconds from the new scroll")
        XCTAssertEqual(try XCTUnwrap(gate.settleIn(following: false, at: 6.9)), 0.1, accuracy: 1e-9)
    }

    /// While reading, a scroll somewhere else or a sideways one is no sign of
    /// reading, and does not postpone anything.
    func testIgnoredEventsDoNotPostponeTheResume() throws {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertEqual(gate.handle(vertical(30), overStage: false, following: false, at: 3), .ignored)
        XCTAssertEqual(gate.handle(vertical(2, dx: 50), overStage: true, following: false, at: 3), .ignored)
        XCTAssertEqual(try XCTUnwrap(gate.settleIn(following: false, at: 3)), 1, accuracy: 1e-9)
    }

    /// Tapping a line, the Sync pill and Sync Here resume at once and reset the
    /// gate, so the next scroll starts from nothing and no old wait is pending.
    func testResetClearsEverything() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        gate.reset()
        XCTAssertEqual(gate, LyricFollowGate())
        XCTAssertNil(gate.settleIn(following: false, at: 1))
        XCTAssertEqual(gate.handle(vertical(5), overStage: true, following: true, at: 2), .nudged, "from nothing again")
    }

    /// A brush that moved the page without stopping it is put back half a second
    /// after the hand has gone, rather than left a few points off until the next
    /// line turns.
    func testABrushIsSettledHalfASecondAfterTheHandLeaves() throws {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 5), .nudged)
        XCTAssertEqual(try XCTUnwrap(gate.settleIn(following: true, at: 5)), 0.5, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(try XCTUnwrap(gate.settleIn(following: true, at: 5.5)), 0)
    }

    // MARK: - The event, apart from AppKit

    func testPhasesMapFromAppKit() {
        XCTAssertEqual(ScrollSample.Phase([]), .none)
        XCTAssertEqual(ScrollSample.Phase(.mayBegin), .mayBegin)
        XCTAssertEqual(ScrollSample.Phase(.began), .began)
        XCTAssertEqual(ScrollSample.Phase(.changed), .changed)
        XCTAssertEqual(ScrollSample.Phase(.ended), .ended)
        XCTAssertEqual(ScrollSample.Phase(.cancelled), .cancelled)
        XCTAssertEqual(ScrollSample.Phase([.began, .changed]), .began)
        XCTAssertTrue(vertical(1, phase: .none, momentum: .changed).isMomentum)
        XCTAssertFalse(vertical(1, phase: .changed).isMomentum)
    }
}
