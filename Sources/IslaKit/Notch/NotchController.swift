import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

@MainActor
final class NotchController {
    private var panel: NotchPanel?
    private(set) var rootView: NotchRootView?
    private var viewModel: NotchViewModel?

    /// The live model, for App Intents. Read-only and optional on purpose: the
    /// panel builds its model in `install()`, so an intent that launched the app
    /// can arrive before there is one, and "not ready yet" is an honest answer.
    var intentModel: NotchViewModel? { viewModel }
    /// Internal so a test can read the rects the controller cuts
    /// (`NotchControllerRectTests`); nothing outside this file writes to it.
    let pointer = PointerWatcher()
    private let lockPresence = LockScreenPresence()
    /// The lock screen's player, in a window of its own — see `LockCardWindow`.
    private let lockCard = LockCardWindow()
    /// Stores that belong to the session, not to the panel: a rebuild replaces
    /// the panel and its view model and leaves these untouched.
    private let stores = NotchStores()
    private var closeActiveRectWork: DispatchWorkItem?
    /// The body height the open rects are cut for right now. It trails the
    /// body's own height on the way down (see `openRectHeight`), so it is the
    /// controller, not the model, that knows it.
    private var appliedOpenSize: CGSize?
    /// Whether the drag in flight opened the panel itself, so the drop surface
    /// folds back into the island when it ends rather than leaving a surface
    /// nobody asked for open (spec §19.7).
    private var dragOpenedPanel = false
    /// The pass that lets the rects shrink once the body has stopped moving.
    private var rectShrinkWork: DispatchWorkItem?
    private var collapseCheckWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// Held so `teardown` can actually undo `install`. Discarding the tokens
    /// left the registrations permanent by construction, which was harmless
    /// only for as long as `install` was called exactly once.
    private var observerTokens: [NSObjectProtocol] = []
    /// True while the display is asleep — the sampler and every poll are
    /// stopped, and the wake handler puts back only what it stopped.
    private var screensAreAsleep = false
    private var geometryWatchdog: Timer?
    /// Watches for a click in another app while the panel is pinned open.
    ///
    /// A pinned panel is deliberately deaf to the pointer, so the ordinary
    /// hover rule cannot close it, and it only receives key events on the two
    /// tabs that take the keyboard — which left a panel opened by ⌃⌥⌘I on the
    /// media tab with no way out but the hotkey itself. A global monitor sees
    /// clicks the app never receives, which is exactly the signal needed.
    private var pinnedClickMonitor: Any?
    /// Escape, held system-wide for exactly as long as a pinned panel without
    /// the keyboard stands — see `NotchViewModel.claimsEscape`. A Carbon hot
    /// key for the same reason the three shortcuts are: it needs no
    /// permission and sees nothing else that is typed. Registered and given up
    /// by `updateEscapeHotKey` alone.
    private var escapeHotKey: HotKeyRegistration?
    /// Test seams: what registers the transient Escape — a test process must
    /// not reserve a real key for the login session — and the menus whose
    /// opening takes Escape back from it (`attachForTesting` passes its own).
    var escapeKeyRegistrar: (@escaping () -> Void) -> HotKeyRegistration? = { action in
        GlobalHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, action: action)
    }
    private(set) var menuTracking: MenuTracking = .shared
    /// Delete and ⌘⌫, held while the pointer is on the Shelf and something is
    /// selected there (spec §8.2) — see `NotchViewModel.claimsDelete` and
    /// `ShelfDeleteKeyHolder`, which is the only thing that registers them.
    /// Driven by `updateDeleteKey`, from every input of the claim at once.
    private lazy var deleteKey = ShelfDeleteKeyHolder(registrar: deleteKeyRegistrar) { [weak self] in
        self?.deleteKeyPressed()
    }
    /// Test seams: a registrar that records instead of reserving a key for the
    /// login session, set before the first claim, and the app's activation,
    /// which a test process does not control. Production leaves both alone.
    var deleteKeyRegistrar: ShelfDeleteKeyHolder.Registrar?
    var appIsActive: () -> Bool = { NSApp?.isActive ?? false }
    /// Where app activation is heard; a test posts to its own center.
    var activationCenter: NotificationCenter = .default
    /// Whether the Shelf's Delete and ⌘⌫ are held right now.
    var holdsDeleteKey: Bool { deleteKey.isRegistered }
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0
    /// Stamp of the panel `build()` last made. The synthetic-notch looks a
    /// build schedules do nothing once a newer build has outdated them.
    private var buildGeneration = 0

    func install() {
        stores.onScreenshot = { [weak self] url in
            self?.viewModel?.receivedScreenshot(at: url)
        }
        stores.ambient.onEvent = { [weak self] activity in
            self?.presentAmbient(activity)
        }
        // The volume and brightness pop-up (spec §12). Both closures are read at
        // each key, so the lock and the reading land on whatever is current.
        stores.hud.isLocked = { [weak self] in
            guard let self else { return false }
            return self.lockPresence.isLocked || self.viewModel?.isLockedPresentation == true
        }
        stores.hud.onReading = { [weak self] reading in
            self?.presentHUD(reading)
        }
        stores.promises.onBatch = { [weak self] urls in
            self?.promisedFilesArrived(urls)
        }
        stores.promises.onAirDropBatch = { [weak self] urls in
            self?.promisedFilesArrivedForAirDrop(urls)
        }
        stores.start()
        // After `start()` and never inside it: the tap exists only once the
        // setting and the permission are both true, and this is where the app
        // first asks. `launched()` also gives a stale Accessibility entry its
        // once-per-build repair when the setting is already on.
        stores.hud.launched()
        build()
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        })
        // ⌘-Tab, the Dock, Spotlight launching something: another app came to
        // the front, which is the keyboard's click in another app. A pinned
        // panel ends on it exactly as the outside-click monitor ends it — see
        // `NotchViewModel.appActivated(ownPID:activatedPID:)`. The pid is read
        // here, off the notification, so nothing non-Sendable crosses into
        // the main-actor block.
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated { self?.applicationActivated(activated) }
        })
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        })
        // A dark display has no hover to watch and no clipboard anybody can
        // change, so every poll stops with it — the pointer sampler, the
        // pasteboard timer, and the media ticker alike. Left running, a locked
        // laptop with the lid shut kept asking Spotify where it was, twice a
        // minute, all night.
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensAreAsleep = true
                self.geometryTrace("screens asleep")
                // A charger moment's timer does not run while the Mac sleeps,
                // so a lid closed right after plugging in woke to the old
                // percentage still on the island.
                self.clearAmbient()
                self.clearHUD()
                // And anything waiting for the island: nobody will see it, and
                // the second it may wait is over long before the lid opens.
                self.alertQueue.removeAll()
                self.setOpen(false)
                self.pointer.setInside(false)
                self.pointer.stop()
                self.stores.suspendForIdleScreen()
                // The watchdog too. It was the one repeating timer a dark
                // display left running — thirty wake-ups a minute, all night,
                // checking the frame of a window nobody could see. The wake
                // handler starts it again before anything is on screen.
                self.stopGeometryWatchdog()
            }
        })
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensAreAsleep = false
                self.geometryTrace("screens awake locked=\(self.lockPresence.isLocked ? 1 : 0)")
                let plan = Self.wakePlan(
                    isLocked: self.lockPresence.isLocked,
                    lockedPresentation: self.viewModel?.isLockedPresentation == true
                )
                for step in plan {
                    switch step {
                    case .startWatchdog: self.startGeometryWatchdog()
                    case .resumeStores: self.stores.resumeFromIdleScreen()
                    case .repairUnlock: self.screenUnlocked()
                    case .reactivateCardMedia: self.viewModel?.media.setActive(true, surface: .lockCard)
                    case .restartPointer: self.pointer.start()
                    }
                }
            }
        })
        // Locking replaces the desktop with the shield, and the pill stays on
        // it — see `LockScreenPresence` for the mechanism. Wired here because
        // the two sides of the transition are this controller's verbs: fold,
        // stop the sampler, raise the level; then put all three back.
        lockPresence.onLock = { [weak self] in self?.screenLocked() }
        lockPresence.onUnlock = { [weak self] in self?.screenUnlocked() }
        lockPresence.start()
        startGeometryWatchdog()
        // Verification hook, environment-gated like the panel's own: the lock
        // card is the one surface that cannot be screenshotted where it lives,
        // because the shield owns the screen while it is up. Launched with
        // DI_LOCK_PREVIEW=1 the app presents the card as though locked, over
        // the ordinary desktop, so its glass can be seen against a real
        // wallpaper. An app launched normally never has the variable.
        if DebugTrail.lockPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.screenLocked() }
            }
        }
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    private func activeSpaceChanged() {
        geometryTrace("space changed")
        // Same repair as the wake handler: a space change with the shield
        // down while the panel still thinks it is locked means the unlock
        // transition was lost — recover rather than stay stranded.
        if !lockPresence.isLocked, viewModel?.isLockedPresentation == true {
            screenUnlocked()
        }
        // Re-assert z-order on the space just arrived at. `.canJoinAllSpaces`
        // keeps the panel present everywhere, but a transition can leave it
        // behind other windows' ordering on the new space; fronting it again
        // makes the island read as fixed to the notch the way the hardware is.
        panel?.orderFrontRegardless()
        // Entering a full-screen app is a Space change, and a moment already
        // on screen would ride into it (K-003): end it with the Space it was
        // shown on. A peek's work item is cancelled with its flag, or the flag
        // would stay raised with nothing left to lower it.
        if let vm = viewModel, momentsAreQuiet() {
            if vm.isPeeking {
                peekWork?.cancel()
                peekWork = nil
                vm.isPeeking = false
            }
            if vm.ambient != nil { clearAmbient() }
        }
        // The pop-up is an answer to a key press and rides no Space into a new
        // one: it ends with the Space it was shown on — and an alert that was
        // waiting behind it gets the island, as when the pop-up folds.
        clearHUD()
        promoteWaitingAlert()
        guard viewModel?.isOpen == true else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
    }

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

    private func promisedFilesArrived(_ urls: [URL]) {
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
    private func promisedFilesArrivedForAirDrop(_ urls: [URL]) {
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
    private func screenLocked() {
        // A charger or headphones moment does not carry over the shield. The
        // locked pill is cut for music alone — and so is the volume pop-up,
        // which the tap does not even hear while the Mac is locked.
        clearAmbient()
        clearHUD()
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
    private func applyLockedActiveRect() {
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
    private func screenUnlocked() {
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
    }

    private func screenParametersChanged() {
        // No screens at all, for the moment. Nothing to anchor to and nothing
        // to draw; the next notification arrives with the new arrangement.
        guard let fresh = NotchGeometry.current() else {
            geometryTrace("params: no screen")
            return
        }
        geometryTrace("params: fresh \(Self.describe(fresh)) current \(viewModel.map { Self.describe($0.geometry) } ?? "nil")")
        guard let current = viewModel?.geometry, current.matches(fresh) else {
            geometryTrace("params: rebuilding (locked=\(viewModel?.isLockedPresentation == true ? 1 : 0))")
            rebuild()
            return
        }
        // Same display, same notch: keep the panel and everything on it.
        //
        // Except while the shield is up, where the panel is deliberately the
        // size of the whole screen so the card can sit at its centre. These
        // notifications fire for plenty of reasons that change nothing — the
        // locked display sleeping and rewaking is one — and re-applying the
        // notch frame to a locked panel shrank it back to 700×444, stranding
        // the card off-centre and unclickable until unlock.
        if let screen = viewModel?.geometry.screen { lockCard.reposition(on: screen) }
        panel?.setFrame(fresh.windowFrame, display: false)
        recutPointerRects()
    }

    /// Same display, same notch — but not necessarily the same neighbours.
    ///
    /// A rect that reaches the top edge grows past it only where no display
    /// sits directly above (`NotchGeometry.includingTopEdge`), and docking or
    /// undocking one there changes that without moving this display at all.
    /// Cut only in `build` and on the panel's own changes, the rects kept
    /// reaching two points into a display just docked above — its bottom edge
    /// lit the island and warmed the sampler — or stopped short of an edge
    /// that had just become one, so a click thrown at the top of the screen
    /// fell through, until the next track change or open re-cut them.
    private func recutPointerRects() {
        guard let vm = viewModel else { return }
        pointer.warmZone = vm.geometry.warmZone
        pointer.coolZone = vm.geometry.coolZone
        pointer.approachZone = vm.geometry.approachZone
        pointer.closeRect = vm.geometry.hoverRect(for: vm.openBodySize)
        // A display change moves the geometry without animating the body: no
        // spring to wait for, so a shrink applies at once.
        if vm.isOpen { refreshOpenRects(animated: false) } else { refreshCollapsedRects() }
    }

    /// A synthetic notch found at launch is checked again shortly after.
    ///
    /// `NotchGeometry` remembers a display's cutout and refuses to forget it on
    /// a glitched reading, but the memory is empty on the first read — and the
    /// first read happens at login, which is exactly when a Mac is still
    /// settling its displays. A launch that lands in that window would draw the
    /// synthetic pill for the rest of the session, since nothing else asks
    /// again. Two later looks cost nothing and end that.
    ///
    /// Asked at the end of every `build()`, not only at launch: a display
    /// reconfiguration or a wake rebuilds the panel while the built-in display
    /// is just as unsettled, and a synthetic pill drawn then stayed for the
    /// session (F-047). The generation stamp bounds that — each build's looks
    /// belong to it alone, so a rebuild storm leaves one pair of live looks.
    nonisolated static func syntheticRecheckDelays(
        isPhysical: Bool, generation: Int, current: Int
    ) -> [TimeInterval] {
        guard !isPhysical, generation == current else { return [] }
        return [1.5, 5.0]
    }

    private func verifySyntheticNotch() {
        let generation = buildGeneration
        let delays = Self.syntheticRecheckDelays(
            isPhysical: viewModel?.geometry.isPhysical ?? true,
            generation: generation,
            current: buildGeneration
        )
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.buildGeneration == generation,
                          self.viewModel?.geometry.isPhysical == false else { return }
                    guard let fresh = NotchGeometry.current(), fresh.isPhysical else { return }
                    self.geometryTrace("late notch found, rebuilding")
                    self.rebuild()
                }
            }
        }
    }

    /// A transaction that refuses to animate whatever is written inside it.
    private static var cut: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    /// Verification-only geometry trail, behind DI_GEOM=1: the panel drifting
    /// out of place is a state, not an event, so the watchdog samples as well
    /// as narrating each notification that could have caused it.
    private func geometryTrace(_ message: @autoclosure () -> String) {
        guard DebugTrail.geometry else { return }
        DebugTrail.note("GEOM \(message())")
    }

    static func describe(_ geometry: NotchGeometry) -> String {
        String(
            format: "screen=%.0fx%.0f@%.0f,%.0f notch=%.0fx%.0f cx=%.0f physical=%d scale=%.1f",
            geometry.screen.frame.width, geometry.screen.frame.height,
            geometry.screen.frame.origin.x, geometry.screen.frame.origin.y,
            geometry.notchSize.width, geometry.notchSize.height,
            geometry.notchCenterX, geometry.isPhysical ? 1 : 0,
            geometry.screen.backingScaleFactor
        )
    }

    /// Watches where the panel actually is against where it belongs — and puts
    /// it back when the two disagree.
    ///
    /// Not only a diagnostic. A panel can be moved or resized by things this
    /// app never hears about, and the failure it produces — the island and the
    /// card drawn small and off to one side — is invisible from the inside and
    /// stands until some later notification happens to correct it. Two seconds
    /// is far below noticing, and re-applying a frame that is already right
    /// costs nothing because it is skipped.
    private func startGeometryWatchdog() {
        guard geometryWatchdog == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, let vm = self.viewModel else { return }
                // One frame for the panel's whole life now: the card is a
                // separate window, so nothing about a lock changes this one.
                let want = vm.geometry.windowFrame
                let have = panel.frame
                let agrees = abs(want.origin.x - have.origin.x) < 1 && abs(want.origin.y - have.origin.y) < 1
                    && abs(want.width - have.width) < 1 && abs(want.height - have.height) < 1
                // The window's frame is only half of it. The content view and
                // the SwiftUI view inside it carry their own sizes, and a card
                // drawn at half scale in a correctly-sized window is what it
                // looks like when those disagree — the window is right and the
                // layout is describing a different display.
                let content = panel.contentView
                let hosted = (content as? NotchRootView)?.islandHosting ?? content?.subviews.first
                let contentFits = content.map {
                    abs($0.bounds.width - have.width) < 1 && abs($0.bounds.height - have.height) < 1
                } ?? true
                let hostedFits = hosted.map {
                    abs($0.frame.width - have.width) < 1 && abs($0.frame.height - have.height) < 1
                } ?? true
                if DebugTrail.geometry {
                    DebugTrail.note(String(
                        format: "GEOM watch panel=%.0fx%.0f@%.0f,%.0f want=%.0fx%.0f@%.0f,%.0f %@ content=%.0fx%.0f hosted=%.0fx%.0f%@%@ locked=%d card=%d %@",
                        have.width, have.height, have.origin.x, have.origin.y,
                        want.width, want.height, want.origin.x, want.origin.y,
                        agrees ? "ok" : "DRIFTED",
                        content?.bounds.width ?? -1, content?.bounds.height ?? -1,
                        hosted?.frame.width ?? -1, hosted?.frame.height ?? -1,
                        contentFits ? "" : " CONTENT-MISMATCH",
                        hostedFits ? "" : " HOSTED-MISMATCH",
                        vm.isLockedPresentation ? 1 : 0,
                        self.lockCard.isPresenting ? 1 : 0,
                        Self.describe(vm.geometry)
                    ))
                }
                guard !agrees || !contentFits || !hostedFits else { return }
                if !agrees { panel.setFrame(want, display: true) }
                // A resize the window server deferred leaves SwiftUI proposing
                // the old size — which is the shrunken, off-centre card itself.
                // Both layers are put back, not only the outer one.
                content?.frame = CGRect(origin: .zero, size: want.size)
                hosted?.frame = CGRect(origin: .zero, size: want.size)
                content?.layoutSubtreeIfNeeded()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        geometryWatchdog = timer
    }

    private func stopGeometryWatchdog() {
        geometryWatchdog?.invalidate()
        geometryWatchdog = nil
    }

    func teardown() {
        lockPresence.stop()
        pointer.stop()
        stopGeometryWatchdog()
        if let pinnedClickMonitor {
            removeOutsideClickMonitor(pinnedClickMonitor)
            self.pinnedClickMonitor = nil
        }
        // Explicitly, not by the sink that normally gives it up: the sinks go
        // with `cancellables` below, and a registration left behind would
        // keep Escape from every app for the rest of the session.
        escapeHotKey?.unregister()
        escapeHotKey = nil
        // The same, and for the same reason: a Delete left registered is the
        // person's Delete taken in every app.
        deleteKey.teardown()
        stores.stop()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        // Nothing is on screen any more, whatever the views report on the way
        // out: no batch may outlive the panel.
        stores.lyricTranslation.resetDemand()
    }

    /// Plays out `verdictForDeliberateOpen` for a commanded open — a hot key, a
    /// Shortcut, the Translate service — and says whether it may go on.
    ///
    /// One place, because there are five of these commands and the dark
    /// display was the second condition they all had to learn: each used to
    /// ask the verdict and shake by itself, and none of them knew the screens
    /// were asleep, so an automation that ran with the lid shut opened a
    /// pinned panel nobody could see and started the media clock for it
    /// (J-026). Over the shield the refusal is the pill's shake; on a dark
    /// display it is nothing at all, because there is nothing to see it.
    private func admitsCommandedOpen(_ vm: NotchViewModel) -> Bool {
        switch vm.verdictForDeliberateOpen(screensAsleep: screensAreAsleep) {
        case .proceed:
            return true
        case .refuseWithShake:
            vm.nudgeLockedIsland()
            return false
        case .refuseQuietly:
            geometryTrace("command refused: screens asleep")
            return false
        }
    }

    /// Opens on the lyrics stage (spec §19.6).
    ///
    /// The same shape as `translateCommanded(_:)` and for the same reasons:
    /// refused over the shield before anything is touched, and pinned open
    /// because the pointer that asked for it is on the keyboard rather than on
    /// the notch.
    /// Pressing it again turns the stage back into the player rather than
    /// doing nothing, so one key is the whole round trip.
    func toggleLyrics() {
        guard let vm = viewModel else { return }
        guard admitsCommandedOpen(vm) else { return }
        // Pressed again with the stage up, it turns back into the player: one
        // key is the whole round trip, and the panel is left open on the music
        // it was opened for.
        if vm.isOpen, vm.surface == .stage {
            vm.hideLyrics()
            return
        }
        openOnLyrics(vm)
    }

    /// The Show Lyrics intent: `toggleLyrics()` without the fold-back.
    ///
    /// The toggle is right for a key — one key is the whole round trip — and
    /// wrong for a Shortcut or a Focus automation called *Show*, which ran on a
    /// panel already showing the words and folded them away (F-024).
    ///
    /// `pin: false` is the island menu's row on a panel already open; see
    /// `performMenu`.
    func showLyrics(pin: Bool = true) {
        guard let vm = viewModel else { return }
        guard admitsCommandedOpen(vm) else { return }
        guard NotchViewModel.showLyricsVerdict(isOpen: vm.isOpen, surface: vm.surface) == .open else { return }
        openOnLyrics(vm, pin: pin)
    }

    /// The open half of `toggleLyrics()`, shared with `showLyrics()` so the
    /// two cannot open the page in two different ways.
    private func openOnLyrics(_ vm: NotchViewModel, pin: Bool = true) {
        peekWork?.cancel()
        vm.isPeeking = false
        // Through `choose`, so a press during the first-run welcome retires
        // it and the stage shows now. Through `open` it went up behind the
        // welcome and appeared only after Get Started, a lyrics page nobody
        // remembered asking for (J-018).
        vm.openStage()
        // Pinned, like ⌃⌥⌘I and for the same reason: the hand that pressed it is
        // on the keyboard, not on the notch, and an unpinned panel nobody is
        // hovering folds a third of a second after it appears. Lyrics are read
        // for the length of a song, which is the longest any of these stays up.
        if pin { vm.isPinnedOpen = true }
        setOpen(true)
        pointer.setInside(true, grace: pin ? 0 : NotchMetrics.menuReturnGrace)
        updatePinnedClickMonitor()
    }

    /// ⌃⌥⌘V: Clipboard, with the caret in its search, from whatever app is in
    /// front (spec §19.8). Pressed again on Clipboard it closes, so one key is
    /// the whole round trip, as ⌃⌥⌘L is for the stage.
    func toggleClipboard() {
        guard let vm = viewModel else { return }
        if vm.isOpen, vm.presented == .clipboard {
            setOpen(false)
            // The pointer may stand on the folding panel; see
            // `PointerWatcher.closedByHand()`.
            pointer.closedByHand()
            updatePinnedClickMonitor()
            return
        }
        openCommanded(.clipboard)
    }

    /// A secondary click at `point`, in the content view: the island's menu,
    /// the locked island's shake, or nothing of the island's (spec §19.9).
    private func secondaryClicked(at point: NSPoint) -> Bool {
        guard let vm = viewModel, let rootView else { return false }
        switch IslandMenu.secondaryClick(
            at: point, active: rootView.activeRect, bubble: rootView.bubbleRect,
            isOpen: vm.isOpen, isLocked: vm.isLockedPresentation,
            headerHeight: vm.geometry.notchSize.height
        ) {
        case .passThrough:
            return false
        case .shake:
            vm.nudgeLockedIsland()
            return true
        case .menu:
            // A paused song still has words to show, so Lyrics follows the
            // song, not the play state.
            let items = IslandMenu.items(
                bindings: HotKeyCenter.shared.bindings, hasSong: vm.media.track != nil
            )
            // Read before the menu tracks: a row's open is pinned only from
            // the closed island (see `performMenu`).
            let fromOpenPanel = vm.isOpen
            let menu = IslandMenu.menu(items) { [weak self] kind in
                self?.performMenu(kind, fromOpenPanel: fromOpenPanel)
            }
            // Returns once a row is chosen or the menu is dismissed: AppKit
            // tracks it in its own loop.
            menu.popUp(positioning: nil, at: point, in: rootView)
            return true
        }
    }

    /// A row of the island's menu. From the closed island the row is the
    /// whole gesture and the open is pinned, as a command's is. From the
    /// header of a panel already open the pointer stays in charge (§19.1's
    /// closing rule): pinned, the panel ignored the pointer leaving and held
    /// Escape system-wide until a click elsewhere (R8 review F3). The menu's
    /// return grace covers a row that hung below the body.
    ///
    /// The panel's state is read again at the row as well: Open on Hover can
    /// open it behind a menu popped from the closed island, and that open is
    /// the pointer's (R-5).
    func performMenu(_ kind: IslandMenuItem.Kind, fromOpenPanel: Bool) {
        let pin = !(fromOpenPanel || viewModel?.isOpen == true)
        switch kind {
        case .clipboard: openCommanded(.clipboard, pin: pin)
        case .translateClipboard: translateCommanded(NSPasteboard.general.string(forType: .string))
        case .shelf: openCommanded(.tray, pin: pin)
        case .lyrics: showLyrics(pin: pin)
        case .settings: openCommanded(.settings, pin: pin)
        case .quit: NSApp.terminate(nil)
        case .separator: break
        }
    }

    /// Opens on `surface` the way a command does: refused over the shield
    /// like every command, and pinned, because the hand that asked is on a
    /// menu or a key rather than resting on the notch — the chosen row can sit
    /// below the open body, and an unpinned panel would fold as it opened.
    /// Through `choose`, so a menu row during the first-run welcome retires it.
    ///
    /// Unpinned (`pin: false`, a menu row on an open panel), the pointer gets
    /// the menu's return grace here as well as from `MenuTracking`: which of
    /// the two runs first — the row's action or the menu's close — is
    /// AppKit's, and a grace given there would otherwise be taken back here.
    func openCommanded(_ surface: NotchViewModel.Surface, pin: Bool = true) {
        guard let vm = viewModel, admitsCommandedOpen(vm) else { return }
        peekWork?.cancel()
        vm.isPeeking = false
        vm.choose(surface)
        if pin { vm.isPinnedOpen = true }
        setOpen(true)
        pointer.setInside(true, grace: pin ? 0 : NotchMetrics.menuReturnGrace)
        updatePinnedClickMonitor()
    }

    /// Escape, or Return on a Clipboard row: the keyboard folds the panel
    /// with the pointer perhaps resting on it. Not a plain `setInside(false)`
    /// — the open body's rect is still cut while the panel folds, so the
    /// resting pointer read as an arrival and, with Open on Hover on,
    /// reopened the island 50 ms later (R8 review F2); see
    /// `PointerWatcher.closedByHand()`.
    func closeFromKeyboard() {
        setOpen(false)
        pointer.closedByHand()
    }

    /// Opens on Translate with this text already in it — or, with no text (an
    /// image on the clipboard), on Translate saying so. It used to
    /// return without a trace on no text, which looked exactly like a shortcut
    /// that was not registered (F-040).
    func translateCommanded(_ text: String?) {
        guard let vm = viewModel else { return }
        // Refused over the shield, before the translator, the surface or
        // `setOpen` is touched: this route would open the panel over the
        // password field and then make it key through `open(.translate)` — a window the lock
        // presentation deliberately lifted above the shield, holding the
        // keyboard in front of the password field, the exact hazard
        // `panel.onPress` refuses for the same reason. Refused quietly, too,
        // on a dark display (J-026).
        guard admitsCommandedOpen(vm) else { return }
        peekWork?.cancel()
        vm.isPeeking = false
        // Cut to the limit before anything — the field, the pane's measuring,
        // an engine — sees it: a multi-megabyte clipboard used to stall the
        // main thread for over a second (J-017). The view model then puts it
        // in the field, covered, and raises the keyboard through the surface
        // change: set directly, the surface changed without ever raising
        // `wantsKeyboard`, and the panel showed a text field whose keystrokes
        // went to the app underneath.
        vm.receiveCommandedTranslation(Translator.prepareCommandInput(text))
        setOpen(true)
        // The pointer is wherever the user left it, which is not on the notch,
        // so both halves of the close rule are held off for the same span: the
        // sampler's own tick and the deferred collapse check below. Granting
        // the grace and then scheduling a 0.6 s collapse meant the translation
        // still vanished before it could be read — just slightly later.
        pointer.setInside(true, grace: NotchMetrics.translateReadDelay)
        // Held open by the pointer rule like any other surface, so it folds when
        // the user moves away — a translation they walked away from is done.
        scheduleCollapseIfPointerAway(after: NotchMetrics.translateReadDelay)
    }

    /// Settings changed something the pointer machinery holds a copy of.
    /// Settings changed the body width.
    ///
    /// The geometry is read once when the panel is built, so the panel is rebuilt
    /// rather than nudged — the same path a display change takes, and the only
    /// one known to leave the window, the active rect and the hover rects all
    /// agreeing with each other afterwards.
    func refreshGeometry() {
        rebuild()
    }

    /// The island was clicked — the collapsed pill, or the header strip that is
    /// all of the island that shows while the panel is open.
    ///
    /// A toggle: open, then shut again by the same gesture on the same surface.
    /// Refused with a shake while the Mac is locked: the island stays visible
    /// over the shield on purpose, and a click there has to say *not here*
    /// rather than either opening over the password field or doing nothing at
    /// all, which reads as a dead app rather than a decision.
    /// `opening` is what was clicked: the bubble opens the tray, the island
    /// what it shows (`NotchViewModel.islandClick`) — or, on an alert, folds
    /// it. Internal rather than private so a test can click without a panel.
    func islandClicked(opening surface: NotchViewModel.Surface? = nil) {
        guard let vm = viewModel else { return }
        // Diagnostic, behind DI_GEOM=1: the third line of the click trail, so
        // a gesture that fired reads here as refused, closed, or opened.
        geometryTrace("click open=\(vm.isOpen ? 1 : 0) locked=\(vm.isLockedPresentation ? 1 : 0)")
        if vm.isLockedPresentation {
            vm.nudgeLockedIsland()
            return
        }
        // A second click closes. The click that opens and the click that closes
        // are the same gesture on the same surface — guarding the open state
        // here meant the island could be opened by clicking it and then not
        // closed by clicking it, which reads as the app having stopped
        // listening. Walking away closes it too; see `clickOpened`.
        if vm.isOpen {
            // `setOpen(false)` drops the pin and retires the click monitor with
            // it, and it cannot early-return here — `vm.isOpen` was just read as
            // true. Writing either again would be a third copy of an invariant
            // that only needs two.
            setOpen(false)
            // Not a plain `setInside(false)`. `openRect` is still cut for the
            // open body until `collapse()` shrinks it a moment later, so the
            // pointer that just clicked sits inside it: with Open on Hover on,
            // the next sample read an arrival, waited `openDelay`, and reopened
            // the panel ~50 ms after this click shut it — click to close did
            // nothing but make the island fold and unfold.
            pointer.closedByHand()
            return
        }

        // An alert folds rather than opening anything (spec §19.1): the island
        // returns to what is live, and the next click opens that.
        if surface == nil, vm.islandClick == .foldAlert {
            foldAlert()
            return
        }

        // Everything the hover route used to do, in the same order, so a click
        // opens the panel the way a hover did rather than by a second path that
        // merely ends up open too. The surface, the lift and the pin are the
        // view model's — `clickOpened` — and the panel's own machinery is here.
        // On the island it clicked, or on the body that is opening — measured
        // for that body, not the one shown last (R8 review F1).
        let point = pointerLocation()
        let island = pointer.islandRect
        vm.clickOpened(opening: surface) { body in
            vm.geometry.hoverRect(for: body).contains(point) || island.contains(point)
        }
        // Before `setOpen`, not after. Telling the watcher afterwards let it
        // re-enter `onChange` mid-expansion and re-run the open path against a
        // panel that was already opening.
        pointer.setInside(true)
        setOpen(true)
        updatePinnedClickMonitor()
    }

    /// Whether the cursor is standing where the open panel holds itself open
    /// from.
    ///
    /// The same rule the watcher closes on — the body as drawn and as the
    /// watcher still has it cut, the island the panel opened from until the
    /// pointer reaches the body, and the body it shrank from while that holds —
    /// asked of the watcher, so the answer cannot drift from the rule it stands
    /// in for. The body alone stopped containing the collapsed island in R8,
    /// when surfaces took their own widths: the peek is wider than the player
    /// it opens (R8 review F1). And a copy of the rule without the shrink
    /// folded the island 0.6 s after a dot to Music had dropped Clipboard's
    /// keyboard, with the pointer still on the dot (review 5, S2).
    private var pointerIsOnOpenPanel: Bool {
        guard let vm = viewModel else { return false }
        let point = pointerLocation()
        return vm.geometry.hoverRect(for: vm.openBodySize).contains(point)
            || pointer.closeRect.contains(point)
            || pointer.holdsBeyondBody(at: point)
    }

    /// Test seam: where the pointer is, in screen coordinates.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    func refreshPointerTuning() {
        pointer.openDelay = NotchViewModel.hoverOpenDelay
    }

    /// The ⌃⌥⌘I hotkey, `presentWelcome()` on a fresh account, the
    /// `DI_OPEN_PANEL` verification hook, and the open half of `show()`. (The
    /// Translate service opens through `translateCommanded(_:)`, which sets its
    /// own tab and its own grace, not here.)
    ///
    /// Opens until something closes it — the same command again, Escape, a
    /// click outside, or another app coming to the front (⌘-Tab) — rather than
    /// until the next pointer sample, which is what folded it a third of a
    /// second after it appeared and made the keyboard route to the panel
    /// unusable.
    func toggle() {
        guard let viewModel else { return }
        // Refused over the shield, before the pin or `setOpen` is touched: an
        // open there would grow the clickable region from the deliberate
        // pill-sized locked rect to the open body, over the password field. The
        // shake is the same refusal the island's own click gives — and
        // `presentWelcome()` keeps its own silent guard, so the welcome never
        // reaches here while locked.
        guard admitsCommandedOpen(viewModel) else { return }
        // `setOpen`'s close path defers the `isOpen` mutation to the next run
        // loop pass, so reading `viewModel.isOpen` right after calling it would
        // read the stale, pre-close value. Capture the intended target state
        // once, up front, and use that for both calls.
        let opening = !viewModel.isOpen
        viewModel.isPinnedOpen = opening
        setOpen(opening)
        if opening {
            pointer.setInside(true)
        } else {
            // The same hazard as the second click on the island: ⌃⌥⌘I can be
            // pressed with the pointer standing on the panel, and the rect an
            // arrival is measured against is still the open body's while the
            // panel folds. See `PointerWatcher.closedByHand()`.
            pointer.closedByHand()
        }
        updatePinnedClickMonitor()
    }

    /// Show Isla, opening the app again from Spotlight or Finder while it
    /// runs, and a second copy handing over: `toggle()`'s open, and nothing
    /// when the panel is already open.
    ///
    /// Those three called the toggle, or nothing at all: the Shortcut closed a
    /// panel it was meant to show (F-024), and reopening the app did nothing
    /// visible, which for an app with no window reads as broken (F-023). An
    /// open panel is left exactly as it is — its tab and its pin — because
    /// whoever opened it is still reading it.
    func show() {
        guard let viewModel else { return }
        guard admitsCommandedOpen(viewModel) else { return }
        guard NotchViewModel.showVerdict(isOpen: viewModel.isOpen) == .open else { return }
        toggle()
    }

    /// The one visible moment on a fresh account: the body shows the welcome and
    /// the panel opens itself to show it.
    ///
    /// Here rather than in `AppDelegate` because the view model belongs to the
    /// panel — it is built inside `build()` and replaced by every rebuild — so
    /// the delegate holds the controller, not what the controller made.
    ///
    /// Through `toggle()`, which pins: the pointer is wherever the user left it
    /// at launch, and an unpinned panel nobody is hovering folds a third of a
    /// second after appearing, which is the same as never having opened. Pinned,
    /// it closes the way every commanded open closes — Escape, a second click on
    /// the island, a click in another app, or switching to one.
    func presentWelcome() {
        guard let viewModel else { return }
        // Not over the shield. The island is deliberately inert while the Mac is
        // locked, so a welcome there could neither be read nor dismissed —
        // better to spend the moment on the next launch, which is what leaving
        // the flag unset does.
        guard !viewModel.isLockedPresentation else { return }
        // Nor on a dark display, for the same reason and one more: `toggle()`
        // now refuses there (J-026), so raising the flag first would leave the
        // welcome waiting under whatever the panel is next opened for at wake
        // — the very hazard the guard below exists for.
        guard !screensAreAsleep else { return }
        // Only onto a panel this opens itself. A drag onto the island, or a click
        // on it, can have opened the panel inside the 0.8 s delay this is called
        // after, and the flag is the welcome: raising it over that panel drew the
        // welcome on top of whatever it had been opened for — a file dropped on
        // the island half a second after login lost `ShelfPane`'s drop highlight
        // mid-drag to a pane nobody had asked for. Skipping only the `toggle()`
        // left exactly that, which is the same defect `71d414f` fixed in the
        // other ordering. Unset, the moment is spent on the next launch instead:
        // `hasCompletedFirstRun` is still false, so it is still owed.
        guard !viewModel.isOpen else { return }
        viewModel.isShowingWelcome = true
        toggle()
    }

    /// Keeps the outside-click watch alive exactly while the panel is holding
    /// itself open — which since the teleprompter went on 2026-08-22 means the
    /// pin and nothing else (`holdsOpen` is now just `isPinnedOpen`). It is a
    /// state the pointer cannot end, and it promises a click outside will.
    private func updatePinnedClickMonitor(selectionIsCurrent: Bool? = nil) {
        // Also watched while a Shelf tile is selected on an open panel, pinned
        // or not (re-review 2026-10-15): clicking into Mail leaves Mail the
        // active app (this panel never activates, so no activation notification
        // fires), and with the pointer resting over the grid the transient
        // Delete key then ate the next ⌫ and removed the tile. A mouse-down
        // outside the panel ends the selection; global mouse monitors need no
        // Accessibility permission, unlike key monitors.
        //
        // `selectionIsCurrent` is the value a `$shelfSelectionIsCurrent` sink was
        // handed: `@Published` announces before it stores, so re-reading the
        // property there saw the old value and the first selection never
        // installed the watch (re-review 2026-10-15, Codex P1).
        let selected = selectionIsCurrent ?? (viewModel?.shelfSelectionIsCurrent == true)
        let wanted = viewModel?.holdsOpen == true || (viewModel?.isOpen == true && selected)
        if wanted, pinnedClickMonitor == nil {
            pinnedClickMonitor = installOutsideClickMonitor { [weak self] in
                MainActor.assumeIsolated { self?.outsideMouseDown() }
            }
        } else if !wanted, let monitor = pinnedClickMonitor {
            removeOutsideClickMonitor(monitor)
            pinnedClickMonitor = nil
        }
    }

    /// Test seams: a test process must not register a real global monitor.
    var installOutsideClickMonitor: (@escaping @Sendable () -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in handler() }
    }
    var removeOutsideClickMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    /// A mouse-down in another application (this app never sees clicks on its
    /// own panel here). Drops the Shelf selection, which releases the Delete
    /// key, and ends a pin.
    func outsideMouseDown() {
        guard let vm = viewModel else { return }
        vm.shelf.clearSelection()
        if vm.holdsOpen {
            // Whatever was holding the panel open is over.
            vm.isPinnedOpen = false
            setOpen(false)
            // Deliberate, like the other two closes: the click landed in
            // another app, but `openRect` reaches past the region this
            // panel takes clicks in, so the pointer that made it can be
            // inside the rect an arrival is measured against.
            pointer.closedByHand()
        }
        updatePinnedClickMonitor()
    }

    /// Another app came to the front. Ends a pin the way a click in another app
    /// does, and for the same reason: ⌘-Tab is that click, made from the
    /// keyboard. Before this a pinned panel outlived every switch of app that
    /// did not involve the mouse.
    private func applicationActivated(_ pid: pid_t?) {
        guard let vm = viewModel, let pid,
              vm.appActivated(ownPID: ProcessInfo.processInfo.processIdentifier, activatedPID: pid)
        else { return }
        vm.isPinnedOpen = false
        setOpen(false)
        // The pointer may be anywhere, including inside the rect an arrival is
        // measured against while the panel folds. See
        // `PointerWatcher.closedByHand()`.
        pointer.closedByHand()
        updatePinnedClickMonitor()
    }

    /// Holds Escape while a pinned panel without the keyboard stands, and
    /// gives it back the moment it does not.
    ///
    /// Takes the three published values as they arrive rather than reading the
    /// model: `@Published` emits before the property is written, so the model
    /// still holds the old value inside the sink. Whether the app is active is
    /// read live — it is not the model's, and it changes only through the two
    /// notifications that call this.
    private func updateEscapeHotKey(pinned: Bool, panelHasKeyboard: Bool, locked: Bool) {
        let wanted = NotchViewModel.claimsEscape(
            pinned: pinned,
            panelHasKeyboard: panelHasKeyboard,
            appIsActive: appIsActive(),
            locked: locked,
            menuOpen: menuTracking.hasOpenMenus
        )
        if wanted, escapeHotKey == nil {
            // Plain Escape, no modifiers. A combination macOS refuses leaves
            // the panel as it was before this existed — closed by the hot key
            // again or a click elsewhere — and says so in the log rather than
            // pretending.
            escapeHotKey = escapeKeyRegistrar { [weak self] in
                self?.escapeHotKeyPressed()
            }
            if escapeHotKey == nil { Log.app.error("macOS refused the transient Escape hot key") }
        } else if !wanted, let registration = escapeHotKey {
            registration.unregister()
            escapeHotKey = nil
        }
    }

    /// Escape, caught by the transient hot key: the same two steps
    /// `NotchPanel.sendEvent` takes when the panel is key — a pane that wants
    /// it first, then the fold — so the key means the same thing whichever
    /// route delivered it.
    private func escapeHotKeyPressed() {
        guard let vm = viewModel, let panel else { return }
        // Asked again rather than trusted: the press can be queued behind the
        // event that just ended the claim.
        guard NotchViewModel.claimsEscape(
            pinned: vm.isPinnedOpen,
            panelHasKeyboard: vm.wantsKeyboard,
            appIsActive: appIsActive(),
            locked: vm.isLockedPresentation,
            menuOpen: menuTracking.hasOpenMenus
        ) else { return }
        if panel.escapeHandled?() == true { return }
        panel.onEscape?()
    }

    /// Holds Delete and ⌘⌫ or lets them go. Takes every input as it arrives —
    /// see the sink in `build` for why not from the model — and reads only
    /// whether the app is active live, since that is not the model's and
    /// changes through the two notifications that call `refreshDeleteKey`.
    private func updateDeleteKey(open: Bool, onShelf: Bool, pointerOnShelf: Bool, hasSelection: Bool, locked: Bool) {
        deleteKey.update(wanted: NotchViewModel.claimsDelete(
            panelOpen: open, onShelf: onShelf, pointerOnShelf: pointerOnShelf,
            hasSelection: hasSelection, appIsActive: appIsActive(), locked: locked
        ))
    }

    /// The same, from the model's stored values — for a caller that fires after
    /// they are written (a notification), never from a `@Published` sink.
    func refreshDeleteKey() {
        guard let vm = viewModel else { return deleteKey.teardown() }
        updateDeleteKey(
            open: vm.isOpen, onShelf: vm.presented == .tray,
            pointerOnShelf: vm.isPointerOnShelf, hasSelection: vm.shelfSelectionIsCurrent,
            locked: vm.isLockedPresentation
        )
    }

    /// Delete, caught by the transient hot key: removes the Shelf's selection
    /// — the cards, never the files — and nothing else. The claim is asked
    /// again first, as the Escape key's is: a press can be queued behind the
    /// very event that ended it, and a press that arrives with no claim gives
    /// the keys back instead of acting.
    func deleteKeyPressed() {
        guard let vm = viewModel else { return deleteKey.teardown() }
        guard NotchViewModel.claimsDelete(
            panelOpen: vm.isOpen, onShelf: vm.presented == .tray,
            pointerOnShelf: vm.isPointerOnShelf, hasSelection: vm.shelfSelectionIsCurrent,
            appIsActive: appIsActive(), locked: vm.isLockedPresentation
        ) else { return deleteKey.teardown() }
        vm.shelf.removeSelected()
    }

    /// Cuts the sampler's tray rect for the body on screen, or empties it.
    /// `surface` is passed by a caller that runs inside a `$surface` sink,
    /// where the model still holds the old one.
    private func updateShelfZone(open: Bool, size: CGSize, surface: NotchViewModel.Surface? = nil) {
        guard let vm = viewModel, open, (surface ?? vm.surface) == .tray, !vm.isShowingWelcome,
              !vm.isDropTargeted, !vm.isLockedPresentation else {
            pointer.shelfRect = .zero
            return
        }
        let body = vm.geometry.contentRect(for: size)
            .offsetBy(dx: vm.geometry.windowFrame.minX, dy: vm.geometry.windowFrame.minY)
        pointer.shelfRect = ShelfLayout.pointerZone(
            bodyScreenRect: body, headerHeight: vm.geometry.notchSize.height
        )
    }

    // MARK: - Construction

    private func rebuild() {
        // Carried across, because a display change is not a decision to throw
        // away what the panel was showing. The stores themselves already
        // survive — they belong to the session, not the panel — so this is
        // only the panel's own state.
        let previousSurface = viewModel?.surface
        // And where the pages were: the page the bare notch opens and where
        // Settings' close button goes back to (R8b review F9).
        let previousPlace = viewModel?.place
        // The old pages to rest, so their display link stops with them: the
        // link holds its target, and nothing else would ever end it.
        viewModel?.pageTravel.finish()
        let wasOpen = viewModel?.isOpen ?? false
        let wasShowingWelcome = viewModel?.isShowingWelcome ?? false
        // The pin belongs to the panel being torn down; the monitor watching
        // for its exit has to go with it, or it outlives every rebuild.
        viewModel?.isPinnedOpen = false
        updatePinnedClickMonitor()
        // Before the sinks that drive it are dropped with `cancellables`
        // below: the old panel's claim is over whatever it said, and the new
        // one makes its own when it has a pointer and a selection.
        deleteKey.teardown()
        pointer.shelfRect = .zero
        peekWork?.cancel()
        collapseCheckWork?.cancel()
        pointer.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        // A recording in the Settings pane being torn down would otherwise
        // depend on SwiftUI calling that row's `onDisappear` when the content
        // view goes, which AppKit hosting does not promise, and with the
        // recording stuck every shortcut stays unregistered.
        HotKeyCenter.shared.endRecording()
        // Out of the lock-screen space before it goes, if it is in one. The
        // replacement is lifted again below when the Mac is still locked.
        lockPresence.release(panel)
        panel?.orderOut(nil)
        // Demand the old content registered is dropped here, not left to its
        // `onDisappear` (which the line below does not promise): see
        // `LyricTranslation.resetDemand` (review 2026-10-15).
        stores.lyricTranslation.resetDemand()
        panel?.contentView = nil
        panel = nil
        rootView = nil
        viewModel = nil
        build(restoring: previousSurface, place: previousPlace, wasOpen: wasOpen, showingWelcome: wasShowingWelcome)
    }

    private func build(
        restoring restoredSurface: NotchViewModel.Surface? = nil,
        place: NotchViewModel.Place? = nil,
        wasOpen: Bool = false,
        showingWelcome: Bool = false
    ) {
        guard let geometry = NotchGeometry.current() else { return }
        buildGeneration += 1
        let vm = NotchViewModel(geometry: geometry, stores: stores)
        // Before any rect is cut. The surface decides how far down and how
        // wide the panel reaches, and restoring it afterwards left every rect
        // cut for the default body — so a restored 400 pt surface opened with a
        // close rect drawn for a shorter one, and folded under a pointer
        // resting in its lower half.
        if let restoredSurface { vm.surface = restoredSurface }
        // After the surface, whose own setting records where the gear goes
        // back to; see `restorePlace`.
        if let place { vm.restorePlace(place) }
        // Carried across for the same reason as the surface, and it is the more
        // fragile of the two: the welcome is shown once per account, so dropping
        // it here did not merely lose a pane — it spent the account's one moment
        // on nothing at all. Plugging in a display mid-read is the obvious way
        // in; the one that actually bit is a fresh login, where the display
        // arrangement is still settling in the same second `presentWelcome()`
        // fires, so a rebuild lands just after the flag is raised and the
        // welcome is gone before anybody could have read it.
        //
        // Not in tension with `setOpen(false)` lowering it: that is the panel
        // *ending* — Escape, a click in another app, the screen sleeping — and
        // the moment ends with it. A rebuild is the same panel made again, so
        // whatever it was showing is still owed. If the reopen at the bottom of
        // this method does not fire, because the pin went with the old panel and
        // the pointer is elsewhere, the welcome waits for the next open of this
        // launch rather than being silently spent.
        vm.isShowingWelcome = showingWelcome
        vm.onIslandClick = { [weak self] in self?.islandClicked() }
        vm.onBubbleClick = { [weak self] in self?.islandClicked(opening: .tray) }
        viewModel = vm

        let panel = NotchPanel(contentRect: geometry.windowFrame)
        let root = NotchStage.make(viewModel: vm, windowSize: geometry.windowSize).root

        // Entering draws the edge, leaving takes it away. The shake used to
        // fire here, which spent the refusal on a gesture that had not asked
        // for anything yet — a pointer crossing the top of a locked screen is
        // not a request to open the island.
        root.onLockedHover = { [weak self] entered in
            self?.viewModel?.isHovering = entered
        }
        root.onDragEntered = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            // A card dragged out of the tray crossing its own panel is not a
            // file arriving: turning the tray into the drop surface under it
            // would take away the place it came from (and the drop is refused,
            // `acceptDrop`).
            guard !ShelfDragSource.isDraggingOut else { return }
            // The drop surface is presented over whatever is chosen — the
            // welcome too — and comes off it when the drag ends (spec §19.7).
            // A drag that found the island shut opened it, and shuts it again.
            if !vm.isOpen { self.dragOpenedPanel = true }
            vm.isDropTargeted = true
            self.setOpen(true)
        }
        // Which well the drag is over (spec §8.3). The pointer's place in the
        // window becomes a place in the body, and the body's own rule says
        // which action a release there takes. Published only when it changes:
        // the system reports every move, and each publish redraws the pane.
        root.onDragMoved = { [weak self] point in
            guard let self, let vm = self.viewModel else { return }
            let body = vm.geometry.contentRect(for: vm.openBodySize)
            let target = ShelfDropTarget.target(
                atBodyPoint: ShelfDropTarget.bodyPoint(windowPoint: point, contentRect: body),
                bodyWidth: vm.openBodySize.width, notchHeight: vm.geometry.notchSize.height
            )
            if vm.shelfDropTarget != target { vm.shelfDropTarget = target }
        }
        root.onPromisedDrop = { [weak self] in
            guard let vm = self?.viewModel else { return false }
            let toAirDrop = vm.shelfDropTarget == .airDrop
            vm.shelfDropTarget = .keep
            return toAirDrop
        }
        root.onDragExited = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.isDropTargeted = false
            vm.shelfDropTarget = .keep
            self.endDropSurface()
        }
        root.promises = stores.promises
        root.onDrop = { [weak self] urls in
            guard let self, let vm = self.viewModel else { return false }
            vm.isDropTargeted = false
            // AirDrop's well sends and keeps nothing; anywhere else keeps.
            let target = vm.shelfDropTarget
            vm.shelfDropTarget = .keep
            if target == .airDrop {
                ShelfSharing.airDrop(urls, refusingOn: self.stores.shelf)
                self.endDropSurface()
                return true
            }
            let accepted = vm.acceptDrop(urls: urls)
            self.endDropSurface()
            return accepted
        }

        // Escape folds the panel from any surface. It used to be bound inside the
        // two panes that take the keyboard, which meant the teleprompter's
        // documented "ends three ways" was really one — its pane never held
        // the keyboard, so Escape never reached it and the pin outlived the
        // script.
        //
        // The panel only sees Escape while it is key, though, which outside
        // Translate it never is — so "any surface" was still false for the panels
        // that most needed it, the ones the keyboard opened (F-004). A pinned
        // panel now also reaches here through a transient hot key; see
        // `updateEscapeHotKey`. An unpinned one has the pointer on it, and the
        // pointer leaving is what closes it.
        // Delete and ⌘⌫ on a panel that is key: the Shelf's selection, and
        // nothing else's. The registered hot key covers the common case of a
        // panel that is not key; see `NotchPanel.removeKeyHandled`.
        panel.removeKeyHandled = { [weak self] in
            guard let vm = self?.viewModel, vm.presented == .tray,
                  !vm.isLockedPresentation, !vm.shelf.selection.isEmpty else { return false }
            vm.shelf.removeSelected()
            return true
        }

        panel.onEscape = { [weak self] in self?.closeFromKeyboard() }

        // Escape reaches the panes first, and only folds the panel if none of
        // them wanted it. Swallowing every Escape here made the two panes'
        // own handlers — the translator's "clear the field", the notes' "hand
        // the keyboard back" — unreachable code, and closed the whole panel
        // when Escape was pressed to cancel an input-method composition.
        panel.escapeHandled = { [weak self] in
            guard let vm = self?.viewModel else { return false }
            return vm.consumeEscape()
        }

        // ↑ ↓ move through Clipboard's list and Return copies the row and
        // closes (spec §19.8): asked before the search field, which has the
        // caret and would otherwise take the arrows to its own start and end.
        panel.listKeyHandled = { [weak self] key in
            guard let self, let vm = self.viewModel else { return false }
            switch vm.consumeListKey(key) {
            case .ignored:
                return false
            case .handled:
                return true
            case .handledAndClose:
                self.closeFromKeyboard()
                return true
            }
        }

        // ⌘, opens Settings from Clipboard or Translate (spec §19.1). Settings
        // takes no keyboard, so choosing it hands the keyboard back on its own
        // (`NotchViewModel.surface`). While a shortcut field records, ⌘, is the
        // shortcut being recorded, not a way somewhere: Settings is already up.
        panel.settingsKeyHandled = { [weak self] in
            guard let vm = self?.viewModel, vm.presented != .settings else { return false }
            vm.open(.settings)
            return true
        }

        // ⌃Tab and ⌃⇧Tab turn the page while the panel has the keyboard (spec
        // §19.16), and keep it there; see `NotchViewModel.turnPageByKey`.
        panel.pageKeyHandled = { [weak self] step in
            self?.viewModel?.turnPageByKey(step, reduceMotion: SystemAppearance.shared.reduceMotion) ?? false
        }

        // A right-click on the island, its bubble or an open surface's header
        // row opens the island's menu (spec §19.9); over the lock it shakes.
        panel.secondaryClickHandled = { [weak self] point in
            self?.secondaryClicked(at: point) ?? false
        }

        // ⇧⌘C copies the translation, which no responder owns: the caret is
        // in the source field, so ⌘C and ⇧⌘C both copied the source (H-018).
        panel.onCopyTranslation = { [weak self] in
            guard let vm = self?.viewModel else { return false }
            return vm.copyTranslationIfShowing()
        }

        panel.onPress = { [weak self] location in self?.pressed(atWindowPoint: location) }

        panel.contentView = root
        panel.ignoresMouseEvents = true
        panel.setFrame(geometry.windowFrame, display: false)
        panel.orderFrontRegardless()

        self.panel = panel
        self.rootView = root

        applyActiveRect(open: false)

        pointer.openRect = geometry.collapsedHoverRect(for: vm.bodySize.width)
        // The drawn shape, not the padded target: what lights is what you are on.
        pointer.hoverRect = geometry.collapsedIslandHoverRect(for: vm.bodySize.width)
        pointer.warmZone = geometry.warmZone
        pointer.coolZone = geometry.coolZone
        pointer.approachZone = geometry.approachZone
        // Cut for the surface that will be showing: a rebuild restores the
        // previous one, and the surfaces differ in width and height.
        pointer.closeRect = geometry.hoverRect(for: vm.openBodySize)
        // A real notch is a hole: nothing is under it, so opening the moment the
        // pointer arrives costs nothing. A synthetic one sits on a working menu
        // bar, and a pointer crossing the middle of it is usually on its way
        // somewhere else — unfolding the panel over what it was reaching for is
        // the whole complaint. Staying put is what asks for the panel.
        pointer.openDelay = NotchViewModel.hoverOpenDelay
        // Both directions of a drag, not just the incoming one. A file being
        // dragged *out* of the shelf never touches this view's dragging
        // destination callbacks, so the panel counted the pointer as away,
        // folded 0.32 s in, and tore down the very view the drag session was
        // still running from.
        //
        // Knowing about the outgoing drag was only half the fix, and this comment
        // claimed the whole one until 2026-09-10. The watcher closes down two
        // paths and only the already-outside one asked this question; the
        // departure from `closeRect` — the path a drag out actually takes — folded
        // the panel regardless, and became reachable the moment a click stopped
        // pinning. Both ask now: see `PointerWatcher.tick`.
        //
        // A press that began on the panel is a drag too, of a slider or the
        // scrubber, and it is held by the same rule (F-028): overshooting the
        // Panel Width slider past the edge used to make the window
        // click-through and fold the panel 0.32 s later, discarding the width
        // the slider had not committed yet. `pressIsHeld` checks the button as
        // well as the latch, so a release the panel never heard cannot leave
        // an invisible click-eating rect behind.
        pointer.isDragging = { [weak root, weak panel] in
            Self.holdsOpen(
                receivingDrag: root?.isReceivingDrag ?? false,
                draggingOut: ShelfDragSource.isDraggingOut,
                menuOpen: MenuTracking.shared.isOpen,
                pressHeld: panel?.pressIsHeld() ?? false,
                sheetAttached: panel?.attachedSheet != nil
            )
        }
        // A menu held the panel open while it tracked; once it closes, the row
        // that was chosen may have hung below the panel, so the pointer is
        // given a moment to come back before its absence counts — the same
        // grace a translation summoned from the keyboard gets, only shorter.
        MenuTracking.shared.onAllClosed = { [weak self] in
            guard let self, self.viewModel?.isOpen == true else { return }
            self.pointer.setInside(true, grace: NotchMetrics.menuReturnGrace)
        }
        MenuTracking.shared.start()
        pointer.isPanelOpen = { [weak vm] in vm?.isOpen ?? false }
        pointer.collapsedIsland = { [weak self] in self?.collapsedIslandScreenRect() ?? .zero }
        // Only while a shrink holds the panel (`PointerWatcher.shrunkFromRect`):
        // a press or a scroll in the app under where the old body was is the
        // person working there. A mouse monitor needs no permission.
        pointer.watchPressesElsewhere = { handler in
            NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { event in
                guard event.type != .scrollWheel
                    || PointerWatcher.startsAScroll(phase: event.phase, momentum: event.momentumPhase)
                else { return }
                handler()
            }
        }
        pointer.stopWatchingPresses = { NSEvent.removeMonitor($0) }
        // Only while the sampler idles (`PointerWatcher.updateMovementWatch`):
        // a move toward the notch ticks at once instead of on the next 125 ms
        // beat, so a quick flick and click is never a click on the menu bar.
        // Drags count as moves — a button held does not make the pointer slower.
        pointer.watchMovement = { handler in
            NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            ) { _ in handler() }
        }
        pointer.stopWatchingMovement = { NSEvent.removeMonitor($0) }
        pointer.onChange = { [weak self] inside in
            guard let self, let vm = self.viewModel else { return }
            // The edge is drawn from the shape's own `.onHover`, not from
            // here: this rect is padded for a forgiving open, and an edge lit
            // from it appears while the cursor is beside the island.
            //
            // What the crossing means is the view model's — `pointerCrossed`,
            // where it can be tested without a pointer. What it does to the
            // panel is this closure's. An arrival at the closed island lands on
            // Music: the island is for glancing at a track, and the other tabs
            // are somewhere to go once it is open, not somewhere to arrive. An
            // arrival on a panel already open keeps its tab. Deliberate routes still
            // choose their own tab — ⌃⌥⌘T lands on Translate, and a drag stays on
            // the Shelf, which is what `dragging` is for.
            switch vm.pointerCrossed(inside: inside, dragging: self.pointer.isDragging()) {
            case .opens: self.setOpen(true)
            case .closes: self.setOpen(false)
            case .standsAsItIs: break
            }
            // An arrival may have dropped the pin, and the monitor watching for
            // the click that would otherwise have ended it goes with it.
            self.updatePinnedClickMonitor()
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] interactive in
            self?.panel?.ignoresMouseEvents = !interactive
        }
        pointer.onHoverChange = { [weak self] hovering in
            guard let vm = self?.viewModel else { return }
            // Only while it is shut. An open panel has already answered the
            // pointer, and lifting its whole surface would be answering twice.
            vm.isHovering = hovering && !vm.isOpen
        }
        // The pointer on the Shelf pane, from the sampler (see
        // `NotchViewModel.isPointerOnShelf`). The rect is cut with the open
        // body (`updateShelfZone`) and empty whenever the Shelf is not showing,
        // which reports "off" at once.
        pointer.onShelfChange = { [weak self] onShelf in
            self?.viewModel?.isPointerOnShelf = onShelf
        }
        // Not in the dark. A rebuild can land while the display sleeps — an
        // external display that drops off the bus with it moves the notch
        // display's frame — and this restarted the sampler the sleep handler
        // had stopped, for the rest of the night. The wake handler starts it.
        if !screensAreAsleep { pointer.start() }

        // Each surface has its own size (spec §19.6–§19.8), so changing what
        // is presented changes how wide and how far down the panel reaches,
        // and both the clickable region and the region the pointer counts as
        // "on the panel" are cut from that — through the one path an open
        // uses, `refreshOpenRects`. The presented surface moves with the
        // surface chosen, the drop surface and the welcome laid over it, and
        // the song: the stage with no song is the empty player. A pass later:
        // `@Published` announces before it stores, and `openBodySize` reads the
        // stored values.
        vm.$surface.removeDuplicates().map { _ in () }
            .merge(with: vm.$isDropTargeted.removeDuplicates().map { _ in () })
            .merge(with: vm.$isShowingWelcome.removeDuplicates().map { _ in () })
            .merge(with: vm.media.$track.map { $0 == nil }.removeDuplicates().map { _ in () })
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let vm = self.viewModel, vm.isOpen else { return }
                    DispatchQueue.main.async { self.refreshOpenRects() }
                }
            }
            .store(in: &cancellables)

        // The media clock follows the surface while the panel is open: on for
        // the player and the stage, off for everything else (see
        // `mediaClockWanted`). Coming back to the player goes through
        // `setActive(true)` exactly as an open does, so the position is
        // recomputed from the anchor, the feed is asked again and the shuffle
        // and repeat switches are re-read — nothing drawn from a clock that
        // stood still while Settings was up. Reads the value the publisher
        // hands over, not `vm.surface`: `@Published` announces before it
        // stores. Closed or locked, the open and lock paths own the clock, and
        // a surface set before an open (the translate hot key) is read by the
        // open.
        vm.$surface
            .removeDuplicates()
            .sink { [weak self] surface in
                MainActor.assumeIsolated {
                    guard let vm = self?.viewModel, vm.isOpen, !vm.isLockedPresentation else { return }
                    vm.media.setActive(Self.mediaClockWanted(isOpen: true, surface: surface, locked: false))
                }
            }
            .store(in: &cancellables)

        // A track appearing or disappearing changes the collapsed shell's
        // width. Re-cut both pointer and hit-test regions after @Published has
        // committed the new value, without disturbing an already open panel.
        vm.media.$track
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)

        // The pill folds into the notch when a pause settles and comes back
        // when playback does — its width changes without the track appearing
        // or disappearing. Cut only for those, a folded pill left an invisible
        // pill-wide strip beside the notch taking the menu bar's clicks and
        // hover, and a pill brought back answered only across the notch.
        vm.$pauseHasSettled.removeDuplicates()
            .combineLatest(vm.media.$isPlaying.removeDuplicates())
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)

        // Peeking changes the collapsed pill's width, so the pointer and
        // hit-test regions have to be re-cut with it or the wider shell would
        // look interactive while only the old strip answered.
        vm.$isPeeking
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)
        // The charger or headphones widen the pill the same way.
        vm.$ambient
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)
        // And so does the volume pop-up — only when it appears or folds, not
        // with each press, which moves a bar and changes no width.
        vm.$hud
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)
        wireShelfIslandCuts(vm)
        wirePageTravelCuts(vm)

        // An alert that had to wait for the island — a surface open, files
        // dragged over it, the Mac locked — shows if the island comes free
        // inside its second (spec §19.1). A pass later: `@Published` announces
        // before it stores, and the queue reads the stored values.
        vm.$isOpen.removeDuplicates().map { _ in () }
            .merge(with: vm.$isDropTargeted.removeDuplicates().map { _ in () })
            .merge(with: vm.$isLockedPresentation.removeDuplicates().map { _ in () })
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.promoteWaitingAlert() }
            }
            .store(in: &cancellables)

        // Sneak peek: a new track shows itself, then gets out of the way.
        //
        // Keyed on the track's identity rather than on any of the fields that
        // describe it. A single skip publishes several snapshots in the space
        // of a hundred milliseconds — the immediate one, the settled echo, the
        // artwork — and peeking per snapshot is the flicker every app in this
        // category has shipped at least once.
        vm.media.$track
            .map { $0?.key }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] key in
                guard key != nil else { return }
                self?.sneakPeek()
            }
            .store(in: &cancellables)

        // The I-beam over the Translate editor (PTR-02). The rect goes to zero
        // with the surface, so the tracking area is re-cut on the same change
        // that swaps the pane.
        vm.$textInputRect
            .removeDuplicates()
            .sink { [weak self] rect in
                MainActor.assumeIsolated {
                    guard let root = self?.rootView else { return }
                    root.textRects = [NotchRootView.textRect(fromTopLeft: rect, windowHeight: root.bounds.height)]
                        .filter { !$0.isEmpty }
                }
            }
            .store(in: &cancellables)

        // Driven by the deliberate request, not by which surface is showing:
        // only a surface that types asks, and a click back into one asks again
        // (`panel.onPress`).
        vm.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
            }
            .store(in: &cancellables)

        // Escape for a pinned panel; see `wireEscapeClaim`.
        wireEscapeClaim(vm)
        wireShelfClaims(vm)
        // And let go of Escape while this app is active: Quick Look and AirDrop
        // activate it from a Shelf card, and their windows answer Escape.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let vm = self.viewModel else { return }
                    self.updateEscapeHotKey(
                        pinned: vm.isPinnedOpen,
                        panelHasKeyboard: vm.wantsKeyboard,
                        locked: vm.isLockedPresentation
                    )
                }
            }
            .store(in: &cancellables)

        // Clicking into another app drops the keyboard: there is no
        // click-outside to catch, but losing key status says the same. The tab
        // stays as it was — only the claim on the keyboard is dropped.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.viewModel?.wantsKeyboard = false }
            }
            .store(in: &cancellables)

        // A rebuilt panel starts closed. Reopen it only if it was open before
        // the rebuild, or if the pointer is on the *collapsed* target — the
        // one that means "open me". Testing the expanded body's hover rect
        // instead popped the panel open on any display change that happened to
        // find the cursor in the top-centre 644×220 of the screen, which is
        // where a document's own toolbar lives.
        let pointerOnTarget = geometry
            .collapsedHoverRect(for: vm.bodySize.width)
            .contains(NSEvent.mouseLocation)
        let pointerOnBody = geometry.hoverRect(for: vm.openBodySize).contains(NSEvent.mouseLocation)
        // And nothing opens on a dark display: an open panel starts the media
        // clock, and a cursor left resting on the notch is not somebody asking.
        if !screensAreAsleep, pointerOnTarget || (wasOpen && pointerOnBody) {
            pointer.setInside(true)
            setOpen(true)
        }

        // A rebuild can land mid-lock — plugging in a display does not wait
        // for the password. The fresh panel starts at the normal level with
        // its sampler running; dress it for the lock screen again, or the
        // pill vanishes from the shield at the exact moment a display
        // changes. Last, so it also undoes the reopen just above.
        if lockPresence.isLocked { screenLocked() }
        verifySyntheticNotch()
    }

    // MARK: - Open / close

    /// Hands the keyboard to the panel, or gives it back. Internal so a test
    /// can ask without a panel.
    ///
    /// Never over the lock, whoever asked: Clipboard's search field raises the
    /// claim directly when it takes focus, past `open(_:)`'s guard, and this
    /// route opens the panel and makes it key (R8 review F6).
    func setKeyboard(_ wants: Bool) {
        if wants {
            if let vm = viewModel, vm.isLockedPresentation {
                // Lowered again, a pass later — not here, inside the claim's
                // own publisher, where the write would land before the one
                // that raised it. Left raised, every later raise was a
                // duplicate the keyboard sink dropped (R-8).
                DispatchQueue.main.async { [weak vm] in vm?.wantsKeyboard = false }
                return
            }
            setOpen(true)
            pointer.setInside(true)
        }
        panel?.acceptsKeyboard = wants
        // A shortcut being recorded needs the keyboard it just lost, and the
        // Settings row that started it may not be told (see `rebuild`).
        if !wants { HotKeyCenter.shared.endRecording() }
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// The pointer decides, almost always. A field with something in it does
    /// not hold the panel open: it is opened by hovering, and anything that
    /// survives the pointer leaving has to be dismissed some other way, which
    /// is a second rule to learn for a panel that has exactly one. What was
    /// typed is kept, so coming back finds it where it was left.
    ///
    /// The pin is the single exception, and it is enforced where the pointer is
    /// read rather than here — see `NotchViewModel.holdsOpen`. It exists for
    /// the routes that open the panel with the pointer nowhere near it: ⌃⌥⌘I,
    /// the Translate service, and VoiceOver firing the island's accessibility
    /// action. A click on the island only pins when the pointer would land
    /// outside the open panel, which it normally does not.
    ///
    /// The teleprompter used to be the exception here and went on 2026-08-22.
    /// Everything else that closes the panel still closes it: the screen
    /// sleeping, the space changing, the display arrangement changing. A pinned
    /// panel surviving any of those would be one stuck open on a screen nobody
    /// is looking at.
    private func setOpen(_ open: Bool) {
        guard let vm = viewModel, vm.isOpen != open else { return }
        // Closing for any reason drops the pin: a panel that is shut is not
        // being held open.
        if !open {
            vm.isPinnedOpen = false
            updatePinnedClickMonitor()
            // The welcome lives exactly as long as the panel it opened. Left
            // standing, it would be waiting inside the *next* open too — click
            // the island to glance at a track and get the welcome again — for
            // the whole launch, since only Get Started or a tab retires it.
            // The flag is deliberately not set here: closing the panel is not
            // an answer, and the reasons a panel closes include the screen
            // going to sleep. Unanswered, the next launch asks again.
            vm.isShowingWelcome = false
        }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            // The view model ends the moment and the peek as `isOpen` flips
            // (F-033); their timers go here, so neither lands on a panel that
            // has since closed and folds a pill nobody asked to see.
            peekWork?.cancel()
            peekWork = nil
            ambientWork?.cancel()
            ambientWork = nil
            // The pop-up's own timer, with the flag the view model has ended. The
            // key keeps working with the panel open, and the player's slider is
            // where its volume shows; the permission is looked at again, since
            // the panel opening is one of the moments trust is re-read.
            hudFoldWork?.cancel()
            hudFoldWork = nil
            stores.hud.panelOpened()
            withAnimation(Theme.open(reduceMotion: SystemAppearance.shared.reduceMotion)) { vm.isOpen = true }
            // Only for the surfaces that draw the clock. Opening onto Settings
            // or the tray leaves it off; the surface sink in `build` starts it
            // the moment the player comes up, with the same re-anchoring an
            // open does.
            if Self.mediaClockWanted(isOpen: true, surface: vm.surface, locked: vm.isLockedPresentation) {
                vm.media.setActive(true)
            }
        } else {
            // The keyboard goes first and the fold goes second — one run-loop
            // pass apart, never together. Dropped in the same pass, resigning
            // the field's first responder and structurally removing that field
            // land in one transaction, and SwiftUI applies the state but loses
            // the repaint: the panel stands on screen fully expanded with
            // `isOpen` already false, wedged until the next hover repaints it.
            // That was the translate tab "hanging open" — type, move the
            // pointer away, and the picture stayed while the state closed.
            vm.wantsKeyboard = false
            let generation = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.collapse()
            }
        }
    }

    /// Runs the deferred half of closing right now, and cancels the one still
    /// in flight so it cannot land later on a panel that has moved on.
    ///
    /// For the transitions that reconfigure the panel in the same breath as
    /// closing it — locking is the only one — where a collapse arriving a pass
    /// late would undo the configuration it was supposed to precede.
    private func collapseNow() {
        openGeneration += 1
        closeActiveRectWork?.cancel()
        closeActiveRectWork = nil
        guard viewModel?.isOpen == true else { return }
        collapse(deferRectShrink: false)
    }

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse(deferRectShrink: Bool = true) {
        guard let vm = viewModel, vm.isOpen else { return }
        // Nothing counted open outlives the panel it was opened from.
        MenuTracking.shared.reset()
        // Whatever was uncovered by hand goes back under cover with the panel.
        // The next hover is the one nobody planned, and it must not open onto
        // a row somebody revealed ten minutes ago.
        vm.privacy.coverEverything()
        // Animated when the user is watching it fold, and not when they are
        // not. `deferRectShrink == false` is the lock path, where the panel is
        // about to be resized to the whole display and its content replaced by
        // the lock card: an open→closed animation still in flight across that
        // swap is what made the card and the pill slide in from the notch's
        // old position, at the old size, instead of simply being there.
        // The animated close is `Theme.close`, the open's spring a beat late,
        // so the body has faded before the shape's edge reaches it (H-012).
        if deferRectShrink {
            withAnimation(Theme.close(reduceMotion: SystemAppearance.shared.reduceMotion)) { vm.isOpen = false }
        } else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { vm.isOpen = false }
        }
        vm.media.setActive(false)
        // Off the Shelf the moment the panel folds, not when the rect shrinks
        // 0.45 s later: the zone would otherwise outlive the panel by that long
        // and a reopen elsewhere would find the pointer "still on it".
        pointer.shelfRect = .zero
        // The caller is reconfiguring the panel immediately after this — the
        // lock screen resizing it to the whole display and cutting its own
        // rect. A delayed shrink would land on top of that.
        guard deferRectShrink else {
            applyActiveRect(open: false)
            return
        }
        // Shrink only once the panel has finished collapsing. Doing it
        // while it is still visibly there would leave a window in which
        // clicks land on whatever is behind the panel.
        let work = DispatchWorkItem { [weak self] in
            self?.closeActiveRectWork = nil
            self?.applyActiveRect(open: false)
        }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.collapseRectShrinkDelay, execute: work)
    }

    private func scheduleCollapseIfPointerAway(after delay: TimeInterval = NotchMetrics.pointerAwayCollapseDelay) {
        // Stamped like every other deferred step in this file. A bare
        // `asyncAfter` from an earlier open stayed armed, so pressing ⌃⌥⌘T twice
        // a few seconds apart let the first timer fold the translation the
        // second one had just put on screen.
        collapseCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.collapseCheckWork = nil
            // A panel that has closed since has nothing to fold, and its
            // resync would undo `closedByHand()`: the pointer resting over
            // where the body was, counted inside against the old rect, kept
            // a hover from opening the island until it had left that rect
            // (R-6). The sampler owns a closed panel's pointer.
            guard vm.isOpen else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !self.pointerIsOnOpenPanel
            self.pointer.setInside(!away)
            if away, !vm.holdsOpen { self.setOpen(false) }
        }
        collapseCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The height the open rects are cut for: growing is immediate, so the
    /// pointer never falls through a region the animation has not covered yet,
    /// but shrinking waits for the body to stop. Collapse springs the body from
    /// 400 down to 208 over `Theme.expandSettle`, and the rects used to drop to
    /// 208 on the first frame: for that long the still-drawn lower part of the
    /// panel let every click through to the app beneath it, and a pointer
    /// resting there stood outside the close rect and folded the panel shut
    /// (review 2026-10-15). `bodySettled` is true on the pass scheduled for the
    /// end of the spring.
    nonisolated static func openRectHeight(applied: CGFloat?, target: CGFloat, bodySettled: Bool) -> CGFloat {
        guard let applied, target < applied, !bodySettled else { return target }
        return applied
    }

    /// The same for both sides: the surfaces differ in width as well as height
    /// (spec §19.6–§19.8), and the stage turning into the player narrows the
    /// shape by two hundred points on the island's spring. Each side grows at
    /// once and shrinks when the body has stopped.
    nonisolated static func openRectSize(applied: CGSize?, target: CGSize, bodySettled: Bool) -> CGSize {
        CGSize(
            width: openRectHeight(applied: applied?.width, target: target.width, bodySettled: bodySettled),
            height: openRectHeight(applied: applied?.height, target: target.height, bodySettled: bodySettled)
        )
    }

    /// How long a shrink of the open rects waits for the drawn body to stop.
    ///
    /// The hold used to be `Theme.expandSettle` (0.5 s) for every shrink. That
    /// is right while the body springs down (Expand to Collapse, a tab switch,
    /// a song ending), but under Reduce Motion the body crossfades in 0.24 s,
    /// so a 0.5 s hold left a strip of dead, click-swallowing panel for the
    /// better part of a quarter second after nothing was drawn there; and a
    /// change of height that is not animated at all (a display change re-cutting
    /// the rects) has nothing to wait for (review 2026-10-15).
    nonisolated static func shrinkHold(reduceMotion: Bool, animated: Bool) -> TimeInterval {
        guard animated else { return 0 }
        return reduceMotion ? Theme.reducedMotionDuration : Theme.expandSettle
    }

    /// The two sinks that keep the Shelf's Delete key and pointer zone true to the
    /// model, in one place so `attachForTesting` installs exactly what `build`
    /// does (review 2026-10-15: the tests called `refreshDeleteKey()` by hand and
    /// so never ran the wiring they were named for).
    /// The Shelf is a live activity (spec §19.1): the island grows out of the
    /// notch, or the bubble appears beside a song, when the Shelf becomes live
    /// — a file a person put there, or a collected file's moment — and goes
    /// back when it stops; and the bubble widens when the count gains a digit.
    /// Re-cut the clickable regions for each, a pass later so `@Published`
    /// has stored what it announced, and for nothing else: a ninth screenshot
    /// changes no outline. Read from the shelf the view model draws, so a test
    /// with stores of its own is cut against them.
    private func wireShelfIslandCuts(_ vm: NotchViewModel) {
        vm.shelf.$items
            .combineLatest(vm.$isShowingCollected)
            .map { NotchViewModel.shelfCut(items: $0, showingCollected: $1) }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)
    }

    private func wireShelfClaims(_ vm: NotchViewModel) {
        // Delete and ⌘⌫ for the Shelf, from every input of the claim at once
        // (`NotchViewModel.claimsDelete`). The values are the ones the
        // publishers hand over, never `vm`'s: `@Published` announces before it
        // stores, so the model still holds the old value inside the sink — the
        // mistake that would leave a registration standing for one change too
        // long. Any one input going false gives the keys back in this same
        // turn; there is no timer and no "later".
        vm.$isOpen.combineLatest(vm.$surface, vm.$isShowingWelcome)
            .combineLatest(vm.$isPointerOnShelf, vm.$shelfSelectionIsCurrent, vm.$isLockedPresentation)
            .sink { [weak self] base, pointerOnShelf, selection, locked in
                MainActor.assumeIsolated {
                    self?.updateDeleteKey(
                        open: base.0, onShelf: base.1 == .tray && !base.2,
                        pointerOnShelf: pointerOnShelf, hasSelection: selection, locked: locked
                    )
                }
            }
            .store(in: &cancellables)
        // A selection appearing or ending adds or drops the outside-click watch.
        vm.$shelfSelectionIsCurrent.removeDuplicates()
            .sink { [weak self] current in
                MainActor.assumeIsolated { self?.updatePinnedClickMonitor(selectionIsCurrent: current) }
            }
            .store(in: &cancellables)
        // Activation is the one input of the Delete claim that is not the
        // model's: Quick Look and AirDrop activate Isla from a Shelf card, and
        // while it is active its own windows answer Delete. Installed here, not
        // in `build`, so a test hears it through an injected center
        // (re-review 2026-10-15: the sink was build-only and the test called
        // `refreshDeleteKey()` by hand).
        activationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: activationCenter.publisher(for: NSApplication.didResignActiveNotification))
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDeleteKey() }
            }
            .store(in: &cancellables)
        // The tray's pointer zone follows the surface: cut for the tray's body
        // while it shows, empty on every other surface, and at once (not a pass
        // later like the rects) because it is what ends the Delete claim.
        vm.$surface
            .removeDuplicates()
            .sink { [weak self] surface in
                MainActor.assumeIsolated {
                    guard let self, let vm = self.viewModel else { return }
                    // The body the *new* surface asks for: `vm.openBodySize`
                    // still reads the old one inside this sink.
                    let size = SurfaceLayout.bodySize(
                        for: surface, bodyWidth: vm.geometry.expandedSize.width, notch: vm.geometry.notchSize
                    )
                    self.updateShelfZone(open: vm.isOpen && surface == .tray, size: size, surface: surface)
                }
            }
            .store(in: &cancellables)
    }

    /// The pages' travel (§19.16) re-cuts the open rects twice: as a leg
    /// begins, over every page it can reach (`openBodySize`), so the outline
    /// the fingers draw is never outside them and nothing is cut sixty times
    /// a second; and as it ends, back to the page's own. A leg that came to
    /// rest on its page has no spring left to wait for, so that shrink is
    /// immediate; one ended by Settings or the stage taking the panel shrinks
    /// as any surface change does, once the outline has followed. A pass
    /// later, as every surface change: `@Published` announces before it
    /// stores.
    private func wirePageTravelCuts(_ vm: NotchViewModel) {
        vm.pageTravel.$reachable
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] reachable in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let vm = self.viewModel, vm.isOpen else { return }
                        self.refreshOpenRects(animated: !reachable.isEmpty || !vm.presented.isPage)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Escape for a pinned panel, held while the pin stands and the panel
    /// is not key — see `NotchViewModel.claimsEscape`. Driven by the pin
    /// itself, so every way a pin ends gives Escape back with it: the fold,
    /// the pointer arriving (`pointerArrived()` clears it without going
    /// through the controller), the outside click, a rebuild. And re-read as
    /// one of the app's menus opens or the last one closes: while a menu
    /// tracks, Escape is the menu's (R8 review F4).
    private func wireEscapeClaim(_ vm: NotchViewModel) {
        vm.$isPinnedOpen
            .combineLatest(vm.$wantsKeyboard, vm.$isLockedPresentation)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] pinned, keyboard, locked in
                MainActor.assumeIsolated {
                    self?.updateEscapeHotKey(pinned: pinned, panelHasKeyboard: keyboard, locked: locked)
                }
            }
            .store(in: &cancellables)
        menuTracking.onOpenChange = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.updateEscapeHotKey(
                pinned: vm.isPinnedOpen, panelHasKeyboard: vm.wantsKeyboard, locked: vm.isLockedPresentation
            )
        }
    }

    /// The closed island as drawn now, in screen coordinates: every point a
    /// click lands on — the padded strip, the shoulders `closedTopRadius`
    /// wide, the Shelf's bubble. What `PointerWatcher.islandRect` reads.
    func collapsedIslandScreenRect() -> CGRect {
        guard let vm = viewModel else { return .zero }
        let width = vm.bodySize.width, height = vm.bodySize.height
        let bubble = vm.bubbleCount.map {
            vm.geometry.bubbleScreenRect(islandWidth: width, height: height, count: $0)
        } ?? .zero
        return Self.collapsedIslandRect(
            geometry: vm.geometry,
            body: CGSize(width: width, height: max(vm.geometry.collapsedDepth, height)),
            shoulder: vm.closedTopRadius,
            bubble: bubble
        )
    }

    /// The pure half of `collapsedIslandScreenRect()`: the hover strip, the
    /// clickable shape with its shoulders, and the bubble when there is one.
    nonisolated static func collapsedIslandRect(
        geometry: NotchGeometry, body: CGSize, shoulder: CGFloat, bubble: CGRect
    ) -> CGRect {
        let strip = geometry.collapsedHoverRect(for: body.width, height: body.height)
        let shape = geometry.contentScreenRect(for: body).insetBy(dx: -shoulder, dy: 0)
        let island = strip.union(shape)
        return bubble.isEmpty ? island : island.union(bubble)
    }

    /// A mouse-down on the panel, where it landed in the window
    /// (`NotchPanel.onPress`): a press into the field of a surface that
    /// types asks for the keyboard.
    ///
    /// Clicking away drops the keyboard but leaves the surface where it
    /// was, so a click back into the field has to be able to ask for it
    /// again.
    func pressed(atWindowPoint location: NSPoint) {
        guard let vm = viewModel, vm.presented.takesKeyboard else { return }
        // Body coordinates run down from the open body's top-left; the
        // window's run up from its bottom.
        let body = vm.geometry.contentRect(for: vm.openBodySize)
        let point = CGPoint(x: location.x - body.minX, y: body.maxY - location.y)
        guard vm.pressClaimsKeyboard(atBodyPoint: point) else { return }
        // Never while the shield is up. The lock card takes clicks — that
        // is how its transport works — and with the last-used tab on
        // translate or notes, one of those clicks used to raise
        // `wantsKeyboard`, which opens the panel and makes it key: a
        // window the lock presentation has deliberately lifted *above* the
        // shield, now holding the keyboard, in front of the password
        // field. Typing on the lock screen belongs to the lock screen.
        guard !vm.isLockedPresentation else { return }
        vm.wantsKeyboard = true
    }

    /// Test seam: gives the controller a model and a root view without building
    /// a panel, starting the stores or reading a screen, so the rect logic can be
    /// held at the controller rather than by its pure helpers alone.
    func attachForTesting(
        viewModel: NotchViewModel, rootView: NotchRootView, menuTracking: MenuTracking? = nil
    ) {
        self.viewModel = viewModel
        self.rootView = rootView
        installOutsideClickMonitor = { _ in NSObject() }
        removeOutsideClickMonitor = { _ in }
        // A private tracker, so no test touches the shared one, and an Escape
        // that reserves nothing.
        self.menuTracking = menuTracking ?? MenuTracking()
        escapeKeyRegistrar = { _ in InertHotKeyRegistration() }
        pointer.isPanelOpen = { [weak viewModel] in viewModel?.isOpen ?? false }
        pointer.collapsedIsland = { [weak self] in self?.collapsedIslandScreenRect() ?? .zero }
        wireEscapeClaim(viewModel)
        // The same sinks `build` installs, so a test that flips `isOpen`, the tab
        // or the pointer sees the registration follow without a manual refresh.
        wireShelfClaims(viewModel)
        wireShelfIslandCuts(viewModel)
        wirePageTravelCuts(viewModel)
    }

    /// Re-cuts both rects for the body currently on screen.
    func refreshOpenRects(
        bodySettled: Bool = false, animated: Bool = true,
        reduceMotion: Bool? = nil
    ) {
        guard let vm = viewModel, vm.isOpen else { return }
        rectShrinkWork?.cancel()
        rectShrinkWork = nil
        let target = vm.openBodySize
        let hold = Self.shrinkHold(
            reduceMotion: reduceMotion ?? SystemAppearance.shared.reduceMotion, animated: animated
        )
        let size = Self.openRectSize(
            applied: appliedOpenSize, target: target, bodySettled: bodySettled || hold == 0
        )
        if size.height > target.height || size.width > target.width {
            // Still shrinking: look again when the spring has settled. A newer
            // refresh cancels this one and decides afresh.
            let work = DispatchWorkItem { [weak self] in
                self?.rectShrinkWork = nil
                self?.refreshOpenRects(bodySettled: true)
            }
            rectShrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        }
        applyActiveRect(open: true, body: size)
        pointer.closeRect = vm.geometry.hoverRect(for: size)
    }

    /// Shows the new track for a moment, then folds back.
    ///
    /// The lowest of the island's alerts (spec §19.1, rank 10), so it goes
    /// through `alertQueue` like the rest: it waits, for a second at most,
    /// while the panel is open, files are dragged to it or the Mac is locked,
    /// and while a higher alert — the pop-up, the charger, headphones — holds
    /// the island. A peek on top of one of those would put two things in one
    /// pill. Nothing peeks *at* a locked screen: the peek re-cuts the collapsed
    /// rects, and while the shield is up those rects belong to the lock card —
    /// a track changing on a locked Mac used to hand the card's hit region to a
    /// strip computed for the notch-sized window, killing its transport and
    /// leaving a phantom click-eating rectangle elsewhere on the shield.
    ///
    /// Refused outright, not queued, with the pointer on the island: the user
    /// is doing something there, and the peek would fold the pill out from
    /// under them when it ended. The pointer is asked only once nothing
    /// blocks — over an open panel it is always inside, and that says nothing
    /// about the pill the peek will widen once the panel has gone.
    private func sneakPeek() {
        guard NotchViewModel.newTracksEnabled else { return }
        guard let vm = viewModel else { return }
        let blocked = Self.alertsBlocked(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
        )
        guard blocked || !pointer.isInside else { return }
        // A track that arrives folded — paused, or behind a film — has no pill
        // to widen. Peeking anyway drew its title into a wing of no width,
        // which under a real notch is invisible and beside a drawn one is not.
        guard vm.compactMediaActivity.isVisible else { return }
        // Nor over a talk, a projector or a film (K-003): the title would land
        // on the audience's screen. After the cheaper guards, since this one
        // reads the displays.
        guard !momentsAreQuiet() else { return }
        guard postAlert(.peek, to: vm) == .show else { return }

        peekWork?.cancel()
        vm.isPeeking = true
        // Spoken only once every refusal above has passed, so VoiceOver hears
        // a new track exactly when a sighted person sees one — and the Peek
        // at New Tracks switch silences both. The pill's own label, so the
        // announcement and what VoiceOver reads on the pill are one sentence.
        Announcer.shared.announce(vm.compactAccessibilityLabel)

        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            // The pointer may have arrived while the peek was up, and a peek
            // ending must never take a panel the user is now using with it.
            guard !vm.isOpen, !self.pointer.isInside else {
                vm.isPeeking = false
                return
            }
            // The pill's own fold, not the 0.16 s content ease: a peek ending
            // takes some 200 pt of title back in, and at that speed it read as
            // the pill snapping shut. The shell declares the same curve for
            // `isPeeking`; stating it here keeps the two from drifting apart.
            withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.isPeeking = false
            }
            self.promoteWaitingAlert()
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.sneakPeekDuration, execute: work)
    }

    // MARK: The island's alerts in time (spec §19.1)

    /// The alerts that could not show at once, each for a second at most. What
    /// *is* showing is the view model's (`vm.activity`), so the two cannot
    /// disagree about it.
    private var alertQueue = IslandAlertQueue()

    /// Whether an alert has to wait for the island: a surface is open, files
    /// are being dragged to it, or the Mac is locked. Pure, so each reason is a
    /// test.
    ///
    /// Waiting is not refusing. An alert held back by one of these shows if
    /// the island comes free within a second of its cause; the refusals in
    /// `hudAllowed` and `ambientAllowed` — a switch off, a dark display, a
    /// film full screen — drop it at once, because a second changes none of
    /// them.
    nonisolated static func alertsBlocked(isOpen: Bool, isDropTargeted: Bool, isLocked: Bool) -> Bool {
        isOpen || isDropTargeted || isLocked
    }

    /// Asks the queue whether `alert` shows now, waits, or is dropped, against
    /// what the island holds this instant.
    private func postAlert(_ alert: IslandActivity, to vm: NotchViewModel) -> IslandAlertQueue.Verdict {
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
    private func foldAlert() {
        guard let vm = viewModel else { return }
        hudFoldWork?.cancel()
        hudFoldWork = nil
        ambientWork?.cancel()
        ambientWork = nil
        peekWork?.cancel()
        peekWork = nil
        withAnimation(Theme.island(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.hud = nil
            vm.ambient = nil
        }
        promoteWaitingAlert()
    }

    /// The drag is over — dropped, sent to AirDrop or taken away. The drop
    /// surface comes off what it was laid over (spec §19.7): a panel the drag
    /// opened folds back into the island, where the Shelf now shows as live,
    /// and one that was already open goes back to the surface it was on.
    private func endDropSurface() {
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
    private func promoteWaitingAlert() {
        guard let vm = viewModel else { return }
        while !vm.activity.isAlert,
              !Self.alertsBlocked(
                  isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
              ),
              let next = alertQueue.next(at: Date()) {
            switch next {
            case .ambient(let activity): presentAmbient(activity)
            case .peek: sneakPeek()
            // The pop-up never waits, and live activities are never posted.
            case .hud, .music, .shelf, .none: break
            }
        }
    }

    private var ambientWork: DispatchWorkItem?
    private var hudFoldWork: DispatchWorkItem?
    /// How long the pop-up stays after the last press. `Theme.hudLinger`; a
    /// test shortens it rather than wait a second and a half.
    var hudFoldDelay: TimeInterval = Theme.hudLinger
    private var hudAnnounceWork: DispatchWorkItem?

    // MARK: The volume and brightness pop-up (spec §12)

    /// How long after the last press the level is spoken. A held key repeats
    /// many times a second, and a high-priority announcement each time would be
    /// VoiceOver talking over itself about numbers already out of date.
    static let hudAnnounceDelay: TimeInterval = 0.25

    /// Shows a key's result on the island, and restarts the fold.
    ///
    /// The key has already been applied and consumed; this only says so. The
    /// level is announced even when nothing is drawn — with the panel open the
    /// volume has its slider but brightness has nothing, and a person on
    /// VoiceOver has neither.
    func presentHUD(_ reading: HUDReading) {
        guard let vm = viewModel else { return }
        let moment = HUDMoment(reading)
        hudAnnounceWork?.cancel()
        let announce = DispatchWorkItem {
            Announcer.shared.announce(moment.accessibilityLabel)
        }
        hudAnnounceWork = announce
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hudAnnounceDelay, execute: announce)

        guard Self.hudAllowed(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted,
            isLocked: vm.isLockedPresentation, screensAsleep: screensAreAsleep
        ) else { return }

        // The highest of R7's alerts, so the queue always says show; asked all
        // the same, so a peek or a charger waiting behind an older pop-up is
        // judged against this one.
        guard postAlert(.hud(moment), to: vm) == .show else { return }

        let reduceMotion = SystemAppearance.shared.reduceMotion
        if vm.hud == nil {
            // Unfolding, on the pop-up's own quick, critically damped spring
            // (`Theme.hud`): on the island's slower, bouncier curve a key
            // press felt heavy, and the owner's review (2026-10-18) asked for
            // the system's feel — there at once, no overshoot.
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
            withAnimation(Theme.hud(reduceMotion: reduceMotion)) {
                vm.isPeeking = false
                vm.ambient = nil
                vm.hud = moment
            }
        } else {
            // Already up: the bar follows on its own curve; the shape has
            // nothing to do.
            vm.hud = moment
        }
        hudFoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.hudFoldWork = nil
            // The island returns to its live activity — the song, the Shelf —
            // on the curve the pop-up arrived on, or to an alert that waited
            // for the pop-up and is still inside its second.
            withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.hud = nil
            }
            self.promoteWaitingAlert()
        }
        hudFoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hudFoldDelay, execute: work)
    }

    /// Whether the pop-up may be drawn now. Pure, so each refusal is a test.
    ///
    /// Not over the open panel — the player has its own volume slider, and the
    /// panel would not have a pill to widen (the spec is silent, so the key is
    /// applied and nothing is drawn); not while a drag holds the panel open;
    /// not over the lock screen, where the tap passes every event through and
    /// the collapsed rects belong to the card; not on a dark display. A key
    /// press is the person's own act, so unlike the charger it is **not**
    /// refused for a pointer on the pill or a full-screen app.
    nonisolated static func hudAllowed(
        isOpen: Bool, isDropTargeted: Bool, isLocked: Bool, screensAsleep: Bool
    ) -> Bool {
        !isOpen && !isDropTargeted && !isLocked && !screensAsleep
    }

    /// Ends the pop-up at once, for a lock, a dark display and a Space change.
    private func clearHUD() {
        hudFoldWork?.cancel()
        hudFoldWork = nil
        hudAnnounceWork?.cancel()
        hudAnnounceWork = nil
        viewModel?.hud = nil
    }

    /// Shows the charger or headphones on the island for their hold.
    ///
    /// The same restraint as the track peek: through `alertQueue`, so it waits
    /// a second for an open panel, a drag, the lock or the pop-up and is
    /// dropped after it, and refused outright under the pointer (see
    /// `sneakPeek`). Headphones outrank the charger, and a peek already on
    /// screen gives way to either, because the Mac did something and the song
    /// has not changed.
    private func presentAmbient(_ activity: AmbientActivity) {
        // A Mac that reports no battery level shows no Charging (spec §19.4).
        guard let vm = viewModel, activity.showsOnIsland else { return }
        let switchOn: Bool
        switch activity {
        case .charging: switchOn = NotchViewModel.chargingEnabled
        case .headphones: switchOn = NotchViewModel.headphonesEnabled
        }
        let grown = NotchViewModel.ambientBodySize(
            activity, notchSize: vm.geometry.notchSize, bodyWidth: vm.geometry.expandedSize.width
        )
        let blocked = Self.alertsBlocked(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
        )
        // The pointer is asked only once nothing blocks: over an open panel it
        // is always inside, and that says nothing about the pill this will
        // grow once the panel has gone. `promoteWaitingAlert` comes back here,
        // and asks it then.
        guard Self.ambientAllowed(
            switchOn: switchOn,
            pointerInside: !blocked && pointer.isInside,
            pointerUnderGrownPill: !blocked
                && vm.geometry.grownAlertRect(for: .ambient(activity), body: grown).contains(NSEvent.mouseLocation),
            screensAsleep: screensAreAsleep,
            quiet: momentsAreQuiet()
        ) else { return }
        guard postAlert(.ambient(activity), to: vm) == .show else { return }

        let reduceMotion = SystemAppearance.shared.reduceMotion
        peekWork?.cancel()
        peekWork = nil
        ambientWork?.cancel()
        withAnimation(Theme.pill(reduceMotion: reduceMotion)) {
            vm.isPeeking = false
            vm.ambient = activity
        }
        // After the guard, never before it: a moment refused — switch off,
        // panel open, Mac locked, displays asleep — is not shown, and a
        // sentence for something nobody can see would be the voice lying.
        Announcer.shared.announce(activity.accessibilityLabel)
        scheduleAmbientFold(after: activity.holdDuration)
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
    private func momentsAreQuiet() -> Bool {
        let options = NSApp.currentSystemPresentationOptions
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        let active = ids.prefix(Int(count))
        return Self.momentsQuiet(
            // `.hideMenuBar` rather than `.autoHideMenuBar`: the latter is a
            // preference many people keep on all day, the former is an app
            // that took the whole screen.
            fullScreenFrontmost: options.contains(.fullScreen) || options.contains(.hideMenuBar),
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
    private func clearAmbient() {
        ambientWork?.cancel()
        ambientWork = nil
        viewModel?.ambient = nil
    }

    func refreshCollapsedRects() {
        guard let vm = viewModel, !vm.isOpen, !vm.isDropTargeted else { return }
        // A panel still folding keeps its clicks until the fold is done; the
        // close's own cut, already scheduled for then, reads whatever is
        // current when it lands. Cut here, an alert promoted the moment the
        // panel began to close let clicks on the visibly folding panel through
        // to the app behind it (R7 review).
        if let pending = closeActiveRectWork, !pending.isCancelled { return }
        // The locked panel's rect is the card's, and it is cut against a
        // screen-sized window — see `sneakPeek`. Re-cut it for the card, not
        // for the collapsed shell.
        guard !vm.isLockedPresentation else {
            applyLockedActiveRect()
            return
        }
        applyActiveRect(open: false)
    }


    private func applyActiveRect(open: Bool, body: CGSize? = nil) {
        guard let vm = viewModel, let rootView else { return }
        // Any cut that is not a refresh's own outdates the shrink one is waiting
        // to make; a refresh passes `body` and has scheduled its own.
        if body == nil {
            rectShrinkWork?.cancel()
            rectShrinkWork = nil
        }
        // Collapsed, the panel claims the island as drawn — the full notch
        // height on every display, synthetic or not. It used to stop 8 pt down
        // on a synthetic notch so that menu-bar status items underneath kept
        // their clicks; since `NotchShape` fills black unconditionally there,
        // that left most of a permanently visible island dead, and the trade
        // was reversed on 2026-09-10. The open size is the current tab's, not a
        // constant: the teleprompter is taller, and a rect cut for 208 would
        // leave the bottom half of it visible but untouchable.
        let size: CGSize
        if open {
            size = body ?? vm.openBodySize
            appliedOpenSize = size
            // The way back in. `openRect` was only ever cut for the collapsed
            // strip, so once the pointer had been counted as away from an open
            // panel, moving back onto its 620×208 body registered as nothing
            // and only a trip to the notch could reopen it.
            pointer.openRect = vm.geometry.hoverRect(for: size)
        } else {
            appliedOpenSize = nil
            // The full drawn depth, and the full width of the visible compact
            // activity — the pill widens with what is playing, and every point
            // of what is drawn has to open the panel.
            //
            // And the full drawn height: the island is 50 pt tall while a new
            // track peeks (spec §3.5), and `collapsedDepth` alone is the
            // notch's 38. The rects are re-cut on `isPeeking` in both
            // directions, so they cover the 12 pt that grew for the hold and
            // shrink back with the fold.
            let drawnDepth = max(vm.geometry.collapsedDepth, vm.bodySize.height)
            size = CGSize(width: vm.bodySize.width, height: drawnDepth)
            pointer.openRect = vm.geometry.collapsedHoverRect(for: vm.bodySize.width, height: drawnDepth)
        }
        // Follows the pill, which changes width with what is playing and widens
        // again for a peek. Left at the width it was built with, the lift would
        // stop short of the artwork the moment a track started.
        pointer.hoverRect = vm.geometry.collapsedIslandHoverRect(
            for: vm.bodySize.width, height: open ? nil : vm.bodySize.height
        )
        // The shape is drawn `topRadius` wider than the body on each side —
        // that slack is where the concave shoulders live — so the clickable
        // rect is grown to match it. Every point of the compact island opens
        // the panel: the artwork side, the cutout between, the equalizer side,
        // and the shoulders at either end.
        //
        // It follows `bodySize.width`, so it is correct at any width the panel
        // is set to and re-cut whenever that changes.
        //
        // The cost, stated: a status item sitting within `topRadius` of the
        // notch loses that sliver of itself to the panel. Collapsed, this used
        // to stay flush with the body to protect exactly that — but a compact
        // island with dead ends is the worse trade, because the dead ends are
        // invisible and the menu bar's are not.
        updateShelfZone(open: open, size: size)
        // The shoulders of what is drawn: an expanded alert's are wider than a
        // compact activity's (`IslandShapeRadii`).
        let slack = open ? vm.openTopRadius : vm.closedTopRadius
        let rect = vm.geometry.contentRect(for: size).insetBy(dx: -slack, dy: 0)
        rootView.activeRect = NotchRootView.reachingTopEdge(rect, windowHeight: vm.geometry.windowSize.height)
        geometryTrace(String(format: "activeRect open=%d w=%.0f h=%.0f", open ? 1 : 0, rect.width, rect.height))
        // Drags are aimed by hand and land wide, so the target is the visible
        // island generously grown — but nothing like the whole 700×444 window,
        // which is what used to accept a drag merely crossing the top of the
        // screen and switch the panel to the shelf for it.
        rootView.dropRect = rect.insetBy(dx: -24, dy: -24)
        // Widened to match, or the window would ignore mouse events over the
        // very shoulders the rect above just made clickable.
        pointer.interactiveRect = vm.geometry
            .contentScreenRect(for: size)
            .insetBy(dx: -slack, dy: 0)
        // The Shelf's bubble beside Music, its own region (spec §19.7). Re-cut
        // with the island: everything that brings it or takes it away — a
        // track, a pause settling, an alert, the Shelf's first and last file,
        // opening, the lock — already re-cuts these rects.
        if !open, let count = vm.bubbleCount {
            let width = vm.bodySize.width, height = vm.bodySize.height
            rootView.bubbleRect = NotchRootView.reachingTopEdge(
                vm.geometry.bubbleRect(islandWidth: width, height: height, count: count),
                windowHeight: vm.geometry.windowSize.height
            )
            pointer.bubbleRect = vm.geometry.bubbleScreenRect(islandWidth: width, height: height, count: count)
        } else {
            rootView.bubbleRect = .zero
            pointer.bubbleRect = .zero
        }
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

/// The Escape a test attaches: registers nothing, gives nothing back.
private final class InertHotKeyRegistration: HotKeyRegistration {
    func unregister() {}
}
