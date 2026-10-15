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
    func requestPrompt() { prompts += 1 }
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
    private var readings: [HUDReading] = []
    /// Every device the glyph lookup was asked about: the enumerator, counted.
    private var glyphLookups: [AudioDeviceID] = []
    private var glyphs: [AudioDeviceID: String] = [42: "airpods.pro"]
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
            now: { [unowned self] in self.moment }
        )
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
}
