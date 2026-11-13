import XCTest
@testable import IslaKit

/// The island's timer and stopwatch, played out with a clock the test moves
/// and a list of wake-ups it fires by hand.
///
/// `IslandTimerState` is arithmetic on dates and is held by the first group.
/// What could go wrong silently is the sequencing in `IslandTimerCenter`: a
/// pause that leaves the old finish armed, an extend that forgets to re-arm, a
/// replaced countdown whose old wake-up survives, a timer that finished while
/// the app was away being rung late. Each of those is a test below.
@MainActor
final class IslandTimerTests: XCTestCase {
    /// The system as the test scripts it: a settable clock and every scheduled
    /// wake-up, kept so the test can see what is armed and fire it.
    @MainActor final class Rig {
        struct Scheduled {
            var delay: TimeInterval
            var work: @MainActor @Sendable () -> Void
            var cancelled = false
            var fired = false
        }

        var now = Date(timeIntervalSince1970: 1_000_000)
        var scheduled: [Scheduled] = []
        var finishes = 0
        var changes = 0
        private var observation: Any?

        lazy var center: IslandTimerCenter = {
            let center = IslandTimerCenter(environment: IslandTimerCenter.Environment(
                now: { [unowned self] in self.now },
                after: { [unowned self] delay, work in
                    let index = self.scheduled.count
                    self.scheduled.append(Scheduled(delay: delay, work: work))
                    return { [unowned self] in self.scheduled[index].cancelled = true }
                }
            ))
            center.onCountdownFinished = { [unowned self] in self.finishes += 1 }
            observation = center.objectWillChange.sink { [unowned self] _ in self.changes += 1 }
            return center
        }()

        /// Wake-ups still armed: not cancelled and not yet run.
        var armed: [Scheduled] { scheduled.filter { !$0.cancelled && !$0.fired } }

        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

        /// Runs the wake-up at `index` as the timer would, whether or not it
        /// was cancelled, so a test can prove a cancelled one is harmless.
        func fire(_ index: Int) {
            scheduled[index].fired = true
            scheduled[index].work()
        }
    }

    // MARK: State arithmetic

    func testStateElapsedRemainingAndProgress() {
        let start = Date(timeIntervalSince1970: 100)
        let state = IslandTimerState(kind: .countdown(duration: 300), runningSince: start, banked: 60)
        let now = start.addingTimeInterval(90)
        XCTAssertEqual(state.elapsed(at: now), 150, accuracy: 1e-9)
        XCTAssertEqual(state.remaining(at: now) ?? -1, 150, accuracy: 1e-9)
        XCTAssertEqual(state.progress(at: now) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertFalse(state.isFinished(at: now))
        XCTAssertFalse(state.isPaused)
    }

    func testCountdownClampsAtZeroAndFullProgress() {
        let start = Date(timeIntervalSince1970: 100)
        let state = IslandTimerState(kind: .countdown(duration: 10), runningSince: start, banked: 0)
        let late = start.addingTimeInterval(500)
        XCTAssertEqual(state.remaining(at: late), 0)
        XCTAssertEqual(state.progress(at: late), 1)
        XCTAssertTrue(state.isFinished(at: late))
        XCTAssertTrue(state.isFinished(at: start.addingTimeInterval(10)))
        XCTAssertFalse(state.isFinished(at: start.addingTimeInterval(9.99)))
    }

    func testStopwatchHasNoRemainingProgressOrFinish() {
        let start = Date(timeIntervalSince1970: 100)
        let state = IslandTimerState(kind: .stopwatch, runningSince: start, banked: 5)
        let now = start.addingTimeInterval(7)
        XCTAssertEqual(state.elapsed(at: now), 12, accuracy: 1e-9)
        XCTAssertNil(state.remaining(at: now))
        XCTAssertNil(state.progress(at: now))
        XCTAssertFalse(state.isFinished(at: now.addingTimeInterval(1_000_000)))
    }

    func testClockStepBackNeverRunsTheTimerBackwards() {
        let start = Date(timeIntervalSince1970: 100)
        let state = IslandTimerState(kind: .stopwatch, runningSince: start, banked: 5)
        XCTAssertEqual(state.elapsed(at: start.addingTimeInterval(-60)), 5)
    }

    func testPausedStateDoesNotAdvance() {
        let state = IslandTimerState(kind: .stopwatch, runningSince: nil, banked: 42)
        XCTAssertTrue(state.isPaused)
        XCTAssertEqual(state.elapsed(at: .distantFuture), 42)
    }

    // MARK: Countdown

    func testStartSetsRemainingProgressAndSchedulesExactlyTheRemainingTime() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 300)
        let state = try! XCTUnwrap(rig.center.countdown)
        XCTAssertEqual(state.remaining(at: rig.now), 300)
        XCTAssertEqual(state.progress(at: rig.now), 0)
        XCTAssertEqual(rig.armed.map(\.delay), [300])
        rig.advance(75)
        XCTAssertEqual(rig.center.countdown?.remaining(at: rig.now), 225)
        XCTAssertEqual(rig.center.countdown?.progress(at: rig.now) ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rig.finishes, 0)
    }

    func testStartClampsTheLength() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 0)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 1))
        rig.center.startCountdown(seconds: -50)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 1))
        rig.center.startCountdown(seconds: 1_000_000)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 86_400))
        rig.center.startCountdown(seconds: .nan)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 1))
        rig.center.startCountdown(seconds: .infinity)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 86_400))
    }

    func testPauseBanksTimeAndCancelsTheScheduledFinish() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 300)
        rig.advance(100)
        rig.center.pauseCountdown()
        let state = try! XCTUnwrap(rig.center.countdown)
        XCTAssertTrue(state.isPaused)
        XCTAssertEqual(state.banked, 100)
        XCTAssertTrue(rig.armed.isEmpty, "a paused countdown must have nothing armed")
        rig.advance(10_000)
        XCTAssertEqual(rig.center.countdown?.remaining(at: rig.now), 200)
        XCTAssertEqual(rig.finishes, 0)
    }

    func testResumeReschedulesForTheRemainingTime() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 300)
        rig.advance(100)
        rig.center.pauseCountdown()
        rig.advance(50)
        rig.center.resumeCountdown()
        XCTAssertEqual(rig.armed.map(\.delay), [200])
        XCTAssertFalse(rig.center.countdown?.isPaused ?? true)
        rig.advance(200)
        rig.fire(rig.scheduled.count - 1)
        XCTAssertEqual(rig.finishes, 1)
        XCTAssertNil(rig.center.countdown)
    }

    func testExtendWhileRunningRearmsForTheNewRemainingTime() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 300)
        rig.advance(100)
        rig.center.extendCountdown(by: 60)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 360))
        XCTAssertEqual(rig.center.countdown?.remaining(at: rig.now), 260)
        XCTAssertEqual(rig.armed.map(\.delay), [260], "only the new wake-up stays armed")
        XCTAssertTrue(rig.scheduled[0].cancelled)
        // The old wake-up running anyway must not ring: 200 s remain from its time.
        rig.advance(200)
        rig.fire(0)
        XCTAssertEqual(rig.finishes, 0)
        XCTAssertNotNil(rig.center.countdown)
    }

    func testExtendWhilePausedSchedulesNothing() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 300)
        rig.advance(100)
        rig.center.pauseCountdown()
        rig.center.extendCountdown(by: 60)
        XCTAssertEqual(rig.center.countdown?.remaining(at: rig.now), 260)
        XCTAssertTrue(rig.armed.isEmpty)
        rig.center.resumeCountdown()
        XCTAssertEqual(rig.armed.map(\.delay), [260])
    }

    func testExtendIgnoresNonsenseAndCapsAtADay() {
        let rig = Rig()
        rig.center.extendCountdown(by: 60)
        XCTAssertNil(rig.center.countdown)
        rig.center.startCountdown(seconds: 300)
        rig.center.extendCountdown(by: 0)
        rig.center.extendCountdown(by: -5)
        rig.center.extendCountdown(by: .nan)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 300))
        rig.center.extendCountdown(by: 1_000_000)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 86_400))
    }

    func testFinishFiresExactlyOnceAndClearsTheCountdown() {
        let rig = Rig()
        var seenCleared = false
        rig.center.onCountdownFinished = { [unowned rig] in
            rig.finishes += 1
            seenCleared = rig.center.countdown == nil
        }
        rig.center.startCountdown(seconds: 60)
        rig.advance(60)
        rig.fire(0)
        XCTAssertEqual(rig.finishes, 1)
        XCTAssertTrue(seenCleared, "the countdown is cleared before the callback runs")
        XCTAssertNil(rig.center.countdown)
        rig.fire(0)
        XCTAssertEqual(rig.finishes, 1, "a second run of the same wake-up must not ring again")
    }

    func testAWakeUpThatRunsEarlyWaitsOutWhatIsLeft() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 60)
        rig.advance(50)
        rig.fire(0)
        XCTAssertEqual(rig.finishes, 0)
        XCTAssertEqual(rig.armed.map(\.delay), [10])
    }

    func testACallAfterTheDeadlineReadsFinishedEvenIfTheWakeUpNeverRan() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 60)
        rig.advance(3_600)   // the Mac slept through it
        rig.center.extendCountdown(by: 60)
        XCTAssertEqual(rig.finishes, 1)
        XCTAssertNil(rig.center.countdown, "extend does not revive a countdown that already ended")
        XCTAssertTrue(rig.armed.isEmpty)
    }

    func testCancelNeverFires() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 60)
        rig.center.cancelCountdown()
        XCTAssertNil(rig.center.countdown)
        XCTAssertTrue(rig.armed.isEmpty)
        rig.advance(60)
        rig.fire(0)
        XCTAssertEqual(rig.finishes, 0)
    }

    func testReplacingACountdownCancelsTheOldSchedule() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 60)
        rig.advance(10)
        rig.center.startCountdown(seconds: 300)
        XCTAssertTrue(rig.scheduled[0].cancelled)
        XCTAssertEqual(rig.armed.map(\.delay), [300])
        XCTAssertEqual(rig.center.countdown?.elapsed(at: rig.now), 0)
        // The old wake-up running regardless must not end the new countdown.
        rig.advance(50)
        rig.fire(0)
        XCTAssertEqual(rig.finishes, 0)
        XCTAssertNotNil(rig.center.countdown)
    }

    func testRepeatedNoOpsPublishNothing() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 300)
        rig.center.startStopwatch()
        rig.center.pauseCountdown()
        rig.center.pauseStopwatch()
        let settled = rig.changes
        rig.center.pauseCountdown()
        rig.center.pauseStopwatch()
        rig.center.resumeCountdown()
        rig.center.resumeStopwatch()
        let resumed = rig.changes
        XCTAssertEqual(resumed, settled + 2)
        rig.center.resumeCountdown()
        rig.center.resumeStopwatch()
        rig.center.startStopwatch()
        rig.center.resetStopwatch()
        rig.center.resetStopwatch()
        rig.center.cancelCountdown()
        rig.center.cancelCountdown()
        XCTAssertEqual(rig.changes, resumed + 2, "reset and cancel: one change each, the repeats none")
    }

    // MARK: Stopwatch

    func testStopwatchElapsedAcrossPauseResumeAndReset() {
        let rig = Rig()
        rig.center.startStopwatch()
        rig.advance(30)
        rig.center.pauseStopwatch()
        rig.advance(1_000)
        XCTAssertEqual(rig.center.stopwatch?.elapsed(at: rig.now), 30)
        rig.center.resumeStopwatch()
        rig.advance(15)
        XCTAssertEqual(rig.center.stopwatch?.elapsed(at: rig.now), 45)
        XCTAssertTrue(rig.armed.isEmpty, "a stopwatch never schedules anything")
        rig.center.resetStopwatch()
        XCTAssertNil(rig.center.stopwatch)
        rig.center.startStopwatch()
        XCTAssertEqual(rig.center.stopwatch?.elapsed(at: rig.now), 0)
    }

    func testStartingAStopwatchOverOneThatIsThereKeepsItsTime() {
        let rig = Rig()
        rig.center.startStopwatch()
        rig.advance(20)
        rig.center.startStopwatch()
        XCTAssertEqual(rig.center.stopwatch?.elapsed(at: rig.now), 20)
    }

    func testCountdownAndStopwatchAreIndependent() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 60)
        rig.center.startStopwatch()
        rig.center.cancelCountdown()
        XCTAssertNotNil(rig.center.stopwatch)
        rig.center.startCountdown(seconds: 60)
        rig.center.resetStopwatch()
        XCTAssertNotNil(rig.center.countdown)
    }

    // MARK: Format

    func testFormatEdgeCases() {
        typealias Center = IslandTimerCenter
        XCTAssertEqual(Center.format(0, roundingUp: true), "0:00")
        XCTAssertEqual(Center.format(0, roundingUp: false), "0:00")
        XCTAssertEqual(Center.format(0.2, roundingUp: true), "0:01")
        XCTAssertEqual(Center.format(0.2, roundingUp: false), "0:00")
        XCTAssertEqual(Center.format(59.9, roundingUp: false), "0:59")
        XCTAssertEqual(Center.format(59.9, roundingUp: true), "1:00")
        XCTAssertEqual(Center.format(3600, roundingUp: true), "1:00:00")
        XCTAssertEqual(Center.format(3600, roundingUp: false), "1:00:00")
        XCTAssertEqual(Center.format(3599.5, roundingUp: false), "59:59")
        XCTAssertEqual(Center.format(3599.5, roundingUp: true), "1:00:00")
        XCTAssertEqual(Center.format(5 * 60, roundingUp: true), "5:00")
        XCTAssertEqual(Center.format(3_725, roundingUp: false), "1:02:05")
        XCTAssertEqual(Center.format(86_400, roundingUp: true), "24:00:00")
        XCTAssertEqual(Center.format(-3, roundingUp: true), "0:00")
        XCTAssertEqual(Center.format(.nan, roundingUp: false), "0:00")
        XCTAssertEqual(Center.format(.infinity, roundingUp: false), "0:00")
    }

    func testTheWingsShowFiveMinutesRightAfterStartingAndOneInTheLastSecond() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 5 * 60)
        let state = try! XCTUnwrap(rig.center.countdown)
        XCTAssertEqual(IslandTimerCenter.format(state.remaining(at: rig.now) ?? 0, roundingUp: true), "5:00")
        rig.advance(299.4)
        XCTAssertEqual(IslandTimerCenter.format(rig.center.countdown?.remaining(at: rig.now) ?? 0, roundingUp: true), "0:01")
    }

    func testPresetMinutes() {
        XCTAssertEqual(IslandTimerCenter.presetMinutes, [1, 3, 5, 10, 15, 25, 30, 60])
    }

    // MARK: Persistence

    func testSnapshotRoundTripsThroughJSON() throws {
        let rig = Rig()
        rig.center.startCountdown(seconds: 600)
        rig.advance(45)
        rig.center.pauseCountdown()
        rig.center.startStopwatch()
        rig.advance(5)
        let snapshot = rig.center.snapshot
        XCTAssertNotNil(snapshot.countdown)
        XCTAssertNotNil(snapshot.stopwatch)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(IslandTimerCenter.Snapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)

        let other = Rig()
        other.now = rig.now
        other.center.restore(decoded)
        XCTAssertEqual(other.center.countdown, snapshot.countdown)
        XCTAssertEqual(other.center.stopwatch, snapshot.stopwatch)
        XCTAssertEqual(other.center.countdown?.remaining(at: other.now), 555)
        XCTAssertEqual(other.center.stopwatch?.elapsed(at: other.now), 5)
        XCTAssertTrue(other.armed.isEmpty, "a paused countdown restores with nothing armed")
    }

    func testRestoreOfARunningCountdownArmsTheRemainingTime() throws {
        let rig = Rig()
        rig.center.startCountdown(seconds: 600)
        let snapshot = rig.center.snapshot
        let other = Rig()
        other.now = rig.now.addingTimeInterval(100)
        other.center.restore(snapshot)
        XCTAssertEqual(other.armed.map(\.delay), [500])
        other.advance(500)
        other.fire(0)
        XCTAssertEqual(other.finishes, 1)
    }

    func testRestoreOfAFinishedCountdownClearsItWithoutFiring() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 60)
        let snapshot = rig.center.snapshot
        let other = Rig()
        other.now = rig.now.addingTimeInterval(3_600)
        other.center.restore(snapshot)
        XCTAssertNil(other.center.countdown)
        XCTAssertTrue(other.armed.isEmpty)
        XCTAssertEqual(other.finishes, 0, "a timer that ended unseen is gone, not rung late")
    }

    func testRestoreReplacesWhatWasThereAndCancelsItsSchedule() {
        let rig = Rig()
        rig.center.startCountdown(seconds: 60)
        rig.center.restore(IslandTimerCenter.Snapshot(countdown: nil, stopwatch: nil))
        XCTAssertNil(rig.center.countdown)
        XCTAssertTrue(rig.scheduled[0].cancelled)
    }

    func testRestoreRepairsADamagedSnapshot() {
        let rig = Rig()
        let since = rig.now
        let snapshot = IslandTimerCenter.Snapshot(
            countdown: IslandTimerState(kind: .countdown(duration: 10_000_000), runningSince: since, banked: -5),
            stopwatch: IslandTimerState(kind: .countdown(duration: 60), runningSince: since, banked: 0)
        )
        rig.center.restore(snapshot)
        XCTAssertEqual(rig.center.countdown?.kind, .countdown(duration: 86_400))
        XCTAssertEqual(rig.center.countdown?.banked, 0)
        XCTAssertNil(rig.center.stopwatch, "a countdown filed under the stopwatch is dropped")
    }

    func testKindCodableFormIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(IslandTimerState.Kind.countdown(duration: 300)), as: UTF8.self),
                       #"{"countdown":{"duration":300}}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(IslandTimerState.Kind.stopwatch), as: UTF8.self),
                       #"{"stopwatch":{}}"#)
        // Files written by this build must keep reading in the next one.
        XCTAssertEqual(try JSONDecoder().decode(IslandTimerState.Kind.self, from: Data(#"{"countdown":{"duration":90.5}}"#.utf8)),
                       .countdown(duration: 90.5))
        XCTAssertEqual(try JSONDecoder().decode(IslandTimerState.Kind.self, from: Data(#"{"stopwatch":{}}"#.utf8)),
                       .stopwatch)
    }
}
