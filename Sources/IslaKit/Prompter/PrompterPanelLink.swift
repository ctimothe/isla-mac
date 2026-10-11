import Foundation

// The vocabulary the panel and the Prompter share (spec section 11). The
// session stays a model with no UI; the view model turns commands into these
// values, and the controller turns them into panel effects. Kept apart from
// both so a test can drive every rule here without a window, a screen or a
// pointer.

// MARK: - System events

/// What the Mac did, as far as a session is concerned. The controller owns
/// the observers (the lock notifications through `LockScreenPresence`, the
/// workspace's sleep and wake, the screen-parameter change, termination) and
/// forwards each one here, so the mapping from event to state is one function
/// with a test rather than five observer bodies that each had to remember it.
enum PrompterSystemEvent: Sendable, Equatable {
    case screenLocked
    case screenUnlocked
    /// `NSWorkspace.screensDidSleepNotification`: the display went dark.
    case displaysSlept
    /// `NSWorkspace.willSleepNotification`: the whole Mac is going to sleep.
    /// Usually preceded by `displaysSlept`, but not with the lid closed on an
    /// external display, which is how a talk is given.
    case systemWillSleep
    /// The display or the system woke.
    case woke
    /// `didChangeScreenParametersNotification`: the panel is about to be
    /// rebuilt or re-framed.
    case screenParametersChanged
    case appWillTerminate
}

extension PrompterSession {
    /// Spec 7.1 and 11.3 to 11.8, one row per event.
    ///
    /// Unlock and wake do nothing, and that is the rule, not an omission: a
    /// session the system paused is resumed by the speaker (E-39, E-40). A
    /// session that picked itself up on wake would run text past somebody
    /// still finding their place, with the display-awake lease taken again
    /// behind their back. A display change does nothing either (7.3): the
    /// panel is rebuilt around the session, never the other way round.
    func handle(_ event: PrompterSystemEvent) {
        switch event {
        case .screenLocked:
            pause(.lock)
        case .displaysSlept, .systemWillSleep:
            pause(.sleep)
        case .appWillTerminate:
            // Spec 7.1 "App quit: any → ended". The confirmation is the
            // Settings row's (11.7); by the time termination is under way the
            // answer was yes, and the lease must not outlive the process's
            // last chance to end it.
            stop()
        case .screenUnlocked, .woke, .screenParametersChanged:
            return
        }
    }

    /// The `prompter.*` settings the session itself reads (spec 12.2). Speed
    /// applies to a running clock from its next tick (8.1); auto-next and its
    /// delay are read at the next page end (8.6); keep-awake applies at once
    /// (11.8). The rest are the stage's.
    ///
    /// Each one is compared before it is written, so re-applying the same
    /// values (every settings change re-applies all of them) does not
    /// republish the session's speed and redraw a stage for nothing.
    func apply(_ values: PrompterSettingsValues) {
        if speed != PromptClock.clampedSpeed(values.speed) { setSpeed(values.speed) }
        if autoNext != values.autoNext { autoNext = values.autoNext }
        if autoNextDelay != values.autoNextDelay { autoNextDelay = values.autoNextDelay }
        if keepAwake != values.keepAwake { keepAwake = values.keepAwake }
    }
}

// MARK: - What the panel is asked to do

/// The panel's half of a Prompter command, decided by the view model and
/// carried out by the controller (`NotchController.presentPrompter`).
enum PrompterPresentation: Sendable, Equatable {
    /// Refused by `admitsCommandedOpen`: over the shield (the island has
    /// already shaken) or on a dark display (nothing to say). Nothing else.
    case refused
    /// Nothing for the panel: the switch is off, or there was nothing to stop.
    case nothing
    /// A session is live: open the panel on its stage. Not pinned; the
    /// session holds the panel itself (11.1), and a pin would bring its
    /// Escape claim with it (5.4 forbids that).
    case openStage
    /// Open on the Prompter tab, pinned unless the pointer is on it: a question
    /// for the control row (a shared display, 11.6) or a reason (nothing to
    /// read, E-20). No session exists yet.
    case openTab
    /// The session ended: hand the panel back to the pointer, which folds it
    /// if the pointer is elsewhere (a Stop from the hot key) and leaves it on
    /// the tab if the pointer is on it (the stage's Stop button).
    case release
}

/// Why a start asks first (spec 11.6, E-48). `sharingType = .none` hides the
/// panel from software capture only; a hardware mirror, and a lid-shut laptop
/// whose only display is the projector, put the script in front of the room.
enum PrompterDisplayShare: Sendable, Equatable {
    /// An active display is in a mirror set (`CGDisplayIsInMirrorSet`).
    case mirrored
    /// Only external displays, on a Mac with a battery: a laptop presenting
    /// with its lid shut (`NotchController.isSoleExternalDisplay`).
    case soleExternal

    /// Mirrored wins when both hold: it is the case the spec words the
    /// question for.
    static func reading(mirrored: Bool, soleExternal: Bool) -> PrompterDisplayShare? {
        if mirrored { return .mirrored }
        if soleExternal { return .soleExternal }
        return nil
    }

    /// The question the tab's control row asks, above its Start Anyway.
    var message: String {
        switch self {
        case .mirrored:
            return localized("Your display is mirrored. People watching the mirror will see your script.")
        case .soleExternal:
            return localized("Isla is on your only display. People watching it will see your script.")
        }
    }

    /// The arm-then-confirm control's title (`ConfirmationArming`).
    static var confirmTitle: String { localized("Start Anyway") }
}

/// What the view model needs from the controller to decide a command. Set by
/// `NotchController.build()` on every model it makes; a test sets fakes. The
/// defaults are inert: a model nobody wired cannot open anything.
@MainActor
struct PrompterPanelHooks {
    /// The controller's `screensAreAsleep`, for `admitsCommandedOpen`.
    var screensAsleep: @MainActor () -> Bool = { false }
    /// Read once per start, never cached: a projector plugged in a second ago
    /// has to count.
    var displayShare: @MainActor () -> PrompterDisplayShare? = { nil }
    var present: @MainActor (PrompterPresentation) -> Void = { _ in }
}

// MARK: - Parts

extension PrompterParts {
    /// The script a start reads: the library's current one, or the first when
    /// none is current yet (the tab sets it; a fresh library has the sample).
    var currentScript: PrompterScriptRecord? {
        library.currentScriptID.flatMap(library.script) ?? library.scripts.first
    }

    /// The current script's page texts, or nil when no page has a word (E-20:
    /// Start is refused with a reason, which the tab shows). Decided without
    /// tokenizing anything: the tokenizer makes a word of every run of
    /// non-whitespace `Character`s, so "has a non-whitespace character" is
    /// the session's own test for a readable page (`PrompterStageRenderTests`
    /// holds the two equal on the edge cases) and a page of cues alone still
    /// starts and finishes at once (E-21). It replaced tokenizing every page
    /// here, on the main thread, before a start (E-26).
    func readableTexts() -> [String]? {
        guard let record = currentScript else { return nil }
        return record.pages.contains(where: Self.hasWords) ? record.pages : nil
    }

    static func hasWords(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    /// Up to this many bytes of script (about 6,000 words of prose, a long
    /// talk) are tokenized where the start is asked for: 64 KB measured 18 ms
    /// in a debug build, so this is about 9 ms, inside a frame, and a start
    /// that shows its stage at once is worth more than a background hop for
    /// a talk-length script. Past it, a background task (E-26). The UTF-8
    /// count of a native string is O(1), so deciding costs nothing.
    static let synchronousTokenizeLimit = 32_768

    static func tokenizesAtOnce(_ texts: [String]) -> Bool {
        var total = 0
        for text in texts {
            total += text.utf8.count
            if total > synchronousTokenizeLimit { return false }
        }
        return true
    }
}
