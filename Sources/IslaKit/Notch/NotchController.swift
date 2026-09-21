import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchController {
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var viewModel: NotchViewModel?

    /// The live model, for App Intents. Read-only and optional on purpose: the
    /// panel builds its model in `install()`, so an intent that launched the app
    /// can arrive before there is one, and "not ready yet" is an honest answer.
    var intentModel: NotchViewModel? { viewModel }
    private let pointer = PointerWatcher()
    private let lockPresence = LockScreenPresence()
    /// The lock screen's player, in a window of its own — see `LockCardWindow`.
    private let lockCard = LockCardWindow()
    /// Stores that belong to the session, not to the panel: a rebuild replaces
    /// the panel and its view model and leaves these untouched.
    private let stores = NotchStores()
    private var closeActiveRectWork: DispatchWorkItem?
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
    /// tabs that take the keyboard — which left a panel opened by ⌥⌘I on the
    /// media tab with no way out but the hotkey itself. A global monitor sees
    /// clicks the app never receives, which is exactly the signal needed.
    private var pinnedClickMonitor: Any?
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0

    func install() {
        stores.onScreenshot = { [weak self] url in
            self?.viewModel?.receivedScreenshot(at: url)
        }
        stores.start()
        build()
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
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
                self.setOpen(false)
                self.pointer.setInside(false)
                self.pointer.stop()
                self.stores.suspendForIdleScreen()
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
                // Only once it is clear the Mac is not still locked — the
                // checks below decide that.
                if !self.lockPresence.isLocked { self.stores.resumeFromIdleScreen() }
                // Repair path: if the unlock notification was ever missed —
                // it once queued behind a main-thread block and the card
                // stayed stranded on the desktop — waking with the shield
                // down puts the panel back to normal.
                if !self.lockPresence.isLocked, self.viewModel?.isLockedPresentation == true {
                    self.screenUnlocked()
                    return
                }
                if self.lockPresence.isLocked {
                    // Still locked: the sampler must stay stopped. Restarting
                    // it here — the display sleeping and rewaking mid-lock is
                    // the ordinary way the password field is summoned — put it
                    // to work against rects cut before the lock, which killed
                    // the card's transport and could unfold the panel under
                    // the shield. Only the card comes back.
                    if self.viewModel?.isLockedPresentation == true {
                        self.viewModel?.media.setActive(true)
                    }
                    return
                }
                self.pointer.start()
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
        verifySyntheticNotch()
        // Verification hook, environment-gated like the panel's own: the lock
        // card is the one surface that cannot be screenshotted where it lives,
        // because the shield owns the screen while it is up. Launched with
        // DI_LOCK_PREVIEW=1 the app presents the card as though locked, over
        // the ordinary desktop, so its glass can be seen against a real
        // wallpaper. An app launched normally never has the variable.
        if ProcessInfo.processInfo.environment["DI_LOCK_PREVIEW"] == "1" {
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
        guard viewModel?.isOpen == true else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
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
        guard NotchViewModel.showOnLockScreenEnabled else {
            // The card is switched off, but the rest of the lock contract still
            // holds: fold, and stop the sampler. Returning outright left it
            // sampling all through the lock, so a cursor pass over the notch
            // opened an invisible panel beneath the shield.
            setOpen(false)
            collapseNow()
            pointer.setInside(false)
            pointer.stop()
            stores.suspendForIdleScreen()
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
        viewModel?.media.setActive(true)
        // Nobody can copy anything at a locked Mac, and Universal Clipboard
        // arrivals from a phone are not something to record behind a shield.
        // This used to happen only on the branch where the card is switched
        // off — which is not the default — so the pasteboard was polled twice a
        // second for the whole lock on an ordinary install.
        //
        // The media clock stays running: the card is about to be presented, and
        // it draws a scrubber and a moving lyric that both depend on it.
        stores.suspendForIdleScreen(keepingMediaRunning: true)
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
        guard let panel, let rootView, let vm = viewModel else { return }
        rootView.activeRect = .zero
        rootView.dropRect = .zero

        // The pill's own region. It opens nothing — the island stays shut over
        // the shield, by design — but it answers: a hover draws the edge, and a
        // click shakes it off. Silence reads as a dead app rather than as a
        // limit, which is the whole reason this rect exists.
        //
        // It takes clicks now, where before it took only hovers. The area is
        // the notch itself, at the top centre of the screen; the password field
        // is in the middle, and nothing else up there belongs to loginwindow.
        let pill = CGSize(width: vm.bodySize.width, height: vm.geometry.notchSize.height)
        let rect = CGRect(
            x: (panel.frame.width - pill.width) / 2,
            y: panel.frame.height - pill.height,
            width: pill.width,
            height: pill.height
        )
        rootView.lockedHoverRect = rect
        rootView.activeRect = NotchRootView.reachingTopEdge(rect, windowHeight: panel.frame.height)
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
    }

    /// A synthetic notch found at launch is checked again shortly after.
    ///
    /// `NotchGeometry` remembers a display's cutout and refuses to forget it on
    /// a glitched reading, but the memory is empty on the first read — and the
    /// first read happens at login, which is exactly when a Mac is still
    /// settling its displays. A launch that lands in that window would draw the
    /// synthetic pill for the rest of the session, since nothing else asks
    /// again. Two later looks cost nothing and end that.
    private func verifySyntheticNotch() {
        guard viewModel?.geometry.isPhysical == false else { return }
        for delay in [1.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.viewModel?.geometry.isPhysical == false else { return }
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
        guard ProcessInfo.processInfo.environment["DI_GEOM"] == "1" else { return }
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

    /// Samples where the panel actually is against where the geometry says it
    /// belongs. Armed only under DI_GEOM=1.
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
                let hosted = content?.subviews.first
                let contentFits = content.map {
                    abs($0.bounds.width - have.width) < 1 && abs($0.bounds.height - have.height) < 1
                } ?? true
                let hostedFits = hosted.map {
                    abs($0.frame.width - have.width) < 1 && abs($0.frame.height - have.height) < 1
                } ?? true
                if ProcessInfo.processInfo.environment["DI_GEOM"] == "1" {
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

    func teardown() {
        lockPresence.stop()
        pointer.stop()
        if let pinnedClickMonitor {
            NSEvent.removeMonitor(pinnedClickMonitor)
            self.pinnedClickMonitor = nil
        }
        stores.stop()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
    }

    /// Opens on the Music tab with the lyrics page already up.
    ///
    /// The same shape as `translate(_:)` and for the same reasons: refused over
    /// the shield before anything is touched, and pinned open because the
    /// pointer that asked for it is on the keyboard rather than on the notch.
    /// Pressing it again folds the page back to the player rather than doing
    /// nothing, so one key is the whole round trip.
    func toggleLyrics() {
        guard let vm = viewModel else { return }
        guard vm.verdictForDeliberateOpen() == .proceed else {
            vm.nudgeLockedIsland()
            return
        }
        // Pressed again with the page already up, it folds the page back to
        // the player rather than doing nothing: one key is the whole round
        // trip, and the panel is left open on the music it was opened for.
        if vm.isOpen, vm.tab == .media, vm.isShowingLyrics {
            vm.isShowingLyrics = false
            return
        }
        peekWork?.cancel()
        vm.isPeeking = false
        vm.select(.media)
        vm.isShowingLyrics = true
        // Pinned, like ⌥⌘I and for the same reason: the hand that pressed it is
        // on the keyboard, not on the notch, and an unpinned panel nobody is
        // hovering folds a third of a second after it appears. Lyrics are read
        // for the length of a song, which is the longest any of these stays up.
        vm.isPinnedOpen = true
        setOpen(true)
        pointer.setInside(true)
        updatePinnedClickMonitor()
    }

    /// Opens on the translate tab with this text already in it.
    func translate(_ text: String) {
        guard let vm = viewModel else { return }
        // Refused over the shield, before the translator, the tab or `setOpen`
        // is touched: this route would open the panel over the password field
        // and then make it key through `select(.translate)` — a window the lock
        // presentation deliberately lifted above the shield, holding the
        // keyboard in front of the password field, the exact hazard
        // `panel.onPress` refuses for the same reason.
        guard vm.verdictForDeliberateOpen() == .proceed else {
            vm.nudgeLockedIsland()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        peekWork?.cancel()
        vm.isPeeking = false
        vm.translator.input = trimmed
        // Through `select`, so the field that appears can be typed into. Set
        // directly, the tab changed without ever raising `wantsKeyboard`, and
        // the panel showed a text field whose keystrokes went to the app
        // underneath — the one thing `select` adds, and the invariant
        // `NotchViewModel.wantsKeyboard` documents.
        vm.select(.translate)
        setOpen(true)
        // The pointer is wherever the user left it, which is not on the notch,
        // so both halves of the close rule are held off for the same span: the
        // sampler's own tick and the deferred collapse check below. Granting
        // the grace and then scheduling a 0.6 s collapse meant the translation
        // still vanished before it could be read — just slightly later.
        pointer.setInside(true, grace: NotchMetrics.translateReadDelay)
        // Held open by the pointer rule like any other tab, so it folds when
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
    private func islandClicked() {
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

        // Everything the hover route used to do, in the same order, so a click
        // opens the panel the way a hover did rather than by a second path that
        // merely ends up open too. The tab, the lift and the pin are the view
        // model's — `clickOpened` — and the panel's own machinery is here.
        vm.clickOpened(pointerIsOnPanel: pointerIsOnOpenPanel)
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
    /// The same rect the watcher closes on, asked the same way
    /// `scheduleCollapseIfPointerAway` asks it, so the answer cannot drift from
    /// the rule it stands in for. `hoverRect(for: openBodySize)` contains the
    /// whole collapsed island — the pill is never wider than the body it opens
    /// into (`CompactMediaActivity.bodySize` caps it) and never deeper than the
    /// notch — so a click delivered by the mouse always answers true, and only
    /// a click from assistive tech, with the cursor left elsewhere, answers
    /// false.
    private var pointerIsOnOpenPanel: Bool {
        guard let vm = viewModel else { return false }
        return vm.geometry.hoverRect(for: vm.openBodySize).contains(NSEvent.mouseLocation)
    }

    func refreshPointerTuning() {
        pointer.openDelay = NotchViewModel.hoverOpenDelay
    }

    /// The ⌥⌘I hotkey, `presentWelcome()` on a fresh account, and the
    /// `DI_OPEN_LYRICS` verification hook. (The Translate service opens through
    /// `translate(_:)`, which sets its own tab and its own grace, not here.)
    ///
    /// Opens until something closes it — the same command again, Escape, or a
    /// click outside — rather than until the next pointer sample, which is what
    /// folded it a third of a second after it appeared and made the keyboard
    /// route to the panel unusable.
    func toggle() {
        guard let viewModel else { return }
        // Refused over the shield, before the pin or `setOpen` is touched: an
        // open there would grow the clickable region from the deliberate
        // pill-sized locked rect to the open body, over the password field. The
        // shake is the same refusal the island's own click gives — and
        // `presentWelcome()` keeps its own silent guard, so the welcome never
        // reaches here while locked.
        guard viewModel.verdictForDeliberateOpen() == .proceed else {
            viewModel.nudgeLockedIsland()
            return
        }
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
            // The same hazard as the second click on the island: ⌥⌘I can be
            // pressed with the pointer standing on the panel, and the rect an
            // arrival is measured against is still the open body's while the
            // panel folds. See `PointerWatcher.closedByHand()`.
            pointer.closedByHand()
        }
        updatePinnedClickMonitor()
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
    /// the island, or a click in another app.
    func presentWelcome() {
        guard let viewModel else { return }
        // Not over the shield. The island is deliberately inert while the Mac is
        // locked, so a welcome there could neither be read nor dismissed —
        // better to spend the moment on the next launch, which is what leaving
        // the flag unset does.
        guard !viewModel.isLockedPresentation else { return }
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
    private func updatePinnedClickMonitor() {
        let wanted = viewModel?.holdsOpen == true
        if wanted, pinnedClickMonitor == nil {
            pinnedClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.viewModel?.holdsOpen == true else { return }
                    // The click landed in another application — this app never
                    // sees clicks on its own panel here — so whatever was
                    // holding the panel open is over.
                    self.viewModel?.isPinnedOpen = false
                    self.setOpen(false)
                    // Deliberate, like the other two closes: the click landed in
                    // another app, but `openRect` reaches past the region this
                    // panel takes clicks in, so the pointer that made it can be
                    // inside the rect an arrival is measured against.
                    self.pointer.closedByHand()
                    self.updatePinnedClickMonitor()
                }
            }
        } else if !wanted, let monitor = pinnedClickMonitor {
            NSEvent.removeMonitor(monitor)
            pinnedClickMonitor = nil
        }
    }

    // MARK: - Construction

    private func rebuild() {
        // Carried across, because a display change is not a decision to throw
        // away what the panel was showing. The stores themselves already
        // survive — they belong to the session, not the panel — so this is
        // only the panel's own state.
        let previousTab = viewModel?.tab
        let wasOpen = viewModel?.isOpen ?? false
        let wasShowingWelcome = viewModel?.isShowingWelcome ?? false
        // The pin belongs to the panel being torn down; the monitor watching
        // for its exit has to go with it, or it outlives every rebuild.
        viewModel?.isPinnedOpen = false
        updatePinnedClickMonitor()
        peekWork?.cancel()
        collapseCheckWork?.cancel()
        pointer.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
        viewModel = nil
        build(restoring: previousTab, wasOpen: wasOpen, showingWelcome: wasShowingWelcome)
    }

    private func build(
        restoring restoredTab: NotchViewModel.Tab? = nil,
        wasOpen: Bool = false,
        showingWelcome: Bool = false
    ) {
        guard let geometry = NotchGeometry.current() else { return }
        let vm = NotchViewModel(geometry: geometry, stores: stores)
        // Before any rect is cut. The tab decides how far down the panel
        // reaches, and restoring it afterwards left every rect cut for the
        // default media body — so a restored teleprompter opened to its full
        // 400 pt with a close rect drawn for 208, and folded under a pointer
        // resting in the lower half of the pane.
        if let restoredTab { vm.tab = restoredTab }
        // Carried across for the same reason as the tab, and it is the more
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
        viewModel = vm

        let panel = NotchPanel(contentRect: geometry.windowFrame)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: geometry.windowSize))
        root.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchContentView(vm: vm))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        root.addSubview(hosting)

        // Entering draws the edge, leaving takes it away. The shake used to
        // fire here, which spent the refusal on a gesture that had not asked
        // for anything yet — a pointer crossing the top of a locked screen is
        // not a request to open the island.
        root.onLockedHover = { [weak self] entered in
            self?.viewModel?.isHovering = entered
        }
        root.onDragEntered = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            // `showShelfForDrag()`, not a bare `tab = .shelf`: the welcome is
            // drawn over the pane switch, and `setOpen(true)` below has nothing
            // to do on a panel the welcome already opened, so a drag during the
            // first launch used to change nothing visible whatsoever.
            vm.showShelfForDrag()
            vm.isDropTargeted = true
            self.setOpen(true)
        }
        root.onDragExited = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.isDropTargeted = false
            // The pointer usually is not over the panel after a drag leaves.
            self.scheduleCollapseIfPointerAway()
        }
        root.onDrop = { [weak self] urls in
            guard let self, let vm = self.viewModel else { return false }
            vm.isDropTargeted = false
            let accepted = vm.accept(urls: urls)
            self.pointer.setInside(true)
            self.setOpen(true)
            self.scheduleCollapseIfPointerAway()
            return accepted
        }

        // Escape folds the panel from any tab. It used to be bound inside the
        // two panes that take the keyboard, which meant the teleprompter's
        // documented "ends three ways" was really one — its pane never held
        // the keyboard, so Escape never reached it and the pin outlived the
        // script.
        panel.onEscape = { [weak self] in
            guard let self else { return }
            self.setOpen(false)
            self.pointer.setInside(false)
        }

        // Escape reaches the panes first, and only folds the panel if none of
        // them wanted it. Swallowing every Escape here made the two panes'
        // own handlers — the translator's "clear the field", the notes' "hand
        // the keyboard back" — unreachable code, and closed the whole panel
        // when Escape was pressed to cancel an input-method composition.
        panel.escapeHandled = { [weak self] in
            guard let vm = self?.viewModel else { return false }
            return vm.consumeEscape()
        }

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        panel.onPress = { [weak self] in
            guard let vm = self?.viewModel, vm.tab.needsKeyboard else { return }
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
        // Cut for the tab that will be showing, not for the standard body: a
        // rebuild restores the previous tab, and the teleprompter reaches
        // twice as far down as the rest.
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
        pointer.isDragging = { [weak root] in
            (root?.isReceivingDrag ?? false) || ShelfDragSource.isDraggingOut || MenuTracking.shared.isOpen
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
        pointer.onChange = { [weak self] inside in
            guard let self, let vm = self.viewModel else { return }
            // The edge is drawn from the shape's own `.onHover`, not from
            // here: this rect is padded for a forgiving open, and an edge lit
            // from it appears while the cursor is beside the island.
            //
            // What the crossing means is the view model's — `pointerCrossed`,
            // where it can be tested without a pointer. What it does to the
            // panel is this closure's. An arrival lands on Music: the island is
            // for glancing at a track, and the other tabs are somewhere to go
            // once it is open, not somewhere to arrive. Deliberate routes still
            // choose their own tab — ⌥⌘T lands on Translate, and a drag stays on
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
        pointer.start()

        // Switching tabs can change how far down the panel reaches, and both
        // the clickable region and the region the pointer counts as "on the
        // panel" are cut from that. Left alone, the teleprompter would open to
        // its full height with only its top 208 pt alive.
        vm.$tab
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let vm = self.viewModel, vm.isOpen else { return }
                    // A pass later: `bodySize` reads `tab`, and this fires
                    // while the property is still being set.
                    DispatchQueue.main.async { self.refreshOpenRects() }
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

        // Driven by the deliberate request, not by which tab is showing: a
        // hover can land on the typing tab now, and that alone must not take
        // the keyboard away from the window underneath.
        vm.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
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
        if pointerOnTarget || (wasOpen && pointerOnBody) {
            pointer.setInside(true)
            setOpen(true)
        }

        // A rebuild can land mid-lock — plugging in a display does not wait
        // for the password. The fresh panel starts at the normal level with
        // its sampler running; dress it for the lock screen again, or the
        // pill vanishes from the shield at the exact moment a display
        // changes. Last, so it also undoes the reopen just above.
        if lockPresence.isLocked { screenLocked() }
    }

    // MARK: - Open / close

    /// Hands the keyboard to the panel, or gives it back.
    private func setKeyboard(_ wants: Bool) {
        if wants {
            setOpen(true)
            pointer.setInside(true)
        }
        panel?.acceptsKeyboard = wants
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
    /// the routes that open the panel with the pointer nowhere near it: ⌥⌘I,
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
            withAnimation(Theme.open(reduceMotion: SystemAppearance.shared.reduceMotion)) { vm.isOpen = true }
            vm.media.setActive(true)
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

    /// What the menu bar switches. Handed out rather than wrapped: the menu
    /// reads four sections and writes them one at a time, and a controller
    /// method per section would be four methods that only forward.
    var privacy: PrivacyMode? { viewModel?.privacy }

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
        if deferRectShrink {
            withAnimation(Theme.open(reduceMotion: SystemAppearance.shared.reduceMotion)) { vm.isOpen = false }
        } else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { vm.isOpen = false }
        }
        vm.media.setActive(false)
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
        let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.collapseRectShrinkDelay, execute: work)
    }

    private func scheduleCollapseIfPointerAway(after delay: TimeInterval = NotchMetrics.pointerAwayCollapseDelay) {
        // Stamped like every other deferred step in this file. A bare
        // `asyncAfter` from an earlier open stayed armed, so pressing ⌥⌘T twice
        // a few seconds apart let the first timer fold the translation the
        // second one had just put on screen.
        collapseCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.collapseCheckWork = nil
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

    /// Re-cuts both rects for the body currently on screen.
    private func refreshOpenRects() {
        guard let vm = viewModel, vm.isOpen else { return }
        applyActiveRect(open: true)
        pointer.closeRect = vm.geometry.hoverRect(for: vm.openBodySize)
    }

    /// Shows the new track for a moment, then folds back.
    ///
    /// Deliberately does nothing when the panel is already open, when the
    /// pointer is on the panel, or during a drag: in all three cases the user
    /// is doing something, and the peek would either be redundant or would
    /// fold the panel out from under them when it ended.
    private func sneakPeek() {
        guard NotchViewModel.sneakPeekEnabled else { return }
        guard let vm = viewModel, !vm.isOpen, !vm.isDropTargeted else { return }
        // Nothing peeks at a locked screen. The peek re-cuts the collapsed
        // rects, and while the shield is up those rects belong to the lock
        // card — a track changing on a locked Mac used to hand the card's hit
        // region to a strip computed for the notch-sized window, killing its
        // transport and leaving a phantom click-eating rectangle elsewhere on
        // the shield.
        guard !vm.isLockedPresentation else { return }
        guard !pointer.isInside else { return }
        // A track that arrives folded — paused, or behind a film — has no pill
        // to widen. Peeking anyway drew its title into a wing of no width,
        // which under a real notch is invisible and beside a drawn one is not.
        guard vm.compactMediaActivity.isVisible else { return }

        peekWork?.cancel()
        vm.isPeeking = true

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
            withAnimation(Theme.pill(appearing: false, reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.isPeeking = false
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.sneakPeekDuration, execute: work)
    }

    private func refreshCollapsedRects() {
        guard let vm = viewModel, !vm.isOpen, !vm.isDropTargeted else { return }
        // The locked panel's rect is the card's, and it is cut against a
        // screen-sized window — see `sneakPeek`. Re-cut it for the card, not
        // for the collapsed shell.
        guard !vm.isLockedPresentation else {
            applyLockedActiveRect()
            return
        }
        applyActiveRect(open: false)
    }


    private func applyActiveRect(open: Bool) {
        guard let vm = viewModel, let rootView else { return }
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
            size = vm.openBodySize
            // The way back in. `openRect` was only ever cut for the collapsed
            // strip, so once the pointer had been counted as away from an open
            // panel, moving back onto its 620×208 body registered as nothing
            // and only a trip to the notch could reopen it.
            pointer.openRect = vm.geometry.hoverRect(for: vm.openBodySize)
        } else {
            // The full drawn depth, and the full width of the visible compact
            // activity — the pill widens with what is playing, and every point
            // of what is drawn has to open the panel.
            size = CGSize(width: vm.bodySize.width, height: vm.geometry.collapsedDepth)
            pointer.openRect = vm.geometry.collapsedHoverRect(for: vm.bodySize.width)
        }
        // Follows the pill, which changes width with what is playing and widens
        // again for a peek. Left at the width it was built with, the lift would
        // stop short of the artwork the moment a track started.
        pointer.hoverRect = vm.geometry.collapsedIslandHoverRect(for: vm.bodySize.width)
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
        let slack = open ? Theme.openTopRadius : Theme.collapsedTopRadius
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
    }
}
