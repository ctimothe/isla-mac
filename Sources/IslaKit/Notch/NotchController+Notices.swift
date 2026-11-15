import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// The capsule's other notices. Stored properties live in NotchController.swift.
extension NotchController {
    // MARK: The capsule's other notices (spec §19.5 d, amended 2026-10-26)

    /// Where an alert that is not the level goes. Pure, so each case is a test.
    enum NoticePlacement: Equatable {
        /// The shut island, through `alertQueue`, as it always went.
        case island
        /// The capsule under the open panel, now.
        case strip
    }

    /// The capsule while a surface is open; the island otherwise — which
    /// waits, as before, through a drag (the drop surface is the panel's whole
    /// answer) and over the lock screen.
    nonisolated static func noticePlacement(isOpen: Bool, isDropTargeted: Bool, isLocked: Bool) -> NoticePlacement {
        isOpen && !isDropTargeted && !isLocked ? .strip : .island
    }

    /// Puts a notice in the capsule, or makes it wait there behind what
    /// outranks it. True when it shows now.
    @discardableResult
    func presentInStrip(_ notice: StripNotice) -> Bool {
        guard let vm = viewModel else { return false }
        let showing: IslandActivity = vm.hudStrip.map { .hud($0) } ?? vm.stripNotice?.activity ?? .none
        guard stripQueue.post(notice.activity, showing: showing, blocked: false, at: Date()) == .show else {
            return false
        }
        showInStrip(notice)
        return true
    }

    private func showInStrip(_ notice: StripNotice) {
        guard let vm = viewModel else { return }
        stripNoticeWork?.cancel()
        // The level's own curve, in and out: the capsule is one object
        // whatever it carries.
        withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.stripNotice = notice
        }
        stripNoticeShownAt = Date()
        let hold: TimeInterval
        switch notice {
        case .ambient(let ambient): hold = ambient.holdDuration
        case .confirmation: hold = confirmationHold
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.stripNoticeWork = nil
            withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.stripNotice = nil
            }
            self.promoteStripNotice()
        }
        stripNoticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// The capsule is free — the level folded, a notice folded: the highest
    /// notice still inside its patience takes it, while the panel is open.
    func promoteStripNotice() {
        guard let vm = viewModel else { return }
        while vm.isOpen, !vm.isDropTargeted, vm.hudStrip == nil, vm.stripNotice == nil,
              let next = stripQueue.next(at: Date()) {
            // Asked again as it leaves the queue (Codex review 2026-10-26): a
            // charger that waited behind the level must still find its switch
            // on and the moment not quiet, as `presentAmbient` asked it.
            if let notice = StripNotice(next), stripStillAllows(notice) { showInStrip(notice) }
        }
    }

    /// The capsule's own refusals for a notice: the switch, a dark display
    /// and a quiet moment refuse the charger and headphones; a confirmation
    /// of the person's own act is always shown. Under the open panel the
    /// pointer is on the panel, which says nothing about a capsule nobody can
    /// click, so it is not asked.
    private func stripStillAllows(_ notice: StripNotice) -> Bool {
        guard case .ambient(let activity) = notice else { return true }
        let switchOn: Bool
        switch activity {
        case .charging: switchOn = NotchViewModel.chargingEnabled
        case .headphones: switchOn = NotchViewModel.headphonesEnabled
        case .batteryLow: switchOn = NotchViewModel.lowBatteryEnabled
        case .batteryFull: switchOn = NotchViewModel.fullBatteryEnabled
        // The person set it; there is no switch to refuse it.
        case .timerDone: switchOn = true
        }
        return activity.showsOnIsland && Self.ambientAllowed(
            switchOn: switchOn, pointerInside: false, pointerUnderGrownPill: false,
            screensAsleep: screensAreAsleep, quiet: momentsAreQuiet(presentingOnly: activity.isChargerMoment)
        )
    }

    /// The panel closed (the view model took the capsule down in the close's
    /// own transaction). A notice that had only just arrived is handed to the
    /// shut island, which shows it for its hold once the close lets it
    /// (`StripNotice.handsBack`), and so is the best one still waiting for
    /// the capsule inside its patience — it was never seen at all. The rest
    /// go with the panel.
    func stripClosed(_ shown: StripNotice?) {
        let shownAt = stripNoticeShownAt
        let waiting = stripQueue.next(at: Date()).flatMap(StripNotice.init)
        stripNoticeWork?.cancel()
        stripNoticeWork = nil
        stripNoticeShownAt = nil
        stripQueue.removeAll()
        guard let vm = viewModel else { return }
        var owed: [StripNotice] = []
        if let shown, let shownAt, StripNotice.handsBack(shownFor: Date().timeIntervalSince(shownAt)) {
            owed.append(shown)
        }
        if let waiting { owed.append(waiting) }
        // Each waits as any alert posted over an open panel does; the close's
        // promotion pass (`wireAlertPromotion`) brings it up, through its own
        // entry point and every refusal there — the charger's switch included.
        for notice in owed {
            _ = alertQueue.post(notice.activity, showing: vm.activity, blocked: true, at: Date())
        }
    }

    /// Ends whatever the capsule carries besides the level, and what waits
    /// for it: a lock, a dark display, a Space change.
    func clearStripNotice() {
        stripNoticeWork?.cancel()
        stripNoticeWork = nil
        stripNoticeShownAt = nil
        stripQueue.removeAll()
        viewModel?.stripNotice = nil
    }

    func presentAmbient(_ activity: AmbientActivity) {
        var activity = activity
        if activity.isChargerMoment, let latest = latestCharge,
           Date().timeIntervalSince(latest.at) < AmbientActivity.chargingHold + 1 {
            activity = latest.activity
        }
        // A Mac that reports no battery level shows no Charging (spec §19.4).
        guard let vm = viewModel, activity.showsOnIsland else { return }
        let switchOn: Bool
        switch activity {
        case .charging: switchOn = NotchViewModel.chargingEnabled
        case .headphones: switchOn = NotchViewModel.headphonesEnabled
        case .batteryLow: switchOn = NotchViewModel.lowBatteryEnabled
        case .batteryFull: switchOn = NotchViewModel.fullBatteryEnabled
        // The person set the timer; its end has no switch of its own.
        case .timerDone: switchOn = true
        }
        let grown = NotchViewModel.ambientBodySize(
            activity, notchSize: vm.geometry.notchSize, bodyWidth: vm.geometry.expandedSize.width
        )
        if vm.isLockedPresentation, LockedIsland.showsAlert(.ambient(activity), overShield: islandIsOverShield) {
            presentLockedCharge(activity, switchOn: switchOn)
            return
        }
        let placement = Self.noticePlacement(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
        )
        if placement == .strip {
            // Under the open panel the pointer is on the panel, which says
            // nothing about a capsule nobody can click; the switch, a dark
            // display and a full-screen film still refuse it.
            guard stripStillAllows(.ambient(activity)) else { return }
            if presentInStrip(.ambient(activity)) {
                Announcer.shared.announce(activity.accessibilityLabel)
            }
            return
        }
        let blocked = Self.alertsBlocked(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
        )
        // The pointer is asked only once nothing blocks: over an open panel it
        // is always inside, and that says nothing about the pill this will
        // grow once the panel has gone. `promoteWaitingAlert` comes back here,
        // and asks it then.
        // The charger shows under the pointer and over a full-screen app
        // (owner, 2026-10-27: every plug-in, as the menu bar's bolt); the
        // headphones keep the pointer's and the film's restraint.
        // Battery Low and a timer's end are news the person needs wherever
        // the pointer is, as the charger is (plan 2026-11-14 S2, S3).
        let charger = activity.isChargerMoment || activity.isBatteryAlert || activity.isTimerDone
        guard Self.ambientAllowed(
            switchOn: switchOn,
            pointerInside: !charger && !blocked && pointer.isInside,
            pointerUnderGrownPill: !charger && !blocked
                && vm.geometry.grownAlertRect(for: .ambient(activity), body: grown).contains(NSEvent.mouseLocation),
            screensAsleep: screensAreAsleep,
            quiet: momentsAreQuiet(presentingOnly: charger)
        ) else { return }
        guard postAlert(.ambient(activity), to: vm) == .show else { return }

        let reduceMotion = SystemAppearance.shared.reduceMotion
        peekWork?.cancel()
        peekWork = nil
        ambientWork?.cancel()
        // Headphones and the charger outrank the update alert, which the
        // queue took back to return once they fold (spec §19.1).
        cancelUpdateWork()
        withAnimation(Theme.pill(reduceMotion: reduceMotion)) {
            vm.isPeeking = false
            vm.updateOffer = nil
            vm.ambient = activity
        }
        // After the guard, never before it: a moment refused — switch off,
        // panel open, Mac locked, displays asleep — is not shown, and a
        // sentence for something nobody can see would be the voice lying.
        Announcer.shared.announce(activity.accessibilityLabel)
        scheduleAmbientFold(after: activity.holdDuration)
    }

    /// The charger plugged in while the Mac is locked, on the locked island
    /// (spec §3.7, amended 2026-10-26): its compact pill for its hold, no
    /// queue — over the shield the island is the lock's — and no pointer
    /// test, since nothing there opens. The pop-up outranks it: one already
    /// up keeps the island, and the charge is not shown.
    private func presentLockedCharge(_ activity: AmbientActivity, switchOn: Bool) {
        guard let vm = viewModel, vm.hud == nil,
              Self.ambientAllowed(
                  switchOn: switchOn, pointerInside: false, pointerUnderGrownPill: false,
                  screensAsleep: screensAreAsleep, quiet: momentsAreQuiet(presentingOnly: true)
              ) else { return }
        ambientWork?.cancel()
        withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.ambient = activity
        }
        Announcer.shared.announce(activity.accessibilityLabel)
        scheduleAmbientFold(after: activity.holdDuration)
    }

    /// A Charging moment on the island takes a later reading in place: the
    /// battery that began charging a moment after the plug, the adapter's
    /// watts. Nothing is announced again and the hold is not restarted — it
    /// is the same moment, told more exactly. Ignored when no Charging moment
    /// is up, so a reading that lands after the fold puts nothing back.
    func updateShownCharge(_ activity: AmbientActivity) {
        guard let vm = viewModel, case .charging = activity else { return }
        latestCharge = (activity, Date())
        // The capsule's Charging moment takes it the same way.
        if case .ambient(.charging)? = vm.stripNotice, vm.stripNotice != .ambient(activity) {
            withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.stripNotice = .ambient(activity)
            }
            return
        }
        guard case .charging? = vm.ambient, vm.ambient != activity else { return }
        withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.ambient = activity
        }
    }

    /// Folds the moment after `delay`, or, with the pointer resting on the
    /// pill, asks again a second later (`ambientRecheck`). One work item at a
    /// time, always in `ambientWork`, so a lock, a dark display or an open
    /// cancels the whole chain with one call.
    private func scheduleAmbientFold(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel, vm.ambient != nil else { return }
            if let wait = Self.ambientRecheck(pointerInside: self.pointer.isInside) {
                self.scheduleAmbientFold(after: wait)
                return
            }
            withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.ambient = nil
            }
            self.promoteWaitingAlert()
        }
        ambientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether a charger or headphones moment may show at all. Pure, so each
    /// refusal is a test.
    ///
    /// - An open panel, a drag and the lock are not refusals any more: they
    ///   make it wait, for a second, in `alertQueue` (`alertsBlocked`).
    /// - A pointer resting where the grown pill would reach is refused along
    ///   with one already inside: the pill would grow under a still cursor,
    ///   take the clicks meant for the menu bar beside the notch, and with
    ///   Open on Hover on, open the panel nobody asked for.
    /// - A quiet moment (`momentsQuiet`) is refused: the audience's screen is
    ///   not the place for a battery percentage (K-003).
    nonisolated static func ambientAllowed(
        switchOn: Bool, pointerInside: Bool, pointerUnderGrownPill: Bool, screensAsleep: Bool, quiet: Bool
    ) -> Bool {
        switchOn && !pointerInside && !pointerUnderGrownPill && !screensAsleep && !quiet
    }

    /// Whether the transient moments (the track peek, the charger, the
    /// headphones) stay away now. Pure, so each reason is a test (K-003).
    ///
    /// A talk mirrored to a projector, a laptop presenting through HDMI with
    /// its lid shut, and a full-screen film or game each have an audience or an
    /// absorbed viewer, and a 2.2 s pill with a song title on it is noise to
    /// both. `sharingType = .none` hides the panel from screen capture and not
    /// from a hardware mirror, so the pill cannot be left to hide itself. Only
    /// the transient moments are quieted: the resting pill's presence on every
    /// Space is the tested contract (S9-b).
    nonisolated static func momentsQuiet(
        fullScreenFrontmost: Bool, displayMirrored: Bool, soleExternalDisplay: Bool
    ) -> Bool {
        fullScreenFrontmost || displayMirrored || soleExternalDisplay
    }

    /// Only external displays on a Mac that has a battery is a laptop with its
    /// lid shut and a screen plugged in, which is how a talk is given. A Mini
    /// or a Studio has no battery and only ever has external displays, and that
    /// is a desk, so it is not quiet.
    nonisolated static func isSoleExternalDisplay(displaysAreBuiltIn: [Bool], hasInternalBattery: Bool) -> Bool {
        hasInternalBattery && !displaysAreBuiltIn.isEmpty && !displaysAreBuiltIn.contains(true)
    }

    /// The live reading behind `momentsQuiet`. Read when a moment is about to
    /// show, never cached: a display plugged in a second ago has to count.
    ///
    /// `presentingOnly` asks only the presentation reasons — a mirror, a
    /// shut lid on a projector — and not a full-screen app: the charger
    /// (owner, 2026-10-27: a plug-in must always show, as the menu bar's
    /// bolt does) is the Mac's own state, not a song title over a film.
    func momentsAreQuiet(presentingOnly: Bool = false) -> Bool {
        if let momentsQuietForTesting { return momentsQuietForTesting }
        let options = NSApplication.shared.currentSystemPresentationOptions
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        let active = ids.prefix(Int(count))
        return Self.momentsQuiet(
            // `.hideMenuBar` rather than `.autoHideMenuBar`: the latter is a
            // preference many people keep on all day, the former is an app
            // that took the whole screen.
            fullScreenFrontmost: !presentingOnly && (options.contains(.fullScreen) || options.contains(.hideMenuBar)),
            displayMirrored: active.contains { CGDisplayIsInMirrorSet($0) != 0 },
            soleExternalDisplay: Self.isSoleExternalDisplay(
                displaysAreBuiltIn: active.map { CGDisplayIsBuiltin($0) != 0 },
                hasInternalBattery: Self.hasInternalBattery()
            )
        )
    }

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// How long a moment due to fold waits before asking again, or nil to
    /// fold now. Pure, so the rule is a test.
    ///
    /// A pointer resting on the pill is someone reading it (F-033). The fixed
    /// 2.2 s took the pill back from under them; it now waits a second at a
    /// time until the pointer has gone, so it folds at most a second after
    /// they move away.
    nonisolated static func ambientRecheck(pointerInside: Bool) -> TimeInterval? {
        pointerInside ? 1.0 : nil
    }

    /// Whether the pointer watcher must treat the panel as held, with the
    /// pointer off it: what `pointer.isDragging` answers. Pure, so each reason
    /// is a test.
    ///
    /// - An attached sheet holds it (G-012). The Edit Lyrics sheet is taller
    ///   than the panel's body and hangs below it, so moving down to its lower
    ///   fields left the hover rect and folded the panel 0.32 s later, and the
    ///   sheet and its unsaved edits went with it. A sheet is modal: while it
    ///   is up, the panel is where the person is working.
    nonisolated static func holdsOpen(
        receivingDrag: Bool, draggingOut: Bool, menuOpen: Bool, pressHeld: Bool, sheetAttached: Bool
    ) -> Bool {
        receivingDrag || draggingOut || menuOpen || pressHeld || sheetAttached
    }

    /// Ends a charger or headphones moment at once. For a lock, a dark
    /// display, and anything else that takes the pill away.
    func clearAmbient() {
        ambientWork?.cancel()
        ambientWork = nil
        viewModel?.ambient = nil
    }
}
