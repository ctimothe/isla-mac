import Combine
import Foundation

/// One countdown or one stopwatch as plain dates, so it can be written to disk
/// and read back after an update or a restart without losing a second.
///
/// The state never counts anything. A running timer is the date its current
/// stretch began plus the time banked by earlier stretches, and every reading
/// is a subtraction from the `now` the caller passes in. That is what keeps it
/// right across sleep (the Mac's wall clock keeps moving, a ticking counter
/// would not) and what lets the wings redraw from any clock without a second
/// source of truth.
struct IslandTimerState: Equatable, Codable {
    enum Kind: Equatable, Codable {
        case countdown(duration: TimeInterval)
        case stopwatch
    }

    var kind: Kind
    /// When the current running stretch began; nil while paused.
    var runningSince: Date?
    /// Time banked from earlier running stretches.
    var banked: TimeInterval

    var isPaused: Bool { runningSince == nil }

    /// Time the timer has run. A clock stepped back past `runningSince` (the
    /// owner changing the date by hand) reads as no time in the stretch rather
    /// than a negative one, so a timer can never run backwards past its start.
    func elapsed(at now: Date) -> TimeInterval {
        banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Countdown only: `max(0, duration - elapsed)`; nil for a stopwatch.
    func remaining(at now: Date) -> TimeInterval? {
        guard case .countdown(let duration) = kind else { return nil }
        return max(0, duration - elapsed(at: now))
    }

    /// Countdown only: true once the remaining time hits zero. Read from dates,
    /// so a state looked at after the deadline says finished even if the
    /// scheduled wake-up has not run yet (the Mac was asleep).
    func isFinished(at now: Date) -> Bool {
        guard let remaining = remaining(at: now) else { return false }
        return remaining <= 0
    }

    /// 0...1 for a countdown (elapsed over duration), nil for a stopwatch.
    func progress(at now: Date) -> Double? {
        guard case .countdown(let duration) = kind else { return nil }
        guard duration > 0 else { return 1 }
        return min(1, max(0, elapsed(at: now) / duration))
    }
}

/// The island's timer and stopwatch: one of each at most, both survivable
/// across a restart, neither polled.
///
/// The only thing that runs is one wake-up scheduled for exactly the moment a
/// running countdown reaches zero (`Environment.after`). The wings redraw
/// their own digits from `IslandTimerState` at whatever rate the view wants;
/// this object owns the sequencing, which is where the bugs would be: a pause
/// that leaves the old wake-up armed rings a timer that is not running, an
/// extend that forgets to re-arm rings it early, and a replaced countdown whose
/// wake-up survives rings the new one at the old time.
@MainActor
final class IslandTimerCenter: ObservableObject {
    /// How the center reads the time and waits: the system's in the app, a
    /// clock the test moves and a list of wake-ups the test fires by hand in
    /// `IslandTimerTests`.
    struct Environment {
        var now: @MainActor () -> Date
        /// Runs `work` after `delay` seconds; returns a closure that cancels it.
        var after: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> (() -> Void)

        static let live = Environment(
            now: { Date() },
            after: { delay, work in
                let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
                // The wall clock, not the monotonic one: `DispatchTime` stops
                // while the Mac sleeps, so a five-minute timer set before a
                // lid-close would ring minutes late after the wake. A wall
                // deadline that already passed fires at once on wake.
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: item)
                return { item.cancel() }
            }
        )
    }

    /// Both states in one value, for the driver to write to disk.
    struct Snapshot: Equatable, Codable {
        var countdown: IslandTimerState?
        var stopwatch: IslandTimerState?
    }

    /// The longest countdown, in seconds: a day. Anything longer is a stopwatch.
    nonisolated static let maxSeconds: TimeInterval = 86_400

    /// The menu's preset durations, in minutes.
    nonisolated static let presetMinutes: [Int] = [1, 3, 5, 10, 15, 25, 30, 60]

    private let environment: Environment
    private var cancelFinish: (() -> Void)?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    @Published private(set) var countdown: IslandTimerState?
    @Published private(set) var stopwatch: IslandTimerState?

    /// Fires once, on the main actor, when a running countdown reaches zero;
    /// the countdown is already cleared by then. Never fires for a countdown
    /// that was cancelled, or that ended while the app was away (`restore`).
    var onCountdownFinished: (() -> Void)?

    // MARK: Countdown

    /// Starts a countdown, replacing any one already there. The length is
    /// clamped to one second through a day, so a bad value from a Shortcut can
    /// neither ring at once nor schedule a wake-up years away.
    func startCountdown(seconds: TimeInterval) {
        let duration = Self.clamp(seconds)
        disarm()
        countdown = IslandTimerState(kind: .countdown(duration: duration), runningSince: environment.now(), banked: 0)
        arm()
    }

    func pauseCountdown() {
        guard !settle(), var state = countdown, let since = state.runningSince else { return }
        state.banked += max(0, environment.now().timeIntervalSince(since))
        state.runningSince = nil
        disarm()
        countdown = state
    }

    func resumeCountdown() {
        guard !settle(), var state = countdown, state.isPaused else { return }
        state.runningSince = environment.now()
        countdown = state
        arm()
    }

    func cancelCountdown() {
        disarm()
        guard countdown != nil else { return }
        countdown = nil
    }

    /// Adds time to a running or paused countdown (the "+1 min" button). The
    /// duration grows rather than the banked time shrinking, so progress falls
    /// back honestly instead of jumping below zero elapsed. A countdown whose
    /// deadline already passed has finished and is not revived by this.
    func extendCountdown(by seconds: TimeInterval) {
        guard !settle(), var state = countdown, case .countdown(let duration) = state.kind,
              seconds.isFinite, seconds > 0 else { return }
        let extended = min(Self.maxSeconds, duration + seconds)
        guard extended != duration else { return }
        state.kind = .countdown(duration: extended)
        countdown = state
        // Re-armed for the new remaining time; a paused countdown has nothing
        // scheduled and stays that way.
        arm()
    }

    // MARK: Stopwatch

    /// Starts a stopwatch from zero. One already there is left alone, running
    /// or paused: a second tap on the menu item must not throw away the time
    /// on it (`resetStopwatch` is the way to drop one).
    func startStopwatch() {
        guard stopwatch == nil else { return }
        stopwatch = IslandTimerState(kind: .stopwatch, runningSince: environment.now(), banked: 0)
    }

    func pauseStopwatch() {
        guard var state = stopwatch, let since = state.runningSince else { return }
        state.banked += max(0, environment.now().timeIntervalSince(since))
        state.runningSince = nil
        stopwatch = state
    }

    func resumeStopwatch() {
        guard var state = stopwatch, state.isPaused else { return }
        state.runningSince = environment.now()
        stopwatch = state
    }

    /// Drops the stopwatch. The island shows it only while it is running or
    /// paused, so a reset is a removal, not a return to a paused zero.
    func resetStopwatch() {
        guard stopwatch != nil else { return }
        stopwatch = nil
    }

    // MARK: Persistence

    var snapshot: Snapshot { Snapshot(countdown: countdown, stopwatch: stopwatch) }

    /// Puts back what `snapshot` wrote.
    ///
    /// A countdown that reached zero while the app was away is dropped without
    /// ringing: it ended unseen, and an alert for a timer that finished before
    /// the update or the sleep, shown minutes or hours late, is worse than none
    /// (the owner would read "Timer Done" as something that just happened). A
    /// running countdown still in the future is armed again for what is left.
    func restore(_ snapshot: Snapshot) {
        disarm()
        var restored = snapshot.countdown
        if let state = restored {
            // A hand-edited or damaged file must not bypass the clamp `start`
            // applies, nor carry a negative bank.
            if case .countdown(let duration) = state.kind {
                var fixed = state
                fixed.kind = .countdown(duration: Self.clamp(duration))
                fixed.banked = max(0, state.banked)
                restored = fixed
            } else {
                restored = nil
            }
        }
        if let state = restored, state.isFinished(at: environment.now()) { restored = nil }
        countdown = restored
        // A running stopwatch keeps its `runningSince`, so the time Isla was
        // away counts: a stopwatch measures the time since it was started,
        // as the iPhone's does when its app is quit, and an update that
        // paused it for the seconds Isla took to restart would make it read
        // short (Codex review 2026-11-14 asked for the opposite; declined).
        var watch = snapshot.stopwatch
        if let state = watch {
            if case .stopwatch = state.kind {
                var fixed = state
                fixed.banked = max(0, state.banked)
                watch = fixed
            } else {
                watch = nil
            }
        }
        stopwatch = watch
        arm()
    }

    // MARK: Format

    /// The wings' text. A countdown rounds up, so "5:00" shows right after a
    /// five-minute start and "0:01" holds through the last second, never "0:00"
    /// before it rings. A stopwatch rounds down, so it never shows a second it
    /// has not yet reached. "m:ss" under an hour, "h:mm:ss" from one.
    nonisolated static func format(_ seconds: TimeInterval, roundingUp: Bool) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let rounded = roundingUp ? seconds.rounded(.up) : seconds.rounded(.down)
        let whole = Int(min(rounded, 99 * 3600 + 3599))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        if hours > 0 {
            return "\(hours):" + twoDigits(minutes) + ":" + twoDigits(secs)
        }
        return "\(minutes):" + twoDigits(secs)
    }

    // MARK: Private

    private nonisolated static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private nonisolated static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return seconds > 0 ? maxSeconds : 1 }
        return min(maxSeconds, max(1, seconds))
    }

    private func disarm() {
        cancelFinish?()
        cancelFinish = nil
    }

    /// Schedules the finish for exactly the remaining time of a running
    /// countdown, replacing any earlier wake-up; does nothing for a paused or
    /// absent one.
    private func arm() {
        disarm()
        guard let state = countdown, !state.isPaused else { return }
        let now = environment.now()
        guard let remaining = state.remaining(at: now) else { return }
        if remaining <= 0 {
            finish()
            return
        }
        cancelFinish = environment.after(remaining) { [weak self] in
            self?.wake()
        }
    }

    private func wake() {
        // The wake-up that just ran is spent; drop its cancel so a later
        // disarm does not call a closure for work that already happened.
        cancelFinish = nil
        guard let state = countdown, !state.isPaused else { return }
        if state.isFinished(at: environment.now()) {
            finish()
        } else {
            // Ran early (a clock step, a wake from sleep before the deadline):
            // wait out what is left rather than ringing ahead of time.
            arm()
        }
    }

    /// A running countdown whose deadline has passed finishes on any call made
    /// after it, not only when its wake-up runs: the wake-up of a sleeping Mac
    /// can be late, and the dates are the truth. True if it finished here.
    private func settle() -> Bool {
        guard let state = countdown, !state.isPaused, state.isFinished(at: environment.now()) else { return false }
        finish()
        return true
    }

    private func finish() {
        disarm()
        guard countdown != nil else { return }
        countdown = nil
        onCountdownFinished?()
    }
}
