import Combine
import CoreAudio
import Foundation

/// Owns the volume and brightness pop-up's input side (redesign 2026-10-15,
/// spec §12): when the tap exists, when it must not, and what a key does.
///
/// **Nothing is intercepted until two things are true together** — the
/// Volume and Brightness setting is on, and the person has granted
/// Accessibility. Until then no tap exists at all, so there is nothing to
/// pass through and nothing to get wrong. Every way out of "both true" —
/// the setting turned off, the permission taken back — ends the tap at once,
/// and the system has its keys again before the next press.
///
/// Trust is checked at four moments: when the setting changes, when the panel
/// opens (`refresh()`), when the system announces that the Accessibility list
/// changed (`com.apple.accessibility.api`, watched only while it matters), and
/// — only while the setting is on and either the permission is *missing* or
/// the tap would not start — every `pollInterval` seconds, as the fallback for
/// an announcement that never comes. A switched-off Isla neither polls nor
/// listens, a trusted one with a running tap does neither, and neither does one
/// whose display is asleep or whose Mac is locked (`suspend()`/`resume()`).
/// A revoked permission
/// is found by macOS disabling the tap (the owner is told, and looks) or by the
/// panel opening, whichever comes first — **never by a key press**: the tap's
/// callback runs on the main run loop in front of every key in every app, so it
/// does the decode, the consume decision and the level write and nothing else.
/// It used to ask `AXIsProcessTrusted()`, enumerate every audio device for a
/// glyph and resolve missing private-framework clients on each press, and a
/// stall in any of them lagged the keys everywhere and could get the tap
/// disabled by timeout.
@MainActor
final class MediaKeyHUD: ObservableObject {
    /// The slowest the check may run while waiting for the permission, or for a
    /// tap that would not start.
    static let pollInterval: TimeInterval = 2.0

    /// When the system announces a change to the Accessibility list, look again
    /// after each of these. The first catches the usual case; the second is for
    /// tccd, which can answer "not trusted" to the very first look after the
    /// notification, and for `CGEvent.tapCreate`, which can refuse in the same
    /// moment.
    static let grantLookDelays: [TimeInterval] = [0.3, 1.5]

    /// How long the setting may stay on with the permission missing, and in
    /// silence, before Settings suspects a stale entry. Reading the prompt,
    /// opening System Settings and authenticating with Touch ID routinely takes
    /// more than 10 s, and the first version of this hint (10 s) flashed
    /// "remove it with −" in the middle of a slow, correct grant. 30 s is past
    /// that, and any announcement from the system restarts the wait
    /// (`accessibilityListChanged`): the person is acting, and the hint is for
    /// the silent case, an entry macOS keeps for an older copy of Isla
    /// (ad-hoc signing ties a grant to one build) that only removing it and
    /// switching the setting off and on again clears.
    static let staleEntryAfter: TimeInterval = 30.0

    /// How long "on, trusted, and still no tap" may hold before the retry slows
    /// down and Settings says so. A tap macOS refuses right after a grant
    /// starts within a second or two; one that is still refused after this is
    /// not coming from a faster poll, and 2 s forever is a wasted wake-up.
    static let tapRefusedAfter: TimeInterval = 30.0
    /// The retry's pace once `tapRefusedAfter` has passed.
    static let slowPollInterval: TimeInterval = 10.0

    /// Starts `work` after `seconds` and returns a closure that cancels it. A
    /// seam: the tests drive time by hand.
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> () -> Void

    static let mainQueueScheduler: Scheduler = { seconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }

    /// The permission as of the last check.
    @Published private(set) var isTrusted = false
    /// True while the setting is on and the permission is missing: what
    /// Settings shows the "Accessibility" group for.
    @Published private(set) var needsAccessibility = false
    /// True once `needsAccessibility` has held for `staleEntryAfter`: Settings
    /// then adds the line that says what to do about an entry for an older copy.
    /// Evaluated by the looks that already happen (the poll, the notification,
    /// the panel opening), so no timer exists for it and none runs once the
    /// permission is granted.
    @Published private(set) var suspectsStaleEntry = false
    /// True once the setting has been on, the permission granted and no tap
    /// running for `tapRefusedAfter`: Settings says macOS is not passing the
    /// keys on and what to try. Clears the moment a tap starts or the setting
    /// goes off. Before this, the owner saw the Mac's own pop-up and nothing
    /// said why.
    @Published private(set) var tapRefused = false

    /// The setting. A closure, read at each use, so a switch in Settings and a
    /// test's value both act at once.
    var isEnabled: () -> Bool
    /// The Mac is locked: every event passes through and nothing is shown.
    var isLocked: () -> Bool = { false }
    /// A key was applied; the island shows it.
    var onReading: ((HUDReading) -> Void)?

    /// The glyph for an output device. Production asks CoreAudio about that one
    /// device; a test counts the calls.
    typealias DeviceSymbol = (AudioDeviceID) -> String?

    /// Seconds on a monotonic clock. A seam: the tests move time by hand.
    typealias Clock = @MainActor () -> TimeInterval

    /// The least time between two rebuilds of a tap that reports itself
    /// disabled. macOS keeps switching a tap off while Secure Input is on (a
    /// password field, a terminal's "secure keyboard entry"); each disabled
    /// notice queues a `refresh()`, and a refresh that rebuilt every time would
    /// create and destroy a tap in a loop for as long as that lasted. Trust
    /// coming back is exempt: that rebuild is a state change, not a retry.
    static let rebuildInterval: TimeInterval = 5.0

    private let trust: AccessibilityTrust
    private let makeTap: MediaKeyTapFactory
    private let applier: MediaKeyApplying
    private let schedule: Scheduler
    private let deviceSymbol: DeviceSymbol
    private let now: Clock
    private let grantNotifier: AccessibilityGrantNotifying

    /// When `needsAccessibility` last became true, for `staleEntryAfter`.
    private var missingSince: TimeInterval?
    /// When "on, trusted, no tap" began, for `tapRefusedAfter`.
    private var tapMissingSince: TimeInterval?
    /// Ends the watch on the Accessibility list; non-nil while watching.
    private var stopObserving: (() -> Void)?
    /// The looks that follow an announcement, cancelled together.
    private var cancelGrantLooks: [() -> Void] = []

    /// When a tap was last rebuilt, for `rebuildInterval`.
    private var lastRebuild: TimeInterval?

    private var tap: MediaKeyTapping?
    /// When the current tap was made, for `panelOpened()`.
    private var tapCreatedAt: TimeInterval?
    private var cancelPoll: (() -> Void)?
    /// The display is asleep or the Mac is locked: nobody can grant a
    /// permission, so the poll stays down.
    private var isSuspended = false

    /// What the first key-down of a press-and-hold decided, kept until its
    /// key-up. See `handle`.
    private enum Hold { case consume, pass }
    private var holds: [MediaKey: Hold] = [:]
    /// When each hold last had an event (its key-down or a repeat), for
    /// `panelOpened()`: a hold is live only while its events keep coming.
    private var holdLastEvent: [MediaKey: TimeInterval] = [:]

    /// How long a hold may stay silent and still count as a press in progress.
    /// macOS's slowest "delay until repeat" is about 2 s, so a held key sends
    /// its first repeat within that; 3 s leaves a margin. Past it the tap has
    /// stopped hearing the key (the stale-tap case renewal exists for) and the
    /// key-up that would clear the hold is never coming.
    static let holdStaleAfter: TimeInterval = 3.0

    /// Output-device glyphs found so far, for the repeats of a held key only.
    private var glyphs: [AudioDeviceID: String?] = [:]

    /// Every collaborator is optional and resolved in the body, where the main
    /// actor is known to be held: the real ones are main-actor values and a
    /// default argument is not.
    init(
        isEnabled: (() -> Bool)? = nil,
        trust: AccessibilityTrust? = nil,
        makeTap: MediaKeyTapFactory? = nil,
        applier: MediaKeyApplying? = nil,
        schedule: Scheduler? = nil,
        deviceSymbol: DeviceSymbol? = nil,
        now: Clock? = nil,
        grantNotifier: AccessibilityGrantNotifying? = nil
    ) {
        self.isEnabled = isEnabled ?? { NotchViewModel.volumeAndBrightnessEnabled }
        self.trust = trust ?? SystemAccessibilityTrust()
        self.makeTap = makeTap ?? EventMediaKeyTap.live
        self.applier = applier ?? SystemLevelApplier()
        self.schedule = schedule ?? MediaKeyHUD.mainQueueScheduler
        self.deviceSymbol = deviceSymbol ?? { AudioOutputs.output(id: $0)?.symbol }
        self.now = now ?? { ProcessInfo.processInfo.systemUptime }
        self.grantNotifier = grantNotifier ?? InertAccessibilityGrantNotifier.live
    }

    /// Whether a tap is up right now.
    var isTapped: Bool { tap != nil }
    /// Whether the poll is waiting to run (for a permission, or a tap).
    var isPolling: Bool { cancelPoll != nil }
    /// Whether the Accessibility list is being watched for a change.
    var isObserving: Bool { stopObserving != nil }

    /// Decides again, from the setting and the permission as they stand: the
    /// one place a tap is made or ended. Called when the setting changes, when
    /// the panel opens, and by the poll.
    func refresh() {
        let on = isEnabled()
        let trusted = trust.isTrusted()
        // Permission that came back since the last look. A tap made before the
        // permission was revoked is dead even when macOS never said so.
        let regained = trusted && !isTrusted
        if isTrusted != trusted { isTrusted = trusted }
        let missing = on && !trusted
        if needsAccessibility != missing { needsAccessibility = missing }
        if missing {
            if missingSince == nil { missingSince = now() }
        } else {
            missingSince = nil
        }
        let stale = missingSince.map { now() - $0 > Self.staleEntryAfter } ?? false
        if suspectsStaleEntry != stale { suspectsStaleEntry = stale }

        if on && trusted {
            // Revoke and re-grant leaves a tap that exists and hears nothing,
            // and it need not send a disabled notice on the way. Trust going
            // from missing to present, or a tap macOS reports as switched off,
            // means the one we hold is not to be trusted: end it and make a
            // fresh one. A tap that merely reports itself off is rebuilt at
            // most once per `rebuildInterval`; in between it is left as it is
            // (macOS may well keep it off, and the disabled notice has already
            // asked the tap to switch itself back on).
            if let tap {
                let moment = now()
                let dueAgain = lastRebuild.map { moment - $0 >= Self.rebuildInterval } ?? true
                if regained || (!tap.isTapEnabled && dueAgain) {
                    stopTap()
                    lastRebuild = moment
                }
            }
            startTap()
            if tap == nil {
                if tapMissingSince == nil { tapMissingSince = now() }
            } else {
                tapMissingSince = nil
            }
            let refused = tapMissingSince.map { now() - $0 > Self.tapRefusedAfter } ?? false
            if tapRefused != refused { tapRefused = refused }
            // Trusted and the setting on, yet no tap: `CGEvent.tapCreate` can
            // refuse in the moments right after macOS records a grant. This used
            // to wait for the panel to open or the setting to be toggled, so a
            // person who had done everything right saw the Mac's own pop-up
            // until they did something extra. Keep looking until a tap starts,
            // then stop: a running tap needs no poll. Past `tapRefusedAfter` the
            // poll slows to `slowPollInterval` (read when it is scheduled).
            if tap == nil { startPolling() } else { stopPolling() }
        } else {
            stopTap()
            tapMissingSince = nil
            if tapRefused { tapRefused = false }
            if missing { startPolling() } else { stopPolling() }
        }
        updateObserving()
    }

    /// The panel is opening: looks again as `refresh()` does, then renews a tap
    /// older than `rebuildInterval`. The case: Accessibility is revoked and
    /// re-granted between two looks with no disabled notice, so trust reads
    /// true both times (`regained` is false) and a tap that still reports
    /// itself enabled but hears nothing would never be replaced; the media keys
    /// would stay with macOS until the setting is toggled. Only this caller
    /// does it, and a tap younger than the interval is left alone, so it never
    /// rebuilds more than once per `rebuildInterval`. Holds are cleared, as
    /// `stopTap` always does, so nothing is renewed while a hold is active:
    /// opening the panel mid-press would otherwise let the repeats and the
    /// key-up of a key whose key-down Isla consumed slip back to macOS. A hold
    /// with no event for `holdStaleAfter` is dropped and does not count, so a
    /// lost key-up cannot block renewal for good.
    func panelOpened() {
        refresh()
        guard isEnabled(), trust.isTrusted(), tap != nil else { return }
        let moment = now()
        // A hold that heard something lately is a press in progress: renewing
        // now would let its repeats and key-up slip back to macOS. A silent
        // one is a lost key-up; drop it so it cannot veto every opening.
        if holds.keys.contains(where: { moment - (holdLastEvent[$0] ?? -.infinity) <= Self.holdStaleAfter }) { return }
        holds.removeAll()
        holdLastEvent.removeAll()
        guard let created = tapCreatedAt, moment - created >= Self.rebuildInterval else { return }
        stopTap()
        lastRebuild = moment
        startTap()
    }

    /// The display went to sleep, or the Mac locked: stop waiting for a
    /// permission nobody can grant. The tap, if there is one, stays — a lock
    /// passes every key through by itself and a sleeping display has no keys.
    func suspend() {
        isSuspended = true
        stopPolling()
        updateObserving()
    }

    /// The display woke, or the Mac unlocked. Looks again at once, which
    /// restarts the poll if the setting is on and the permission still missing.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        // The wait for a permission starts again: the time the screen was dark
        // is not time the person spent looking at a missing grant.
        if missingSince != nil { missingSince = now() }
        if tapMissingSince != nil { tapMissingSince = now() }
        refresh()
    }

    /// The setting was just changed in Settings. Turning it on asks macOS for
    /// the permission (the prompt, once) before deciding; turning it off needs
    /// no question.
    func settingChanged(to isOn: Bool) {
        if isOn, !trust.isTrusted() { trust.requestPrompt() }
        refresh()
    }

    /// The app is going away, or its session is: nothing may outlive it.
    func stop() {
        stopTap()
        stopPolling()
        stopObservingGrants()
    }

    // MARK: A key

    /// What the tap asks for each press. `true` consumes the event.
    ///
    /// Isla consumes a key **only if it applied it**; every other case — the
    /// setting off, the Mac locked, a modifier chord that is the system's, a
    /// family it cannot move, a device with no volume to set, an output that
    /// changed under the press — answers `false` and the event goes to the
    /// system untouched, which then shows its own pop-up.
    ///
    /// **A press-and-hold is decided once, by its first key-down.** The system
    /// sends a key-down, then repeats of it while the key is held, then a
    /// key-up, and it must see all of them or none: a key-up (or repeats)
    /// without their key-down are strays, and an event passed after its
    /// key-down was swallowed (or the reverse) can stick a key in the system's
    /// own state. So the first key-down decides consume or pass, its repeats
    /// follow that decision, and its key-up returns the same answer and ends
    /// it.
    ///
    /// - A hold decided *pass* stays pass through every repeat, whatever
    ///   changes meanwhile (AirPods connecting, a lock, ⌘ pressed).
    /// - A hold decided *consume* stays consume. Each repeat applies another
    ///   step when it can — setting still on, not locked — and is swallowed
    ///   without a change when it cannot: a Mac that locks mid-hold sees no
    ///   level move and no pop-up, and the key-up still pairs. A repeat that
    ///   arrives with the modifiers changed still steps (with the quarter step
    ///   only while ⌥⇧ stay down); the hold is not re-decided.
    /// - A repeat or a key-up with no hold behind it (the tap began mid-press,
    ///   or the hold was cleared) is passed: the system saw that key-down.
    /// - Mute repeats do nothing, consumed or not: a held mute used to flip the
    ///   mute back and forth.
    func handle(_ press: MediaKeyPress, modifiers: MediaKeyModifiers) -> Bool {
        guard press.isDown else {
            holdLastEvent.removeValue(forKey: press.key)
            return holds.removeValue(forKey: press.key) == .consume
        }

        if press.isRepeat {
            guard holds[press.key] == .consume else { return false }
            holdLastEvent[press.key] = now()
            continueHold(press, modifiers: modifiers)
            return true
        }

        let consumed = decideFreshPress(press, modifiers: modifiers)
        holds[press.key] = consumed ? .consume : .pass
        holdLastEvent[press.key] = now()
        return consumed
    }

    /// The first key-down of a hold: apply it and consume, or leave it.
    private func decideFreshPress(_ press: MediaKeyPress, modifiers: MediaKeyModifiers) -> Bool {
        guard isEnabled() else {
            // The tap should not exist: end it, but not from inside its own
            // callback.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return false
        }
        guard !isLocked(), !modifiers.leavesToTheSystem else { return false }
        guard let reading = applier.apply(press.key, fine: modifiers.fine) else { return false }
        show(reading, isRepeat: false)
        return true
    }

    /// A repeat of a consumed hold.
    private func continueHold(_ press: MediaKeyPress, modifiers: MediaKeyModifiers) {
        guard press.key != .mute, isEnabled(), !isLocked() else { return }
        guard let reading = applier.apply(press.key, fine: modifiers.fine) else { return }
        show(reading, isRepeat: true)
    }

    /// Hands a reading to the island.
    ///
    /// A volume reading carries the device it was applied to and not yet its
    /// glyph: finding that is CoreAudio work and the tap's callback is the one
    /// place it must not happen. The reading is delivered a turn later, once
    /// the glyph is known — the first press of a hold asks CoreAudio about that
    /// one device (a headphone jack's data source can change with the device id
    /// unchanged, so it is never trusted across presses), and its repeats reuse
    /// the answer. Every volume reading goes through the main queue so they
    /// stay in order; brightness readings, which need no glyph, go straight
    /// through.
    private func show(_ reading: HUDReading, isRepeat: Bool) {
        guard reading.kind == .volume, let device = reading.outputDevice else {
            onReading?(reading)
            return
        }
        DispatchQueue.main.async { [weak self] in
            // The press was consumed a turn ago; the Mac may have locked, or
            // the tap ended (setting off, permission revoked), since. A pop-up
            // over the lock screen or after the feature went away is wrong.
            guard let self, !self.isLocked(), self.isTapped else { return }
            var shown = reading
            if isRepeat, let known = self.glyphs[device] {
                shown.deviceSymbol = known
            } else {
                let found = self.deviceSymbol(device)
                self.glyphs[device] = .some(found)
                shown.deviceSymbol = found
            }
            self.onReading?(shown)
        }
    }

    // MARK: Tap and poll

    private func startTap() {
        guard tap == nil else { return }
        let created = makeTap(
            { [weak self] press, modifiers in self?.handle(press, modifiers: modifiers) ?? false },
            { [weak self] in
                // macOS switched the tap off: the tap has already turned itself
                // back on, and the permission may be why it was off.
                //
                // While it was off, the system took a consumed hold's repeats
                // and key-up directly, so the `.consume` entry would otherwise
                // linger until the next fresh press and then swallow a stray
                // key-up the system had already seen. Clear the holds now, so
                // whatever arrives after the re-enable is passed consistently.
                self?.holds.removeAll()
                self?.holdLastEvent.removeAll()
                DispatchQueue.main.async { self?.refresh() }
            }
        )
        // If the system will not make one, nothing is consumed and nothing else
        // changes; the next panel opening tries again.
        guard created.start() else { return }
        tap = created
        tapCreatedAt = now()
        // Resolved here, once per tap, and never by a press: loading the
        // brightness frameworks is the slowest thing a key could trigger.
        applier.prepare()
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
        tapCreatedAt = nil
        holds.removeAll()
        holdLastEvent.removeAll()
    }

    private func startPolling() {
        guard cancelPoll == nil, !isSuspended else { return }
        cancelPoll = schedule(tapRefused ? Self.slowPollInterval : Self.pollInterval) { [weak self] in
            self?.cancelPoll = nil
            self?.refresh()
        }
    }

    private func stopPolling() {
        cancelPoll?()
        cancelPoll = nil
    }

    // MARK: The Accessibility list

    /// Watches the list while there is something to wait for — the permission
    /// missing, or a trusted Isla whose tap would not start — and not otherwise.
    /// Never while suspended: a dark or locked screen has nobody to grant
    /// anything, the same rule as the poll.
    ///
    /// The scheduled looks an announcement queued are **not** tied to the watch:
    /// the first look usually succeeds and ends the watch (a tap now exists),
    /// and cancelling from inside it threw away the 1.5 s look that exists for
    /// the case where the 0.3 s one was early. They are cancelled only when
    /// nothing may run at all: the setting off, the display asleep or locked, or
    /// `stop()`.
    private func updateObserving() {
        let live = isEnabled() && !isSuspended
        if !live { cancelLooks() }
        let waiting = live && (needsAccessibility || (isTrusted && tap == nil))
        if waiting {
            guard stopObserving == nil else { return }
            stopObserving = grantNotifier.observe { [weak self] in self?.accessibilityListChanged() }
        } else {
            stopObserving?()
            stopObserving = nil
        }
    }

    private func stopObservingGrants() {
        stopObserving?()
        stopObserving = nil
        cancelLooks()
    }

    private func cancelLooks() {
        cancelGrantLooks.forEach { $0() }
        cancelGrantLooks = []
    }

    /// The system says the list changed: look after each of
    /// `grantLookDelays`. Never the prompt, never a loop: two scheduled looks
    /// per announcement, and a burst of announcements replaces them rather than
    /// stacking them. An announcement also restarts the stale-entry waits: the
    /// person is acting in System Settings right now, which is the opposite of
    /// the silent case those hints are for.
    private func accessibilityListChanged() {
        guard stopObserving != nil else { return }
        if missingSince != nil { missingSince = now() }
        if tapMissingSince != nil { tapMissingSince = now() }
        cancelLooks()
        cancelGrantLooks = Self.grantLookDelays.map { delay in
            schedule(delay) { [weak self] in self?.refresh() }
        }
    }
}
