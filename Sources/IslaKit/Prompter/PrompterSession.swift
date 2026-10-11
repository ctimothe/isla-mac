import Combine
import Foundation

// Foundation and Combine only. The session is the Prompter's state machine
// (spec section 7) and owns no UI: the stage and the tab observe it, the
// controller drives it from hot keys, lock and sleep, and the panel's hold
// reads `holdsPanel`. Nothing here may reach `NotchViewModel`,
// `NotchController`, `UserDefaults.standard` or a real timer in a test, which
// is why time, timers and the power assertion all come in through the
// initializer.

// MARK: - Vocabulary

/// Spec section 8. Release 1 builds Classic only. Voice (release 2) and Follow
/// (release 3) are added as cases when their engines exist, together with the
/// `preparing` state and the pause reasons only they can produce (`silence`,
/// `interruption`, `permission`); adding a case then makes every switch over
/// these enums say where it needs an answer.
enum PrompterGuidanceMode: String, Sendable, CaseIterable {
    case classic
}

/// Why a session is paused. A user pause is the only one the user caused;
/// lock and sleep are the system's, and none of them ever resumes by itself
/// (spec 7.1, 11.3).
enum PrompterPauseReason: Sendable, Equatable {
    case user
    case lock
    case sleep
}

/// Spec 7.1 for Classic. `idle` is before the first run; `ended` is after a
/// run, and keeps that run's read marks until the next Start.
enum PrompterSessionState: Sendable, Equatable {
    case idle
    case running
    case paused(PrompterPauseReason)
    case finished
    case ended

    /// Running, paused or finished: a session exists and owns the stage.
    var isLive: Bool {
        switch self {
        case .running, .paused, .finished: return true
        case .idle, .ended: return false
        }
    }
}

/// A place in a page that outlives the moment it was taken: a jump target, a
/// resume point, a position the user placed before Start. The offset is a
/// collapsed `Character` offset (spec 3) and is only meaningful for the page
/// text whose hash it carries; spec 6.4 drops it when the hash changes.
struct PromptPosition: Sendable, Equatable, Hashable {
    let offset: Int
    let contentHash: UInt64
}

/// The auto-next countdown of spec 8.6, for the stage to draw. `endsAt` is in
/// the session's own time base (the `now` it was given), so a view should ask
/// `PrompterSession.countdownRemaining` rather than compare it with `Date`.
struct PrompterCountdown: Sendable, Equatable {
    let seconds: Int
    let endsAt: TimeInterval
    let targetPage: Int
}

// MARK: - Seams

/// A scheduled piece of work that can be called off.
protocol PrompterCancellable: AnyObject {
    func cancel()
}

/// Every timer the session uses comes from here, so a test owns time. Actions
/// run on the main actor. `after(0, …)` must run on the next main-queue turn,
/// never synchronously inside the call (spec 8.6: "Delay 0 advances on the
/// next main-queue tick").
@MainActor
protocol PrompterScheduling {
    func every(_ interval: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable
    func after(_ delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable
}

/// The display-awake assertion of spec 11.8. The session calls `begin` and
/// `end` strictly alternately, starting with `begin`; an implementation never
/// sees two of either in a row.
@MainActor
protocol PrompterKeepAwake: AnyObject {
    func begin()
    func end()
}

// MARK: - Session

/// One Prompter, for the life of the app model. Each Start opens a new run
/// with a new `generation`; Stop closes it.
///
/// Spec 7.2, and the upstream defect it answers (research note section 10,
/// item 4): the reference app's teardown closures
/// were not tied to a session, so a Stop followed within 0.4 s by a Start let
/// the first run's delayed dismissal tear the second one down, and its
/// one-second auto-dismiss survived the state that scheduled it. Here every
/// closure that outlives the call creating it captures the generation (and,
/// for the countdown, its own serial) and does nothing once either is stale.
/// Cancelling the timer is the first defence; the generation is the one that
/// holds when a run loop has already dequeued a timer at the moment it is
/// cancelled.
@MainActor
final class PrompterSession: ObservableObject {
    static let allowedCountdowns: Set<Int> = [0, 1, 3, 5]
    static let defaultCountdown = 3

    @Published private(set) var state: PrompterSessionState = .idle
    @Published private(set) var pages: [PromptScript] = []
    @Published private(set) var pageIndex = 0
    /// Fractional words over the current page (`PromptClock.progress`).
    @Published private(set) var progress: Double = 0
    @Published private(set) var speed = PromptClock.defaultSpeed
    @Published private(set) var countdown: PrompterCountdown?
    /// Pages whose end was reached in the current (or the last ended) run,
    /// for the page chips' read mark (spec 5.1).
    @Published private(set) var readPages: Set<Int> = []
    /// Fixed for a run: mode does not change mid-session (spec 10.6).
    @Published private(set) var mode: PrompterGuidanceMode = .classic
    /// A lock or a sleep has paused this session since it last ran: true in
    /// `paused(.lock)` and `paused(.sleep)`, and also in `paused(.user)` when
    /// the lock or sleep came after the user's pause (ruling 20.6 #1). The
    /// state keeps the first reason (20.2 #6), so this is what the lease and
    /// the stage's wheel read instead. A user pause followed by a lock used
    /// to keep the display-awake lease held, because the lock was refused as
    /// a second pause and nothing re-derived the lease; with idle display
    /// sleep blocked, nothing else could end it until the speaker came back.
    /// Cleared by anything that runs the session again, and by Stop.
    @Published private(set) var isPausedBySystem = false

    /// Read when a page finishes. Changing it does not start or cancel a
    /// countdown already decided; the next page end reads the new value.
    var autoNext = false
    /// 0, 1, 3 or 5 seconds. Anything else is the default, so a hand-edited
    /// value cannot schedule a 10,000-second countdown or a negative one.
    var autoNextDelay = PrompterSession.defaultCountdown {
        didSet {
            if !Self.allowedCountdowns.contains(autoNextDelay) { autoNextDelay = Self.defaultCountdown }
        }
    }
    /// `prompter.keepAwake`, default on. Applies to a live session at once.
    var keepAwake = true {
        didSet { reconcileKeepAwake() }
    }

    private(set) var generation = 0

    private let now: @MainActor () -> TimeInterval
    private let scheduler: PrompterScheduling
    private let keepAwakeLease: PrompterKeepAwake

    private var clock: PromptClock?
    private var tickTimer: PrompterCancellable?
    private var countdownTimer: PrompterCancellable?
    /// Bumped for every countdown scheduled or cancelled. A page change keeps
    /// the generation (it is the same run), so the generation alone cannot
    /// tell a countdown that was called off from the one that replaced it.
    private var countdownSerial = 0
    private var leaseHeld = false
    /// The stage's elapsed readout (ruling 20.4: running time only).
    private var elapsed = PromptElapsed()

    init(
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: PrompterScheduling = MainQueuePrompterScheduler(),
        keepAwake: PrompterKeepAwake = ProcessActivityKeepAwake()
    ) {
        self.now = now
        self.scheduler = scheduler
        keepAwakeLease = keepAwake
    }

    // MARK: Reading

    /// The session's half of the panel hold (spec 11.1). The controller ORs it
    /// with the pin; it is a separate flag so ending a pin cannot end a
    /// session and the pin's rules (app activation, Escape) cannot end one.
    var holdsPanel: Bool { state.isLive }

    var script: PromptScript? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }
    var hasNextPage: Bool { pageIndex + 1 < pages.count }

    /// The word being read, nil at the end of the page or with no session.
    var currentWordIndex: Int? { state == .idle ? nil : clock?.currentWordIndex }

    /// Where reading stands, as a position a resume point or a re-anchor can
    /// keep: the start of the current word, or the end of the page.
    var currentPosition: PromptPosition? {
        guard let script, let clock else { return nil }
        let offset = clock.currentWordIndex.map { script.words[$0].range.lowerBound } ?? script.collapsedCount
        return PromptPosition(offset: offset, contentHash: script.contentHash)
    }

    /// How long this run (or the last one, after Stop) has been reading:
    /// running time only, every pause and the wait in `finished` left out
    /// (ruling 20.4). In the session's own time base.
    func elapsedTime() -> TimeInterval {
        elapsed.value(at: now())
    }

    /// Seconds left on the countdown, in the session's time base.
    var countdownRemaining: TimeInterval? {
        countdown.map { max(0, $0.endsAt - now()) }
    }

    // MARK: Commands

    /// Spec 7.1 Start: idle (or ended) to running. Classic has nothing to
    /// prepare, so it skips `preparing`. Refused while a run is live and when
    /// no page has a word (E-20: Start is disabled with a reason; the tab
    /// shows the reason, this only refuses). A blank selected page starts on
    /// the first non-empty one, and a placed position is honored only on the
    /// page it was placed on and only if that page's text is unchanged.
    @discardableResult
    func start(
        pages: [PromptScript],
        page: Int = 0,
        at position: PromptPosition? = nil,
        mode: PrompterGuidanceMode = .classic
    ) -> Bool {
        guard !state.isLive else { return false }
        guard let firstReadable = pages.firstIndex(where: { !$0.words.isEmpty }) else { return false }
        let selected = min(max(page, 0), pages.count - 1)
        let index = pages[selected].words.isEmpty ? firstReadable : selected

        generation &+= 1
        self.mode = mode
        self.pages = pages
        readPages = []
        elapsed.reset()
        var startPosition: PromptPosition?
        if index == selected, let position, position.contentHash == pages[index].contentHash {
            startPosition = position
        }
        load(page: index, at: startPosition)
        transition(to: .running)
        return true
    }

    /// Spec 7.1 Pause, Screen lock, Display or system sleep. A user pause
    /// comes only from `running`. Lock and sleep also pause `finished`: a
    /// countdown that fired behind the lock shield would run the next page
    /// with nobody watching, the very auto-resume 11.3 rules out. A session
    /// already paused keeps the reason it paused for, but a lock or sleep
    /// over a user pause is still recorded (`isPausedBySystem`), so the
    /// display-awake lease lets go of a locked Mac (ruling 20.6 #1).
    func pause(_ reason: PrompterPauseReason = .user) {
        switch (state, reason) {
        case (.running, _), (.finished, .lock), (.finished, .sleep):
            transition(to: .paused(reason))
        case (.paused, .lock), (.paused, .sleep):
            guard !isPausedBySystem else { return }
            isPausedBySystem = true
            reconcileKeepAwake()
        default:
            return
        }
    }

    /// Spec 7.1 Resume. The user may resume from any pause, including lock
    /// and sleep (E-39, E-40: unlock and wake leave it paused; the user's
    /// Resume is what continues it). A page already at its end returns to
    /// `finished`, which decides the countdown afresh.
    func resume() {
        guard case .paused = state else { return }
        transition(to: .running)
    }

    /// The stage's Play/Pause control.
    func togglePlayback() {
        switch state {
        case .running: pause(.user)
        case .paused: resume()
        default: return
        }
    }

    /// Spec 7.1 Next page: from running or finished, progress to 0 on the
    /// following page, same run. Refused while paused, which the table does
    /// not list, and on the last page.
    @discardableResult
    func nextPage() -> Bool {
        goToPage(pageIndex + 1)
    }

    /// The page picker. Same rule as Next page; the current page is not a
    /// page change and is refused.
    @discardableResult
    func goToPage(_ index: Int) -> Bool {
        guard state == .running || state == .finished,
              pages.indices.contains(index), index != pageIndex else { return false }
        cancelCountdown()
        load(page: index, at: nil)
        transition(to: .running)
        return true
    }

    /// Spec 8.5 in a timer mode: sets progress to the word holding `offset`,
    /// clamped to the page and moved past a cue. From `finished` the reader
    /// went back into the text, so the clock runs again; leaving `finished`
    /// cancels the countdown (8.6). A paused session stays paused.
    func jump(toOffset offset: Int) {
        guard state.isLive, var clock, let script else { return }
        let clamped = min(max(offset, 0), script.collapsedCount)
        clock.jump(toWord: script.wordIndex(containingCollapsedOffset: clamped) ?? 0)
        self.clock = clock
        progress = clock.progress
        if state == .finished, !clock.isAtEnd {
            transition(to: .running)
        } else if state == .running, clock.isAtEnd {
            transition(to: .finished)
        }
    }

    /// Applies to the running clock from its next tick (spec 8.1).
    func setSpeed(_ value: Double) {
        speed = PromptClock.clampedSpeed(value)
        clock?.setSpeed(speed)
    }

    /// Spec 7.1 Stop, and the Switch-off and App-quit rows, which end through
    /// the same path after their own confirmation. Teardown order follows
    /// 8.7: invalidate the generation first, so nothing already in flight can
    /// act; then timers; then the lease.
    func stop() {
        guard state.isLive else { return }
        generation &+= 1
        cancelTick()
        cancelCountdown()
        clock?.stop()
        elapsed.halt(at: now())
        state = .ended
        if isPausedBySystem { isPausedBySystem = false }
        reconcileKeepAwake()
        // The run's tokenized pages go with it (ruling 20.6 #8b): a big
        // script's are megabytes, and they were kept until the next Start,
        // which might be never. After `state`, so whatever hears the end
        // (the stage's "End of script" or "Prompter stopped") still reads
        // the run as it was. What the tab shows after Stop, the read marks,
        // and the elapsed figure stay.
        clock = nil
        pages = []
    }

    // MARK: Transitions

    private func load(page index: Int, at position: PromptPosition?) {
        pageIndex = index
        var fresh = PromptClock(script: pages[index], speed: speed)
        if let position, let word = pages[index].wordIndex(containingCollapsedOffset: position.offset) {
            fresh.jump(toWord: word)
        }
        clock = fresh
        progress = fresh.progress
    }

    /// The one place state changes inside a run, so the tick timer, the
    /// countdown and the lease are re-derived from the new state on every path
    /// and none of them can be left behind by a path that forgot it.
    private func transition(to target: PrompterSessionState) {
        var target = target
        if target == .running, clock?.isAtEnd ?? true { target = .finished }

        state = target
        let bySystem = target == .paused(.lock) || target == .paused(.sleep)
        if isPausedBySystem != bySystem { isPausedBySystem = bySystem }

        if target == .running {
            clock?.start(at: now())
            elapsed.run(at: now())
            armTick()
        } else {
            clock?.stop()
            elapsed.halt(at: now())
            cancelTick()
        }

        if target == .finished {
            readPages.insert(pageIndex)
            // A countdown already running for this page end stands; one is
            // never stacked on another.
            if countdown == nil { armCountdownIfDue() }
        } else {
            cancelCountdown()
        }

        reconcileKeepAwake()
    }

    // MARK: Tick

    private func armTick() {
        guard tickTimer == nil else { return }
        let generation = generation
        tickTimer = scheduler.every(PromptClock.tickInterval) { [weak self] in
            self?.tick(generation: generation)
        }
    }

    private func tick(generation: Int) {
        guard generation == self.generation, state == .running, var clock else { return }
        if clock.tick(at: now()) {
            progress = clock.progress
        }
        self.clock = clock
        if clock.isAtEnd { transition(to: .finished) }
    }

    private func cancelTick() {
        tickTimer?.cancel()
        tickTimer = nil
    }

    // MARK: Countdown (spec 8.6)

    private func armCountdownIfDue() {
        guard autoNext, hasNextPage else { return }
        cancelCountdown()
        let seconds = autoNextDelay
        let target = pageIndex + 1
        let generation = generation
        let serial = countdownSerial
        countdown = PrompterCountdown(seconds: seconds, endsAt: now() + Double(seconds), targetPage: target)
        countdownTimer = scheduler.after(Double(seconds)) { [weak self] in
            self?.countdownFired(generation: generation, serial: serial, target: target)
        }
    }

    private func countdownFired(generation: Int, serial: Int, target: Int) {
        guard generation == self.generation, serial == countdownSerial, state == .finished else { return }
        countdownTimer = nil
        countdownSerial &+= 1
        countdown = nil
        load(page: target, at: nil)
        transition(to: .running)
    }

    private func cancelCountdown() {
        countdownSerial &+= 1
        countdownTimer?.cancel()
        countdownTimer = nil
        if countdown != nil { countdown = nil }
    }

    // MARK: Keep awake (spec 11.8)

    /// Held while reading or paused by the user. Deliberately not held in a
    /// lock or sleep pause, though 11.8 says "running or paused": with
    /// `idleDisplaySleepDisabled` held, a Mac locked mid-session kept its
    /// display lit until the user came back. That includes a user pause the
    /// lock or sleep arrived on top of (`isPausedBySystem`). Not held in
    /// `finished`, which 11.8 leaves out. Released on every other path by
    /// construction, since every state change ends here.
    private var wantsKeepAwake: Bool {
        guard keepAwake else { return false }
        switch state {
        case .running: return true
        case .paused(.user): return !isPausedBySystem
        case .paused(.lock), .paused(.sleep), .finished, .idle, .ended: return false
        }
    }

    private func reconcileKeepAwake() {
        let wanted = wantsKeepAwake
        guard wanted != leaseHeld else { return }
        leaseHeld = wanted
        if wanted { keepAwakeLease.begin() } else { keepAwakeLease.end() }
    }
}

// MARK: - Production seams

/// Timers on the main dispatch queue, which the run loop drains in every mode,
/// so the text keeps moving while a menu is tracked or a scroll is in flight
/// (a `Timer` in the default mode would stall there).
@MainActor
final class MainQueuePrompterScheduler: PrompterScheduling {
    nonisolated init() {}

    func every(_ interval: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable {
        let source = DispatchSource.makeTimerSource(queue: .main)
        let nanos = Int(max(interval, 0.001) * 1e9)
        source.schedule(deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos), leeway: .milliseconds(5))
        source.setEventHandler { MainActor.assumeIsolated { action() } }
        source.resume()
        return DispatchSourceCancellable(source)
    }

    func after(_ delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            DispatchQueue.main.async(execute: item)
        }
        return WorkItemCancellable(item)
    }
}

/// A dispatch source keeps firing after the last reference to it goes unless
/// it is cancelled, so dropping this token cancels it too.
private final class DispatchSourceCancellable: PrompterCancellable {
    private let source: DispatchSourceTimer
    init(_ source: DispatchSourceTimer) { self.source = source }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

private final class WorkItemCancellable: PrompterCancellable {
    private let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
    deinit { item.cancel() }
}

/// `ProcessInfo.beginActivity` with the options spec 11.8 names. Ending is
/// also done on deinit, so an app model that drops a live session without
/// stopping it cannot leave the display pinned awake for the rest of the run.
@MainActor
final class ProcessActivityKeepAwake: PrompterKeepAwake {
    private var token: NSObjectProtocol?

    nonisolated init() {}

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Prompter session"
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
