import XCTest
@testable import IslaKit

// MARK: - Fakes

@MainActor
final class FakeTrust: AccessibilityTrust {
    var trusted: Bool
    private(set) var prompts = 0
    private(set) var checks = 0
    init(_ trusted: Bool = false) { self.trusted = trusted }
    func isTrusted() -> Bool { checks += 1; return trusted }
    func requestPrompt() { prompts += 1 }
}

/// A tap that is a counter. The factory records what each tap was handed, so a
/// test can press a key through the handler a real tap would call.
@MainActor
final class FakeTap: MediaKeyTapping {
    var started = false
    private(set) var stops = 0
    var startSucceeds = true
    var isRunning: Bool { started }
    func start() -> Bool {
        guard startSucceeds else { return false }
        started = true
        return true
    }
    func stop() { started = false; stops += 1 }
}

@MainActor
final class FakeTapFactory {
    private(set) var taps: [FakeTap] = []
    private(set) var handler: MediaKeyHandler?
    private(set) var disabled: (@MainActor () -> Void)?
    var startSucceeds = true

    var factory: MediaKeyTapFactory {
        { [unowned self] handler, disabled in
            self.handler = handler
            self.disabled = disabled
            let tap = FakeTap()
            tap.startSucceeds = self.startSucceeds
            self.taps.append(tap)
            return tap
        }
    }

    var created: Int { taps.count }
    var live: [FakeTap] { taps.filter(\.started) }
}

@MainActor
final class ManualScheduler {
    private(set) var intervals: [TimeInterval] = []
    private var pending: [Int: @MainActor () -> Void] = [:]
    private var next = 0

    var scheduler: MediaKeyHUD.Scheduler {
        { [unowned self] seconds, work in
            let id = self.next
            self.next += 1
            self.intervals.append(seconds)
            self.pending[id] = work
            return { [weak self] in self?.pending[id] = nil }
        }
    }

    var pendingCount: Int { pending.count }

    /// Fires everything that is waiting, once.
    func fire() {
        let due = pending
        pending = [:]
        for (_, work) in due { work() }
    }
}

@MainActor
final class FakeApplier: MediaKeyApplying {
    var reading: HUDReading?
    private(set) var applied: [(MediaKey, Bool)] = []
    init(_ reading: HUDReading? = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil)) {
        self.reading = reading
    }
    func apply(_ key: MediaKey, fine: Bool) -> HUDReading? {
        applied.append((key, fine))
        return reading
    }
}

/// When the pop-up taps the keys and when it must not (spec §12): the setting
/// and the permission together, torn down the moment either goes, polled only
/// while waiting for a permission, and consuming only what it applied. No test
/// here creates a real event tap or shows the real Accessibility prompt.
@MainActor
final class MediaKeyHUDTests: XCTestCase {
    private var enabled = false
    private let trust = FakeTrust()
    private let taps = FakeTapFactory()
    private let clock = ManualScheduler()
    private let applier = FakeApplier()
    private var readings: [HUDReading] = []

    private func hud() -> MediaKeyHUD {
        let hud = MediaKeyHUD(
            isEnabled: { [unowned self] in self.enabled },
            trust: trust,
            makeTap: taps.factory,
            applier: applier,
            schedule: clock.scheduler
        )
        hud.onReading = { [unowned self] in self.readings.append($0) }
        return hud
    }

    private func down(_ key: MediaKey, isRepeat: Bool = false) -> MediaKeyPress {
        MediaKeyPress(key: key, isDown: true, isRepeat: isRepeat)
    }

    private func up(_ key: MediaKey) -> MediaKeyPress {
        MediaKeyPress(key: key, isDown: false, isRepeat: false)
    }

    // MARK: Nothing is tapped until both are true

    func testNothingIsTappedWhileTheSettingIsOff() {
        let hud = hud()
        trust.trusted = true
        enabled = false
        hud.refresh()
        XCTAssertEqual(taps.created, 0)
        XCTAssertFalse(hud.isTapped)
        XCTAssertFalse(hud.needsAccessibility)
    }

    func testNothingIsTappedWhileUntrusted() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        XCTAssertEqual(taps.created, 0, "no permission, no tap — not even a failed attempt")
        XCTAssertTrue(hud.needsAccessibility, "Settings shows its Accessibility group")
    }

    func testBothTrueMakesOneTapAndRefreshingAgainMakesNoSecond() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        hud.refresh()
        hud.refresh()
        XCTAssertEqual(taps.created, 1)
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.needsAccessibility)
    }

    func testATapTheSystemWillNotMakeConsumesNothingAndCrashesNothing() {
        let hud = hud()
        taps.startSucceeds = false
        enabled = true
        trust.trusted = true
        hud.refresh()
        XCTAssertFalse(hud.isTapped)
        XCTAssertTrue(taps.live.isEmpty)
    }

    // MARK: Torn down at once

    func testTurningTheSettingOffEndsTheTapAtOnce() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        let tap = taps.taps[0]
        XCTAssertTrue(tap.started)
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(tap.started)
        XCTAssertEqual(tap.stops, 1)
        XCTAssertFalse(hud.isTapped)
    }

    func testLosingTrustEndsTheTapAndStartsWaitingForItBack() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        let tap = taps.taps[0]
        trust.trusted = false
        hud.refresh()
        XCTAssertFalse(tap.started)
        XCTAssertFalse(hud.isTapped)
        XCTAssertTrue(hud.needsAccessibility)
        XCTAssertTrue(hud.isPolling, "waiting for the permission to come back")
    }

    func testAKeyPressedAfterTrustWentIsNotConsumed() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        trust.trusted = false
        XCTAssertFalse(hud.handle(down(.volumeUp), modifiers: .none), "the system keeps it")
        XCTAssertTrue(applier.applied.isEmpty)
        XCTAssertTrue(readings.isEmpty)
    }

    func testAKeyPressedAfterTheSettingWentOffIsNotConsumed() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        enabled = false
        XCTAssertFalse(hud.handle(down(.mute), modifiers: .none))
        XCTAssertTrue(applier.applied.isEmpty)
    }

    func testMacOSSwitchingTheTapOffMakesTheOwnerLookAtTrustAgain() async {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        let tap = taps.taps[0]
        trust.trusted = false
        taps.disabled?()
        // The owner looks on the next turn, never inside the tap's own callback.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(tap.started, "a revoked permission is one of the reasons macOS disables a tap")
    }

    // MARK: Consuming

    func testAKeyIsConsumedOnlyWhenIslaAppliedIt() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()

        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        XCTAssertEqual(readings.count, 1)

        applier.reading = nil
        XCTAssertFalse(hud.handle(down(.brightnessUp), modifiers: .none), "not applicable: the system's")
        XCTAssertEqual(readings.count, 1, "and nothing is shown for it")
    }

    func testTheMatchingKeyUpIsSwallowedAndAnUnmatchedOneIsNot() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()

        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        XCTAssertTrue(hud.handle(up(.volumeUp), modifiers: .none), "the release of a consumed press")
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none), "a second release has no press behind it")

        applier.reading = nil
        XCTAssertFalse(hud.handle(down(.mute), modifiers: .none))
        XCTAssertFalse(hud.handle(up(.mute), modifiers: .none), "a passed-through press passes its release")
    }

    func testRepeatsAreActedOnAndFineStepsAreForwarded() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        XCTAssertTrue(hud.handle(down(.volumeUp, isRepeat: true), modifiers: MediaKeyModifiers(fine: true)))
        XCTAssertEqual(applier.applied.count, 2)
        XCTAssertEqual(applier.applied[0].1, false)
        XCTAssertEqual(applier.applied[1].1, true)
        XCTAssertEqual(readings.count, 2)
    }

    func testTheHandlerTheTapIsGivenIsTheSameDecision() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        XCTAssertEqual(taps.handler?(down(.volumeDown), .none), true)
        XCTAssertEqual(taps.handler?(up(.volumeDown), .none), true)
    }

    func testNothingIsConsumedOrShownWhileTheMacIsLocked() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        var locked = true
        hud.isLocked = { locked }
        hud.refresh()
        for key in MediaKey.allCases {
            XCTAssertFalse(hud.handle(down(key), modifiers: .none), "\(key) passes through over the lock screen")
            XCTAssertFalse(hud.handle(up(key), modifiers: .none))
        }
        XCTAssertTrue(applier.applied.isEmpty, "nothing was changed behind the shield")
        XCTAssertTrue(readings.isEmpty, "nothing is shown")
        locked = false
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none), "and it works again on unlock")
    }

    // MARK: Prompt and polling

    func testTurningItOnAsksForTheNeededPermissionOnce() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        XCTAssertEqual(trust.prompts, 1)
        hud.refresh()
        hud.refresh()
        XCTAssertEqual(trust.prompts, 1, "the poll and the panel opening never prompt")
    }

    func testTurningItOnWhenAlreadyTrustedDoesNotPromptAndTapsAtOnce() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.settingChanged(to: true)
        XCTAssertEqual(trust.prompts, 0)
        XCTAssertTrue(hud.isTapped)
    }

    func testTurningItOffNeverPrompts() {
        let hud = hud()
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertEqual(trust.prompts, 0)
    }

    func testWhileWaitingForThePermissionItPollsNoFasterThanEveryTwoSeconds() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        XCTAssertEqual(clock.pendingCount, 1)
        XCTAssertGreaterThanOrEqual(MediaKeyHUD.pollInterval, 2)
        // Many refreshes in a row make one poll, not many.
        hud.refresh(); hud.refresh()
        XCTAssertEqual(clock.pendingCount, 1)
        clock.fire()
        XCTAssertEqual(clock.pendingCount, 1, "still untrusted: one more wait, never a loop")
        XCTAssertTrue(clock.intervals.allSatisfy { $0 >= 2 })
    }

    func testThePollEndsWhenThePermissionArrivesAndTheTapAppears() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        trust.trusted = true
        clock.fire()
        XCTAssertEqual(clock.pendingCount, 0, "trusted: no polling at all")
        XCTAssertFalse(hud.isPolling)
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.needsAccessibility)
    }

    func testThePollEndsWhenTheSettingIsTurnedOff() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        XCTAssertTrue(hud.isPolling)
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(hud.isPolling)
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertFalse(hud.needsAccessibility)
    }

    func testNoPollingWhenOffOrWhenTrusted() {
        let hud = hud()
        enabled = false
        trust.trusted = false
        hud.refresh()
        XCTAssertEqual(clock.intervals.count, 0, "off and untrusted: nothing to wait for")
        enabled = true
        trust.trusted = true
        hud.refresh()
        XCTAssertEqual(clock.intervals.count, 0, "on and trusted: nothing to wait for")
    }

    func testOpeningThePanelNoticesAPermissionGrantedMeanwhile() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        trust.trusted = true
        hud.refresh()   // what the panel opening calls
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.isPolling)
    }

    func testStopEndsEverything() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.refresh()
        hud.stop()
        XCTAssertFalse(hud.isTapped)
        XCTAssertFalse(hud.isPolling)
        XCTAssertEqual(taps.taps[0].stops, 1)
    }
}
