import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// Alerts, the volume pop-up and confirmations. Stored properties live in NotchController.swift.
extension NotchController {
    // MARK: The island's alerts in time (spec §19.1)

    /// Whether an alert has to wait for the island: a surface is open, files
    /// are being dragged to it, or the Mac is locked. Pure, so each reason is a
    /// test.
    ///
    /// Waiting is not refusing. An alert held back by one of these shows if
    /// the island comes free within a second of its cause; the refusals in
    /// `hudPlacement` and `ambientAllowed` — a switch off, a dark display, a
    /// film full screen — drop it at once, because a second changes none of
    /// them.
    nonisolated static func alertsBlocked(isOpen: Bool, isDropTargeted: Bool, isLocked: Bool) -> Bool {
        isOpen || isDropTargeted || isLocked
    }

    /// Asks the queue whether `alert` shows now, waits, or is dropped, against
    /// what the island holds this instant.
    func postAlert(_ alert: IslandActivity, to vm: NotchViewModel) -> IslandAlertQueue.Verdict {
        alertQueue.post(
            alert, showing: vm.activity,
            blocked: Self.alertsBlocked(
                isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
            ),
            at: Date()
        )
    }

    /// A click on an alert (spec §19.1): it folds now, on the curve it would
    /// have folded on, and the island returns to what is live — or to an
    /// alert still waiting inside its second. Its timer goes with it, so it
    /// cannot fold a second time over whatever came back.
    func foldAlert() {
        guard let vm = viewModel else { return }
        hudFoldWork?.cancel()
        hudFoldWork = nil
        ambientWork?.cancel()
        ambientWork = nil
        peekWork?.cancel()
        peekWork = nil
        confirmationWork?.cancel()
        confirmationWork = nil
        withAnimation(Theme.island(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.hud = nil
            vm.confirmation = nil
            vm.ambient = nil
        }
        promoteWaitingAlert()
    }

    /// The drag is over — dropped, sent to AirDrop or taken away. The drop
    /// surface comes off what it was laid over (spec §19.7): a panel the drag
    /// opened folds back into the island, where the Shelf now shows as live,
    /// and one that was already open goes back to the surface it was on.
    func endDropSurface() {
        guard dragOpenedPanel else {
            // The pointer usually is not over the panel after a drag leaves.
            scheduleCollapseIfPointerAway()
            return
        }
        dragOpenedPanel = false
        setOpen(false)
        // The pointer let go on the island, inside the open rect that is
        // about to shrink: counted as an arrival, Open on Hover would open the
        // panel straight back up.
        pointer.closedByHand()
    }

    /// The island is free again — an alert folded, a surface closed, the drag
    /// left, the Mac unlocked: the highest alert still inside its second takes
    /// it. Through the alert's own entry point, so every refusal is asked
    /// again — the pointer may be on the island by now, or a film full screen
    /// — and one refused there lets the next in line have its turn.
    func promoteWaitingAlert() {
        guard let vm = viewModel else { return }
        while !vm.activity.isAlert,
              !Self.alertsBlocked(
                  isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
              ),
              let next = alertQueue.next(at: Date()) {
            switch next {
            case .confirmation(let confirmation): presentConfirmation(confirmation)
            case .ambient(let activity): presentAmbient(activity)
            case .update(let offer): presentUpdate(offer)
            case .peek: sneakPeek()
            // The pop-up never waits, and live activities are never posted.
            case .hud, .music, .shelf, .live, .none: break
            }
        }
        // The update alert is not only what waited: an offer taken down by an
        // open, a lock or a dark display was never queued, and is still owed.
        considerUpdateOffer()
    }

    // MARK: The volume and brightness pop-up (spec §12)

    /// How long after the last press the level is spoken. A held key repeats
    /// many times a second, and a high-priority announcement each time would be
    /// VoiceOver talking over itself about numbers already out of date.
    static let hudAnnounceDelay: TimeInterval = 0.25

    /// Where a key's result is drawn.
    enum HUDPlacement: Equatable {
        /// The shut island's expanded alert (spec §19.5 d).
        case pill
        /// The locked island's compact pill, over the shield (spec §3.7,
        /// amended 2026-10-26; `LockedHUDLayout`).
        case locked
        /// The capsule under the open panel (`HUDStripLayout`, spec §19.5 d,
        /// amended 2026-10-25).
        case strip
    }

    /// Shows a key's result, and restarts the fold.
    ///
    /// The key has already been applied and consumed; this only says so. The
    /// level is announced even when nothing is drawn — over the lock screen,
    /// or a dark display — so a person on VoiceOver is never left without it.
    ///
    /// Each press costs the main thread one store and nothing else once the
    /// pop-up is up: the level goes to `HUDLiveLevel`, which only the pop-up's
    /// own view watches, and the fold timer is pushed back. The island's body,
    /// the outline and the alert queue are touched on the arrival and the
    /// fold alone (owner, 2026-10-25: "as light as the native macOS one").
    func presentHUD(_ reading: HUDReading) {
        guard let vm = viewModel else { return }
        let moment = HUDMoment(reading)
        hudAnnounceWork?.cancel()
        let announce = DispatchWorkItem {
            Announcer.shared.announce(moment.accessibilityLabel)
        }
        hudAnnounceWork = announce
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hudAnnounceDelay, execute: announce)

        guard let placement = Self.hudPlacement(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted,
            isLocked: vm.isLockedPresentation, screensAsleep: screensAreAsleep,
            overShield: islandIsOverShield
        ) else { return }

        let reduceMotion = SystemAppearance.shared.reduceMotion
        switch placement {
        case .locked:
            // Over the shield the island is the lock's, so no queue: the
            // pop-up replaces the charger, and nothing else can be up there.
            if vm.hud == nil {
                ambientWork?.cancel()
                ambientWork = nil
                withAnimation(Theme.hud(reduceMotion: reduceMotion)) {
                    vm.ambient = nil
                    vm.hud = moment
                }
            } else {
                vm.hud = moment
            }
        case .strip:
            // A satellite of the panel, not an alert: it takes no part in the
            // island's queue, replaces nothing and waits for nothing — the
            // panel being open means every alert is already waiting for it to
            // close, so nothing else is on screen to stack with.
            if vm.hudStrip == nil {
                // The level outranks whatever else the capsule carries — the
                // charger, headphones, a confirmation — and takes it over in
                // one transaction, as the pill replaces what it outranks;
                // the replaced notice is dropped with its timer (spec §19.1).
                stripNoticeWork?.cancel()
                stripNoticeWork = nil
                withAnimation(Theme.hud(reduceMotion: reduceMotion)) {
                    vm.stripNotice = nil
                    vm.hudStrip = moment
                }
            } else {
                // Already up: the bar follows on its own curve; the capsule
                // has nothing to do.
                vm.hudStrip = moment
            }
        case .pill:
            // The highest of R7's alerts, so the queue always says show; asked
            // all the same, so a peek or a charger waiting behind an older
            // pop-up is judged against this one.
            guard postAlert(.hud(moment), to: vm) == .show else { return }
            if vm.hud == nil {
                // Unfolding, on the pop-up's own quick, critically damped
                // spring (`Theme.hud`): on the island's slower, bouncier curve
                // a key press felt heavy, and the owner's review (2026-10-18)
                // asked for the system's feel — there at once, no overshoot.
                //
                // It replaces what it outranks — the charger, headphones, a
                // peek — and the replaced alert is
                // dropped with its timer, not left underneath to come back when
                // this folds (spec §19.1): a percentage shown again after the
                // pop-up is a percentage from before it.
                peekWork?.cancel()
                peekWork = nil
                ambientWork?.cancel()
                ambientWork = nil
                confirmationWork?.cancel()
                confirmationWork = nil
                // The update alert is the one replaced alert that is not
                // dropped: the queue took it back as this was posted (spec
                // §19.1), and it returns, with a fresh hold, when this folds.
                cancelUpdateWork()
                withAnimation(Theme.hud(reduceMotion: reduceMotion)) {
                    vm.isPeeking = false
                    vm.ambient = nil
                    vm.hud = moment
                    vm.confirmation = nil
                    vm.updateOffer = nil
                }
            } else {
                // Already up: the bar follows on its own curve; the shape has
                // nothing to do, and the view model hears nothing of it
                // (`NotchViewModel.hud`).
                vm.hud = moment
            }
        }
        hudFoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.hudFoldWork = nil
            // The island returns to its live activity — the song, the Shelf —
            // on the curve the pop-up arrived on, or to an alert that waited
            // for the pop-up and is still inside its second. The capsule folds
            // on the same curve.
            withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.hud = nil
                vm.hudStrip = nil
            }
            self.promoteStripNotice()
            self.promoteWaitingAlert()
        }
        hudFoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hudFoldDelay, execute: work)
    }

    /// Where the pop-up may be drawn now, or nowhere. Pure, so each refusal is
    /// a test.
    ///
    /// The shut island's pill when the panel is shut; the capsule under the
    /// panel when it is open (it was refused outright until 2026-10-25, on the
    /// premise that the player had its own volume slider — withdrawn on
    /// 2026-10-16 — and brightness never had one). Not while a drag holds the
    /// panel open, whose drop surface is the whole answer; not over the lock
    /// screen, where the tap passes every event through and the collapsed rects
    /// belong to the card; not on a dark display. A key press is the person's
    /// own act, so unlike the charger it is **not** refused for a pointer on
    /// the pill or a full-screen app.
    ///
    /// Over the lock screen (amended 2026-10-26): the locked island's compact
    /// pill when the island is over the shield (`overShield`, the panel in the
    /// lock screen's SkyLight space with the card), and nowhere otherwise —
    /// then the tap never took the key (`MediaKeyHUD.drawsWhileLocked`), and
    /// the system's own pop-up is showing. The card is a window of its own in
    /// the middle of the display and the pill sits at the notch, so neither
    /// moves or covers the other; the card's own volume bar watches the same
    /// output and moves with the key.
    nonisolated static func hudPlacement(
        isOpen: Bool, isDropTargeted: Bool, isLocked: Bool, screensAsleep: Bool, overShield: Bool = false
    ) -> HUDPlacement? {
        guard !screensAsleep else { return nil }
        // `LockedIsland.showsAlert` says the same of `.hud`.
        if isLocked { return overShield ? .locked : nil }
        guard !isDropTargeted else { return nil }
        return isOpen ? .strip : .pill
    }

    /// Whether the island is over the lock screen now, to draw on: locked as
    /// the island presents it, the display awake, and the panel in the space
    /// above the shield (`LockScreenPresence.isAboveShield`) — the one answer
    /// the key tap, the pop-up and the charger all ask.
    var islandIsOverShield: Bool {
        guard let vm = viewModel, vm.isLockedPresentation, !screensAreAsleep else { return false }
        if let overShieldForTesting { return overShieldForTesting }
        guard let panel else { return false }
        return lockPresence.isAboveShield(windowNumber: panel.windowNumber)
    }

    // MARK: The island's confirmations (2026-10-25, MR-7)

    /// Shows "Lyrics imported", "Copied" or "Added to Shelf" on the shut
    /// island for its hold, through `alertQueue` like every alert.
    ///
    /// Posted while the panel is open or a drag is under way, it waits for the
    /// panel to close and then shows its usual hold; if the panel is still
    /// open `IslandAlertQueue.confirmationPatience` (5 s) after the act, it
    /// lapses. A file dropped onto an already-open panel returns to the player
    /// (`endDropSurface`), not to the tray, and an LRC import runs from
    /// Settings: with the old one-second wait neither was ever answered. A
    /// newer confirmation replaces an older one at once (equal rank), the key
    /// pop-up replaces it outright, and a lock or a dark display ends it.
    ///
    /// Unlike the charger it is not refused with the pointer on the island:
    /// a drop leaves the pointer exactly there, and the act is the person's
    /// own, as a key press is. Nor over a full-screen app, for the same
    /// reason. A dark display shows nothing.
    func presentConfirmation(_ confirmation: IslandConfirmation) {
        guard let vm = viewModel, !screensAreAsleep else { return }
        // Over an open panel: in the capsule under it, now (2026-10-26).
        if Self.noticePlacement(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
        ) == .strip {
            presentInStrip(.confirmation(confirmation))
            return
        }
        guard postAlert(.confirmation(confirmation), to: vm) == .show else { return }

        let reduceMotion = SystemAppearance.shared.reduceMotion
        // What it outranks goes, and is dropped with its timer (spec §19.1);
        // the update choice is the queue's to bring back.
        peekWork?.cancel()
        peekWork = nil
        ambientWork?.cancel()
        ambientWork = nil
        cancelUpdateWork()
        confirmationWork?.cancel()
        withAnimation(Theme.pill(reduceMotion: reduceMotion)) {
            vm.isPeeking = false
            vm.ambient = nil
            vm.updateOffer = nil
            vm.confirmation = confirmation
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.confirmationWork = nil
            withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.confirmation = nil
            }
            self.promoteWaitingAlert()
        }
        confirmationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmationHold, execute: work)
    }

    /// Ends a confirmation at once, for a lock, a dark display and a Space
    /// change.
    func clearConfirmation() {
        confirmationWork?.cancel()
        confirmationWork = nil
        alertQueue.removeConfirmations()
        viewModel?.confirmation = nil
    }

    /// Ends the pop-up at once, for a lock, a dark display and a Space change.
    func clearHUD() {
        hudFoldWork?.cancel()
        hudFoldWork = nil
        hudAnnounceWork?.cancel()
        hudAnnounceWork = nil
        viewModel?.hud = nil
        viewModel?.hudStrip = nil
        clearStripNotice()
    }
}
