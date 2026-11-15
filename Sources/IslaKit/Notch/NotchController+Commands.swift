import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// Commands that open, toggle or route the panel. Stored properties live in NotchController.swift.
extension NotchController {
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
    func secondaryClicked(at point: NSPoint) -> Bool {
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
                bindings: HotKeyCenter.shared.bindings, hasSong: vm.media.track != nil,
                countdown: stores.live.timers.countdown, stopwatch: stores.live.timers.stopwatch
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
        case .translateClipboard: translateClipboardCommanded()
        case .shelf: openCommanded(.tray, pin: pin)
        case .lyrics: showLyrics(pin: pin)
        case .settings: openCommanded(.settings, pin: pin)
        case .quit: NSApp.terminate(nil)
        case .separator, .timerGroup: break
        case .startTimer(let minutes): stores.live.timers.startCountdown(seconds: TimeInterval(minutes * 60))
        case .startStopwatch: stores.live.timers.startStopwatch()
        case .pauseTimer: stores.live.timers.pauseCountdown()
        case .resumeTimer: stores.live.timers.resumeCountdown()
        case .cancelTimer: stores.live.timers.cancelCountdown()
        case .pauseStopwatch: stores.live.timers.pauseStopwatch()
        case .resumeStopwatch: stores.live.timers.resumeStopwatch()
        case .resetStopwatch: stores.live.timers.resetStopwatch()
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
        translateCommanded { _ in Translator.prepareCommandInput(text) }
    }

    /// ⌃⌥⌘T and the menu's Translate Clipboard: the clipboard's text, read
    /// only once the open is admitted, and read the way the Paste button
    /// reads it (`Translator.textFromPasteboard`).
    ///
    /// Both used to read the pasteboard themselves and hand the string over.
    /// The read then came before the lock's refusal, so the hot key pressed
    /// over the shield, or with the display dark, still read the clipboard —
    /// and under Ask could raise macOS's paste alert there. And a read macOS
    /// refused arrived as `nil`, which the pane reported as "The clipboard
    /// has no text." to somebody whose clipboard was full of it.
    func translateClipboardCommanded() {
        translateCommanded { vm in vm.translator.textFromPasteboard() }
    }

    private func translateCommanded(_ input: (NotchViewModel) -> Translator.CommandInput) {
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
        vm.receiveCommandedTranslation(input(vm))
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
            // "Downloaded" and "AirDrop" also show the file they name (plan
            // 2026-11-14 S5): the click is the obvious next step, and the
            // island folds either way.
            let reveal = vm.confirmation?.revealsFile
            foldAlert()
            if let reveal { Self.revealDownload(named: reveal) }
            return
        }
        // The update alert is answered by its buttons alone; a click beside
        // them is not an answer, and opening the panel would take it down.
        if surface == nil, vm.islandClick == .nothing { return }
        // A timer, a recording or a download answers in place (plan
        // 2026-11-14): there is no surface for any of them to open.
        if surface == nil, case .live(let live) = vm.islandClick {
            liveClicked(live)
            return
        }
        openFromIsland(opening: surface)
    }

    /// A click's open, after the click has decided to open: the surface, the
    /// lift and the pin, then the panel. Shared with the pull, so the two
    /// gestures open the panel by one path rather than two that merely end up
    /// open.
    private func openFromIsland(opening surface: NotchViewModel.Surface?) {
        guard let vm = viewModel else { return }
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

    /// One scroll event on the panel, for the vertical pull: whether it is
    /// kept. The verdict is `NotchViewModel.pullScroll`'s; the open, the close
    /// and the refusal are played out here, the way a click's are.
    func pullScrolled(_ event: NSEvent) -> Bool {
        guard let vm = viewModel else { return false }
        let outcome = vm.pullScroll(PageScroll(event), region: pullRegion(of: event))
        switch outcome {
        case .pass:
            return false
        case .swallow, .stretch, .settle:
            return true
        case .refuse:
            vm.nudgeLockedIsland()
            return true
        case .open(let surface):
            islandPulledOpen(opening: surface)
            return true
        case .close:
            islandPulledShut()
            return true
        }
    }

    /// Where on the panel a scroll event landed, for `IslandPull`: the shut
    /// island's hit region and the bubble's, or the open body's header row
    /// and the rest of it. Read off the event's own location against the
    /// rects `hitTest` answers from, so the pull is heard exactly where a
    /// click would be.
    private func pullRegion(of event: NSEvent) -> IslandPull.Region {
        guard let panel, let rootView, let vm = viewModel, event.window === panel else { return .outside }
        let point = event.locationInWindow
        guard vm.isOpen else {
            if rootView.activeRect.contains(point) { return .island }
            if rootView.bubbleRect.contains(point) { return .bubble }
            return .outside
        }
        guard rootView.activeRect.contains(point) else { return .outside }
        // The header row is the top `notchHeight` of the body on every
        // surface (`SurfaceLayout.headerCentreY`); the window's top is the
        // body's.
        let headerFloor = vm.geometry.windowSize.height - vm.geometry.notchSize.height
        return point.y >= headerFloor ? .header : .body
    }

    /// Two fingers down over the shut island: what a click opens. An alert
    /// folds first rather than instead — the owner asked for the island to be
    /// *shown*, and a pull is the more deliberate of the two gestures — and
    /// the update alert, answered by its buttons alone, is left standing as
    /// a click leaves it. Internal so a test can pull without a trackpad.
    func islandPulledOpen(opening surface: NotchViewModel.Surface? = nil) {
        guard let vm = viewModel, !vm.isOpen else { return }
        if vm.isLockedPresentation {
            vm.nudgeLockedIsland()
            return
        }
        if surface == nil {
            switch vm.islandClick {
            case .nothing: return
            case .foldAlert: foldAlert()
            case .open, .live: break
            }
        }
        openFromIsland(opening: surface)
    }

    /// Two fingers up on the open panel: back to the shut island, pinned or
    /// not — the gesture is as explicit as the click on the notch that closes
    /// a pinned panel too. The click's own close, `closedByHand` included, so
    /// Open on Hover does not reopen the panel under the pointer that pushed
    /// it shut.
    func islandPulledShut() {
        guard let vm = viewModel, vm.isOpen else { return }
        setOpen(false)
        pointer.closedByHand()
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
}
