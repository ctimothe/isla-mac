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
/// callback runs in front of every key in every app, so it does the decode and
/// the consume decision and nothing else. It used to ask
/// `AXIsProcessTrusted()`, enumerate every audio device for a glyph and resolve
/// missing private-framework clients on each press, and a stall in any of them
/// lagged the keys everywhere and could get the tap disabled by timeout.
///
/// **The key path, since 2026-10-18.** The callback runs on the tap's own
/// thread (`EventMediaKeyTap`), not the main run loop, and decides from
/// `MediaKeyGate` — the setting, the lock and the hold table, mirrored there by
/// this object whenever they change — plus the applier's cached `canApply`.
/// The hardware write follows on the applier's queue, from cached levels, and
/// the reading reaches the island in one hop to the main actor. Before, the
/// callback sat on the main run loop and wrote the volume before answering,
/// and the reading took a second main-queue turn for its glyph: a busy main
/// thread (the owner's Mac loaded with agents) made every press heavy and let
/// macOS disable the tap by timeout.
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

    /// How long, after Isla repaired its own entry and raised the prompt, the
    /// permission may stay missing in silence before Settings falls back to the
    /// by-hand footnote. Reading the prompt, opening System Settings and
    /// authenticating with Touch ID routinely takes more than 10 s, and the
    /// first version of this hint (10 s) flashed "remove it with −" in the
    /// middle of a slow, correct grant. 30 s is past that, and any
    /// announcement from the system restarts the wait
    /// (`accessibilityListChanged`): the person is acting, and the hint is for
    /// the silent case. Since 2026-10-17 it is only the fallback: Isla clears
    /// its own stale entry first (`AccessibilityRepairing`), so the footnote
    /// shows only when the prompt that made possible still brought no grant
    /// after this long — whatever the reset itself returned, because a Mac with
    /// no entry at all can fail it and needs no hint — or at once when this
    /// code identity has already had its one repair and Isla is still not
    /// trusted.
    static let staleEntryAfter: TimeInterval = 30.0

    /// An announcement from the system that the Accessibility list changed,
    /// less than this long ago, defers a reset: tccd can answer "not trusted"
    /// for a moment after a grant, and a reset then would wipe the grant that
    /// was just made. The reset waits `grantLookDelays[1]` (1.5 s) and then
    /// reads trust again; it is not refused for the whole period. Announcements
    /// are only recorded while the setting is on and the HUD is watching the
    /// list, so a grant made with the setting off is guarded only by the trust
    /// read right before the tool runs.
    static let announcementQuietPeriod: TimeInterval = 5.0

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
    /// True when `staleEntryAfter` after Isla's repair and its prompt the
    /// permission is still missing, or at once when this code identity already
    /// had its one repair and the permission is still missing: Settings then
    /// adds the line that says what to do by hand. Evaluated by the looks that already happen (the poll, the
    /// notification, the panel opening), so no timer exists for it and none
    /// runs once the permission is granted.
    @Published private(set) var suspectsStaleEntry = false
    /// True while the reset tool runs: Settings greys "Open Privacy &
    /// Security…" (greyed, not hidden, so the row does not jump), because a
    /// grant made through it now would be wiped by the reset finishing.
    @Published private(set) var isRepairing = false
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
    private let now: Clock
    private let grantNotifier: AccessibilityGrantNotifying
    private let repairer: AccessibilityRepairing
    private let ledger: AccessibilityRepairLedger
    private let currentBuildIdentity: () -> String
    private let sessionIsAvailable: () -> Bool

    /// What Isla's own repair of its Accessibility entry has done since the
    /// setting went on, for the fallback footnote.
    private enum Repair {
        /// Not attempted, or finished and forgotten (granted, setting off).
        case none
        /// An announcement from the system came just before: the reset waits
        /// for one more look (the closure cancels it).
        case deferred(cancel: () -> Void)
        /// The reset is running; the prompt waits for it.
        case running
        /// The reset has finished, worked or not, and the prompt was raised at
        /// this moment (restarted by any announcement from the system).
        case prompted(at: TimeInterval)
        /// This code identity already had its one repair and Isla is still not
        /// trusted: the manual route is the only one left.
        case spent
    }
    private var repair = Repair.none {
        didSet {
            var running = false
            if case .running = repair { running = true }
            if isRepairing != running { isRepairing = running }
        }
    }
    /// When the system last announced a change to the Accessibility list.
    private var lastAnnouncement: TimeInterval?
    /// Bumped whenever a running repair stops mattering (setting off, a newer
    /// repair), so its late completion neither prompts nor reports.
    private var repairGeneration = 0
    /// Launch has not yet had its once-per-build look: waiting for the display
    /// to wake and the Mac to unlock, if either was not true at launch.
    private var launchRepairPending = false
    /// A switch-on's repair that a lock or a sleep cut off before the tool
    /// started. It has its own flag because it must skip the ledger check: the
    /// launch repair of this identity may have been made already, and that is
    /// no reason to leave this switch-on without its try.
    private var switchOnRepairPending = false
    /// Where the repair now running, or last waited for, came from.
    private enum Origin { case switchOn, launch }
    private var repairOrigin = Origin.switchOn
    /// A reset process is running. Never two at once: a second could finish
    /// after the person had granted, and wipe the grant. A switch-on that
    /// arrives while one runs adopts it and follows its post-repair path.
    private var toolInFlight = false
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

    /// What the tap's thread decides from: the setting, the lock and the hold
    /// table. See `handle`.
    let gate = MediaKeyGate()
    /// The tap's handler: the gate, the applier and the hop back here.
    private var route: MediaKeyRoute!

    /// How long a hold may stay silent and still count as a press in progress.
    /// macOS's slowest "delay until repeat" is about 2 s, so a held key sends
    /// its first repeat within that; 3 s leaves a margin. Past it the tap has
    /// stopped hearing the key (the stale-tap case renewal exists for) and the
    /// key-up that would clear the hold is never coming.
    static let holdStaleAfter: TimeInterval = 3.0

    /// Every collaborator is optional and resolved in the body, where the main
    /// actor is known to be held: the real ones are main-actor values and a
    /// default argument is not.
    init(
        isEnabled: (() -> Bool)? = nil,
        trust: AccessibilityTrust? = nil,
        makeTap: MediaKeyTapFactory? = nil,
        applier: MediaKeyApplying? = nil,
        schedule: Scheduler? = nil,
        now: Clock? = nil,
        grantNotifier: AccessibilityGrantNotifying? = nil,
        repairer: AccessibilityRepairing? = nil,
        ledger: AccessibilityRepairLedger? = nil,
        currentBuildIdentity: (() -> String)? = nil,
        sessionIsAvailable: (() -> Bool)? = nil
    ) {
        self.isEnabled = isEnabled ?? { NotchViewModel.volumeAndBrightnessEnabled }
        self.trust = trust ?? SystemAccessibilityTrust()
        self.makeTap = makeTap ?? EventMediaKeyTap.live
        self.applier = applier ?? SystemLevelApplier()
        self.schedule = schedule ?? MediaKeyHUD.mainQueueScheduler
        self.now = now ?? { ProcessInfo.processInfo.systemUptime }
        self.grantNotifier = grantNotifier ?? InertAccessibilityGrantNotifier.live
        self.repairer = repairer ?? InertAccessibilityRepair.live
        self.ledger = ledger ?? MemoryRepairLedger.live
        self.currentBuildIdentity = currentBuildIdentity ?? { CodeIdentity.running }
        // Under XCTest the real answer would depend on the owner's screen.
        self.sessionIsAvailable = sessionIsAvailable ?? {
            PlayerBridge.isRunningTests ? true : CodeIdentity.sessionIsAvailable
        }
        route = MediaKeyRoute(
            gate: gate,
            applier: self.applier,
            deliver: { [weak self] reading in
                // The one hop to the main actor a press costs.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.present(reading) } }
            },
            settingWentOff: { [weak self] in
                // The tap should not exist: end it, but not from inside its own
                // callback.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        )
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
        if !missing {
            // A grant that arrives while the tool still runs (from a System
            // Settings window that was open already) must not discard the run:
            // the tool is about to finish and may clear that very grant, and
            // `toolFinished` re-reads trust to decide what to ask. Only the
            // setting going off ends it early.
            if on, toolInFlight, case .running = repair { } else { forgetRepair() }
        }
        let stale: Bool
        switch repair {
        case .prompted(let at): stale = now() - at > Self.staleEntryAfter
        case .spent: stale = true
        case .none, .deferred, .running: stale = false
        }
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
        mirrorGate()
        // The one repair a look may fire: a launch's own, still pending. See
        // `repairIfDueAtLaunch`.
        if launchRepairPending || switchOnRepairPending { repairIfPending() }
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
        if gate.hasHold(heardSince: moment - Self.holdStaleAfter) { return }
        gate.clearHolds()
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
        // Both of the lock path's branches come through here, after the lock
        // is already true, so the tap's thread stops taking keys at once.
        mirrorGate()
    }

    /// The Mac locked or unlocked. `suspend()` and `resume()` cover the lock
    /// and the usual unlock, but an unlock with the display still dark resumes
    /// nothing, and until something mirrored it the tap's thread would keep
    /// leaving every key to the system.
    func lockChanged() {
        mirrorGate()
    }

    /// Copies the setting and the lock where the tap's thread reads them. Every
    /// path that changes either ends here: `refresh()` (the setting, the
    /// permission, the poll), `suspend()`/`resume()` and `lockChanged()`.
    private func mirrorGate() {
        gate.mirror(enabled: isEnabled(), locked: isLocked())
    }

    /// The display woke, or the Mac unlocked. Looks again at once, which
    /// restarts the poll if the setting is on and the permission still missing.
    func resume() {
        // Before the guard: a wake that resumes the stores while the Mac still
        // reads as locked clears `isSuspended`, and the unlock replayed after it
        // would otherwise return here and strand a pending repair. Idempotent.
        repairIfPending()
        guard isSuspended else { return }
        isSuspended = false
        // The wait for a permission starts again: the time the screen was dark
        // is not time the person spent looking at a missing grant.
        if case .prompted = repair { repair = .prompted(at: now()) }
        if tapMissingSince != nil { tapMissingSince = now() }
        refresh()
        repairIfPending()
    }

    /// The setting was just changed in Settings. Turning it on, with the
    /// permission missing, clears Isla's own Accessibility entry and then asks
    /// macOS for the permission (the prompt, once) before deciding; turning it
    /// off ends any repair in flight and needs no question.
    func settingChanged(to isOn: Bool) {
        switchOnRepairPending = false
        if isOn {
            if !trust.isTrusted() { beginRepair(origin: .switchOn) }
        } else {
            forgetRepair()
        }
        refresh()
    }

    /// Launch: the once-per-build look at a stale entry, for a person who
    /// updated Isla with the setting already on. Called after the first
    /// `refresh()`. If the session is not available (the display dark, the Mac
    /// locked) it stays pending; see `repairIfDueAtLaunch`.
    func launched() {
        launchRepairPending = true
        refresh()
        repairIfPending()
    }

    // MARK: Repairing Isla's own Accessibility entry

    /// Repairs at most once per code identity, and only while the setting is on,
    /// the session available (`sessionIsAvailable`: the Mac unlocked and the
    /// display awake, as macOS says it, not as `LockScreenPresence` believes),
    /// the existing suspend and lock checks pass and the permission is missing.
    ///
    /// **A look may fire this, in this one case.** `launched()` runs before
    /// `LockScreenPresence` has started, so a relaunch onto a locked Mac or a
    /// dark display looks unlocked and awake to it, and it may never deliver an
    /// unlock for a lock it never saw. So while a launch repair is *pending* —
    /// the setting on, the permission missing, no repair made yet — `resume()`
    /// and `refresh()` (the poll included) try again and make it as soon as the
    /// session is available. The pending flag is the gate: it is cleared the
    /// moment the repair is made, found unneeded or found spent, so a look never
    /// repairs twice and never repairs for anything but a launch.
    private func repairIfPending() {
        repairSwitchOnIfPending()
        repairIfDueAtLaunch()
    }

    /// A switch-on whose repair a lock or sleep cut off before the tool started:
    /// the same rules as a launch's, minus the ledger (this switch-on has not
    /// had its try) and minus macOS's session check (the click proved someone
    /// was there; only a real lock or sleep makes it wait).
    private func repairSwitchOnIfPending() {
        guard switchOnRepairPending else { return }
        guard isEnabled() else { switchOnRepairPending = false; return }
        guard !isSuspended, !isLocked() else { return }
        switchOnRepairPending = false
        guard !trust.isTrusted() else { return }
        beginRepair(origin: .switchOn)
        refresh()
    }

    private func repairIfDueAtLaunch() {
        guard launchRepairPending else { return }
        guard isEnabled() else { launchRepairPending = false; return }
        guard !isSuspended, !isLocked(), sessionIsAvailable() else { return }
        launchRepairPending = false
        guard !trust.isTrusted() else { return }
        guard ledger.lastRepairedBuild != currentBuildIdentity() else {
            // This code identity has had its one try and is still untrusted.
            if case .none = repair { repair = .spent }
            refresh()
            return
        }
        beginRepair(origin: .launch)
        refresh()
    }

    /// Resets Isla's entry, then, after it has finished whether or not it
    /// worked, raises the prompt once. The prompt must come after: while a
    /// stale entry exists macOS shows nothing. The identity is written to the
    /// ledger only when the prompt is raised (or the run ends with Isla already
    /// trusted), so a run cut off by a quit or a crash is retried by the next
    /// launch; "once per identity" means once the prompt has been asked.
    ///
    /// Straight after an announcement from the system it defers (see
    /// `announcementQuietPeriod`): it looks again 1.5 s later instead.
    private func beginRepair(origin: Origin) {
        switch repair {
        case .running, .deferred: return
        default: break
        }
        repairGeneration += 1
        let generation = repairGeneration
        if let at = lastAnnouncement, now() - at < Self.announcementQuietPeriod {
            let cancel = schedule(Self.grantLookDelays[1]) { [weak self] in
                self?.deferredRepairDue(generation: generation, origin: origin)
            }
            repair = .deferred(cancel: cancel)
            return
        }
        startRepair(origin: origin)
    }

    private func deferredRepairDue(generation: Int, origin: Origin) {
        guard generation == repairGeneration, case .deferred = repair else { return }
        repair = .none
        // The deferral has served its purpose: a repair re-armed after a lock
        // must not defer again for the same announcement.
        lastAnnouncement = nil
        guard isEnabled() else { forgetRepair(); refresh(); return }
        startRepair(origin: origin)
        refresh()
    }

    private func startRepair(origin: Origin) {
        // Read again right before the tool runs, after any deferral: the person
        // may have granted in the meantime, and a reset would wipe it.
        guard !trust.isTrusted() else { forgetRepair(); return }
        // Nobody can answer a prompt: wait for them. A switch-on is its own
        // proof that someone is there, so only a real lock or sleep stops it;
        // a launch also asks macOS, which may know of a lock Isla never saw.
        guard !isSuspended, !isLocked(), origin == .switchOn || sessionIsAvailable() else {
            repair = .none
            if origin == .launch { launchRepairPending = true } else { switchOnRepairPending = true }
            return
        }
        repairOrigin = origin
        repair = .running
        // Never two tools at once: if one is still running (the setting went
        // off and on again), this switch-on adopts it and its completion.
        guard !toolInFlight else { return }
        toolInFlight = true
        repairer.reset { [weak self] _ in self?.toolFinished() }
    }

    private func toolFinished() {
        toolInFlight = false
        guard case .running = repair else { return }
        // The setting went off while the tool ran: nothing is left to ask.
        guard isEnabled() else { forgetRepair(); refresh(); return }
        // The permission arrived meanwhile: nothing to ask, nothing to retry.
        guard !trust.isTrusted() else {
            ledger.lastRepairedBuild = currentBuildIdentity()
            forgetRepair()
            refresh()
            return
        }
        // The display went dark or the Mac locked while it ran: nobody can
        // answer a prompt. Nothing was written to the ledger, so the first
        // awake, unlocked look makes the attempt again.
        guard !isSuspended, !isLocked(), repairOrigin == .switchOn || sessionIsAvailable() else {
            if repairOrigin == .launch { launchRepairPending = true } else { switchOnRepairPending = true }
            forgetRepair()
            refresh()
            return
        }
        // Whether the reset worked or not, the prompt comes after it: while a
        // stale entry exists macOS shows nothing, and when the reset failed it
        // costs nothing to ask. The footnote waits `staleEntryAfter` either way.
        repair = .prompted(at: now())
        trust.requestPrompt()
        ledger.lastRepairedBuild = currentBuildIdentity()
        refresh()
    }

    private func forgetRepair() {
        if case .deferred(let cancel) = repair { cancel() }
        if case .none = repair { return }
        repairGeneration += 1
        repair = .none
    }

    /// The app is going away, or its session is: nothing may outlive it.
    func stop() {
        stopTap()
        stopPolling()
        stopObservingGrants()
    }

    // MARK: A key

    /// The same decision the tap's handler makes, through the same route, from
    /// the main actor: mirrors the setting and the lock first, then asks. The
    /// tests' door to the key path; the app's keys arrive on the tap's thread
    /// and read only what was mirrored. See `MediaKeyGate.decide` for the
    /// rules.
    func handle(_ press: MediaKeyPress, modifiers: MediaKeyModifiers) -> Bool {
        mirrorGate()
        return route.receive(press, modifiers: modifiers, now: now())
    }

    /// Hands a reading to the island, on the main actor, one hop after the
    /// write. The press was consumed a moment ago; the Mac may have locked, or
    /// the tap ended (setting off, permission revoked), since. A pop-up over
    /// the lock screen or after the feature went away is wrong. The glyph and
    /// the name came with the reading, from the applier's cache, so nothing
    /// here asks CoreAudio — they used to be looked up here, on a second
    /// main-queue turn.
    private func present(_ reading: HUDReading) {
        guard !isLocked(), isTapped else { return }
        onReading?(reading)
    }

    // MARK: Tap and poll

    private func startTap() {
        guard tap == nil else { return }
        let route = self.route!
        let gate = self.gate
        let created = makeTap(
            // On the tap's thread. The clock is the same monotonic one `now`
            // defaults to, read directly because `now` is main-actor.
            { press, modifiers in route.receive(press, modifiers: modifiers, now: ProcessInfo.processInfo.systemUptime) },
            { [weak self] in
                // macOS switched the tap off; this runs on the tap's thread
                // just before the tap switches itself back on, and the
                // permission may be why it was off.
                //
                // While it was off, the system took a consumed hold's repeats
                // and key-up directly, so the `.consume` entry would otherwise
                // linger until the next fresh press and then swallow a stray
                // key-up the system had already seen. Clear the holds now, so
                // whatever arrives after the re-enable is passed consistently.
                gate.clearHolds()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        )
        // If the system will not make one, nothing is consumed and nothing else
        // changes; the next panel opening tries again.
        guard created.start() else { return }
        tap = created
        tapCreatedAt = now()
        // Resolved here, once per tap, and never by a press: loading the
        // brightness frameworks is the slowest thing a key could trigger. This
        // also reads the levels and starts the listeners that keep them
        // current; until it returns, `canApply` says no and a key passes.
        applier.prepare()
        mirrorGate()
    }

    private func stopTap() {
        let had = tap != nil
        // The tap first (its thread has left its loop when `stop()` returns),
        // then the listeners: nothing of either outlives this.
        tap?.stop()
        tap = nil
        tapCreatedAt = nil
        gate.clearHolds()
        if had { applier.stop() }
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
        lastAnnouncement = now()
        if case .prompted = repair { repair = .prompted(at: now()) }
        if tapMissingSince != nil { tapMissingSince = now() }
        cancelLooks()
        cancelGrantLooks = Self.grantLookDelays.map { delay in
            schedule(delay) { [weak self] in self?.refresh() }
        }
    }
}

/// What the tap's thread decides a key from, and nothing else: the setting and
/// the lock as `MediaKeyHUD` last mirrored them, and the hold table.
///
/// The callback used to read the setting, the lock and the holds straight off
/// the main actor, which it could only do because it ran on the main run loop
/// — and so every key waited for the main thread. The values now live here,
/// behind `lock`: the main actor writes the setting and the lock whenever
/// either changes and clears the holds when a tap ends; the tap's thread reads
/// them and writes the holds. The lock is held for a dictionary update and
/// never across a call out, so neither side can wait on the other for longer
/// than that — which is why `@unchecked Sendable` is safe.
final class MediaKeyGate: @unchecked Sendable {
    /// What to do with one event.
    enum Verdict: Equatable {
        /// Leave it to the system.
        case pass
        /// Leave it to the system; the setting is off, so the tap should not
        /// exist and the owner should look again.
        case settingOff
        /// Consume it, and apply the key when `apply` is true.
        case consume(apply: Bool)
    }

    private enum Hold { case consume, pass }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var enabled = false
    private var locked = false
    /// What the first key-down of a press-and-hold decided, kept until its
    /// key-up.
    private var holds: [MediaKey: Hold] = [:]
    /// When each hold last had an event (its key-down or a repeat), for
    /// `MediaKeyHUD.panelOpened()`: a hold is live only while its events keep
    /// coming.
    private var lastEvent: [MediaKey: TimeInterval] = [:]

    func mirror(enabled: Bool, locked: Bool) {
        lock.withLock {
            self.enabled = enabled
            self.locked = locked
        }
    }

    func clearHolds() {
        lock.withLock {
            holds.removeAll()
            lastEvent.removeAll()
        }
    }

    /// Whether any hold had an event at or after `moment`.
    func hasHold(heardSince moment: TimeInterval) -> Bool {
        lock.withLock { holds.keys.contains { (lastEvent[$0] ?? -.infinity) >= moment } }
    }

    /// Isla consumes a key **only if it can apply it** (`capable`, the
    /// applier's cached answer); every other case — the setting off, the Mac
    /// locked, a modifier chord that is the system's, a family it cannot move,
    /// a device with no volume to set — passes and the event goes to the
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
    ///
    /// Since 2026-10-18 the hardware write happens after this answers, so a
    /// write the device refuses at that moment (rare: `canApply` reflects the
    /// cached state) is a consumed key that shows nothing, where it used to be
    /// passed to the system. That is the price of never making the key wait.
    func decide(
        _ press: MediaKeyPress, modifiers: MediaKeyModifiers, capable: Bool, now: TimeInterval
    ) -> Verdict {
        lock.withLock {
            let key = press.key
            guard press.isDown else {
                lastEvent.removeValue(forKey: key)
                return holds.removeValue(forKey: key) == .consume ? .consume(apply: false) : .pass
            }
            if press.isRepeat {
                guard holds[key] == .consume else { return .pass }
                lastEvent[key] = now
                return .consume(apply: key != .mute && enabled && !locked && capable)
            }
            let verdict: Verdict
            if !enabled {
                verdict = .settingOff
            } else if locked || modifiers.leavesToTheSystem || !capable {
                verdict = .pass
            } else {
                verdict = .consume(apply: true)
            }
            holds[key] = verdict == .consume(apply: true) ? .consume : .pass
            lastEvent[key] = now
            return verdict
        }
    }
}

/// The tap's handler, assembled: ask the applier whether the key's family can
/// be applied (cached), let the gate decide, hand the write to the applier's
/// queue, answer. Every member is immutable and `Sendable`, so it can be
/// called from the tap's thread and from the main actor alike.
final class MediaKeyRoute: Sendable {
    let gate: MediaKeyGate
    let applier: MediaKeyApplying
    /// Called on the applier's queue with each reading to show.
    let deliver: @Sendable (HUDReading) -> Void
    /// Called on the tap's thread when a fresh press found the setting off.
    let settingWentOff: @Sendable () -> Void

    init(
        gate: MediaKeyGate, applier: MediaKeyApplying,
        deliver: @escaping @Sendable (HUDReading) -> Void, settingWentOff: @escaping @Sendable () -> Void
    ) {
        self.gate = gate
        self.applier = applier
        self.deliver = deliver
        self.settingWentOff = settingWentOff
    }

    /// `true` consumes the event. Returns before the key is applied.
    func receive(_ press: MediaKeyPress, modifiers: MediaKeyModifiers, now: TimeInterval) -> Bool {
        let capable = press.isDown && applier.canApply(press.key)
        switch gate.decide(press, modifiers: modifiers, capable: capable, now: now) {
        case .pass:
            return false
        case .settingOff:
            settingWentOff()
            return false
        case .consume(let apply):
            if apply { applier.submit(press.key, fine: modifiers.fine, deliver: deliver) }
            return true
        }
    }
}
