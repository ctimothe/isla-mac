import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchController {
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var viewModel: NotchViewModel?
    private let pointer = PointerWatcher()
    private let lockPresence = LockScreenPresence()
    private var closeActiveRectWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0

    func install() {
        build()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
        // A dark display has no hover to watch, so the one timer that never
        // otherwise stops — the pointer sampler — stops with it. The panel
        // closes too, so waking always starts from the same, folded state.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setOpen(false)
                self.pointer.setInside(false)
                self.pointer.stop()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointer.start() }
        }
        // Locking replaces the desktop with the shield, and the pill stays on
        // it — see `LockScreenPresence` for the mechanism. Wired here because
        // the two sides of the transition are this controller's verbs: fold,
        // stop the sampler, raise the level; then put all three back.
        lockPresence.onLock = { [weak self] in self?.screenLocked() }
        lockPresence.onUnlock = { [weak self] in self?.screenUnlocked() }
        lockPresence.start()
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    private func activeSpaceChanged() {
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
        guard NotchViewModel.showOnLockScreenEnabled else { return }
        setOpen(false)
        pointer.setInside(false)
        // The cursor still moves on the lock screen — that is how the
        // password field is summoned — so a running sampler would count a
        // pass over the notch as a hover and unfold the panel there.
        pointer.stop()
        // Click-through for the whole locked stretch. `build` starts panels
        // this way, and the first sample after unlock puts it right again.
        panel?.ignoresMouseEvents = true
        lockPresence.apply(to: panel, locked: true)
    }

    /// Unconditional, unlike the lock side: the toggle may have been flipped
    /// mid-lock, and putting a panel back on a level it already occupies
    /// costs nothing. `pointer.start()` doubles with the wake handler when
    /// the display slept too — starting twice only reschedules the timer.
    private func screenUnlocked() {
        lockPresence.apply(to: panel, locked: false)
        pointer.start()
    }

    private func screenParametersChanged() {
        let fresh = NotchGeometry.current()
        guard let current = viewModel?.geometry, current.matches(fresh) else {
            rebuild()
            return
        }
        // Same display, same notch: keep the panel and everything on it.
        panel?.setFrame(fresh.windowFrame, display: false)
    }

    func teardown() {
        lockPresence.stop()
        pointer.stop()
        viewModel?.stop()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
    }

    /// Opens on the translate tab with this text already in it.
    func translate(_ text: String) {
        guard let vm = viewModel else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        peekWork?.cancel()
        vm.isPeeking = false
        vm.translator.input = trimmed
        vm.tab = .translate
        setOpen(true)
        pointer.setInside(true)
        // Held open by the pointer rule like any other tab, so it folds when
        // the user moves away — a translation they walked away from is done.
        scheduleCollapseIfPointerAway()
    }

    func toggle() {
        guard let viewModel else { return }
        // `setOpen`'s close path defers the `isOpen` mutation to the next run
        // loop pass, so reading `viewModel.isOpen` right after calling it would
        // read the stale, pre-close value. Capture the intended target state
        // once, up front, and use that for both calls.
        let opening = !viewModel.isOpen
        setOpen(opening)
        pointer.setInside(opening)
    }

    // MARK: - Construction

    private func rebuild() {
        let previousTab = viewModel?.tab
        peekWork?.cancel()
        pointer.stop()
        viewModel?.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
        viewModel = nil
        build()
        if let previousTab { viewModel?.tab = previousTab }
    }

    private func build() {
        let geometry = NotchGeometry.current()
        let vm = NotchViewModel(geometry: geometry)
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

        root.onDragEntered = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.tab = .shelf
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

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        panel.onPress = { [weak self] in
            guard let vm = self?.viewModel, vm.tab.needsKeyboard else { return }
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
        pointer.warmZone = geometry.warmZone
        // Cut for the tab that will be showing, not for the standard body: a
        // rebuild restores the previous tab, and the teleprompter reaches
        // twice as far down as the rest.
        pointer.closeRect = geometry.hoverRect(for: vm.openBodySize)
        // A real notch is a hole: nothing is under it, so opening the moment the
        // pointer arrives costs nothing. A synthetic one sits on a working menu
        // bar, and a pointer crossing the middle of it is usually on its way
        // somewhere else — unfolding the panel over what it was reaching for is
        // the whole complaint. Staying put is what asks for the panel.
        pointer.openDelay = NotchMetrics.openDelay
        pointer.isDragging = { [weak root] in root?.isReceivingDrag ?? false }
        pointer.isPanelOpen = { [weak vm] in vm?.isOpen ?? false }
        pointer.onChange = { [weak self] inside in
            guard let self else { return }
            // The one place the pointer does not decide — see `holdsOpen`.
            // Guarded here rather than inside `setOpen` so that the reasons
            // that are not the pointer, like the screen going to sleep, still
            // close a running teleprompter.
            if !inside, self.viewModel?.holdsOpen == true { return }
            self.setOpen(inside)
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] interactive in
            self?.panel?.ignoresMouseEvents = !interactive
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

        vm.start()

        // A rebuilt panel starts closed. If the pointer is already sitting on
        // it, reopen at once instead of waiting for a trip back to the notch.
        if geometry.hoverRect(for: vm.openBodySize).contains(NSEvent.mouseLocation) {
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
    /// The teleprompter is the single exception, and it is one because it
    /// cannot be anything else: a script is read while looking at the camera,
    /// which is precisely the moment nobody is touching the trackpad. The
    /// exception is held as narrow as it goes — one tab, and only while the
    /// script is actually moving — and it is enforced where the pointer is
    /// read, not here. Everything else that closes the panel still closes it:
    /// the screen sleeping, the space changing, the display arrangement
    /// changing. A pinned teleprompter surviving any of those would be a panel
    /// stuck open on a screen nobody is looking at.
    private func setOpen(_ open: Bool) {
        guard let vm = viewModel, vm.isOpen != open else { return }
        // Closing for any reason ends the take: the pin is a consequence of the
        // script moving, so the script stops with the panel.
        if !open { vm.teleprompter.suspend() }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            withAnimation(Theme.openAnimation) { vm.isOpen = true }
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

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse() {
        guard let vm = viewModel, vm.isOpen else { return }
        // Whatever was uncovered by hand goes back under cover with the panel.
        // The next hover is the one nobody planned, and it must not open onto
        // a row somebody revealed ten minutes ago.
        vm.privacy.coverEverything()
        withAnimation(Theme.openAnimation) { vm.isOpen = false }
        vm.media.setActive(false)
        // Shrink only once the panel has finished collapsing. Doing it
        // while it is still visibly there would leave a window in which
        // clicks land on whatever is behind the panel.
        let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.collapseRectShrinkDelay, execute: work)
    }

    private func scheduleCollapseIfPointerAway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.pointerAwayCollapseDelay) { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !vm.geometry.hoverRect(for: vm.openBodySize).contains(NSEvent.mouseLocation)
            self.pointer.setInside(!away)
            if away, !vm.holdsOpen { self.setOpen(false) }
        }
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
        guard !pointer.isInside else { return }

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
            withAnimation(Theme.contentAnimation) { vm.isPeeking = false }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.sneakPeekDuration, execute: work)
    }

    private func refreshCollapsedRects() {
        guard let vm = viewModel, !vm.isOpen, !vm.isDropTargeted else { return }
        applyActiveRect(open: false)
    }


    private func applyActiveRect(open: Bool) {
        guard let vm = viewModel, let rootView else { return }
        // Collapsed, the panel claims only its target strip — on a synthetic
        // notch that is deliberately shallower than the menu bar, so clicks on
        // status items underneath reach them instead of a panel nobody can see.
        // The open size is the current tab's, not a constant: the teleprompter
        // is taller, and a rect cut for 208 would leave the bottom half of it
        // visible but untouchable.
        let size: CGSize
        if open {
            size = vm.openBodySize
        } else {
            // A synthetic notch still claims only the top strip so menu-bar
            // items underneath remain clickable, but the strip spans the full
            // width of the visible compact activity.
            size = CGSize(width: vm.bodySize.width, height: vm.geometry.collapsedDepth)
            pointer.openRect = vm.geometry.collapsedHoverRect(for: vm.bodySize.width)
        }
        var rect = vm.geometry.contentRect(for: size)
        if open {
            // Slack so the concave shoulders stay grabbable. Never while
            // collapsed: that would swallow clicks on menu bar items next to
            // the notch.
            rect = rect.insetBy(dx: -Theme.openTopRadius, dy: 0)
        }
        rootView.activeRect = rect
        pointer.interactiveRect = vm.geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -Theme.openTopRadius : 0, dy: 0)
    }
}
