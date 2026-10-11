import Foundation
import XCTest
@testable import IslaKit

// MARK: - Fakes

/// The test's clock. The session reads time only through the closure built
/// from this, so no test waits on a real second.
@MainActor
private final class FakeTime {
    var now: TimeInterval = 1_000
}

/// A scheduler that fires only when the test advances time. It keeps
/// cancelled entries so a test can force one to run anyway: that is the race
/// spec 7.2 is about (a run loop that already dequeued a timer fires it after
/// the cancel), and the session's generation check must make it harmless.
@MainActor
private final class FakeScheduler: PrompterScheduling {
    final class Entry: PrompterCancellable {
        let interval: TimeInterval?
        let delay: TimeInterval
        var due: TimeInterval
        let action: @MainActor () -> Void
        private(set) var isCancelled = false

        init(interval: TimeInterval?, delay: TimeInterval, due: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.delay = delay
            self.due = due
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    let time: FakeTime
    private(set) var entries: [Entry] = []

    init(time: FakeTime) { self.time = time }

    var live: [Entry] { entries.filter { !$0.isCancelled } }
    var liveRepeating: [Entry] { live.filter { $0.interval != nil } }
    var liveOneShots: [Entry] { live.filter { $0.interval == nil } }

    func every(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry(interval: interval, delay: interval, due: time.now + interval, action: action)
        entries.append(entry)
        return entry
    }

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry(interval: nil, delay: delay, due: time.now + max(0, delay), action: action)
        entries.append(entry)
        return entry
    }

    /// Moves time forward, firing every live entry that falls due, in order,
    /// re-arming repeating ones. Firing can schedule or cancel others.
    func advance(by dt: TimeInterval) {
        let target = time.now + dt
        while true {
            let due = live.filter { $0.due <= target + 1e-9 }.min { $0.due < $1.due }
            guard let entry = due else { break }
            time.now = max(time.now, entry.due)
            if let interval = entry.interval {
                entry.due += interval
            } else {
                entry.cancel()
            }
            entry.action()
        }
        time.now = target
    }

    /// Runs an entry's action regardless of its cancellation.
    func forceFire(_ entry: Entry) { entry.action() }
}

@MainActor
private final class FakeKeepAwake: PrompterKeepAwake {
    private(set) var begins = 0
    private(set) var ends = 0
    /// Set when `begin` arrives while already held or `end` while not held:
    /// an unbalanced lease is the bug, whatever the counts say.
    private(set) var unbalanced = false
    var isHeld: Bool { begins > ends }

    func begin() {
        if isHeld { unbalanced = true }
        begins += 1
    }

    func end() {
        if !isHeld { unbalanced = true; return }
        ends += 1
    }
}

// MARK: - Tests

/// Spec section 7 (state machine, generations), 8.1 and 8.6 (Classic clock,
/// countdown, end of script) and the session half of section 11 (hold,
/// keep-awake). Everything runs on fakes: no real timer, no power assertion,
/// no UserDefaults, no files.
@MainActor
final class PrompterSessionTests: XCTestCase {
    private var time: FakeTime!
    private var scheduler: FakeScheduler!
    private var lease: FakeKeepAwake!
    private var session: PrompterSession!

    override func setUp() async throws {
        try await super.setUp()
        time = FakeTime()
        scheduler = FakeScheduler(time: time)
        lease = FakeKeepAwake()
        let time = self.time!
        session = PrompterSession(now: { time.now }, scheduler: scheduler, keepAwake: lease)
    }

    override func tearDown() async throws {
        XCTAssertFalse(lease.unbalanced, "keep-awake lease was begun twice or ended while not held")
        session = nil
        try await super.tearDown()
    }

    private func pages(_ texts: String...) -> [PromptScript] { texts.map(PromptScript.init) }

    private let twelveWords = "one two three four five six seven eight nine ten eleven twelve"

    /// Lets the 20 Hz tick run for `seconds` of fake time.
    private func run(_ seconds: TimeInterval) { scheduler.advance(by: seconds) }

    /// Runs page `pageIndex` to its end at 8 words per second.
    private func finishCurrentPage() {
        session.setSpeed(8)
        var guardCount = 0
        while session.state == .running, guardCount < 10_000 {
            run(0.05)
            guardCount += 1
        }
    }

    // MARK: Defaults and idle

    func testANewSessionIsIdleHoldsNothingAndSchedulesNothing() {
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.holdsPanel)
        XCTAssertEqual(scheduler.entries.count, 0)
        XCTAssertEqual(lease.begins, 0)
        XCTAssertEqual(session.speed, 3.0)
        XCTAssertFalse(session.autoNext)
        XCTAssertEqual(session.autoNextDelay, 3)
        XCTAssertTrue(session.keepAwake)
        XCTAssertEqual(session.mode, .classic)
    }

    // MARK: 7.1 Start: idle -> running (Classic skips preparing)

    func testStartGoesStraightToRunningInClassic() {
        XCTAssertTrue(session.start(pages: pages(twelveWords)))
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.pageIndex, 0)
        XCTAssertEqual(session.progress, 0)
        XCTAssertTrue(session.holdsPanel)
        XCTAssertEqual(scheduler.liveRepeating.count, 1)
        XCTAssertEqual(scheduler.liveRepeating.first?.interval, PromptClock.tickInterval)
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(lease.begins, 1)
    }

    func testRunningTicksAdvanceProgressAtTheSessionSpeed() {
        session.setSpeed(2.5)
        session.start(pages: pages(twelveWords))
        run(1.0)
        XCTAssertEqual(session.progress, 2.5, accuracy: 1e-6)
        XCTAssertEqual(session.currentWordIndex, 2)
    }

    func testStartIsRefusedWithNoPagesOrOnlyBlankPages() {
        XCTAssertFalse(session.start(pages: []))
        XCTAssertFalse(session.start(pages: pages("", "  \n\n ", "\t")))
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(scheduler.entries.count, 0)
        XCTAssertEqual(lease.begins, 0)
    }

    /// E-20: a blank current page jumps to the first non-empty page.
    func testABlankSelectedPageStartsOnTheFirstNonEmptyPage() {
        XCTAssertTrue(session.start(pages: pages("", "first words", "", "later words"), page: 2))
        XCTAssertEqual(session.pageIndex, 1)
    }

    func testAnOutOfRangeSelectedPageIsClamped() {
        XCTAssertTrue(session.start(pages: pages("a b", "c d"), page: 9))
        XCTAssertEqual(session.pageIndex, 1)
        session.stop()
        XCTAssertTrue(session.start(pages: pages("a b", "c d"), page: -3))
        XCTAssertEqual(session.pageIndex, 0)
    }

    /// Start begins where the user placed a position, if its page hash still
    /// matches (spec 6.4: a stored offset is dropped when the text changed).
    func testStartBeginsAtAPlacedPositionWhenItsHashMatches() {
        let page = PromptScript("alpha beta gamma delta")
        let offsetOfGamma = page.words[2].range.lowerBound
        session.start(pages: [page], at: PromptPosition(offset: offsetOfGamma, contentHash: page.contentHash))
        XCTAssertEqual(session.progress, 2)
    }

    func testAPositionWithAStaleHashIsDropped() {
        let page = PromptScript("alpha beta gamma delta")
        session.start(pages: [page], at: PromptPosition(offset: page.words[2].range.lowerBound, contentHash: 42))
        XCTAssertEqual(session.progress, 0)
    }

    func testAPositionInsideACueStartsAfterIt() {
        let page = PromptScript("hello [look at camera] world")
        let insideCue = page.words[2].range.lowerBound + 1
        session.start(pages: [page], at: PromptPosition(offset: insideCue, contentHash: page.contentHash))
        XCTAssertEqual(session.currentWordIndex, 4)
    }

    func testStartIsRefusedWhileASessionIsLive() {
        session.start(pages: pages(twelveWords))
        let generation = session.generation
        XCTAssertFalse(session.start(pages: pages("other text")))
        XCTAssertEqual(session.generation, generation)
        XCTAssertEqual(session.script?.source, twelveWords)
        XCTAssertEqual(scheduler.liveRepeating.count, 1)
        XCTAssertEqual(lease.begins, 1)
    }

    // MARK: 7.1 Pause / Resume

    func testPauseStopsTheClockAndCancelsTheTick() {
        session.start(pages: pages(twelveWords))
        run(0.5)
        let before = session.progress
        session.pause()
        XCTAssertEqual(session.state, .paused(.user))
        XCTAssertTrue(session.holdsPanel)
        XCTAssertEqual(scheduler.live.count, 0)
        run(10)
        XCTAssertEqual(session.progress, before)
    }

    func testResumeCountsOnlyFromTheResume() {
        session.setSpeed(2)
        session.start(pages: pages(twelveWords))
        run(0.5)
        session.pause()
        run(30)
        session.resume()
        XCTAssertEqual(session.state, .running)
        run(0.5)
        XCTAssertEqual(session.progress, 2.0, accuracy: 1e-6)
    }

    func testPauseAndResumeOutsideTheirStatesDoNothing() {
        session.pause()
        XCTAssertEqual(session.state, .idle)
        session.resume()
        XCTAssertEqual(session.state, .idle)
        session.start(pages: pages(twelveWords))
        session.resume()
        XCTAssertEqual(session.state, .running)
        session.pause()
        session.pause(.lock)
        XCTAssertEqual(session.state, .paused(.user), "a later pause does not rewrite why it paused")
    }

    func testTogglePlaybackPausesAndResumes() {
        session.start(pages: pages(twelveWords))
        session.togglePlayback()
        XCTAssertEqual(session.state, .paused(.user))
        session.togglePlayback()
        XCTAssertEqual(session.state, .running)
    }

    // MARK: 7.1 End reached / 8.6 Classic end of script

    func testEndReachedFinishesAndStopsTheClock() {
        session.start(pages: pages("one two three"))
        finishCurrentPage()
        XCTAssertEqual(session.state, .finished)
        XCTAssertEqual(session.progress, 3)
        XCTAssertTrue(session.holdsPanel)
        XCTAssertEqual(scheduler.liveRepeating.count, 0)
    }

    /// Textream `cb4a10b`: the speaker finishes 10 to 20 s after the scroll
    /// does, so a Classic session at its last word waits for Stop.
    func testClassicNeverDismissesItselfAtTheEnd() {
        session.start(pages: pages("one two three"))
        finishCurrentPage()
        XCTAssertEqual(scheduler.live.count, 0)
        run(600)
        XCTAssertEqual(session.state, .finished)
        XCTAssertTrue(session.holdsPanel)
    }

    /// E-21: a page of only cues or punctuation finishes at once, no hang.
    func testACueOnlyPageFinishesImmediately() {
        XCTAssertTrue(session.start(pages: pages("[smile] [pause] --")))
        XCTAssertEqual(session.state, .finished)
        XCTAssertEqual(scheduler.liveRepeating.count, 0)
    }

    func testAFinishedPageIsMarkedRead() {
        session.start(pages: pages("one two", "three four"))
        XCTAssertEqual(session.readPages, [])
        finishCurrentPage()
        XCTAssertEqual(session.readPages, [0])
    }

    // MARK: 8.6 Countdown

    private func finishFirstOfTwoPages(delay: Int) {
        session.autoNext = true
        session.autoNextDelay = delay
        session.start(pages: pages("one two", "three four five"))
        finishCurrentPage()
    }

    func testCountdownAdvancesAfterOneThreeAndFiveSeconds() {
        for delay in [1, 3, 5] {
            setUpFreshSession()
            finishFirstOfTwoPages(delay: delay)
            XCTAssertEqual(session.state, .finished)
            XCTAssertEqual(session.countdown?.seconds, delay)
            XCTAssertEqual(session.countdown?.targetPage, 1)
            run(Double(delay) - 0.01)
            XCTAssertEqual(session.pageIndex, 0, "delay \(delay) fired early")
            run(0.02)
            XCTAssertEqual(session.pageIndex, 1, "delay \(delay)")
            XCTAssertEqual(session.state, .running)
            XCTAssertEqual(session.progress, 0)
            XCTAssertNil(session.countdown)
            XCTAssertFalse(lease.unbalanced)
        }
    }

    /// Delay 0 advances on the next main-queue tick, not synchronously.
    /// The first page is cue-only so it finishes synchronously inside Start
    /// (E-21); a page finished by a tick would let the fake run the delay-0
    /// work in the same advance, which hides whether it was deferred at all.
    func testCountdownOfZeroAdvancesOnTheNextTick() {
        session.autoNext = true
        session.autoNextDelay = 0
        session.start(pages: pages("[pause]", "three four five"))
        XCTAssertEqual(session.pageIndex, 0)
        XCTAssertEqual(session.state, .finished)
        XCTAssertEqual(scheduler.liveOneShots.first?.delay, 0)
        run(0)
        XCTAssertEqual(session.pageIndex, 1)
        XCTAssertEqual(session.state, .running)
    }

    func testAnUnsupportedDelayFallsBackToThreeSeconds() {
        session.autoNextDelay = 7
        XCTAssertEqual(session.autoNextDelay, 3)
        session.autoNextDelay = -1
        XCTAssertEqual(session.autoNextDelay, 3)
        session.autoNextDelay = 5
        XCTAssertEqual(session.autoNextDelay, 5)
    }

    func testNoCountdownWithoutAutoNext() {
        session.start(pages: pages("one two", "three four"))
        finishCurrentPage()
        XCTAssertNil(session.countdown)
        XCTAssertEqual(scheduler.live.count, 0)
        run(60)
        XCTAssertEqual(session.pageIndex, 0)
    }

    func testNoCountdownOnTheLastPage() {
        session.autoNext = true
        session.start(pages: pages("one two"))
        finishCurrentPage()
        XCTAssertNil(session.countdown)
        XCTAssertEqual(scheduler.live.count, 0)
    }

    /// E-37: the countdown is cancelled by Stop.
    func testStopCancelsTheCountdown() {
        finishFirstOfTwoPages(delay: 3)
        session.stop()
        XCTAssertNil(session.countdown)
        XCTAssertEqual(scheduler.live.count, 0)
        run(10)
        XCTAssertEqual(session.state, .ended)
        XCTAssertEqual(session.pageIndex, 0)
    }

    /// E-37: the countdown is cancelled by a page change.
    func testAPageChangeCancelsTheCountdown() {
        session.autoNext = true
        session.autoNextDelay = 3
        session.start(pages: pages("one", "two three", "four five"))
        finishCurrentPage()
        XCTAssertNotNil(session.countdown)
        XCTAssertTrue(session.goToPage(2))
        XCTAssertNil(session.countdown)
        XCTAssertEqual(scheduler.liveOneShots.count, 0)
        session.setSpeed(0.5)
        run(3.5)
        XCTAssertEqual(session.pageIndex, 2, "the cancelled countdown must not move the page again")
    }

    /// E-36 for Classic: progress changing in `finished` (a tap back into the
    /// text) leaves `finished`, and leaving `finished` cancels the countdown.
    func testProgressChangingCancelsTheCountdown() {
        finishFirstOfTwoPages(delay: 1)
        let page = session.script!
        session.jump(toOffset: page.words[0].range.lowerBound)
        XCTAssertEqual(session.state, .running)
        XCTAssertNil(session.countdown)
        XCTAssertEqual(scheduler.liveOneShots.count, 0)
        session.pause()
        run(5)
        XCTAssertEqual(session.pageIndex, 0)
    }

    // MARK: 7.1 Next page

    func testNextPageWhileRunningResetsProgressAndKeepsTheTick() {
        session.start(pages: pages(twelveWords, "[smile] next page words"))
        run(0.5)
        let generation = session.generation
        XCTAssertTrue(session.nextPage())
        XCTAssertEqual(session.pageIndex, 1)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.script?.source, "[smile] next page words")
        XCTAssertEqual(session.currentWordIndex, 1, "progress 0, moved past the leading cue")
        XCTAssertEqual(session.generation, generation, "a page change is the same session")
        XCTAssertEqual(scheduler.liveRepeating.count, 1)
        XCTAssertEqual(lease.begins, 1)
        XCTAssertTrue(lease.isHeld)
    }

    func testNextPageFromFinishedRunsTheNewPage() {
        session.start(pages: pages("one", "two three four"))
        finishCurrentPage()
        XCTAssertFalse(lease.isHeld)
        XCTAssertTrue(session.nextPage())
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.progress, 0)
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(scheduler.liveRepeating.count, 1)
        run(0.25)
        XCTAssertGreaterThan(session.progress, 0)
    }

    func testNextPageOnTheLastPageIsRefused() {
        session.start(pages: pages("one two"))
        XCTAssertFalse(session.hasNextPage)
        XCTAssertFalse(session.nextPage())
        XCTAssertEqual(session.pageIndex, 0)
    }

    /// The 7.1 table allows Next page from running and finished only.
    func testNextPageWhilePausedIsRefused() {
        session.start(pages: pages("one two", "three"))
        session.pause()
        XCTAssertFalse(session.nextPage())
        XCTAssertEqual(session.pageIndex, 0)
        XCTAssertEqual(session.state, .paused(.user))
    }

    func testGoToPageRejectsTheCurrentAndOutOfRangePages() {
        session.start(pages: pages("one two", "three"))
        XCTAssertFalse(session.goToPage(0))
        XCTAssertFalse(session.goToPage(2))
        XCTAssertFalse(session.goToPage(-1))
        XCTAssertTrue(session.goToPage(1))
    }

    // MARK: 7.1 Stop

    func testStopFromEveryLiveStateEndsAndReleasesEverything() {
        let setups: [(String, (PrompterSession) -> Void)] = [
            ("running", { _ in }),
            ("paused(user)", { $0.pause() }),
            ("paused(lock)", { $0.pause(.lock) }),
            ("paused(sleep)", { $0.pause(.sleep) }),
            ("finished", { [unowned self] _ in self.finishCurrentPage() }),
        ]
        for (name, setup) in setups {
            setUpFreshSession()
            session.autoNext = true
            session.start(pages: pages("one two", "three"))
            setup(session)
            session.stop()
            XCTAssertEqual(session.state, .ended, name)
            XCTAssertFalse(session.holdsPanel, name)
            XCTAssertEqual(scheduler.live.count, 0, name)
            XCTAssertFalse(lease.isHeld, name)
            XCTAssertFalse(lease.unbalanced, name)
        }
    }

    func testStopWithoutASessionDoesNothing() {
        session.stop()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(lease.ends, 0)
    }

    func testAStartAfterStopIsANewSession() {
        session.start(pages: pages("one two", "three four"))
        finishCurrentPage()
        let first = session.generation
        session.stop()
        XCTAssertEqual(session.readPages, [0], "read marks outlive the run until the next start")
        XCTAssertTrue(session.start(pages: pages("five six")))
        XCTAssertGreaterThan(session.generation, first)
        XCTAssertEqual(session.readPages, [])
        XCTAssertEqual(session.state, .running)
    }

    // MARK: 7.1 Screen lock, display or system sleep

    func testLockPausesWithItsReasonAndNeverResumesByItself() {
        session.start(pages: pages(twelveWords))
        run(0.3)
        session.pause(.lock)
        XCTAssertEqual(session.state, .paused(.lock))
        XCTAssertTrue(session.holdsPanel)
        XCTAssertEqual(scheduler.live.count, 0)
        let progress = session.progress
        run(3_600)
        XCTAssertEqual(session.state, .paused(.lock))
        XCTAssertEqual(session.progress, progress)
    }

    func testSleepPausesWithItsReasonAndNeverResumesByItself() {
        session.start(pages: pages(twelveWords))
        session.pause(.sleep)
        XCTAssertEqual(session.state, .paused(.sleep))
        run(3_600)
        XCTAssertEqual(session.state, .paused(.sleep))
    }

    func testTheUserCanResumeAfterLockOrSleep() {
        for reason in [PrompterPauseReason.lock, .sleep] {
            setUpFreshSession()
            session.start(pages: pages(twelveWords))
            session.pause(reason)
            session.resume()
            XCTAssertEqual(session.state, .running, "\(reason)")
            XCTAssertTrue(lease.isHeld)
        }
    }

    /// A countdown that fired while the screen is locked would run the next
    /// page with nobody watching, which is exactly the auto-resume 11.3 rules
    /// out. A lock or sleep in `finished` therefore pauses and cancels it.
    func testLockWhileACountdownRunsCancelsItAndPauses() {
        finishFirstOfTwoPages(delay: 1)
        session.pause(.lock)
        XCTAssertEqual(session.state, .paused(.lock))
        XCTAssertNil(session.countdown)
        run(10)
        XCTAssertEqual(session.pageIndex, 0)
        XCTAssertEqual(session.state, .paused(.lock))
    }

    func testResumingAtTheEndReturnsToFinishedAndRestartsTheCountdown() {
        finishFirstOfTwoPages(delay: 1)
        session.pause(.sleep)
        session.resume()
        XCTAssertEqual(session.state, .finished)
        XCTAssertEqual(session.countdown?.seconds, 1)
        run(1.01)
        XCTAssertEqual(session.pageIndex, 1)
    }

    func testAUserPauseInFinishedIsNotAState() {
        session.start(pages: pages("one"))
        finishCurrentPage()
        session.pause()
        XCTAssertEqual(session.state, .finished)
    }

    // MARK: 7.1 Switch turned off, app quit

    /// Both rows end the session through the same path as Stop; the
    /// confirmation (quit) and the surface removal (switch) are the
    /// controller's. This pins that Stop is valid from every live state, so
    /// the caller needs no state check of its own.
    func testSwitchOffAndQuitEndThroughStop() {
        session.start(pages: pages(twelveWords))
        session.pause(.sleep)
        session.stop()
        XCTAssertEqual(session.state, .ended)
        XCTAssertFalse(session.holdsPanel)
    }

    // MARK: 7.2 Generation identity

    /// E-34: Start, Stop, Start within 0.4 s. Every deferred closure of the
    /// first run is stale; forcing them to run anyway (the race where a timer
    /// was already dequeued when it was cancelled) changes nothing in the
    /// second.
    func testClosuresOfAStoppedSessionDoNothingToTheNextOne() {
        session.autoNext = true
        session.autoNextDelay = 1
        session.start(pages: pages("one", "two three four", "five"))
        let firstGeneration = session.generation
        let firstTick = scheduler.liveRepeating.first!
        finishCurrentPage()
        let firstCountdown = scheduler.liveOneShots.first!
        run(0.1)
        session.stop()
        run(0.2)
        XCTAssertTrue(session.start(pages: pages(twelveWords, "second page")))
        XCTAssertNotEqual(session.generation, firstGeneration)
        run(0.05)
        let progress = session.progress
        let ticks = scheduler.liveRepeating.count
        // Time moves without the second run's own tick firing, so any
        // progress below can only come from the first run's closures.
        time.now += 0.1

        scheduler.forceFire(firstCountdown)
        scheduler.forceFire(firstTick)
        scheduler.forceFire(firstTick)

        XCTAssertEqual(session.pageIndex, 0, "the first run's countdown moved the second run's page")
        XCTAssertEqual(session.progress, progress, "the first run's tick advanced the second run")
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(scheduler.liveRepeating.count, ticks)
        XCTAssertEqual(session.script?.source, twelveWords)
    }

    func testAStaleCountdownAfterAManualPageChangeDoesNothing() {
        session.autoNext = true
        session.autoNextDelay = 1
        session.start(pages: pages("one", "two three", "four five"))
        finishCurrentPage()
        let countdown = scheduler.liveOneShots.first!
        session.goToPage(2)
        scheduler.forceFire(countdown)
        XCTAssertEqual(session.pageIndex, 2)
        XCTAssertEqual(session.state, .running)
    }

    /// Same run, same generation, and the session is back in `finished` on
    /// another page: only the countdown's own serial tells the old countdown
    /// from a current one.
    func testACalledOffCountdownCannotFireIntoALaterFinish() {
        session.autoNext = true
        session.autoNextDelay = 1
        session.start(pages: pages("one", "two three", "four five"))
        finishCurrentPage()
        let old = scheduler.liveOneShots.first!
        session.goToPage(2)
        finishCurrentPage()
        XCTAssertEqual(session.state, .finished)
        XCTAssertNil(session.countdown, "the last page has no countdown of its own")
        scheduler.forceFire(old)
        XCTAssertEqual(session.pageIndex, 2)
        XCTAssertEqual(session.state, .finished)
    }

    func testAStaleTickAfterPauseDoesNothing() {
        session.start(pages: pages(twelveWords))
        let tick = scheduler.liveRepeating.first!
        run(0.2)
        session.pause()
        let progress = session.progress
        time.now += 0.2
        scheduler.forceFire(tick)
        XCTAssertEqual(session.progress, progress)
        XCTAssertEqual(session.state, .paused(.user))
    }

    func testEveryStartAndStopMovesTheGeneration() {
        let g0 = session.generation
        session.start(pages: pages("a b"))
        let g1 = session.generation
        session.stop()
        let g2 = session.generation
        XCTAssertNotEqual(g0, g1)
        XCTAssertNotEqual(g1, g2)
        XCTAssertNotEqual(g0, g2)
    }

    // MARK: Hold (spec 11.1, the session half)

    func testHoldsPanelWhileRunningPausedOrFinishedOnly() {
        XCTAssertFalse(session.holdsPanel)
        session.start(pages: pages("one two"))
        XCTAssertTrue(session.holdsPanel)
        session.pause()
        XCTAssertTrue(session.holdsPanel)
        session.resume()
        finishCurrentPage()
        XCTAssertEqual(session.state, .finished)
        XCTAssertTrue(session.holdsPanel)
        session.stop()
        XCTAssertFalse(session.holdsPanel)
    }

    // MARK: Keep-awake lease (spec 11.8)

    func testLeaseIsHeldWhileRunningAndUserPausedAndEndsAtTheEnd() {
        session.start(pages: pages("one two three", "four"))
        XCTAssertTrue(lease.isHeld)
        session.pause()
        XCTAssertTrue(lease.isHeld, "a user pause keeps the display awake")
        session.resume()
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(lease.begins, 1, "pause and resume do not churn the lease")
        finishCurrentPage()
        XCTAssertFalse(lease.isHeld, "finished is not running or paused")
        session.nextPage()
        XCTAssertTrue(lease.isHeld)
        session.stop()
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(lease.begins, lease.ends)
    }

    /// A lock or sleep pause releases the display: an assertion that kept a
    /// locked Mac's display lit until the user came back is a bug, not a
    /// feature. Resume takes it again.
    func testLeaseIsReleasedByLockAndSleepAndRetakenOnResume() {
        for reason in [PrompterPauseReason.lock, .sleep] {
            setUpFreshSession()
            session.start(pages: pages(twelveWords))
            session.pause(reason)
            XCTAssertFalse(lease.isHeld, "\(reason)")
            session.resume()
            XCTAssertTrue(lease.isHeld, "\(reason)")
            session.stop()
            XCTAssertFalse(lease.isHeld)
            XCTAssertFalse(lease.unbalanced)
        }
    }

    func testLeaseIsBalancedAcrossAReplacingSession() {
        session.start(pages: pages(twelveWords))
        session.stop()
        session.start(pages: pages("another script"))
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(lease.begins, 2)
        XCTAssertEqual(lease.ends, 1)
        session.stop()
        XCTAssertEqual(lease.begins, lease.ends)
    }

    func testNoLeaseWhenKeepAwakeIsOff() {
        session.keepAwake = false
        session.start(pages: pages(twelveWords))
        XCTAssertEqual(lease.begins, 0)
        session.keepAwake = true
        XCTAssertTrue(lease.isHeld, "turning it on applies to the running session")
        session.keepAwake = false
        XCTAssertFalse(lease.isHeld, "and so does turning it off")
    }

    func testACueOnlyStartNeverLeavesALeaseBehind() {
        session.start(pages: pages("[pause]"))
        XCTAssertEqual(session.state, .finished)
        XCTAssertFalse(lease.isHeld)
    }

    // MARK: Speed, jumps, position

    func testSpeedIsClampedAndAppliesLive() {
        session.setSpeed(20)
        XCTAssertEqual(session.speed, 8)
        session.setSpeed(0.1)
        XCTAssertEqual(session.speed, 0.5)
        session.start(pages: pages(twelveWords))
        run(1)
        XCTAssertEqual(session.progress, 0.5, accuracy: 1e-6)
        session.setSpeed(4)
        run(0.5)
        XCTAssertEqual(session.progress, 2.5, accuracy: 1e-6)
    }

    func testJumpWhilePausedMovesProgressAndStaysPaused() {
        let page = PromptScript(twelveWords)
        session.start(pages: [page])
        session.pause()
        session.jump(toOffset: page.words[5].range.lowerBound)
        XCTAssertEqual(session.progress, 5)
        XCTAssertEqual(session.state, .paused(.user))
    }

    func testJumpIsClampedToThePage() {
        let page = PromptScript("one two three")
        session.start(pages: [page])
        session.jump(toOffset: -10)
        XCTAssertEqual(session.progress, 0)
        session.jump(toOffset: 10_000)
        XCTAssertEqual(session.currentWordIndex, 2, "the end offset lands on the last word, not past it")
    }

    func testJumpWithoutASessionDoesNothing() {
        session.jump(toOffset: 3)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.progress, 0)
    }

    func testCurrentPositionCarriesTheOffsetAndThePageHash() {
        let page = PromptScript("alpha beta gamma")
        session.start(pages: [page])
        session.jump(toOffset: page.words[1].range.lowerBound)
        XCTAssertEqual(session.currentPosition, PromptPosition(offset: page.words[1].range.lowerBound, contentHash: page.contentHash))
        finishCurrentPage()
        XCTAssertEqual(session.currentPosition?.offset, page.collapsedCount)
    }

    // MARK: Elapsed (ruling 20.4)

    /// The stage's elapsed readout counts running time only: a pause of any
    /// kind, `finished` and the gap before a new start are left out, and a
    /// new start begins again at zero.
    func testElapsedCountsRunningTimeOnly() {
        XCTAssertEqual(session.elapsedTime(), 0, "nothing before a start")
        session.start(pages: pages(twelveWords))
        run(2)
        XCTAssertEqual(session.elapsedTime(), 2, accuracy: 1e-9)

        session.pause(.user)
        run(10)
        XCTAssertEqual(session.elapsedTime(), 2, accuracy: 1e-9, "a user pause is not counted")
        session.resume()
        run(0.5)
        XCTAssertEqual(session.elapsedTime(), 2.5, accuracy: 1e-9)

        session.handle(.screenLocked)
        run(30)
        XCTAssertEqual(session.elapsedTime(), 2.5, accuracy: 1e-9, "nor a lock")
        session.resume()

        finishCurrentPage()
        XCTAssertEqual(session.state, .finished)
        let atEnd = session.elapsedTime()
        run(15)
        XCTAssertEqual(session.elapsedTime(), atEnd, accuracy: 1e-9, "nor the wait after the last word")

        session.stop()
        run(5)
        XCTAssertEqual(session.elapsedTime(), atEnd, accuracy: 1e-9, "Stop keeps the last run's figure")
        session.start(pages: pages(twelveWords))
        XCTAssertEqual(session.elapsedTime(), 0, "a new run starts at zero")
        session.stop()
    }

    /// The value type underneath: halts without a run are harmless, a clock
    /// that runs backwards adds nothing, and a second run keeps the first
    /// baseline.
    func testPromptElapsedAddsOnlyForwardRunningTime() {
        var elapsed = PromptElapsed()
        elapsed.halt(at: 5)
        XCTAssertEqual(elapsed.value(at: 10), 0)
        elapsed.run(at: 10)
        elapsed.run(at: 12)
        XCTAssertEqual(elapsed.value(at: 13), 3)
        elapsed.halt(at: 13)
        XCTAssertEqual(elapsed.value(at: 100), 3)
        elapsed.run(at: 100)
        elapsed.halt(at: 90)
        XCTAssertEqual(elapsed.value(at: 200), 3, "time running backwards reads nothing")
        elapsed.reset()
        XCTAssertEqual(elapsed.value(at: 300), 0)
    }

    // MARK: Helpers

    private func setUpFreshSession() {
        if let lease { XCTAssertFalse(lease.unbalanced) }
        time = FakeTime()
        scheduler = FakeScheduler(time: time)
        lease = FakeKeepAwake()
        let time = self.time!
        session = PrompterSession(now: { time.now }, scheduler: scheduler, keepAwake: lease)
    }
}
