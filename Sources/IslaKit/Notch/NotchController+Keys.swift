import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// Pointer and keyboard holds. Stored properties live in NotchController.swift.
extension NotchController {
    func refreshPointerTuning() {
        pointer.openDelay = NotchViewModel.hoverOpenDelay
    }

    /// Keeps the outside-click watch alive exactly while the panel is holding
    /// itself open — which since the teleprompter went on 2026-08-22 means the
    /// pin and nothing else (`holdsOpen` is now just `isPinnedOpen`). It is a
    /// state the pointer cannot end, and it promises a click outside will.
    func updatePinnedClickMonitor(selectionIsCurrent: Bool? = nil) {
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
    ///
    /// It drops the Shelf selection for the same reason, pinned or not. A
    /// panel opened by a click stays open while the pointer rests on it, and
    /// with a tile selected it holds ⌫ and ⌘⌫ system-wide
    /// (`ShelfDeleteKeyHolder`): ⌘-Tab to Mail, press Delete in a message,
    /// and Isla took the key and removed the card while Mail got nothing.
    /// Isla's own activation — Quick Look, AirDrop — is not another app, and
    /// neither is the activation that follows it: Isla handing the keyboard
    /// back when that window closes (`ActivationLease.end`). The tiles looked
    /// at in Quick Look stay selected for the next thing done with them.
    ///
    /// Internal so a test can stand in for the switch.
    func applicationActivated(_ pid: pid_t?) {
        guard let vm = viewModel, let pid else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let leavingIsla = lastActivatedPID == ownPID
        lastActivatedPID = pid
        if pid != ownPID, !leavingIsla { vm.shelf.clearSelection() }
        guard vm.appActivated(ownPID: ownPID, activatedPID: pid) else { return }
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
    func updateEscapeHotKey(pinned: Bool, panelHasKeyboard: Bool, locked: Bool) {
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
    func updateDeleteKey(open: Bool, onShelf: Bool, pointerOnShelf: Bool, hasSelection: Bool, locked: Bool) {
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
    func updateShelfZone(open: Bool, size: CGSize, surface: NotchViewModel.Surface? = nil) {
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
}
