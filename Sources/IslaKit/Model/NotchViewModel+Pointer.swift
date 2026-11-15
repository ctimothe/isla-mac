import AppKit
import Combine
import UniformTypeIdentifiers

/// What the pointer and a click do, and the verdicts on opening. Stored properties live in NotchViewModel.swift.
extension NotchViewModel {
    /// The pointer reaching the island: the panel is handed back to it.
    ///
    /// State, not event plumbing, so it can be tested without a pointer.
    /// Unconditional on Open on Hover — the setting decides whether arriving
    /// *opens* the panel, never whether arriving takes back a panel that is
    /// already open. A step of its own inside `pointerCrossed` because a drag
    /// arriving must not run it; see there.
    ///
    /// What a click would open, for an arrival at the *closed* island: Open on
    /// Hover opens that (spec §19.1). A panel already open is not being arrived
    /// at, it is being used — the hand that went for a Clipboard row once had
    /// the pane swap under it (J-008, 2026-10-11). The pin still goes either
    /// way: the pointer reaching the panel is what hands it back, whatever
    /// surface it is on.
    func pointerArrived() {
        isPinnedOpen = false
        if !isOpen { land(on: openTarget) }
    }

    /// What the pointer crossing the panel's boundary asks the panel to do.
    ///
    /// A verdict rather than an action, so the sequence that used to strand a
    /// panel open — approach, click, walk away — can be played out in a test
    /// with no panel, no screen and no cursor. The controller keeps the
    /// effects; the rules live here with the state they read.
    enum PointerCrossing: Equatable {
        /// The pointer arrived and Open on Hover is switched on.
        case opens
        /// The pointer left and nothing is holding the panel open.
        case closes
        /// Neither: an arrival that only hands the panel back to the pointer,
        /// or a departure that the pin refuses.
        case standsAsItIs
    }

    /// - Parameter inside: whether the pointer is now within the rect that
    ///   holds the panel open — `NotchGeometry.hoverRect(for:)` while open, the
    ///   collapsed hover rect while shut.
    /// - Parameter dragging: whether a drag session is in flight, in which case
    ///   the arrival is not counted at all. A drag is not a hover: the pointer
    ///   arriving with a file in hand has already said what it wants — the
    ///   drop surface — so the arrival must not reset what lies under it.
    ///   It used to, roughly `openDelay` after the file crossed the island,
    ///   which flipped the pane Shelf→Music mid-drag and took `ShelfPane`'s drop
    ///   highlight with it until the drop put it back. Leaving the pin standing
    ///   with it costs nothing: `PointerWatcher.isDragging` already holds the
    ///   panel open for as long as the session runs.
    func pointerCrossed(inside: Bool, dragging: Bool = false) -> PointerCrossing {
        if inside {
            if !dragging { pointerArrived() }
            // The arrival takes the panel back from whatever opened it without
            // a pointer, and it does so *before* the hover-to-open question is
            // asked. Asked first, with the setting off — the default — it
            // returned early and left the pin standing, so a clicked-open panel
            // ignored the pointer leaving and could only be dismissed by
            // clicking somewhere else entirely.
            //
            if !isOpen, !Self.arrivalMayOpen(over: activity) { return .standsAsItIs }
            return Self.opensOnHoverEnabled ? .opens : .standsAsItIs
        }
        // The one place the pointer does not decide — see `holdsOpen`. Asked
        // here rather than inside `NotchController.setOpen` so that the reasons
        // that are not the pointer, like the screen going to sleep, still close
        // a pinned panel.
        return holdsOpen ? .standsAsItIs : .closes
    }

    /// Whether Open on Hover may open the panel over what the shut island
    /// shows. Not over the update alert: the pointer is on its way to a
    /// button, and opening would take the alert down under it (spec §19.5 f).
    /// Nor over a new track's alert (§3.5, amended 2026-11-15): it hangs 65 pt
    /// under the notch, as the pop-up does, and it comes to the pointer rather
    /// than the pointer to it — a pointer resting on a tab bar under the notch
    /// would otherwise open the panel on every skip. A click still opens it.
    nonisolated static func arrivalMayOpen(over activity: IslandActivity) -> Bool {
        switch activity {
        case .update, .peek: return false
        default: return true
        }
    }

    /// The state half of a click that opens the island. The controller owns the
    /// rest — the active rect, the animation, the pointer watcher.
    ///
    /// - Parameter pointerIsOnPanel: whether the cursor is inside the rect the
    ///   open panel holds itself open from. It normally is, because the island
    ///   sits inside that rect, so a mouse click lands the pointer there by
    ///   definition and the panel needs no pin: leaving is what closes it.
    ///   False only for a click that did not come from the mouse at all — the
    ///   compact island's accessibility action, which VoiceOver fires from the
    ///   keyboard with the cursor wherever it was left.
    /// - Parameter surface: what was clicked asked for — the bubble names the
    ///   tray — or nil for what the island shows (`openTarget`).
    ///
    /// `pointerIsOnPanel` is asked after the surface is chosen, with the body
    /// that is opening. Since R8 every surface has its own width, and a
    /// question put before the choice measured the surface shown last: a click
    /// on the far end of a peek wider than the player read as "pointer
    /// elsewhere" and pinned a panel the pointer was standing on (R8 review F1).
    func clickOpened(opening surface: Surface? = nil, pointerIsOnPanel: (_ openBody: CGSize) -> Bool) {
        // The surface first. Skipping it meant a click opened whatever had
        // been left behind and then swapped panes *during* the expansion,
        // which is most of what read as an unsmooth open. What was clicked
        // decides it (spec §19.1).
        land(on: surface ?? openTarget)
        // The hover lift goes out with the same animation that opens the panel,
        // rather than snapping off the instant `isOpen` flips.
        isHovering = false
        // Pinning a panel the pointer is already standing on is what broke the
        // walk-away: the pin is only cleared when the pointer *arrives*, and
        // arriving is a transition that had already happened before the click.
        // So the departure was refused by `holdsOpen` and the panel stayed open
        // until something else was clicked (fixed 2026-09-10).
        isPinnedOpen = !pointerIsOnPanel(openBodySize)
    }

    /// Whether a pinned panel holds Escape, through a hot key registered only
    /// for as long as this answers true.
    ///
    /// "Escape" was the first way out the pin promised, and it was false: the
    /// panel is key only while Translate or Clipboard asks for the keyboard, Escape is read
    /// only in `NotchPanel.sendEvent`, so after ⌃⌥⌘I on Music the key went to
    /// the app underneath and the panel stayed up (F-004). Making the panel key
    /// would have answered it at the cost of dimming the frontmost window and
    /// stopping its caret — the very rudeness the never-key panel exists to
    /// avoid — so the pin holds Escape instead, and nothing else.
    ///
    /// It holds less than it could, on purpose:
    /// - **not while the panel is key**: `sendEvent` already reads Escape then,
    ///   and must keep reading it first, because an input method mid-composition
    ///   owns it and Translate spends it on clearing the field;
    /// - **not while this app is active**: Quick Look and AirDrop activate it
    ///   from a Shelf card, and their windows answer Escape themselves;
    /// - **never over the shield**: a key the lock screen's password field does
    ///   not get is one taken from the person unlocking;
    /// - **not while one of this app's menus is open**: the island's menu pops
    ///   from a pinned panel's header too, and a Carbon hot key is dispatched
    ///   ahead of the menu's tracking, so the claim folded the panel behind a
    ///   menu that stayed open (R8 review F4).
    ///
    /// The cost is that the one Escape pressed while a pin stands goes to Isla
    /// and not to the app in front — a vim user reading lyrics loses one
    /// keystroke, the one that also folds the panel they were reading. The pin
    /// ends on that press, and the registration ends with it.
    nonisolated static func claimsEscape(
        pinned: Bool,
        panelHasKeyboard: Bool,
        appIsActive: Bool,
        locked: Bool,
        menuOpen: Bool = false
    ) -> Bool {
        pinned && !panelHasKeyboard && !appIsActive && !locked && !menuOpen
    }

    /// Whether the Shelf holds Delete and ⌘⌫, through hot keys registered only
    /// for as long as this answers true (spec §8.2, owner decision 9).
    ///
    /// The panel is never key outside Translate and Clipboard, so a Delete pressed with the
    /// pointer on the Shelf goes to whatever app is in front, and the key
    /// the spec promises would do nothing. The pinned panel's Escape set the
    /// precedent (`claimsEscape`): a Carbon hot key, which needs no permission
    /// and sees nothing else that is typed, held for exactly as long as the
    /// claim stands.
    ///
    /// **A global Delete is the most expensive key to leave behind** — a
    /// registration that outlives its reason eats the person's Delete in every
    /// app until Isla quits — so the claim is as narrow as it can be made, and
    /// every term is one that must hold *now*:
    /// - the panel is open on the tray, and nothing is presented over it;
    /// - the pointer is on the tray — leaving it, even to the header, gives
    ///   Delete back, because that is the person saying their hands are
    ///   elsewhere;
    /// - there is a selection to remove — no selection, no key, so a Delete
    ///   pressed with nothing picked is never swallowed;
    /// - **not while this app is active**: Quick Look and AirDrop activate it,
    ///   and their windows have their own use for the key;
    /// - **never over the shield**.
    ///
    /// A panel that happens to be key needs none of this (`NotchPanel` reads the
    /// key itself), but the claim does not ask: while key, a registration and
    /// `sendEvent` do the same thing, and one fewer term is one fewer way for
    /// the two to disagree.
    nonisolated static func claimsDelete(
        panelOpen: Bool,
        onShelf: Bool,
        pointerOnShelf: Bool,
        hasSelection: Bool,
        appIsActive: Bool,
        locked: Bool
    ) -> Bool {
        panelOpen && onShelf && pointerOnShelf && hasSelection && !appIsActive && !locked
    }

    /// Whether another app coming to the front ends the pin.
    ///
    /// ⌘-Tab is the keyboard's click in another app, and a click in another app
    /// already ends a pin (`NotchController.updatePinnedClickMonitor`). Without
    /// this, switching apps from the keyboard left a pinned panel standing over
    /// the menu bar of the app one had switched to. This app's own activation is
    /// not another app: Quick Look and AirDrop activate Isla from inside a
    /// pinned panel, and the panel must survive that.
    func appActivated(ownPID: pid_t, activatedPID: pid_t) -> Bool {
        isPinnedOpen && activatedPID != ownPID
    }

    /// What a click on the island does: open what it shows, or fold an alert
    /// (spec §19.1's first table).
    var islandClick: IslandClick {
        Self.click(on: activity, live: liveActivity, hasTrack: media.track != nil, lastPage: lastPage)
    }

    /// What ⌃⌥⌘I, Open on Hover and a click open: the player for the song, the
    /// tray for the Shelf, the page last shown on the bare notch — over an
    /// alert, what the click would open once it folds.
    var openTarget: Surface {
        Self.openTarget(live: liveActivity, hasTrack: media.track != nil, lastPage: lastPage)
    }

    func nudgeLockedIsland() {
        guard isLockedPresentation else { return }
        lockedHoverNudges += 1
        // The shake says "not here" only to someone who can see it, and under
        // Reduce Motion it does not play at all. Every refusal comes through
        // here — the click, ⌃⌥⌘I, the translate and lyrics keys, the AX
        // action — so this is the one place the refusal is also spoken. The
        // announcer's repeat window keeps a click that arrives by two routes
        // to one sentence.
        Announcer.shared.announce(localized("Unlock your Mac to open Isla."))
    }

    /// What a deliberate open command — ⌃⌥⌘I, the translate shortcut, the
    /// welcome — is worth right now.
    ///
    /// Over the shield nothing may open and nothing may take the keyboard. An
    /// open there is not merely invisible-because-covered: `setOpen(true)`
    /// grows the clickable region from the deliberate pill-sized locked rect
    /// (`applyLockedActiveRect`) to the open body, over the password field, and
    /// the translate route would additionally land on a tab that types — a
    /// window the lock presentation deliberately lifted above the shield, now
    /// key and holding the keyboard. `panel.onPress` already refuses exactly
    /// that at the keyboard, and the island's own click refusal answers with
    /// the shake; the commands get the same grammar: refuse, and shake the pill
    /// instead of doing nothing, which would read as a dead app rather than as
    /// a limit.
    ///
    /// A verdict rather than an action, so the sequence — command, refusal,
    /// shake — can be played out in a test with no panel, the same shape as
    /// `PointerCrossing`. The controller keeps the effects.
    enum CommandVerdict: Equatable {
        /// The command runs its ordinary open path.
        case proceed
        /// Over the shield: shake the pill and do nothing else.
        case refuseWithShake
        /// Every display asleep: do nothing at all. A Shortcut or a Focus
        /// automation ("when AirPods connect, show lyrics") that ran with the
        /// lid shut opened a pinned panel nobody could see, started the media
        /// clock and the player polls for it, and left it pinned open at wake
        /// (J-026). There is no pill on a dark display to shake, so the refusal
        /// has nothing to say. Deferring the open to wake was rejected: the
        /// automation that asked has long finished, and a panel appearing when
        /// the lid opens is a surprise rather than an answer.
        case refuseQuietly
    }

    /// The verdict for the commanded opens — the hot keys, the Shortcuts, the
    /// Translate service — asked before any of them touches a tab, the
    /// translator, the pin or `setOpen`.
    ///
    /// `screensAsleep` is the controller's, which owns the sleep and wake
    /// notifications; it is a parameter rather than a default so a new command
    /// cannot forget to ask. The lock wins when both hold, so the shield keeps
    /// one grammar however the screen happens to be.
    func verdictForDeliberateOpen(screensAsleep: Bool) -> CommandVerdict {
        if isLockedPresentation { return .refuseWithShake }
        if screensAsleep { return .refuseQuietly }
        return .proceed
    }

    /// What a *show* asks for, as against a toggle.
    ///
    /// Show Isla and Show Lyrics used to call the hot keys' toggles, so a
    /// Shortcut or a Focus automation titled *Show* that ran while the panel
    /// was already open closed it, and Show Lyrics folded the words back to
    /// the player (F-024). A show only ever opens. Asked after the lock
    /// verdict, never instead of it.
    enum ShowVerdict: Equatable {
        /// Run the ordinary pinned open.
        case open
        /// Already showing what was asked for: touch nothing, the pin included.
        case alreadyOpen
    }

    /// Show Isla and reopening the app: an open panel, on whatever surface,
    /// is already the panel.
    nonisolated static func showVerdict(isOpen: Bool) -> ShowVerdict {
        isOpen ? .alreadyOpen : .open
    }

    /// Show Lyrics: only the stage itself is already shown. Open on the player
    /// or another surface, it goes on to the words — where ⌃⌥⌘L's toggle would
    /// turn the stage back into the player instead.
    nonisolated static func showLyricsVerdict(isOpen: Bool, surface: Surface) -> ShowVerdict {
        isOpen && surface == .stage ? .alreadyOpen : .open
    }
}
