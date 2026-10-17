import CoreAudio
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
    var onPrompt: (() -> Void)?
    func requestPrompt() { prompts += 1; onPrompt?() }
}

/// Isla's own Accessibility reset, as a counter. By default it finishes at once
/// and works; a test sets `holds` to finish it by hand and `result` to make it
/// fail. Nothing here starts a process.
@MainActor
final class FakeRepair: AccessibilityRepairing {
    var result = true
    var holds = false
    private(set) var resets = 0
    private var waiting: [@MainActor @Sendable (Bool) -> Void] = []
    /// Called as each reset starts, for ordering against the prompt.
    var onReset: (() -> Void)?

    func reset(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        resets += 1
        onReset?()
        if holds { waiting.append(completion) } else { completion(result) }
    }

    var isWaiting: Bool { !waiting.isEmpty }

    /// The tool finishes.
    func finish(_ worked: Bool? = nil) {
        let due = waiting
        waiting = []
        for completion in due { completion(worked ?? result) }
    }
}

/// A tap that is a counter. The factory records what each tap was handed, so a
/// test can press a key through the handler a real tap would call.
@MainActor
final class FakeTap: MediaKeyTapping {
    var started = false
    private(set) var stops = 0
    var startSucceeds = true
    /// What macOS says about the tap: switched on, or switched off behind our back.
    var enabled = true
    var isRunning: Bool { started }
    var isTapEnabled: Bool { started && enabled }
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
    private var pending: [Int: (interval: TimeInterval, work: @MainActor () -> Void)] = [:]
    private var next = 0

    var scheduler: MediaKeyHUD.Scheduler {
        { [unowned self] seconds, work in
            let id = self.next
            self.next += 1
            self.intervals.append(seconds)
            self.pending[id] = (seconds, work)
            return { [weak self] in self?.pending[id] = nil }
        }
    }

    var pendingCount: Int { pending.count }

    /// The delays of everything still waiting.
    var pendingIntervals: [TimeInterval] { pending.values.map(\.interval).sorted() }

    /// Fires everything that is waiting, once.
    func fire() {
        let due = pending
        pending = [:]
        for (_, item) in due { item.work() }
    }

    /// Fires only what was scheduled with exactly this delay, once, and leaves
    /// the rest waiting: the closure itself runs, not just its scheduling.
    func fire(interval: TimeInterval) {
        let due = pending.filter { $0.value.interval == interval }
        for (id, _) in due { pending[id] = nil }
        for (_, item) in due { item.work() }
    }
}

/// The system's "Accessibility list changed" announcement, as a counter. A test
/// calls `post()`; nothing here touches the real distributed notification centre.
@MainActor
final class FakeGrantNotifier: AccessibilityGrantNotifying {
    private var handlers: [Int: @MainActor @Sendable () -> Void] = [:]
    private var next = 0
    private(set) var observes = 0

    var isObserving: Bool { !handlers.isEmpty }

    func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let id = next
        next += 1
        observes += 1
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    /// What the system does when the list changes.
    func post() { for handler in handlers.values { handler() } }
}

@MainActor
final class FakeApplier: MediaKeyApplying {
    var reading: HUDReading?
    private(set) var applied: [(MediaKey, Bool)] = []
    private(set) var prepares = 0
    init(_ reading: HUDReading? = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil)) {
        self.reading = reading
    }
    func prepare() { prepares += 1 }
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
    private let grants = FakeGrantNotifier()
    private let repair = FakeRepair()
    private let ledger = MemoryRepairLedger()
    private var build = "100"
    private var locked = false
    private var sessionAvailable = true
    private var readings: [HUDReading] = []
    /// Every device the glyph lookup was asked about: the enumerator, counted.
    private var glyphLookups: [AudioDeviceID] = []
    private var glyphs: [AudioDeviceID: String] = [42: "airpods.pro"]
    /// And the name lookup, counted the same way.
    private var nameLookups: [AudioDeviceID] = []
    private var names: [AudioDeviceID: String] = [42: "AirPods Pro"]
    private var moment: TimeInterval = 1000

    private func hud() -> MediaKeyHUD {
        let hud = MediaKeyHUD(
            isEnabled: { [unowned self] in self.enabled },
            trust: trust,
            makeTap: taps.factory,
            applier: applier,
            schedule: clock.scheduler,
            deviceSymbol: { [unowned self] id in
                self.glyphLookups.append(id)
                return self.glyphs[id]
            },
            now: { [unowned self] in self.moment },
            grantNotifier: grants,
            repairer: repair,
            ledger: ledger,
            currentBuildIdentity: { [unowned self] in self.build },
            sessionIsAvailable: { [unowned self] in self.sessionAvailable },
            deviceName: { [unowned self] id in
                self.nameLookups.append(id)
                return self.names[id]
            }
        )
        hud.isLocked = { [unowned self] in self.locked }
        hud.onReading = { [unowned self] in self.readings.append($0) }
        return hud
    }

    /// Lets everything queued on the main queue run, in order.
    private func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }

    private func on(_ hud: MediaKeyHUD) {
        enabled = true
        trust.trusted = true
        hud.refresh()
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

    /// Trust is covered by `refresh()`, the disabled callback and the poll. A
    /// press used to call `AXIsProcessTrusted()` — a round trip to the system
    /// inside the tap's callback.
    func testAPressNeverAsksForTrust() {
        let hud = hud()
        on(hud)
        let before = trust.checks
        for key in MediaKey.allCases {
            _ = hud.handle(down(key), modifiers: .none)
            _ = hud.handle(down(key, isRepeat: true), modifiers: .none)
            _ = hud.handle(up(key), modifiers: .none)
        }
        XCTAssertEqual(trust.checks, before, "no trust call from a press")
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

    func testADisabledNoticeClearsHoldsSoLeftoversPassAfterTheReenable() {
        let hud = hud()
        on(hud)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        taps.disabled?()
        XCTAssertFalse(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none), "the system took it while the tap was off")
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none))
    }

    func testATapMacOSKeepsSwitchingOffIsRebuiltAtMostEveryFiveSeconds() {
        let hud = hud()
        on(hud)
        taps.taps[0].enabled = false
        hud.refresh()
        XCTAssertEqual(taps.created, 2)
        taps.taps[1].enabled = false
        moment += 1
        hud.refresh()
        XCTAssertEqual(taps.created, 2, "one second later: left alone")
        moment += 5
        hud.refresh()
        XCTAssertEqual(taps.created, 3, "six seconds after the first: rebuilt again")
    }

    func testTrustRegainedRebuildsAtOnceInsideTheFiveSeconds() {
        let hud = hud()
        on(hud)
        taps.taps[0].enabled = false
        hud.refresh()
        XCTAssertEqual(taps.created, 2)
        trust.trusted = false
        hud.refresh()
        trust.trusted = true
        moment += 1
        hud.refresh()
        XCTAssertEqual(taps.created, 3)
    }

    func testPanelOpenRenewsATapOlderThanFiveSeconds() {
        let hud = hud()
        on(hud)
        moment += 10
        hud.panelOpened()
        XCTAssertEqual(taps.created, 2)
        XCTAssertTrue(hud.isTapped)
    }

    func testPanelOpenMidPressNeverRenewsAndTheHoldStaysConsumedUntilItsKeyUp() {
        let hud = hud()
        on(hud)
        moment += 10
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        moment += 1
        hud.panelOpened()
        XCTAssertEqual(taps.created, 1, "a hold is in progress, so no rebuild")
        XCTAssertTrue(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none))
        XCTAssertEqual(applier.applied.count, 2, "the repeat still steps")
        XCTAssertTrue(hud.handle(up(.volumeUp), modifiers: .none), "the key-up is consumed")
        hud.panelOpened()
        XCTAssertEqual(taps.created, 2, "the next opening renews")
    }

    func testAHoldThatWentSilentIsDroppedAndTheTapIsRenewed() {
        let hud = hud()
        on(hud)
        moment += 10
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        moment += 4
        hud.panelOpened()
        XCTAssertEqual(taps.created, 2, "no event for 4 s: the key-up is lost, renew")
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none), "the stale hold is gone")
    }

    func testAHoldWhoseRepeatsKeepArrivingNeverLetsAnOpeningRenew() {
        let hud = hud()
        on(hud)
        moment += 10
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        for _ in 0..<50 {
            moment += 0.1
            XCTAssertTrue(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none))
        }
        hud.panelOpened()
        XCTAssertEqual(taps.created, 1, "5 s of repeats: still a live press")
        XCTAssertTrue(hud.handle(up(.volumeUp), modifiers: .none))
    }

    func testPanelOpenLeavesATapYoungerThanFiveSecondsAlone() {
        let hud = hud()
        on(hud)
        moment += 2
        hud.panelOpened()
        XCTAssertEqual(taps.created, 1)
    }

    func testTwoPanelOpensOneSecondApartRebuildOnce() {
        let hud = hud()
        on(hud)
        moment += 10
        hud.panelOpened()
        moment += 1
        hud.panelOpened()
        XCTAssertEqual(taps.created, 2)
    }

    func testPanelOpenMakesNoTapWhileOffOrUntrusted() {
        let hud = hud()
        enabled = false
        trust.trusted = true
        moment += 10
        hud.panelOpened()
        XCTAssertEqual(taps.created, 0)
        enabled = true
        trust.trusted = false
        hud.panelOpened()
        XCTAssertEqual(taps.created, 0)
    }

    func testThePollRefreshNeverRenewsAnOldTap() {
        let hud = hud()
        on(hud)
        moment += 10
        hud.refresh()
        XCTAssertEqual(taps.created, 1)
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

    // MARK: The callback does no slow work

    func testAVolumePressAsksNoDeviceEnumeratorInsideTheCallback() async {
        let hud = hud()
        on(hud)
        applier.reading = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil, outputDevice: 42)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        XCTAssertTrue(glyphLookups.isEmpty, "zero lookups from handle(...)")
        XCTAssertTrue(readings.isEmpty, "the pop-up follows once the glyph is known")
        await drain()
        XCTAssertEqual(glyphLookups, [42], "resolved after the callback returned, for the pop-up only")
        XCTAssertEqual(readings.map(\.deviceSymbol), ["airpods.pro"])
        XCTAssertEqual(readings.first?.outputDevice, 42)
    }

    func testNoPopUpFollowsAPressOnceTheMacLocksBeforeTheQueueDrains() async {
        let hud = hud()
        var locked = false
        hud.isLocked = { locked }
        on(hud)
        applier.reading = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil, outputDevice: 42)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        locked = true
        await drain()
        XCTAssertTrue(readings.isEmpty)
    }

    func testNoPopUpFollowsAPressOnceTheTapHasStoppedBeforeTheQueueDrains() async {
        let hud = hud()
        on(hud)
        applier.reading = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil, outputDevice: 42)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        hud.stop()
        await drain()
        XCTAssertTrue(readings.isEmpty)
    }

    func testTheRepeatsOfAHeldVolumeKeyReuseTheGlyphAndStayInOrder() async {
        let hud = hud()
        on(hud)
        applier.reading = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil, outputDevice: 42)
        _ = hud.handle(down(.volumeUp), modifiers: .none)
        for _ in 0..<10 { _ = hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none) }
        await drain()
        XCTAssertEqual(glyphLookups.count, 1, "one lookup for the hold, none per repeat")
        XCTAssertEqual(readings.count, 11)
        XCTAssertTrue(readings.allSatisfy { $0.deviceSymbol == "airpods.pro" })

        // The next press is a new hold and asks again: a headphone jack's data
        // source changes with the device id unchanged.
        _ = hud.handle(up(.volumeUp), modifiers: .none)
        glyphs[42] = "headphones"
        _ = hud.handle(down(.volumeUp), modifiers: .none)
        await drain()
        XCTAssertEqual(glyphLookups.count, 2)
        XCTAssertEqual(readings.last?.deviceSymbol, "headphones")
    }

    /// The pop-up names the output it changed (spec §19.5 d). The name is
    /// found with the glyph — after the callback, once per hold — since it is
    /// the same CoreAudio enumeration.
    func testThePopUpNamesTheOutputFoundOncePerHold() async {
        let hud = hud()
        on(hud)
        applier.reading = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil, outputDevice: 42)
        _ = hud.handle(down(.volumeUp), modifiers: .none)
        XCTAssertTrue(nameLookups.isEmpty, "zero lookups from handle(...)")
        for _ in 0..<5 { _ = hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none) }
        await drain()
        XCTAssertEqual(nameLookups, [42], "one lookup for the hold")
        XCTAssertTrue(readings.allSatisfy { $0.deviceName == "AirPods Pro" })

        _ = hud.handle(up(.volumeUp), modifiers: .none)
        names[42] = "External Headphones"
        _ = hud.handle(down(.volumeUp), modifiers: .none)
        await drain()
        XCTAssertEqual(nameLookups.count, 2, "a new hold asks again")
        XCTAssertEqual(readings.last?.deviceName, "External Headphones")
    }

    func testBrightnessReadingsNeedNoGlyphAndAreShownAtOnce() {
        let hud = hud()
        on(hud)
        applier.reading = HUDReading(kind: .display, level: 0.5, muted: false, deviceSymbol: nil)
        XCTAssertTrue(hud.handle(down(.brightnessUp), modifiers: .none))
        XCTAssertEqual(readings.count, 1)
        XCTAssertTrue(glyphLookups.isEmpty)
    }

    func testTheApplierIsPreparedOncePerTapAndNeverByAPress() {
        let hud = hud()
        on(hud)
        XCTAssertEqual(applier.prepares, 1)
        for _ in 0..<5 { _ = hud.handle(down(.volumeUp), modifiers: .none) }
        hud.refresh(); hud.refresh()
        XCTAssertEqual(applier.prepares, 1, "presses and refreshes do not resolve anything")
        trust.trusted = false
        hud.refresh()
        trust.trusted = true
        hud.refresh()
        XCTAssertEqual(applier.prepares, 2, "a restarted tap resolves again")
    }

    func testATapThatDidNotStartResolvesNothing() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        XCTAssertEqual(applier.prepares, 0)
    }

    // MARK: Modifier chords belong to the system

    /// All sixteen combinations of ⌘ ⌃ ⌥ ⇧, for every key family: only none and
    /// ⌥⇧ are consumed.
    func testOnlyAPlainPressAndOptionShiftAreConsumed() {
        let all: [CGEventFlags] = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for mask in 0..<16 {
            var flags: CGEventFlags = []
            var names: [String] = []
            for (index, flag) in all.enumerated() where mask & (1 << index) != 0 {
                flags.insert(flag)
                names.append("\(flag.rawValue)")
            }
            let command = flags.contains(.maskCommand), control = flags.contains(.maskControl)
            let option = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)
            let expectConsumed = !command && !control && option == shift
            let modifiers = MediaKeyModifiers(flags: flags)
            XCTAssertEqual(!modifiers.leavesToTheSystem, expectConsumed, "flags \(names)")
            XCTAssertEqual(modifiers.fine, option && shift, "flags \(names)")

            let hud = hud()
            on(hud)
            for key in MediaKey.allCases {   // volume, brightness and illumination
                applier.reading = HUDReading(kind: key.kind, level: 0.5, muted: false, deviceSymbol: nil)
                XCTAssertEqual(hud.handle(down(key), modifiers: modifiers), expectConsumed, "\(key) with \(names)")
                XCTAssertEqual(hud.handle(up(key), modifiers: modifiers), expectConsumed, "its release too")
            }
        }
    }

    func testFnCapsLockAndTheNumericPadBitAreNotModifiers() {
        // The built-in keyboard stamps fn on its media keys.
        let plain = MediaKeyModifiers(flags: [.maskSecondaryFn, .maskAlphaShift, .maskNumericPad])
        XCTAssertFalse(plain.leavesToTheSystem)
        XCTAssertFalse(plain.fine)
        XCTAssertTrue(MediaKeyModifiers(flags: [.maskSecondaryFn, .maskAlternate, .maskShift]).fine)
        XCTAssertTrue(MediaKeyModifiers(flags: [.maskSecondaryFn, .maskCommand]).leavesToTheSystem)
    }

    func testAChordPassedThroughAppliesAndShowsNothing() {
        let hud = hud()
        on(hud)
        XCTAssertFalse(hud.handle(down(.volumeUp), modifiers: MediaKeyModifiers(flags: .maskShift)))
        XCTAssertFalse(hud.handle(down(.brightnessDown), modifiers: MediaKeyModifiers(flags: .maskAlternate)))
        XCTAssertFalse(hud.handle(down(.mute), modifiers: MediaKeyModifiers(flags: .maskCommand)))
        XCTAssertTrue(applier.applied.isEmpty)
        XCTAssertTrue(readings.isEmpty)
    }

    // MARK: A press-and-hold is decided once

    func testAHoldDecidedPassStaysPassThroughItsRepeatsWhateverChanges() {
        let hud = hud()
        on(hud)
        applier.reading = nil                       // the first key-down cannot be applied
        XCTAssertFalse(hud.handle(down(.volumeUp), modifiers: .none))
        applier.reading = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil)
        XCTAssertFalse(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none), "now it could apply; it still passes")
        XCTAssertFalse(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none))
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none), "and so does its release")
        XCTAssertEqual(applier.applied.count, 1, "only the first key-down was tried")
        XCTAssertTrue(readings.isEmpty)
    }

    func testAChordHeldFromTheFirstKeyDownStaysPassedEvenIfTheChordIsReleased() {
        let hud = hud()
        on(hud)
        XCTAssertFalse(hud.handle(down(.volumeUp), modifiers: MediaKeyModifiers(flags: .maskCommand)))
        XCTAssertFalse(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none))
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none))
        XCTAssertTrue(applier.applied.isEmpty)
    }

    func testAHoldDecidedConsumeStaysConsumedAndItsRepeatsFollow() {
        let hud = hud()
        on(hud)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        // The applier would now refuse (the output changed mid-hold): the
        // repeat is still swallowed, so the system never sees a stray repeat.
        applier.reading = nil
        XCTAssertTrue(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none))
        XCTAssertTrue(hud.handle(up(.volumeUp), modifiers: .none))
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none), "the hold ended with its release")
    }

    /// The rule chosen for a lock mid-hold: the hold stays consumed, so its
    /// key-up pairs; nothing changes and nothing is shown while locked.
    func testALockInTheMiddleOfAConsumedHoldSwallowsTheRepeatsWithoutChangingAnything() {
        let hud = hud()
        var locked = false
        hud.isLocked = { locked }
        on(hud)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        locked = true
        XCTAssertTrue(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none), "still consumed")
        XCTAssertEqual(applier.applied.count, 1, "no level change while locked")
        XCTAssertEqual(readings.count, 1, "nothing shown while locked")
        XCTAssertTrue(hud.handle(up(.volumeUp), modifiers: .none), "the release pairs with the swallowed press")
    }

    func testARepeatOrReleaseWithNoPressBehindItIsPassed() {
        let hud = hud()
        on(hud)
        XCTAssertFalse(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none), "the tap began mid-hold")
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none))
        XCTAssertTrue(applier.applied.isEmpty)
    }

    func testEachKeyHasItsOwnHold() {
        let hud = hud()
        on(hud)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        applier.reading = nil
        XCTAssertFalse(hud.handle(down(.brightnessUp), modifiers: .none))
        XCTAssertTrue(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none), "volume's hold is unaffected")
        XCTAssertFalse(hud.handle(up(.brightnessUp), modifiers: .none))
        XCTAssertTrue(hud.handle(up(.volumeUp), modifiers: .none))
    }

    func testAHeldMuteDoesNotFlipTheMuteBackAndForth() {
        let hud = hud()
        on(hud)
        XCTAssertTrue(hud.handle(down(.mute), modifiers: .none))
        for _ in 0..<5 { XCTAssertTrue(hud.handle(down(.mute, isRepeat: true), modifiers: .none), "consumed") }
        XCTAssertEqual(applier.applied.count, 1, "one toggle, however long it is held")
        XCTAssertEqual(readings.count, 1)
        XCTAssertTrue(hud.handle(up(.mute), modifiers: .none))
    }

    func testAHoldWhoseKeyUpWasLostIsReplacedByTheNextFreshPress() {
        let hud = hud()
        on(hud)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        applier.reading = nil
        XCTAssertFalse(hud.handle(down(.volumeUp), modifiers: .none), "a new press decides again")
        XCTAssertFalse(hud.handle(down(.volumeUp, isRepeat: true), modifiers: .none))
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none))
    }

    func testHoldsEndWithTheTap() {
        let hud = hud()
        on(hud)
        XCTAssertTrue(hud.handle(down(.volumeUp), modifiers: .none))
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(hud.handle(up(.volumeUp), modifiers: .none), "no tap, no owed release")
    }

    // MARK: A tap that died

    func testRevokeAndRegrantMakesANewTapWithoutAnyDisabledCallback() {
        let hud = hud()
        on(hud)
        let first = taps.taps[0]
        trust.trusted = false
        hud.refresh()
        XCTAssertFalse(first.started)
        trust.trusted = true
        clock.fire()   // the poll that was waiting for it
        XCTAssertEqual(taps.created, 2, "re-created")
        XCTAssertTrue(taps.taps[1].started)
        XCTAssertEqual(applier.prepares, 2)
    }

    func testATapMacOSSwitchedOffBehindOurBackIsRebuiltByTheNextLook() {
        let hud = hud()
        on(hud)
        let first = taps.taps[0]
        // Revoked and re-granted between two looks: trust reads true both
        // times, no disabled notice came, and the tap hears nothing.
        first.enabled = false
        hud.refresh()
        XCTAssertFalse(first.started, "the dead one was ended")
        XCTAssertEqual(taps.created, 2)
        XCTAssertTrue(taps.taps[1].started)
        hud.refresh()
        XCTAssertEqual(taps.created, 2, "a healthy tap is left alone")
    }

    // MARK: Display sleep

    func testTheTrustPollStopsWhileTheDisplaySleepsAndResumesOnWake() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        XCTAssertTrue(hud.isPolling)

        hud.suspend()
        XCTAssertFalse(hud.isPolling)
        XCTAssertEqual(clock.pendingCount, 0)
        hud.refresh()
        XCTAssertFalse(hud.isPolling, "a refresh during sleep does not restart it")
        XCTAssertTrue(hud.needsAccessibility, "the state itself is kept")

        hud.resume()
        XCTAssertTrue(hud.isPolling, "still on and untrusted: waiting again")
        XCTAssertEqual(clock.pendingCount, 1)
    }

    func testWakingWithThePermissionGrantedMeanwhileMakesTheTapAndDoesNotPoll() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        hud.suspend()
        trust.trusted = true
        hud.resume()
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.isPolling)
    }

    func testWakingWithTheSettingOffDoesNotPoll() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        hud.suspend()
        enabled = false
        hud.resume()
        XCTAssertFalse(hud.isPolling)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testSuspendingKeepsATapThatExists() {
        let hud = hud()
        on(hud)
        hud.suspend()
        XCTAssertTrue(hud.isTapped, "keys pass through a lock by themselves; the tap stays")
    }

    func testTheIdleScreenPathSuspendsTheHUDPoll() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        XCTAssertTrue(hud.isPolling)
        let stores = NotchStores(hud: hud)
        stores.suspendForIdleScreen()
        XCTAssertFalse(hud.isPolling, "display sleep and lock both land here")
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

    // MARK: A tap that would not start is retried (2026-10-16, owner)

    func testATapThatFailsTwiceIsRetriedUntilItStartsAndThenNothingPolls() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        XCTAssertFalse(hud.isTapped)
        XCTAssertTrue(hud.isPolling, "trusted, on, no tap: keep looking")
        XCTAssertFalse(hud.needsAccessibility, "the permission is not what is missing")

        clock.fire()   // second failure
        XCTAssertFalse(hud.isTapped)
        XCTAssertTrue(hud.isPolling)

        taps.startSucceeds = true
        clock.fire()
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.isPolling, "a running tap needs no poll")
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertEqual(taps.created, 3)
        XCTAssertEqual(clock.intervals, [MediaKeyHUD.pollInterval, MediaKeyHUD.pollInterval])
        XCTAssertEqual(trust.prompts, 0, "a retry never raises the prompt")
    }

    func testTurningTheSettingOffDuringTheRetriesStopsEverything() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        XCTAssertTrue(hud.isPolling)
        XCTAssertTrue(hud.isObserving)

        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(hud.isPolling)
        XCTAssertFalse(hud.isObserving)
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertFalse(grants.isObserving)
        let created = taps.created
        clock.fire()
        XCTAssertEqual(taps.created, created, "nothing is left to try again")
    }

    func testTheTapRetryStaysDownWhileTheDisplaySleepsAndComesBackOnWake() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        hud.suspend()
        XCTAssertFalse(hud.isPolling)
        XCTAssertFalse(hud.isObserving)
        hud.refresh()
        XCTAssertFalse(hud.isPolling, "a refresh during sleep does not restart it")
        XCTAssertFalse(hud.isObserving)

        hud.resume()
        XCTAssertTrue(hud.isPolling)
        XCTAssertTrue(hud.isObserving)
    }

    func testARetryThatSucceedsStopsListeningToo() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        taps.startSucceeds = true
        clock.fire()
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.isObserving)
    }

    // MARK: The grant is noticed at once (2026-10-16, owner)

    func testTheAccessibilityListIsWatchedOnlyWhileThePermissionIsMissingOrATapIsPending() {
        let hud = hud()
        hud.refresh()
        XCTAssertFalse(hud.isObserving, "off")
        XCTAssertEqual(grants.observes, 0)

        enabled = true
        trust.trusted = false
        hud.refresh()
        XCTAssertTrue(hud.isObserving, "on and untrusted")
        hud.refresh()
        XCTAssertEqual(grants.observes, 1, "one watch, however many looks")

        trust.trusted = true
        hud.refresh()
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.isObserving, "trusted with a tap: nothing to wait for")

        trust.trusted = false
        hud.refresh()
        XCTAssertTrue(hud.isObserving)
        enabled = false
        hud.refresh()
        XCTAssertFalse(hud.isObserving)
    }

    func testTheAnnouncementLooksAgainAfterAThirdAndAfterOneAndAHalfSeconds() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        XCTAssertEqual(clock.intervals, [MediaKeyHUD.pollInterval])

        grants.post()
        XCTAssertEqual(clock.intervals, [MediaKeyHUD.pollInterval, 0.3, 1.5])
        XCTAssertFalse(hud.isTapped, "the announcement itself decides nothing")

        // tccd lags: the 0.3 s look still hears "not trusted" and changes
        // nothing...
        clock.fire(interval: 0.3)
        XCTAssertFalse(hud.isTapped)
        XCTAssertTrue(hud.needsAccessibility)

        // ...and by the 1.5 s look the grant has landed: that closure alone
        // makes the tap.
        trust.trusted = true
        clock.fire(interval: 1.5)
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.needsAccessibility)
        XCTAssertFalse(hud.isObserving)
        XCTAssertFalse(hud.isPolling)
        XCTAssertEqual(trust.prompts, 0, "noticing a grant never prompts")
    }

    func testTheFirstLookEndingTheWatchDoesNotCancelTheSecond() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()

        trust.trusted = true
        clock.fire(interval: 0.3)
        XCTAssertTrue(hud.isTapped, "the 0.3 s look made the tap")
        XCTAssertFalse(hud.isObserving, "nothing left to wait for")
        XCTAssertEqual(clock.pendingIntervals, [1.5], "the second look survives it")

        // The second look runs on its own: macOS switched the tap off meanwhile
        // and it is due for a rebuild, which only a real refresh would notice.
        taps.taps[0].enabled = false
        moment += MediaKeyHUD.rebuildInterval
        let checks = trust.checks
        clock.fire(interval: 1.5)
        XCTAssertGreaterThan(trust.checks, checks, "the closure itself looked")
        XCTAssertEqual(taps.created, 2, "and rebuilt the tap")
        XCTAssertTrue(hud.isTapped)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testTheSecondLookStillKeepsAHealthyTap() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()
        trust.trusted = true
        clock.fire(interval: 0.3)
        clock.fire(interval: 1.5)
        XCTAssertEqual(taps.created, 1)
        XCTAssertTrue(hud.isTapped)
    }

    func testTheLooksStillDieWhenTheFirstOneHasEndedTheWatchAndTheSettingGoesOff() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()
        trust.trusted = true
        clock.fire(interval: 0.3)
        XCTAssertEqual(clock.pendingIntervals, [1.5])
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testTheLooksStillDieOnSuspendAndOnStopAfterTheWatchEnded() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()
        trust.trusted = true
        clock.fire(interval: 0.3)
        hud.suspend()
        XCTAssertEqual(clock.pendingCount, 0, "a dark screen runs nothing")

        hud.resume()
        grants.post()   // not observing: a tap exists
        XCTAssertEqual(clock.pendingCount, 0)

        trust.trusted = false
        hud.refresh()
        grants.post()
        trust.trusted = true
        clock.fire(interval: 0.3)
        XCTAssertEqual(clock.pendingIntervals, [1.5])
        hud.stop()
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testAnAnnouncementBurstReplacesTheLooksInsteadOfStackingThem() {
        let hud = hud()
        enabled = true
        hud.refresh()
        grants.post()
        grants.post()
        XCTAssertEqual(clock.pendingCount, 3, "the poll and one pair of looks")
    }

    func testTheLooksAnAnnouncementQueuedDieWithTheSetting() {
        let hud = hud()
        enabled = true
        hud.refresh()
        grants.post()
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertFalse(hud.isObserving)
    }

    func testAnAnnouncementWhileTheDisplaySleepsIsNotListenedTo() {
        let hud = hud()
        enabled = true
        hud.refresh()
        hud.suspend()
        grants.post()
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertFalse(grants.isObserving)
    }

    func testStopEndsTheWatchToo() {
        let hud = hud()
        enabled = true
        hud.refresh()
        grants.post()
        hud.stop()
        XCTAssertFalse(grants.isObserving)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    // MARK: Isla repairs its own stale Accessibility entry (2026-10-17, owner)

    func testSwitchingItOnUntrustedRepairsThenPromptsInThatOrder() {
        let hud = hud()
        var events: [String] = []
        repair.onReset = { events.append("reset") }
        trust.onPrompt = { events.append("prompt") }
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        XCTAssertEqual(events, ["reset", "prompt"])
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
    }

    func testThePromptWaitsForTheRepairToFinish() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 0, "macOS would still see the stale entry")
        XCTAssertTrue(hud.needsAccessibility)
        hud.refresh()
        clock.fire()
        XCTAssertEqual(trust.prompts, 0, "no look prompts, and none repairs again")
        XCTAssertEqual(repair.resets, 1)

        repair.finish()
        XCTAssertEqual(trust.prompts, 1)
        hud.refresh()
        XCTAssertEqual(trust.prompts, 1, "once per switch-on")
        XCTAssertEqual(repair.resets, 1)
    }

    func testAFailedRepairStillPromptsAndTheFootnoteWaitsThirtySecondsLikeAnyOther() {
        let hud = hud()
        repair.result = false
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        XCTAssertEqual(trust.prompts, 1, "it costs nothing to ask")
        XCTAssertFalse(hud.suspectsStaleEntry, "a Mac with no entry at all may fail the reset, and needs no hint yet")
        moment += 31
        hud.refresh()
        XCTAssertTrue(hud.suspectsStaleEntry, "still untrusted thirty seconds after the prompt, whatever the reset said")
        trust.trusted = true
        hud.refresh()
        XCTAssertFalse(hud.suspectsStaleEntry)
    }

    func testAGrantWithinThirtySecondsOfAFailedRepairNeverShowsTheFootnote() {
        let hud = hud()
        repair.result = false
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        moment += 20
        trust.trusted = true
        hud.refresh()
        moment += 20
        hud.refresh()
        XCTAssertFalse(hud.suspectsStaleEntry)
    }

    func testTheFootnoteWaitsThirtySecondsAfterASuccessfulRepairAndPrompt() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        XCTAssertTrue(hud.needsAccessibility)
        XCTAssertFalse(hud.suspectsStaleEntry)

        moment += 29.9
        hud.refresh()
        XCTAssertFalse(hud.suspectsStaleEntry, "a slow grant is not a stale entry")

        moment += 0.2
        clock.fire()   // the poll's own look
        XCTAssertTrue(hud.suspectsStaleEntry)
        XCTAssertEqual(trust.prompts, 1, "the prompt was raised once, by the switch")
    }

    func testTheFootnoteNeverShowsWithoutARepairHavingRun() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        moment += 600
        hud.refresh()
        XCTAssertTrue(hud.needsAccessibility)
        XCTAssertFalse(hud.suspectsStaleEntry)
        XCTAssertEqual(repair.resets, 0, "a look never repairs")
    }

    func testTheFootnoteEndsWithTheGrantAndWithTheSetting() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        moment += 31
        hud.refresh()
        XCTAssertTrue(hud.suspectsStaleEntry)

        trust.trusted = true
        hud.refresh()
        XCTAssertFalse(hud.suspectsStaleEntry)
        XCTAssertFalse(hud.isPolling, "no timer runs once the permission is granted")

        trust.trusted = false
        hud.settingChanged(to: true)
        moment += 31
        hud.refresh()
        XCTAssertTrue(hud.suspectsStaleEntry)
        enabled = false
        hud.refresh()
        XCTAssertFalse(hud.suspectsStaleEntry)
    }

    func testSwitchingItOffAndOnRestartsTheThirtySecondsAndRepairsAgain() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        moment += 31
        hud.refresh()
        XCTAssertTrue(hud.suspectsStaleEntry)
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(hud.suspectsStaleEntry)
        enabled = true
        hud.settingChanged(to: true)
        XCTAssertFalse(hud.suspectsStaleEntry)
        XCTAssertEqual(repair.resets, 2, "each switch-on repairs")
        XCTAssertEqual(trust.prompts, 2, "and prompts once")
    }

    func testSwitchingItOffWhileTheRepairRunsNeverPrompts() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        enabled = false
        hud.settingChanged(to: false)
        repair.finish()
        XCTAssertEqual(trust.prompts, 0)
        XCTAssertFalse(hud.suspectsStaleEntry)
    }

    func testTrustedOrOffNeverRepairs() {
        let hud = hud()
        enabled = true
        trust.trusted = true
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 0, "trusted")
        enabled = false
        trust.trusted = false
        hud.settingChanged(to: false)
        XCTAssertEqual(repair.resets, 0, "off")
        XCTAssertEqual(trust.prompts, 0)
    }

    func testTimeSpentAsleepDoesNotCountTowardsTheThirtySeconds() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        hud.suspend()
        moment += 600
        hud.resume()
        XCTAssertFalse(hud.suspectsStaleEntry)
        moment += 31
        hud.refresh()
        XCTAssertTrue(hud.suspectsStaleEntry)
    }

    func testAnAnnouncementRestartsTheFootnoteWait() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        moment += 25
        grants.post()   // the person is acting in System Settings
        moment += 25
        clock.fire(interval: 0.3)
        XCTAssertFalse(hud.suspectsStaleEntry, "fifty seconds in, but only twenty-five since the last sign of life")
        moment += 6
        clock.fire(interval: 1.5)
        XCTAssertTrue(hud.suspectsStaleEntry, "thirty-one silent seconds")
    }

    func testAnAnnouncementClearsAFootnoteThatWasAlreadyShownAfterASuccessfulRepair() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        moment += 31
        hud.refresh()
        XCTAssertTrue(hud.suspectsStaleEntry)
        grants.post()
        clock.fire(interval: 0.3)
        XCTAssertFalse(hud.suspectsStaleEntry)
    }

    // MARK: Launch repairs once per build (2026-10-17, owner)

    func testLaunchWithTheSettingOnAndUntrustedRepairsAndPromptsOncePerBuild() {
        enabled = true
        trust.trusted = false
        hud().launched()
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
        XCTAssertEqual(ledger.lastRepairedBuild, "100")

        let again = hud()   // a second launch of the same build
        again.launched()
        XCTAssertEqual(repair.resets, 1, "a person who declined is not asked at every launch")
        XCTAssertEqual(trust.prompts, 1)

        build = "101"
        hud().launched()
        XCTAssertEqual(repair.resets, 2, "a new build repairs again")
        XCTAssertEqual(trust.prompts, 2)
        XCTAssertEqual(ledger.lastRepairedBuild, "101")
    }

    func testLaunchDoesNothingWhenTrustedOrOff() {
        enabled = true
        trust.trusted = true
        hud().launched()
        enabled = false
        trust.trusted = false
        hud().launched()
        XCTAssertEqual(repair.resets, 0)
        XCTAssertEqual(trust.prompts, 0)
        XCTAssertNil(ledger.lastRepairedBuild)
    }

    func testSwitchingItOnCountsAsTheBuildsRepairSoTheNextLaunchStaysQuiet() {
        let first = hud()
        enabled = true
        trust.trusted = false
        first.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 1)
        hud().launched()
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
    }

    func testLaunchWhileLockedWaitsForTheFirstUnlockedResume() {
        enabled = true
        trust.trusted = false
        locked = true
        let hud = hud()
        hud.launched()
        XCTAssertEqual(repair.resets, 0)
        hud.suspend()
        hud.resume()   // still locked
        XCTAssertEqual(repair.resets, 0)

        locked = false
        hud.suspend()
        hud.resume()
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
        hud.suspend()
        hud.resume()
        XCTAssertEqual(repair.resets, 1, "once")
    }

    func testLaunchWithTheDisplayAsleepWaitsForTheWake() {
        enabled = true
        trust.trusted = false
        let hud = hud()
        hud.suspend()
        hud.launched()
        XCTAssertEqual(repair.resets, 0)
        hud.resume()
        XCTAssertEqual(repair.resets, 1)
    }

    func testAResumeNeverRepairsForALaunchThatAlreadyHadItsLook() {
        enabled = true
        trust.trusted = true
        let hud = hud()
        hud.launched()   // trusted: nothing to do, and nothing pending
        trust.trusted = false
        hud.suspend()
        hud.resume()
        XCTAssertEqual(repair.resets, 0, "only switching it on, or the next build, repairs")
    }

    func testAGrantLookNeverRepairsOrPrompts() {
        enabled = true
        trust.trusted = false
        let hud = hud()
        hud.launched()
        XCTAssertEqual(repair.resets, 1)
        grants.post()
        clock.fire()
        hud.panelOpened()
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
    }

    func testARepairFinishingAfterTheMacLockedIsMadeAgainAtTheNextResume() {
        enabled = true
        trust.trusted = false
        repair.holds = true
        let hud = hud()
        hud.launched()
        locked = true
        hud.suspend()
        repair.finish()
        XCTAssertEqual(trust.prompts, 0, "nobody could answer it")
        locked = false
        repair.holds = false
        hud.resume()
        XCTAssertEqual(repair.resets, 2)
        XCTAssertEqual(trust.prompts, 1)
    }

    func testAHUDBuiltWithDefaultsNeverResetsTheRealEntry() {
        XCTAssertTrue(InertAccessibilityRepair.live is InertAccessibilityRepair)
        XCTAssertTrue(MemoryRepairLedger.live is MemoryRepairLedger)
        var finished: [Bool] = []
        InertAccessibilityRepair.live.reset { finished.append($0) }
        XCTAssertEqual(finished, [false])
        let hud = MediaKeyHUD(isEnabled: { true }, trust: FakeTrust(false))
        hud.settingChanged(to: true)   // would run tccutil if the default were real
        hud.launched()
        hud.stop()
    }

    // MARK: Review round 1 (2026-10-17)

    func testALaunchOntoAnUnavailableSessionWaitsAndThePollFiresItOnce() {
        enabled = true
        trust.trusted = false
        sessionAvailable = false   // locked behind our back, or a dark display
        let hud = hud()
        hud.launched()
        XCTAssertEqual(repair.resets, 0)
        XCTAssertNil(ledger.lastRepairedBuild, "the one try is not spent")
        XCTAssertTrue(hud.isPolling)

        clock.fire()   // the poll, still locked
        XCTAssertEqual(repair.resets, 0)

        sessionAvailable = true
        clock.fire()
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
        XCTAssertEqual(ledger.lastRepairedBuild, "100")
        clock.fire()
        hud.refresh()
        XCTAssertEqual(repair.resets, 1, "once per build: the pending flag is spent")
    }

    func testAPendingRepairIsNotFiredByARefreshOnceTrustedOrOff() {
        enabled = true
        trust.trusted = false
        sessionAvailable = false
        let hud = hud()
        hud.launched()
        trust.trusted = true
        sessionAvailable = true
        hud.refresh()
        trust.trusted = false
        hud.refresh()
        XCTAssertEqual(repair.resets, 0, "granted in the meantime: nothing was pending any more")

        let off = self.hud()
        enabled = false
        sessionAvailable = false
        off.launched()
        enabled = true
        sessionAvailable = true
        off.refresh()
        XCTAssertEqual(repair.resets, 0)
    }

    func testResumeFiresAPendingRepairEvenWhenTheHUDWasNeverSuspended() {
        enabled = true
        trust.trusted = false
        locked = true
        let hud = hud()
        hud.launched()
        hud.suspend()
        // The wake plan resumes the stores while the Mac still reads as locked,
        // then replays the unlock: two resumes, the first clearing the suspend.
        hud.resume()
        XCTAssertEqual(repair.resets, 0)
        locked = false
        hud.resume()   // no longer suspended: the guard used to return here
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
    }

    func testAnAnnouncementJustBeforeASwitchOnDefersTheResetAndAGrantCancelsIt() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()   // watching
        grants.post()
        moment += 1
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 0, "tccd may be about to say yes")
        XCTAssertEqual(trust.prompts, 0)

        trust.trusted = true   // the grant landed
        clock.fire(interval: 1.5)
        XCTAssertEqual(repair.resets, 0, "a fresh grant is never wiped")
        XCTAssertEqual(trust.prompts, 0)
        XCTAssertNil(ledger.lastRepairedBuild)
    }

    func testAnAnnouncementJustBeforeASwitchOnStillRepairsIfNothingChangesAtOnePointFive() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 0)
        moment += 1.5
        clock.fire(interval: 1.5)
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
    }

    func testAnOldAnnouncementDoesNotDefer() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()
        moment += 5
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 1, "five seconds on, the quiet period is over")
    }

    func testTrustIsReadAgainRightBeforeTheReset() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()
        hud.settingChanged(to: true)   // deferred
        trust.trusted = true
        moment += 1.5
        clock.fire()
        XCTAssertEqual(repair.resets, 0)
    }

    func testSwitchingOffCancelsADeferredRepair() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        hud.refresh()
        grants.post()
        hud.settingChanged(to: true)
        enabled = false
        hud.settingChanged(to: false)
        moment += 2
        clock.fire()
        XCTAssertEqual(repair.resets, 0)
    }

    func testTheHUDSaysItIsRepairingOnlyWhileTheToolRuns() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        XCTAssertFalse(hud.isRepairing)
        hud.settingChanged(to: true)
        XCTAssertTrue(hud.isRepairing, "Settings greys Open Privacy & Security… meanwhile")
        repair.finish()
        XCTAssertFalse(hud.isRepairing)

        repair.holds = true
        enabled = false
        hud.settingChanged(to: false)
        enabled = true
        hud.settingChanged(to: true)
        XCTAssertTrue(hud.isRepairing)
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(hud.isRepairing, "switching off ends it")
    }

    func testALaunchWhoseBuildAlreadyHadItsRepairShowsTheFootnoteAtOnceWhileUntrusted() {
        enabled = true
        trust.trusted = false
        ledger.lastRepairedBuild = "100"
        let hud = hud()
        hud.launched()
        XCTAssertEqual(repair.resets, 0, "the one try is spent")
        XCTAssertTrue(hud.suspectsStaleEntry, "the manual route is the only one left")
        trust.trusted = true
        hud.refresh()
        XCTAssertFalse(hud.suspectsStaleEntry, "never while trusted")
    }

    func testTheSpentTryFootnoteNeedsTheSettingOnAndAnAvailableSession() {
        trust.trusted = false
        ledger.lastRepairedBuild = "100"
        enabled = false
        let off = hud()
        off.launched()
        XCTAssertFalse(off.suspectsStaleEntry)

        enabled = true
        sessionAvailable = false
        let dark = hud()
        dark.launched()
        XCTAssertFalse(dark.suspectsStaleEntry, "not judged while nobody can see it")
        sessionAvailable = true
        dark.refresh()
        XCTAssertTrue(dark.suspectsStaleEntry)
    }

    func testANewCodeIdentityWithTheSameBundleVersionRepairsAgain() {
        enabled = true
        trust.trusted = false
        build = "cdhash-a"
        hud().launched()
        XCTAssertEqual(repair.resets, 1)
        build = "cdhash-b"   // a rebuild or a re-sign: same CFBundleVersion, new TCC identity
        hud().launched()
        XCTAssertEqual(repair.resets, 2)
        XCTAssertEqual(ledger.lastRepairedBuild, "cdhash-b")
    }

    // MARK: Review round 2 (2026-10-17)

    func testSwitchingOffAndOnWhileTheToolRunsNeverStartsASecondOne() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 1)
        enabled = false
        hud.settingChanged(to: false)
        enabled = true
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 1, "the new switch-on waits for the run already going")
        XCTAssertEqual(trust.prompts, 0)
        XCTAssertTrue(hud.isRepairing)

        repair.finish()
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1, "one prompt, after the one reset")
        XCTAssertFalse(hud.isRepairing)
    }

    func testARunThatFinishesAfterAGrantRaisesNoPromptAndTheSwitchOffOnWaitsForNothingMore() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        enabled = false
        hud.settingChanged(to: false)
        enabled = true
        hud.settingChanged(to: true)
        trust.trusted = true
        repair.finish()
        XCTAssertEqual(trust.prompts, 0, "trust is read again once the run ends")
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(ledger.lastRepairedBuild, "100", "granted: nothing left to retry")
    }

    func testAFinishedRunWhoseSwitchWentOffForGoodRaisesNothing() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        enabled = false
        hud.settingChanged(to: false)
        repair.finish()
        XCTAssertEqual(trust.prompts, 0)
        // And a later switch-on may start a tool again: none is in flight now.
        repair.holds = false
        enabled = true
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 2)
        XCTAssertEqual(trust.prompts, 1)
    }

    func testTheLedgerIsWrittenOnlyWhenThePromptIsRaised() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        XCTAssertNil(ledger.lastRepairedBuild, "a run still going has spent nothing")
        repair.finish()
        XCTAssertEqual(trust.prompts, 1)
        XCTAssertEqual(ledger.lastRepairedBuild, "100")
    }

    func testARepairInterruptedBeforeCompletionIsRetriedByTheNextLaunch() {
        enabled = true
        trust.trusted = false
        repair.holds = true
        hud().launched()   // Isla quits here: the completion never arrives
        XCTAssertEqual(repair.resets, 1)
        XCTAssertNil(ledger.lastRepairedBuild)

        let next = hud()   // a fresh HUD on the same ledger and identity
        next.launched()
        XCTAssertEqual(repair.resets, 2, "the one try was never spent")
        XCTAssertFalse(next.suspectsStaleEntry)
    }

    func testASwitchOnAlwaysAsksEvenWhenTheSessionReadsUnavailable() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        sessionAvailable = false   // CG misreporting, e.g. a dark main display under Screen Sharing
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 1, "the click proves someone is there")
        XCTAssertEqual(trust.prompts, 1)
    }

    func testASwitchOnStillWaitsOutARealLockOrSleep() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        locked = true
        hud.settingChanged(to: true)
        XCTAssertEqual(repair.resets, 0)
        XCTAssertEqual(trust.prompts, 0)
    }

    func testADeferredSwitchOnInterruptedByALockIsNotTurnedIntoSpent() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        ledger.lastRepairedBuild = "100"   // this identity already had its launch repair
        hud.refresh()
        grants.post()
        hud.settingChanged(to: true)   // deferred
        locked = true
        hud.suspend()
        moment += 1.5
        clock.fire(interval: 1.5)
        XCTAssertEqual(repair.resets, 0)
        XCTAssertFalse(hud.suspectsStaleEntry, "not the manual route: this switch-on has not had its try")

        locked = false
        hud.resume()
        XCTAssertEqual(repair.resets, 1)
        XCTAssertEqual(trust.prompts, 1)
        hud.resume()
        hud.refresh()
        XCTAssertEqual(repair.resets, 1, "once")
    }

    func testAPendingSwitchOnIsDroppedWhenTrustedOrSwitchedOff() {
        let hud = hud()
        enabled = true
        trust.trusted = false
        locked = true
        hud.settingChanged(to: true)
        trust.trusted = true
        locked = false
        hud.refresh()
        trust.trusted = false
        hud.refresh()
        XCTAssertEqual(repair.resets, 0)

        enabled = true
        locked = true
        hud.settingChanged(to: true)
        enabled = false
        hud.settingChanged(to: false)
        enabled = true
        locked = false
        hud.refresh()
        XCTAssertEqual(repair.resets, 0)
    }

    func testTheSessionIsUnavailableWhenLockedAsleepOrOffTheConsole() {
        XCTAssertTrue(CodeIdentity.sessionIsAvailable(session: nil, displayAsleep: false))
        XCTAssertTrue(CodeIdentity.sessionIsAvailable(session: [:], displayAsleep: false), "absent keys mean available")
        XCTAssertFalse(CodeIdentity.sessionIsAvailable(session: ["CGSSessionScreenIsLocked": true], displayAsleep: false))
        XCTAssertTrue(CodeIdentity.sessionIsAvailable(session: ["CGSSessionScreenIsLocked": false], displayAsleep: false))
        XCTAssertFalse(CodeIdentity.sessionIsAvailable(session: [:], displayAsleep: true))
        XCTAssertFalse(
            CodeIdentity.sessionIsAvailable(session: [CodeIdentity.onConsoleKey: false], displayAsleep: false),
            "fast user switching: another user has the screen"
        )
        XCTAssertTrue(CodeIdentity.sessionIsAvailable(session: [CodeIdentity.onConsoleKey: true], displayAsleep: false))
    }

    func testTheRunningCodesUniqueHashIsReadWithoutTheSigningInformationFlag() {
        let hash = CodeIdentity.runningUniqueHash()
        XCTAssertNotNil(hash, "the test host is signed, and the default flags carry the unique hash")
        XCTAssertEqual(CodeIdentity.running.count, (hash?.count ?? 0) * 2)
    }

    // MARK: Review round 3 (2026-10-17)

    func testAGrantSeenWhileTheToolRunsDoesNotLoseTheRunAndAWipedGrantIsAskedForOnce() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        trust.trusted = true   // granted from a System Settings window that was already open
        hud.refresh()
        XCTAssertTrue(hud.isRepairing, "the run is still going")
        XCTAssertEqual(trust.prompts, 0)

        trust.trusted = false   // the reset finished and wiped it
        repair.finish()
        XCTAssertEqual(trust.prompts, 1, "exactly one prompt, after the run")
        XCTAssertEqual(ledger.lastRepairedBuild, "100")
        XCTAssertFalse(hud.isRepairing)
        hud.refresh()
        XCTAssertEqual(trust.prompts, 1)
        XCTAssertEqual(repair.resets, 1)
    }

    func testAGrantSeenWhileTheToolRunsAndStillThereAfterwardsRaisesNoPrompt() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        trust.trusted = true
        hud.refresh()
        repair.finish()
        XCTAssertEqual(trust.prompts, 0)
        XCTAssertEqual(ledger.lastRepairedBuild, "100")
        XCTAssertFalse(hud.isRepairing)
        XCTAssertFalse(hud.suspectsStaleEntry)
    }

    func testSwitchingOffWhileAGrantAndTheToolOverlapRaisesNothingAndClearsIsRepairing() {
        let hud = hud()
        repair.holds = true
        enabled = true
        trust.trusted = false
        hud.settingChanged(to: true)
        trust.trusted = true
        hud.refresh()
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(hud.isRepairing)
        trust.trusted = false
        repair.finish()
        XCTAssertEqual(trust.prompts, 0)
        // Off by a look alone, without the switch's own call.
        enabled = true
        hud.settingChanged(to: true)
        enabled = false
        hud.refresh()
        XCTAssertFalse(hud.isRepairing)
    }

    // MARK: Trusted, but the tap never starts (2026-10-16, owner)

    func testATapThatNeverStartsSlowsTheRetryAndSaysSoAfterThirtySeconds() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        XCTAssertFalse(hud.tapRefused)
        XCTAssertEqual(clock.intervals, [MediaKeyHUD.pollInterval])

        moment += 29.9
        clock.fire()
        XCTAssertFalse(hud.tapRefused)
        XCTAssertEqual(clock.intervals.last, MediaKeyHUD.pollInterval)

        moment += 0.2
        clock.fire()
        XCTAssertTrue(hud.tapRefused)
        XCTAssertEqual(clock.intervals.last, MediaKeyHUD.slowPollInterval, "the retry backs off")
        XCTAssertTrue(hud.isPolling, "but it does not stop")
        XCTAssertFalse(hud.needsAccessibility, "the permission is not what is missing")
        XCTAssertEqual(trust.prompts, 0)
    }

    func testTheRefusedNoticeClearsTheMomentATapStarts() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        moment += 31
        clock.fire()
        XCTAssertTrue(hud.tapRefused)
        taps.startSucceeds = true
        clock.fire()
        XCTAssertTrue(hud.isTapped)
        XCTAssertFalse(hud.tapRefused)
        XCTAssertFalse(hud.isPolling)
    }

    func testTheRefusedNoticeClearsWhenTheSettingGoesOff() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        moment += 31
        clock.fire()
        XCTAssertTrue(hud.tapRefused)
        enabled = false
        hud.settingChanged(to: false)
        XCTAssertFalse(hud.tapRefused)
        XCTAssertFalse(hud.isPolling)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testTheRefusedWaitRestartsOnAnAnnouncementAndAfterSleep() {
        let hud = hud()
        taps.startSucceeds = false
        on(hud)
        moment += 25
        grants.post()
        moment += 25
        clock.fire(interval: 0.3)
        XCTAssertFalse(hud.tapRefused)

        hud.suspend()
        moment += 600
        hud.resume()
        XCTAssertFalse(hud.tapRefused, "dark-screen time does not count")
        moment += 31
        hud.refresh()
        XCTAssertTrue(hud.tapRefused)
    }

    func testAHealthyTapNeverReadsAsRefused() {
        let hud = hud()
        on(hud)
        moment += 600
        hud.refresh()
        XCTAssertFalse(hud.tapRefused)
    }

    func testAHUDBuiltWithDefaultsNeverRegistersARealObserver() {
        let hud = MediaKeyHUD(isEnabled: { true }, trust: FakeTrust(false))
        hud.refresh()
        XCTAssertTrue(hud.needsAccessibility)
        XCTAssertTrue(hud.isObserving, "it asked, and the inert notifier took it")
        hud.stop()
    }
}
