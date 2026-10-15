import Combine
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
/// switched-off Isla does not poll. A revoked permission is found by the next
/// key press, by macOS disabling the tap, or by the panel opening, whichever
/// comes first.
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

    private let trust: AccessibilityTrust
    private let makeTap: MediaKeyTapFactory
    private let applier: MediaKeyApplying
    private let schedule: Scheduler

    private var tap: MediaKeyTapping?
    private var cancelPoll: (() -> Void)?
    /// Keys whose press Isla applied and whose release it therefore owes the
    /// same answer: a key-up the system sees without its key-down would be a
    /// stray release.
    private var consumedKeys: Set<MediaKey> = []

    /// Every collaborator is optional and resolved in the body, where the main
    /// actor is known to be held: the real ones are main-actor values and a
    /// default argument is not.
    init(
        isEnabled: (() -> Bool)? = nil,
        trust: AccessibilityTrust? = nil,
        makeTap: MediaKeyTapFactory? = nil,
        applier: MediaKeyApplying? = nil,
        schedule: Scheduler? = nil
    ) {
        self.isEnabled = isEnabled ?? { NotchViewModel.volumeAndBrightnessEnabled }
        self.trust = trust ?? SystemAccessibilityTrust()
        self.makeTap = makeTap ?? EventMediaKeyTap.live
        self.applier = applier ?? SystemLevelApplier()
        self.schedule = schedule ?? MediaKeyHUD.mainQueueScheduler
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
        if isTrusted != trusted { isTrusted = trusted }
        let missing = on && !trusted
        if needsAccessibility != missing { needsAccessibility = missing }

        if on && trusted {
            stopPolling()
            startTap()
        } else {
            stopTap()
            if missing { startPolling() } else { stopPolling() }
        }
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
        consumedKeys.removeAll()
    }

    // MARK: A key

    /// What the tap asks for each press. `true` consumes the event.
    ///
    /// Isla consumes a key **only if it applied it**; every other case — the
    /// setting off, trust gone, the Mac locked, a family it cannot move, a
    /// device with no volume to set — answers `false` and the event goes to
    /// the system untouched, which then shows its own pop-up. The release of a
    /// key whose press was consumed is swallowed with it.
    func handle(_ press: MediaKeyPress, modifiers: MediaKeyModifiers) -> Bool {
        guard press.isDown else { return consumedKeys.remove(press.key) != nil }
        guard isEnabled(), trust.isTrusted() else {
            // The tap should not exist: end it, but not from inside its own
            // callback.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return false
        }
        guard !isLocked() else { return false }
        guard let reading = applier.apply(press.key, fine: modifiers.fine) else { return false }
        consumedKeys.insert(press.key)
        onReading?(reading)
        return true
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
        if created.start() { tap = created }
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
        consumedKeys.removeAll()
    }

    private func startPolling() {
        guard cancelPoll == nil else { return }
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
