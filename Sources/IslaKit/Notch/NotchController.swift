import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

@MainActor
final class NotchController {
    var panel: NotchPanel?
    var rootView: NotchRootView?
    var viewModel: NotchViewModel?

    /// The live model, for App Intents. Read-only and optional on purpose: the
    /// panel builds its model in `install()`, so an intent that launched the app
    /// can arrive before there is one, and "not ready yet" is an honest answer.
    var intentModel: NotchViewModel? { viewModel }
    /// Internal so a test can read the rects the controller cuts
    /// (`NotchControllerRectTests`); nothing outside this file writes to it.
    let pointer = PointerWatcher()
    let lockPresence = LockScreenPresence()
    /// The lock screen's player, in a window of its own — see `LockCardWindow`.
    let lockCard = LockCardWindow()
    /// Stores that belong to the session, not to the panel: a rebuild replaces
    /// the panel and its view model and leaves these untouched.
    let stores = NotchStores()
    var closeActiveRectWork: DispatchWorkItem?
    /// The body height the open rects are cut for right now. It trails the
    /// body's own height on the way down (see `openRectHeight`), so it is the
    /// controller, not the model, that knows it.
    var appliedOpenSize: CGSize?
    /// Whether the drag in flight opened the panel itself, so the drop surface
    /// folds back into the island when it ends rather than leaving a surface
    /// nobody asked for open (spec §19.7).
    var dragOpenedPanel = false
    /// The pass that lets the rects shrink once the body has stopped moving.
    var rectShrinkWork: DispatchWorkItem?
    var collapseCheckWork: DispatchWorkItem?
    var peekWork: DispatchWorkItem?
    var cancellables = Set<AnyCancellable>()
    /// The live-activity hub's sink, which lives as long as the controller,
    /// not as long as one panel (`cancellables` is dropped on every rebuild).
    private var liveCancellables = Set<AnyCancellable>()
    /// Folds a timer's controls a few seconds after the last touch.
    var timerControlsFold: DispatchWorkItem?
    /// Held so `teardown` can actually undo `install`. Discarding the tokens
    /// left the registrations permanent by construction, which was harmless
    /// only for as long as `install` was called exactly once.
    private var observerTokens: [NSObjectProtocol] = []
    /// True while the display is asleep — the sampler and every poll are
    /// stopped, and the wake handler puts back only what it stopped.
    var screensAreAsleep = false
    var geometryWatchdog: Timer?
    /// Watches for a click in another app while the panel is pinned open.
    ///
    /// A pinned panel is deliberately deaf to the pointer, so the ordinary
    /// hover rule cannot close it, and it only receives key events on the two
    /// tabs that take the keyboard — which left a panel opened by ⌃⌥⌘I on the
    /// media tab with no way out but the hotkey itself. A global monitor sees
    /// clicks the app never receives, which is exactly the signal needed.
    var pinnedClickMonitor: Any?
    /// Hears every scroll event that lands on the panel, for the vertical
    /// pull that opens and closes it (`IslandPull`). A local monitor, as the
    /// pages' is: the panel is never key, and only the events AppKit already
    /// delivers to this app — the pointer over the island's hit region, or
    /// over the open panel — ever reach it, so it costs nothing anywhere else
    /// on the screen. Installed for the session, not per panel: `build`
    /// replaces the panel and the model, and the monitor asks for the current
    /// ones at each event.
    private var pullMonitor: Any?
    /// Escape, held system-wide for exactly as long as a pinned panel without
    /// the keyboard stands — see `NotchViewModel.claimsEscape`. A Carbon hot
    /// key for the same reason the three shortcuts are: it needs no
    /// permission and sees nothing else that is typed. Registered and given up
    /// by `updateEscapeHotKey` alone.
    var escapeHotKey: HotKeyRegistration?
    /// Test seams: what registers the transient Escape — a test process must
    /// not reserve a real key for the login session — and the menus whose
    /// opening takes Escape back from it (`attachForTesting` passes its own).
    var escapeKeyRegistrar: (@escaping () -> Void) -> HotKeyRegistration? = { action in
        GlobalHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, action: action)
    }
    var menuTracking: MenuTracking = .shared
    /// Delete and ⌘⌫, held while the pointer is on the Shelf and something is
    /// selected there (spec §8.2) — see `NotchViewModel.claimsDelete` and
    /// `ShelfDeleteKeyHolder`, which is the only thing that registers them.
    /// Driven by `updateDeleteKey`, from every input of the claim at once.
    lazy var deleteKey = ShelfDeleteKeyHolder(registrar: deleteKeyRegistrar) { [weak self] in
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
    var openGeneration = 0
    /// Stamp of the panel `build()` last made. The synthetic-notch looks a
    /// build schedules do nothing once a newer build has outdated them.
    var buildGeneration = 0

    /// Test seam: where the pointer is, in screen coordinates.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    /// Test seams: a test process must not register a real global monitor.
    var installOutsideClickMonitor: (@escaping @Sendable () -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in handler() }
    }
    var removeOutsideClickMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    /// The app the last activation went to, so one that leaves Isla itself
    /// can be told from a switch between two other apps.
    var lastActivatedPID: pid_t?

    /// The alerts that could not show at once, each for a second at most. What
    /// *is* showing is the view model's (`vm.activity`), so the two cannot
    /// disagree about it.
    var alertQueue = IslandAlertQueue()

    var ambientWork: DispatchWorkItem?
    var hudFoldWork: DispatchWorkItem?
    /// How long the pop-up stays after the last press. `Theme.hudLinger`; a
    /// test shortens it rather than wait a second and a half.
    var hudFoldDelay: TimeInterval = Theme.hudLinger
    var hudAnnounceWork: DispatchWorkItem?

    /// A test's answer for the lift, which needs a real panel and the
    /// compositor; production never sets it.
    var overShieldForTesting: Bool?
    /// A test's answer for `momentsAreQuiet`, which reads the owner's real
    /// displays and frontmost app; production never sets it.
    var momentsQuietForTesting: Bool?

    var confirmationWork: DispatchWorkItem?
    /// How long a confirmation holds the island. `IslandConfirmation
    /// .holdDuration`; a test shortens it rather than wait a second and a half.
    var confirmationHold: TimeInterval = IslandConfirmation.holdDuration

    /// The capsule's own queue: what waits there behind the level or a
    /// higher notice, by the island's ranks and patience. The shut island's
    /// `alertQueue` never sees these; a notice shown in the capsule has been
    /// shown.
    var stripQueue = IslandAlertQueue()
    var stripNoticeWork: DispatchWorkItem?
    var stripNoticeShownAt: Date?

    /// Shows the charger or headphones on the island for their hold.
    ///
    /// The same restraint as the track peek: through `alertQueue`, so it waits
    /// a second for an open panel, a drag, the lock or the pop-up and is
    /// dropped after it, and refused outright under the pointer (see
    /// `sneakPeek`). Headphones outrank the charger, and a peek already on
    /// screen gives way to either, because the Mac did something and the song
    /// has not changed.
    /// The newest charger reading and when it came, for a plug-in that
    /// waited in a queue (Codex review 2026-10-27): the re-reads land while
    /// nothing is on screen to take them, and the moment promoted a second
    /// later would show, and announce, the edge's reading — Charging for On
    /// Hold, no watts.
    var latestCharge: (activity: AmbientActivity, at: Date)?

    /// Which versions have had their answer. A test hands in a suite of its
    /// own, so it never writes the test host's defaults.
    var updateOfferMemory = UpdateOfferMemory()
    /// What a check last found: what the island may offer. A test hands in
    /// its own rather than run a check.
    var availableUpdate: () -> UpdateCheck.Release? = { UpdateCheck.shared.lastAvailable }
    /// What Install and Try Again run — the installer Settings' Update Now
    /// runs, so the two cannot install differently. A test records instead.
    var installUpdate: (_ release: UpdateCheck.Release, _ retry: Bool) -> Void = { release, retry in
        if retry { UpdateInstaller.shared.reset() }
        UpdateInstaller.shared.install(release)
    }
    /// Where the install is, for the alert's stage. A test hands in its own.
    var installerState: () -> (phase: UpdateInstaller.Phase, release: UpdateCheck.Release?) = {
        (UpdateInstaller.shared.phase, UpdateInstaller.shared.release)
    }
    /// Quit Isla, after an update that needs a restart. Never in a test.
    var quitApp: () -> Void = { NSApp.terminate(nil) }
    /// Whether this is a quiet moment, for a test: the live answer reads the
    /// displays and the battery, which a test must not.
    var updateMomentsQuiet: (() -> Bool)?
    /// Whether the Mac is locked, for a test: the live answer is the lock
    /// presence's, which follows the real session.
    var updateScreenLocked: (() -> Bool)?
    /// The screen saver is up (`com.apple.screensaver.didstart`), perhaps
    /// still inside its password grace, so not locked.
    var screenSaverRunning = false
    /// This login session is the one at the screen; false while another user
    /// is switched in.
    var sessionActive = true
    /// How long an unanswered offer stands (§19.1: at most 20 s). A test
    /// shortens it.
    var updateOfferHold: TimeInterval = NotchController.updateOfferHoldDefault

    var updateFoldWork: DispatchWorkItem?
    var updateRetryWork: DispatchWorkItem?

    func install() {
        stores.onScreenshot = { [weak self] url in
            self?.viewModel?.receivedScreenshot(at: url)
        }
        stores.ambient.onEvent = { [weak self] activity in
            // A plug-in's own reading is the newest there is.
            if activity.isChargerMoment { self?.latestCharge = (activity, Date()) }
            self?.presentAmbient(activity)
        }
        stores.ambient.onChargeUpdate = { [weak self] activity in
            self?.updateShownCharge(activity)
        }
        // The volume and brightness pop-up (spec §12). Both closures are read at
        // each key, so the lock and the reading land on whatever is current.
        stores.hud.isLocked = { [weak self] in
            guard let self else { return false }
            return self.lockPresence.isLocked || self.viewModel?.isLockedPresentation == true
        }
        // Over the lock screen a key is Isla's only while the island is over
        // the shield to show it — the same lift that puts the card there.
        stores.hud.drawsWhileLocked = { [weak self] in self?.islandIsOverShield ?? false }
        stores.hud.onReading = { [weak self] reading in
            self?.presentHUD(reading)
        }
        // The timer, the microphone and camera, and Downloads (plan
        // 2026-11-14): what stands goes to the island, what ends is an alert.
        stores.live.$live
            .sink { [weak self] live in self?.liveActivitiesChanged(live) }
            .store(in: &liveCancellables)
        stores.live.onTimerFinished = { [weak self] duration in self?.timerFinished(duration) }
        stores.live.onDownloadEvent = { [weak self] event in self?.downloadEvent(event) }
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
        pullMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.pullScrolled(event) ?? false } ? nil : event
        }
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
                // A dark display draws nothing over the shield: the keys go
                // back to the system until it wakes.
                self.stores.hud.lockChanged()
                // A charger moment's timer does not run while the Mac sleeps,
                // so a lid closed right after plugging in woke to the old
                // percentage still on the island.
                self.clearAmbient()
                self.clearHUD()
                self.clearConfirmation()
                self.clearUpdateOffer()
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
                self.stores.hud.lockChanged()
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
                // An update offer the dark display took down, or found while
                // it was dark, is owed at the first idle moment after it.
                self.considerUpdateOffer()
            }
        })
        // Locking replaces the desktop with the shield, and the pill stays on
        // it — see `LockScreenPresence` for the mechanism. Wired here because
        // the two sides of the transition are this controller's verbs: fold,
        // stop the sampler, raise the level; then put all three back.
        lockPresence.onLock = { [weak self] in self?.screenLocked() }
        lockPresence.onUnlock = { [weak self] in self?.screenUnlocked() }
        lockPresence.start()
        // Two ways nobody sees the island that are not a lock: the screen
        // saver inside its password grace, and another user switched in. Only
        // the update alert asks — it is the one alert an unseen fold answers
        // (spec §19.5 f) — so these are watched for it alone.
        let distributed = DistributedNotificationCenter.default()
        for (name, running) in [("com.apple.screensaver.didstart", true), ("com.apple.screensaver.didstop", false)] {
            observerTokens.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenSaverChanged(running: running) }
            })
        }
        for (name, active) in [
            (NSWorkspace.sessionDidResignActiveNotification, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, true),
        ] {
            observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionActiveChanged(active) }
            })
        }
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

    func teardown() {
        if let pullMonitor { NSEvent.removeMonitor(pullMonitor) }
        pullMonitor = nil
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
            DistributedNotificationCenter.default().removeObserver(token)
        }
        observerTokens.removeAll()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        // Nothing is on screen any more, whatever the views report on the way
        // out: no batch may outlive the panel.
        stores.lyricTranslation.resetDemand()
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
    var pointerIsOnOpenPanel: Bool {
        guard let vm = viewModel else { return false }
        let point = pointerLocation()
        return vm.geometry.hoverRect(for: vm.openBodySize).contains(point)
            || pointer.closeRect.contains(point)
            || pointer.holdsBeyondBody(at: point)
    }

    // MARK: - Construction

    func rebuild() {
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
        vm.onBubbleClick = { [weak self] in self?.bubbleClicked() }
        vm.liveActivities = stores.live.live
        vm.onTimerControl = { [weak self] in self?.timerControl($0) }
        vm.onMicrophoneControl = { [weak self] in self?.microphoneControl($0) }
        vm.onUpdateAction = { [weak self] in self?.updateAlertAction($0) }
        vm.onConfirmation = { [weak self] in self?.presentConfirmation($0) }
        vm.onStripClosed = { [weak self] in self?.stripClosed($0) }
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
        // A confirmation widens it too, from the notch to its words.
        vm.$confirmation
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
        vm.$hudShown
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)
        // And the update alert, the deepest of them: 120 pt below the notch,
        // with its buttons in that depth, which must be clickable the moment
        // it shows.
        vm.$updateOffer
            .map { $0?.version }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)
        // A check that found an update, or the installer moving on, may give
        // the island something to offer or take an offer back (spec §19.5 f).
        // A pass later, for the same reason as the queue's sink below.
        UpdateCheck.shared.$lastAvailable.map { $0?.version }.removeDuplicates().map { _ in () }
            .merge(with: UpdateInstaller.shared.$phase.map(Self.updateStep).removeDuplicates().map { _ in () })
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStateChanged() }
            }
            .store(in: &cancellables)
        wireShelfIslandCuts(vm)
        wirePageTravelCuts(vm)

        wireAlertPromotion(vm)

        // Sneak peek: a new track shows itself, then gets out of the way.
        //
        // Keyed on the track's identity rather than on any of the fields that
        // describe it. A single skip publishes several snapshots in the space
        // of a hundred milliseconds — the immediate one, the settled echo, the
        // artwork — and peeking per snapshot is the flicker every app in this
        // category has shipped at least once.
        //
        // The presented track's, not the reported one's: the peek used to fire
        // on the raw key, while the island still showed the old cover or the
        // placeholder, and so it peeked the new title over the wrong picture.
        // The presenter swaps title and cover together, once per song, so the
        // peek fires once, with its cover (owner, 2026-10-25).
        vm.nowPlaying.$presented
            .map { $0?.key }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] key in
                guard key != nil else {
                    // The song went with nothing after it: an alert left up
                    // would be the pop-up's shape with no song in it for the
                    // rest of its hold.
                    self?.endPeekWithoutASong()
                    return
                }
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
}
