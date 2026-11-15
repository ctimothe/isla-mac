import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// Opening and closing the panel and its wiring. Stored properties live in NotchController.swift.
extension NotchController {
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
    func setOpen(_ open: Bool) {
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
            // The pill's own timer, with the flag the view model has ended. The
            // key keeps working with the panel open and the next press shows
            // its level as the capsule under the panel (`hudPlacement`); the
            // permission is looked at again, since the panel opening is one of
            // the moments trust is re-read.
            hudFoldWork?.cancel()
            hudFoldWork = nil
            // The update alert's hold and retry: the view model takes the alert
            // down with the open, and the panel closing offers it again.
            cancelUpdateWork()
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
    func collapseNow() {
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
        // The capsule under the panel folds with it (the view model takes it
        // down as `isOpen` flips, in the close's own transaction); its timer
        // goes too, so it cannot fold a pop-up that a press on the shut island
        // has drawn since, nor promote a waiting alert early.
        if vm.hudStrip != nil {
            hudFoldWork?.cancel()
            hudFoldWork = nil
        }
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

    func scheduleCollapseIfPointerAway(after delay: TimeInterval = NotchMetrics.pointerAwayCollapseDelay) {
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
    func wireShelfIslandCuts(_ vm: NotchViewModel) {
        vm.shelf.$items
            .combineLatest(vm.$isShowingCollected)
            .map { NotchViewModel.shelfCut(items: $0, showingCollected: $1) }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCollapsedRects() }
            }
            .store(in: &cancellables)
    }

    func wireShelfClaims(_ vm: NotchViewModel) {
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
    func wirePageTravelCuts(_ vm: NotchViewModel) {
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
    func wireEscapeClaim(_ vm: NotchViewModel) {
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

    /// Test seam: gives the controller a model and a root view without building
    /// a panel, starting the stores or reading a screen, so the rect logic can be
    /// held at the controller rather than by its pure helpers alone.
    func attachForTesting(
        viewModel: NotchViewModel, rootView: NotchRootView, menuTracking: MenuTracking? = nil
    ) {
        self.viewModel = viewModel
        self.rootView = rootView
        viewModel.onConfirmation = { [weak self] in self?.presentConfirmation($0) }
        viewModel.onStripClosed = { [weak self] in self?.stripClosed($0) }
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
        wireAlertPromotion(viewModel)
    }

    /// An alert that had to wait for the island — a surface open, files
    /// dragged over it, the Mac locked — shows if the island comes free
    /// inside its wait (spec §19.1; a confirmation's is five seconds). A pass
    /// later: `@Published` announces before it stores, and the queue reads the
    /// stored values. Shared with `attachForTesting`, so a test that closes
    /// the panel sees the waiting alert follow.
    func wireAlertPromotion(_ vm: NotchViewModel) {
        vm.$isOpen.removeDuplicates().map { _ in () }
            .merge(with: vm.$isDropTargeted.removeDuplicates().map { _ in () })
            .merge(with: vm.$isLockedPresentation.removeDuplicates().map { _ in () })
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.promoteWaitingAlert() }
            }
            .store(in: &cancellables)
    }

    /// Shows the new track for a moment, then folds back.
    ///
    /// The lowest of the island's alerts (spec §19.1, rank 10), so it goes
    /// through `alertQueue` like the rest: it waits, for a second at most,
    /// while the panel is open, files are dragged to it or the Mac is locked,
    /// and while a higher alert — the pop-up, the charger, headphones — holds
    /// the island. A new track on top of one of those would put two things in
    /// one island. Nothing peeks *at* a locked screen: the peek re-cuts the collapsed
    /// rects, and while the shield is up those rects belong to the lock card —
    /// a track changing on a locked Mac used to hand the card's hit region to a
    /// strip computed for the notch-sized window, killing its transport and
    /// leaving a phantom click-eating rectangle elsewhere on the shield.
    ///
    /// Refused outright, not queued, with the pointer on the island: the user
    /// is doing something there, and the alert would fold out from under them
    /// when it ended. The pointer is asked only once nothing blocks — over an
    /// open panel it is always inside, and that says nothing about the island
    /// the alert will hang from once the panel has gone.
    ///
    /// Shown as the volume pop-up is (spec §3.5, amended 2026-11-15): its shape
    /// under the notch, its spring in and out.
    func sneakPeek() {
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
        // Unfolding as the pop-up does, on its spring (§3.5, amended
        // 2026-11-15: "exactly how the volume changer is shown").
        withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.isPeeking = true
        }
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
            // Folding back into the song's pill on the pop-up's spring, as
            // the pop-up folds. The shell declares the same curve for
            // `isPeeking`; stating it here keeps the two from drifting apart.
            withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                vm.isPeeking = false
            }
            self.promoteWaitingAlert()
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.sneakPeekDuration, execute: work)
    }

    /// Folds a new track's alert whose song is gone, on the pop-up's spring.
    func endPeekWithoutASong() {
        guard let vm = viewModel, vm.isPeeking else { return }
        peekWork?.cancel()
        peekWork = nil
        withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.isPeeking = false
        }
        promoteWaitingAlert()
    }
}

/// The Escape a test attaches: registers nothing, gives nothing back.
private final class InertHotKeyRegistration: HotKeyRegistration {
    func unregister() {}
}
