import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// The lock screen, display sleep and wake. Stored properties live in NotchController.swift.
extension NotchController {
    /// Whether a lock starts the media clock for the card. Not while the
    /// display is dark.
    ///
    /// With any "require password after" delay above zero, the display sleeps
    /// first and the lock arrives later; with "immediately" the two race. Either
    /// way the sleep handler had already stopped the clock, and the lock turned
    /// it straight back on — with a song playing, the ten-a-second ticker and
    /// the once-a-second Apple event into the player — for a card nobody could
    /// see, for as long as the display stayed dark. Music keeps a Mac awake
    /// with its display off, so that was hours. The wake handler starts the
    /// clock the moment the card can be seen. Pure, so `LockedClockTests` can
    /// hold the rule without a controller.
    /// What a file that a drag promised does when it finally lands. A promise
    /// can take minutes (an iCloud Photos original), long enough for the Mac to
    /// lock or sleep, and the pointer that dropped it is long gone. Opening the
    /// panel then put it over the shield (G-025); the card is still added, and
    /// the user finds it on the Shelf when they next look.
    enum PromiseArrivalPlan: Equatable {
        case addQuietly
        case addAndOpen
    }

    nonisolated static func promiseArrivalPlan(locked: Bool, asleep: Bool) -> PromiseArrivalPlan {
        locked || asleep ? .addQuietly : .addAndOpen
    }

    func promisedFilesArrived(_ urls: [URL]) {
        let plan = Self.promiseArrivalPlan(
            locked: lockPresence.isLocked || viewModel?.isLockedPresentation == true,
            asleep: screensAreAsleep
        )
        switch plan {
        case .addQuietly:
            stores.shelf.add(urls)
        case .addAndOpen:
            guard let vm = viewModel else {
                stores.shelf.add(urls)
                return
            }
            vm.isDropTargeted = false
            _ = vm.accept(urls: urls)
            pointer.setInside(true)
            setOpen(true)
            scheduleCollapseIfPointerAway()
        }
    }

    /// Promised files that were dropped on the Shelf's AirDrop well have been
    /// written: send them, and keep nothing (spec §8.3). Nothing opens and no
    /// card appears — the sheet is the answer — and over the shield or on a dark
    /// display they go to the Shelf instead, quietly: a share sheet nobody can
    /// see, or raised over the password field, is worse than a card found later.
    func promisedFilesArrivedForAirDrop(_ urls: [URL]) {
        let plan = Self.promiseArrivalPlan(
            locked: lockPresence.isLocked || viewModel?.isLockedPresentation == true,
            asleep: screensAreAsleep
        )
        guard plan == .addAndOpen else {
            stores.shelf.add(urls)
            return
        }
        ShelfSharing.airDrop(urls, refusingOn: stores.shelf)
    }

    static func lockKeepsMediaRunning(screensAsleep: Bool) -> Bool {
        !screensAsleep
    }

    /// Whether the media clock — the ten-a-second position ticker, and with
    /// lyrics on the once-a-second Apple event into Spotify — should run for
    /// what is on screen.
    ///
    /// Opening the panel used to start it on any tab. A panel left open on
    /// the Shelf, Clipboard or Settings while Spotify played paid eleven
    /// wake-ups a second to move a scrubber nobody could see (F-015). Only the
    /// player, the stage and the lock card draw a scrubber or a lyric, so only
    /// they run it. The lock card answers for itself with the panel closed,
    /// whatever surface was left open — the lock path starts it, and
    /// `lockKeepsMediaRunning` holds the dark-display exception there. Pure, so
    /// `MediaClockTests` can hold the rule without a controller.
    static func mediaClockWanted(isOpen: Bool, surface: NotchViewModel.Surface, locked: Bool) -> Bool {
        locked || (isOpen && (surface == .player || surface == .stage))
    }

    /// The lock screen is display-only for the panel: the compact pill keeps
    /// rendering — `MediaController` never stops with the shield up, so
    /// artwork, equalizer and the playing/paused state stay current — but
    /// nothing may open over the shield and nothing may take a click that was
    /// aimed at the password field. Mirrors the display-sleep handler above,
    /// with the level raise on top. The switch lives in Settings; off means
    /// none of this happens and the panel sinks under the shield as any
    /// ordinary window does.
    func screenLocked() {
        // Nothing carries over the shield: the lock is a cut. The pop-up and
        // the charger may show again over it, on their own news (spec §3.7,
        // amended 2026-10-26); nothing from before the lock does.
        clearAmbient()
        clearHUD()
        clearConfirmation()
        // Nor the update alert: nothing on the shield takes a click but the
        // card. It is offered again after the unlock.
        clearUpdateOffer()
        guard NotchViewModel.showOnLockScreenEnabled else {
            // The card is switched off, but the rest of the lock contract still
            // holds: fold, and stop the sampler. Returning outright left it
            // sampling all through the lock, so a cursor pass over the notch
            // opened an invisible panel beneath the shield.
            setOpen(false)
            collapseNow()
            pointer.setInside(false)
            pointer.stop()
            stores.suspendForIdleScreen(forLock: true)
            return
        }
        setOpen(false)
        // Synchronously, not on the next run-loop pass. `setOpen`'s close path
        // defers the visual half, and that deferred half used to land *after*
        // everything below: it called `media.setActive(false)`, silencing the
        // card this method just brought to life, and scheduled a rect for the
        // 700×444 notch window that replaced the card's own — on a window now
        // the size of the whole display, which put the only clickable region
        // near the bottom-left corner and left the transport dead for the
        // entire lock.
        collapseNow()
        pointer.setInside(false)
        // The cursor still moves on the lock screen — that is how the
        // password field is summoned — so a running sampler would count a
        // pass over the notch as a hover and unfold the panel there.
        pointer.stop()
        // Click-through for the whole locked stretch. `build` starts panels
        // this way, and the first sample after unlock puts it right again.
        // The card is interactive — its transport answers clicks and its bar
        // scrubs — so the panel keeps taking events, but only inside the
        // card: everything outside its rect stays click-through, and the
        // password field keeps the rest of the screen.
        // The notch panel keeps taking hovers so the pill can answer one with a
        // nudge, and takes no clicks at all: the card is a window of its own
        // now, and everywhere else on the shield belongs to the password field.
        panel?.ignoresMouseEvents = false
        // A cut, not a transition. Nothing interpolates between the island and
        // the locked pill.
        withTransaction(Self.cut) { viewModel?.isLockedPresentation = true }
        geometryTrace("locked")
        let keepsMediaRunning = Self.lockKeepsMediaRunning(screensAsleep: screensAreAsleep)
        // As the lock card, not the panel: a first Automation prompt raised
        // here would sit under the shield where nobody can answer it, so the
        // card asks a player only what macOS already allows.
        if keepsMediaRunning { viewModel?.media.setActive(true, surface: .lockCard) }
        // Nobody can copy anything at a locked Mac, and Universal Clipboard
        // arrivals from a phone are not something to record behind a shield.
        // This used to happen only on the branch where the card is switched
        // off — which is not the default — so the pasteboard was polled twice a
        // second for the whole lock on an ordinary install.
        //
        // The media clock stays running: the card is about to be presented, and
        // it draws a scrubber and a moving lyric that both depend on it.
        //
        // Stopping the poll was not enough on its own: the resume kept the
        // old baseline, so the first poll after unlock recorded whatever had
        // arrived during the lock. `forLock` makes the resume start fresh.
        stores.suspendForIdleScreen(keepingMediaRunning: keepsMediaRunning, forLock: true)
        applyLockedActiveRect()
        lockPresence.apply(to: panel, locked: true)
        // The panel is over the shield now, or the compositor refused: either
        // way the key tap's mirror learns it here, after the lift, so it takes
        // a key only once the island can show it (`islandIsOverShield`).
        stores.hud.lockChanged()
        // And the card, in its own window, at the centre of the notch's own
        // display — not `panel.screen`, which is nil while the window is
        // momentarily off every display mid-reconfiguration, and not the
        // primary one, which is a different display whenever the notch is not
        // on it.
        if let vm = viewModel, let screen = vm.geometry.screen as NSScreen? {
            lockCard.present(
                media: vm.media,
                lyrics: vm.lyrics,
                localLookup: { vm.lyricsCoordinator.localLookup },
                translation: vm.translation,
                nowPlaying: vm.nowPlaying,
                on: screen,
                presence: lockPresence
            )
        }
    }

    /// Makes the panel cover the whole display, and says so when it cannot.
    /// While locked the notch panel takes no clicks at all.
    ///
    /// The card lives in its own window, which is its own hit region; the pill
    /// answers a hover with a nudge and nothing else, per the product call.
    /// Everywhere else on the shield belongs to the password field.
    func applyLockedActiveRect() {
        guard let rootView, let vm = viewModel else { return }
        // The panel's frame is the geometry's window frame; a controller built for
        // a test has no panel, and the cut is the same arithmetic against it.
        let window = panel?.frame.size ?? vm.geometry.windowSize
        rootView.activeRect = .zero
        rootView.dropRect = .zero
        // The bubble never stands over the shield (spec §19.1).
        rootView.bubbleRect = .zero
        pointer.bubbleRect = .zero

        // The pill's own region. It opens nothing — the island stays shut over
        // the shield, by design — but it answers: a hover draws the edge, and a
        // click shakes it off. Silence reads as a dead app rather than as a
        // limit, which is the whole reason this rect exists.
        //
        // It takes clicks now, where before it took only hovers. The area is
        // the notch itself, at the top centre of the screen; the password field
        // is in the middle, and nothing else up there belongs to loginwindow.
        let pill = vm.lockedIslandSize
        let rect = CGRect(
            x: (window.width - pill.width) / 2,
            y: window.height - pill.height,
            width: pill.width,
            height: pill.height
        )
        rootView.lockedHoverRect = rect
        rootView.activeRect = NotchRootView.reachingTopEdge(rect, windowHeight: window.height)
    }

    /// Unconditional, unlike the lock side: the toggle may have been flipped
    /// mid-lock, and putting a panel back on a level it already occupies
    /// costs nothing. `pointer.start()` doubles with the wake handler when
    /// the display slept too — starting twice only reschedules the timer.
    func screenUnlocked() {
        // A pop-up or a charger over the shield ends with it, as a cut: left
        // up, the unlocked shell would redraw the compact pop-up as the 103 pt
        // alert for what was left of its linger.
        clearHUD()
        clearAmbient()
        lockCard.dismiss(presence: lockPresence)
        lockPresence.apply(to: panel, locked: false)
        geometryTrace("unlocked")
        withTransaction(Self.cut) { viewModel?.isLockedPresentation = false }
        // The volume keys' tap reads the lock from a mirror on its own thread;
        // an unlock with the display still dark resumes nothing below, so say
        // so here or the keys stay with the system until the wake.
        stores.hud.lockChanged()
        // The notch frame first, then the collapsed strip's rect; the first
        // pointer sample after unlock re-applies the hover machinery.
        if let vm = viewModel { panel?.setFrame(vm.geometry.windowFrame, display: true) }
        // The nudge region belongs to the lock screen only; unlocked, the
        // ordinary hover rules apply again and this must not linger.
        rootView?.lockedHoverRect = .zero
        applyActiveRect(open: false)
        // The ticker belongs to an open panel, and the panel is folded after
        // unlock — setActive(false) puts the idle contract back.
        viewModel?.media.setActive(false)
        // Unless the display is still dark: unlocking a Mac whose screen has
        // not woken yet must not restart the sampler the sleep handler stopped.
        if !screensAreAsleep {
            pointer.start()
            // The lock path suspends the pasteboard poll, and only the display
            // wake handler used to resume it — so locking and unlocking without
            // the display ever sleeping left clipboard capture dead for the
            // rest of the session.
            stores.resumeFromIdleScreen()
        }
        // An update offer the lock took down, or found while it stood, is
        // owed now; with the display still dark it waits on for the wake.
        updateScreenSeenAgain()
    }
}

// MARK: - Waking

extension NotchController {
    enum WakeStep: Equatable {
        case startWatchdog
        case resumeStores
        case repairUnlock
        case reactivateCardMedia
        case restartPointer
    }

    /// What a display waking has to do, in order. Pure, so the decisions that
    /// have each cost a bug are tests rather than comments.
    ///
    /// - The watchdog comes first and always: the card over a locked Mac is
    ///   exactly what it keeps in place.
    /// - The stores resume only once it is clear the Mac is not still locked.
    /// - Awake, unlocked, but still dressed for the lock: the unlock
    ///   notification was missed (it once queued behind a main-thread block
    ///   and the card stayed stranded on the desktop), so the unlock is
    ///   replayed and nothing else runs.
    /// - Still locked: the pointer sampler must stay stopped. Restarting it
    ///   there, the display sleeping and rewaking mid-lock being the ordinary
    ///   way the password field is summoned, put it to work against rects cut
    ///   before the lock, which killed the card's transport and could unfold
    ///   the panel under the shield. Only the card's media comes back.
    nonisolated static func wakePlan(isLocked: Bool, lockedPresentation: Bool) -> [WakeStep] {
        if isLocked {
            return lockedPresentation ? [.startWatchdog, .reactivateCardMedia] : [.startWatchdog]
        }
        if lockedPresentation {
            return [.startWatchdog, .resumeStores, .repairUnlock]
        }
        return [.startWatchdog, .resumeStores, .restartPointer]
    }
}
