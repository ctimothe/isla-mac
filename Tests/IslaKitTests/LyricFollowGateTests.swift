import AppKit
import XCTest
@testable import IslaKit

/// When a scroll on the lyric stage means "I am reading", and when the page goes
/// back to the song by itself (owner, 2026-10-16: a slip of the hand lost the
/// synchronization for good). The gate is a value and the clock is handed in, so
/// every case here is a list of numbers.
@MainActor
final class LyricFollowGateTests: XCTestCase {
    private func vertical(
        _ dy: CGFloat, dx: CGFloat = 0, phase: ScrollSample.Phase = .changed,
        momentum: ScrollSample.Phase = .none
    ) -> ScrollSample {
        ScrollSample(deltaX: dx, deltaY: dy, phase: phase, momentumPhase: momentum)
    }

    /// `isLive` with the pointer as a plain Bool: off the stage by default.
    private func live(_ gate: LyricFollowGate, at now: TimeInterval, over: Bool = false) -> Bool {
        gate.isLive(at: now, pointerOverStage: { over })
    }

    // MARK: - Where and which way

    /// An event while the pointer is anywhere but the stage decides nothing and
    /// leaves no trace — not even the start of a gesture.
    func testAScrollOutsideTheStageIsIgnored() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(80), overStage: false, following: true, at: 0), .ignored)
        XCTAssertEqual(gate, LyricFollowGate(), "no state moved")
        XCTAssertEqual(settle(gate, following: true, at: 0), .none, "and nothing is waiting")
    }

    func testAMostlySidewaysSwipeIsIgnored() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(5, dx: 40), overStage: true, following: true, at: 0), .ignored)
        XCTAssertEqual(gate.handle(vertical(30, dx: -31), overStage: true, following: true, at: 0.01), .ignored)
        XCTAssertEqual(gate.travelled, 0, "no sideways travel is counted")
        // A diagonal that is more down than across is a scroll.
        XCTAssertEqual(gate.handle(vertical(30, dx: 29), overStage: true, following: true, at: 0.02), .stoppedFollowing)
    }

    /// A zero-delta event that is no hold is not a scroll: nothing is counted,
    /// and an end with nothing live leaves no state. (`mayBegin` and `began`
    /// hold the page; see `testTwoFingersLaidDownHoldThePage`.)
    func testAZeroDistanceEventIsIgnored() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(0, phase: .changed), overStage: true, following: true, at: 0), .ignored)
        XCTAssertEqual(gate.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 0.2), .ignored)
        XCTAssertEqual(settle(gate, following: true, at: 0), .none)
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

    // MARK: - A live trackpad gesture

    /// Slow reading: 6 pt, a pause longer than the silence rule with the fingers
    /// still down, 6 pt. A trackpad sends nothing while the fingers rest, and
    /// this is one gesture all the same; the tally must not reset on the gap.
    func testSlowReadingWithFingersDownStillDetaches() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(6, phase: .began), overStage: true, following: true, at: 0), .nudged)
        XCTAssertTrue(live(gate, at: 0.1))
        XCTAssertEqual(gate.handle(vertical(6, phase: .changed), overStage: true, following: true, at: 1.4),
                       .stoppedFollowing, "fingers never lifted, so 6 + 6 reaches 12")
    }

    /// A gesture is live from `began` to the fingers lifting and the glide
    /// ending.
    func testALiveGestureRunsFromBeganThroughMomentumEnd() {
        var gate = LyricFollowGate()
        XCTAssertFalse(live(gate, at: 0))
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertTrue(live(gate, at: 5), "fingers resting for five seconds: still live")
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 5.1)
        XCTAssertFalse(live(gate, at: 5.1), "fingers lifted, no glide")
        _ = gate.handle(vertical(3, phase: .none, momentum: .began), overStage: true, following: true, at: 5.15)
        XCTAssertTrue(live(gate, at: 5.2), "a glide began")
        _ = gate.handle(vertical(0, phase: .none, momentum: .ended), overStage: true, following: true, at: 5.6)
        XCTAssertFalse(live(gate, at: 5.6))
    }

    /// Item 4: events with no phase at all — a notched wheel, a smooth-scroll
    /// utility, a mouse driver with fine deltas — are live for the silence gap
    /// after each, so line-follow does not centre under a hand moving the page.
    func testPhaselessScrollsAreLiveForTheGapAfterEachEvent() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(1, phase: .none), overStage: true, following: true, at: 10)
        XCTAssertTrue(live(gate, at: 10.2))
        XCTAssertTrue(live(gate, at: 10.49))
        XCTAssertFalse(live(gate, at: 10.5), "0.5 s of silence ends it")
        _ = gate.handle(vertical(1, phase: .none), overStage: true, following: true, at: 10.4)
        XCTAssertTrue(live(gate, at: 10.8), "each event extends it")
        XCTAssertFalse(LyricsStage.centresOnLineChange(following: true, gestureIsLive: live(gate, at: 10.8)))
        // And a phased event takes over: no phaseless clock after it.
        _ = gate.handle(vertical(1, phase: .began), overStage: true, following: true, at: 20)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 20.1)
        XCTAssertFalse(live(gate, at: 20.2))
    }

    /// The end arrives even when the pointer has wandered off the stage, or the
    /// gesture would be live for good.
    func testTheEndOfAGestureIsHeardAnywhere() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertEqual(gate.handle(vertical(0, phase: .ended), overStage: false, following: true, at: 1), .ignored)
        XCTAssertFalse(live(gate, at: 1))
    }

    /// Item 1. A trackpad sends nothing while the fingers rest, which looks the
    /// same as an end event that never came. A silent gesture is let go of after
    /// the timeout only when the pointer is off the stage; over it, it stays
    /// live — and the page is not recentred, resumed or the tally reset.
    func testALongRestWithThePointerOnTheStageStaysLive() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(6, phase: .began), overStage: true, following: true, at: 0), .nudged)
        let long = LyricFollowGate.liveTimeout + 20
        XCTAssertTrue(live(gate, at: long, over: true), "resting on the pad, pointer over the stage")
        XCTAssertEqual(
            gate.settle(following: true, pointerOverStage: { true }, at: long), .wait(LyricFollowGate.liveRecheck),
            "no recentre under the hand"
        )
        XCTAssertEqual(
            gate.settle(following: false, pointerOverStage: { true }, at: long), .wait(LyricFollowGate.liveRecheck),
            "no resume under the hand"
        )
        XCTAssertEqual(gate.travelled, 6, "the tally survives the rest")
        // The reader moves again after the long pause: 6 + 6 reaches 12.
        XCTAssertEqual(
            gate.handle(vertical(6, phase: .changed), overStage: true, following: true, at: long),
            .stoppedFollowing
        )
    }

    /// And with the pointer gone, the silent gesture is let go of.
    func testALongRestWithThePointerAwayIsLetGo() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertTrue(live(gate, at: LyricFollowGate.liveTimeout, over: false))
        XCTAssertFalse(live(gate, at: LyricFollowGate.liveTimeout + 0.1, over: false))
        XCTAssertEqual(
            gate.settle(following: true, pointerOverStage: { false }, at: LyricFollowGate.liveTimeout + 0.1), .recentre
        )
    }

    /// The stage does not centre on a turning line under a hand that is moving
    /// the page, nor while it is not following.
    func testLineFollowIsPausedDuringALiveGesture() {
        XCTAssertTrue(LyricsStage.centresOnLineChange(following: true, gestureIsLive: false))
        XCTAssertFalse(LyricsStage.centresOnLineChange(following: true, gestureIsLive: true))
        XCTAssertFalse(LyricsStage.centresOnLineChange(following: false, gestureIsLive: false))
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertFalse(LyricsStage.centresOnLineChange(following: true, gestureIsLive: live(gate, at: 0.2)))
    }

    // MARK: - Putting the page back after a brush

    private func settle(
        _ gate: LyricFollowGate, following: Bool, over: Bool = false, at now: TimeInterval
    ) -> LyricFollowGate.Settle {
        gate.settle(following: following, pointerOverStage: { over }, at: now)
    }

    /// No recentre while the gesture is live, however long since the last
    /// event; resting fingers send none.
    func testNoRecentreWhileTheGestureIsLive() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertEqual(settle(gate, following: true, at: 0.1), .wait(LyricFollowGate.liveRecheck))
        XCTAssertEqual(settle(gate, following: true, at: 9), .wait(LyricFollowGate.liveRecheck), "fingers still down")
    }

    /// After the fingers lift and the glide ends, the page is put back half a
    /// second later.
    func testRecentreAfterTheGestureHasEndedAndMomentumToo() throws {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        _ = gate.handle(vertical(2, phase: .ended), overStage: true, following: true, at: 0.25)
        _ = gate.handle(vertical(2, phase: .none, momentum: .began), overStage: true, following: true, at: 0.25)
        XCTAssertEqual(settle(gate, following: true, at: 0.5), .wait(LyricFollowGate.liveRecheck), "the glide is running")
        _ = gate.handle(vertical(0, phase: .none, momentum: .ended), overStage: true, following: true, at: 0.5)
        XCTAssertEqual(settle(gate, following: true, at: 0.5), .wait(0.5), "half a second after the glide ends")
        XCTAssertEqual(settle(gate, following: true, at: 1), .recentre)
    }

    /// A wheel has no end event: it is put back half a second after the notch.
    func testAWheelIsRecentredAfterTheGap() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(3, phase: .none), overStage: true, following: true, at: 2), .nudged)
        XCTAssertEqual(settle(gate, following: true, at: 2.25), .wait(0.25))
        XCTAssertEqual(settle(gate, following: true, at: 2.5), .recentre)
    }

    /// The wheel keeps the silence rule for the tally too.
    func testAWheelGapStartsANewGesture() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .none), overStage: true, following: true, at: 0)
        XCTAssertEqual(gate.handle(vertical(3, phase: .none), overStage: true, following: true, at: 0.4), .nudged)
        XCTAssertEqual(gate.travelled, 6)
        XCTAssertEqual(gate.handle(vertical(3, phase: .none), overStage: true, following: true, at: 1.0), .nudged)
        XCTAssertEqual(gate.travelled, 3, "0.6 s of silence: a new gesture")
    }

    /// Item 2: the recentre is timed from the lift, not from the last movement.
    /// A brush, fingers resting three seconds, then lifting: the page is not put
    /// back as the fingers leave, but half a second after.
    func testRecentreIsTimedFromTheLiftNotTheLastMovement() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertEqual(settle(gate, following: true, at: 3), .wait(LyricFollowGate.liveRecheck), "resting")
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 3)
        XCTAssertEqual(settle(gate, following: true, at: 3), .wait(0.5), "half a second from the lift")
        XCTAssertEqual(settle(gate, following: true, at: 3.5), .recentre)
    }

    /// Item 2, for the glide: from its end.
    func testRecentreIsTimedFromTheEndOfTheGlide() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(3, phase: .began), overStage: true, following: true, at: 0)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 0.5)
        _ = gate.handle(vertical(2, phase: .none, momentum: .began), overStage: true, following: true, at: 0.5)
        _ = gate.handle(vertical(0, phase: .none, momentum: .ended), overStage: true, following: true, at: 2)
        XCTAssertEqual(settle(gate, following: true, at: 2), .wait(0.5))
    }

    /// Item 3: two fingers laid on the pad and not moved hold the page —
    /// `mayBegin`, or a `began` with no distance — and a cancel ends it like a
    /// lift.
    func testTwoFingersLaidDownHoldThePage() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(0, phase: .mayBegin), overStage: true, following: true, at: 0), .held)
        XCTAssertTrue(live(gate, at: 2), "held, however long")
        XCTAssertEqual(gate.travelled, 0, "no distance added")
        XCTAssertFalse(LyricsStage.centresOnLineChange(following: true, gestureIsLive: live(gate, at: 2)))
        XCTAssertEqual(settle(gate, following: true, at: 2), .wait(LyricFollowGate.liveRecheck))
        // Lifted without moving: a cancel, the same as an end.
        _ = gate.handle(vertical(0, phase: .cancelled), overStage: true, following: true, at: 3)
        XCTAssertFalse(live(gate, at: 3))
        XCTAssertEqual(settle(gate, following: true, at: 3.5), .recentre)

        var began = LyricFollowGate()
        XCTAssertEqual(began.handle(vertical(0, phase: .began), overStage: true, following: true, at: 0), .held)
        XCTAssertTrue(live(began, at: 1))
        _ = began.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 1)
        XCTAssertFalse(live(began, at: 1))
    }

    /// Laying fingers elsewhere holds nothing, and a stray end with nothing live
    /// creates no state.
    func testHoldsElsewhereAndStrayEndsDoNothing() {
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(0, phase: .mayBegin), overStage: false, following: true, at: 0), .ignored)
        XCTAssertEqual(gate.handle(vertical(0, phase: .ended), overStage: true, following: true, at: 1), .ignored)
        XCTAssertEqual(gate, LyricFollowGate())
    }

    // MARK: - Coming back

    func testItFollowsAgainFourSecondsAfterTheLastScroll() throws {
        XCTAssertEqual(LyricFollowGate.resumeDelay, 4)
        var gate = LyricFollowGate()
        XCTAssertEqual(gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 10), .stoppedFollowing)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: false, at: 10)
        XCTAssertEqual(settle(gate, following: false, at: 10), .wait(4))
        XCTAssertEqual(settle(gate, following: false, at: 13.5), .wait(0.5))
        XCTAssertEqual(settle(gate, following: false, at: 14), .resume, "due at 14 s with the pointer away")
    }

    /// Resting fingers hold the page where it is however long they rest.
    func testNoResumeWhileFingersAreStillDown() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        XCTAssertEqual(settle(gate, following: false, at: 14), .wait(LyricFollowGate.liveRecheck))
    }

    /// Reading a verse with the pointer still over the stage is not interrupted:
    /// the resume is due but waits, asks again every second, and fires the
    /// moment the pointer has left.
    func testResumeWaitsWhileThePointerIsOverTheStageAndFiresWhenItLeaves() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: false, at: 0)
        XCTAssertEqual(settle(gate, following: false, over: true, at: 4), .wait(LyricFollowGate.pointerRecheck))
        XCTAssertEqual(settle(gate, following: false, over: true, at: 30), .wait(LyricFollowGate.pointerRecheck),
                       "however long the pointer rests there")
        XCTAssertEqual(settle(gate, following: false, over: false, at: 30.5), .resume, "it left: back at once")
        // And the pointer is not even asked before the four seconds are up.
        var asked = false
        _ = gate.settle(following: false, pointerOverStage: { asked = true; return false }, at: 2)
        XCTAssertFalse(asked)
    }

    /// Momentum arrives after the fingers have gone, and holds the page back
    /// the same: the four seconds run from the last event of any kind.
    func testMomentumPostponesTheResume() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: false, at: 0)
        XCTAssertEqual(gate.handle(vertical(15, phase: .none, momentum: .changed), overStage: true, following: false, at: 1.25), .kept)
        _ = gate.handle(vertical(0, phase: .none, momentum: .ended), overStage: true, following: false, at: 1.25)
        XCTAssertEqual(settle(gate, following: false, at: 1.25), .wait(4), "from the glide, not from the lift before it")
    }

    func testANewScrollPostponesTheResume() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: false, at: 0)
        XCTAssertEqual(settle(gate, following: false, at: 3), .wait(1))
        XCTAssertEqual(gate.handle(vertical(1, phase: .began), overStage: true, following: false, at: 3), .kept)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: false, at: 3)
        XCTAssertEqual(settle(gate, following: false, at: 3), .wait(4), "four seconds from the new scroll")
        XCTAssertEqual(settle(gate, following: false, at: 7), .resume)
    }

    /// While reading, a scroll somewhere else or a sideways one is no sign of
    /// reading, and does not postpone anything.
    func testIgnoredEventsDoNotPostponeTheResume() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        _ = gate.handle(vertical(0, phase: .ended), overStage: true, following: false, at: 0)
        XCTAssertEqual(gate.handle(vertical(30), overStage: false, following: false, at: 3), .ignored)
        XCTAssertEqual(gate.handle(vertical(2, dx: 50), overStage: true, following: false, at: 3), .ignored)
        XCTAssertEqual(settle(gate, following: false, at: 3), .wait(1))
    }

    /// Tapping a line, the Sync pill and Sync Here resume at once and reset the
    /// gate, so the next scroll starts from nothing and no old wait is pending.
    func testResetClearsEverything() {
        var gate = LyricFollowGate()
        _ = gate.handle(vertical(20, phase: .began), overStage: true, following: true, at: 0)
        gate.reset()
        XCTAssertEqual(gate, LyricFollowGate())
        XCTAssertFalse(live(gate, at: 0))
        XCTAssertEqual(settle(gate, following: false, at: 1), .none)
        XCTAssertEqual(gate.handle(vertical(5), overStage: true, following: true, at: 2), .nudged, "from nothing again")
    }

    // MARK: - The pointer seam

    /// The stage's pointer check compares the mouse's screen location with the
    /// anchor view's screen rect; the window is never shown.
    func testThePointerIsOverTheStageWhenItsScreenRectHoldsTheMouse() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let view = NSView(frame: NSRect(x: 50, y: 60, width: 100, height: 80))
        window.contentView?.addSubview(view)
        let pointer = StagePointer()
        pointer.view = view
        // The view's screen rect: window origin + (50, 60), 100 x 80.
        pointer.location = { NSPoint(x: 160, y: 270) }
        XCTAssertTrue(pointer.isOver())
        pointer.location = { NSPoint(x: 149, y: 270) }
        XCTAssertFalse(pointer.isOver(), "just left of it")
        pointer.location = { NSPoint(x: 160, y: 341) }
        XCTAssertFalse(pointer.isOver(), "just above it")
        pointer.view = nil
        XCTAssertFalse(pointer.isOver(), "no view, no stage")
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
