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
/// Trust is checked at three moments and never in a loop: when the setting
/// changes, when the panel opens (`refresh()`), and — only while the setting is
/// on and the permission is *missing* — every `pollInterval` seconds, because
/// granting it happens in another app and nothing announces it. A trusted or a
/// switched-off Isla does not poll, and neither does one whose display is
/// asleep or whose Mac is locked (`suspend()`/`resume()`). A revoked permission
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
    /// The slowest the check may run while waiting for the permission.
    static let pollInterval: TimeInterval = 2.0

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

    private let trust: AccessibilityTrust
    private let makeTap: MediaKeyTapFactory
    private let applier: MediaKeyApplying
    private let schedule: Scheduler
    private let deviceSymbol: DeviceSymbol

    private var tap: MediaKeyTapping?
    private var cancelPoll: (() -> Void)?
    /// The display is asleep or the Mac is locked: nobody can grant a
    /// permission, so the poll stays down.
    private var isSuspended = false

    /// What the first key-down of a press-and-hold decided, kept until its
    /// key-up. See `handle`.
    private enum Hold { case consume, pass }
    private var holds: [MediaKey: Hold] = [:]

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
        deviceSymbol: DeviceSymbol? = nil
    ) {
        self.isEnabled = isEnabled ?? { NotchViewModel.volumeAndBrightnessEnabled }
        self.trust = trust ?? SystemAccessibilityTrust()
        self.makeTap = makeTap ?? EventMediaKeyTap.live
        self.applier = applier ?? SystemLevelApplier()
        self.schedule = schedule ?? MediaKeyHUD.mainQueueScheduler
        self.deviceSymbol = deviceSymbol ?? { AudioOutputs.output(id: $0)?.symbol }
    }

    /// Whether a tap is up right now.
    var isTapped: Bool { tap != nil }
    /// Whether the permission poll is waiting to run.
    var isPolling: Bool { cancelPoll != nil }

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

        if on && trusted {
            stopPolling()
            // Revoke and re-grant leaves a tap that exists and hears nothing,
            // and it need not send a disabled notice on the way. Trust going
            // from missing to present, or a tap macOS reports as switched off,
            // means the one we hold is not to be trusted: end it and make a
            // fresh one.
            if let tap, regained || !tap.isTapEnabled { stopTap() }
            startTap()
        } else {
            stopTap()
            if missing { startPolling() } else { stopPolling() }
        }
    }

    /// The display went to sleep, or the Mac locked: stop waiting for a
    /// permission nobody can grant. The tap, if there is one, stays — a lock
    /// passes every key through by itself and a sleeping display has no keys.
    func suspend() {
        isSuspended = true
        stopPolling()
    }

    /// The display woke, or the Mac unlocked. Looks again at once, which
    /// restarts the poll if the setting is on and the permission still missing.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
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
        guard press.isDown else { return holds.removeValue(forKey: press.key) == .consume }

        if press.isRepeat {
            guard holds[press.key] == .consume else { return false }
            continueHold(press, modifiers: modifiers)
            return true
        }

        let consumed = decideFreshPress(press, modifiers: modifiers)
        holds[press.key] = consumed ? .consume : .pass
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
            guard let self else { return }
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
                DispatchQueue.main.async { self?.refresh() }
            }
        )
        // If the system will not make one, nothing is consumed and nothing else
        // changes; the next panel opening tries again.
        guard created.start() else { return }
        tap = created
        // Resolved here, once per tap, and never by a press: loading the
        // brightness frameworks is the slowest thing a key could trigger.
        applier.prepare()
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
        holds.removeAll()
    }

    private func startPolling() {
        guard cancelPoll == nil, !isSuspended else { return }
        cancelPoll = schedule(Self.pollInterval) { [weak self] in
            self?.cancelPoll = nil
            self?.refresh()
        }
    }

    private func stopPolling() {
        cancelPoll?()
        cancelPoll = nil
    }
}
