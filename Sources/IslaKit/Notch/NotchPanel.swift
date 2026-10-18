import AppKit

/// Borderless, non-activating panel that lives above the menu bar on every space.
final class NotchPanel: NSPanel {
    /// Off by default: taking key status dims the title bar of whatever the
    /// user is working in and stops their insertion point blinking, which is
    /// far too rude for a panel one merely hovers. The translate tab needs
    /// typing, so it turns this on for as long as it is open.
    ///
    /// `.nonactivatingPanel` is what makes that affordable — the panel gets
    /// keyboard input without the app ever becoming active.
    var acceptsKeyboard = false {
        didSet {
            guard acceptsKeyboard != oldValue else { return }
            if acceptsKeyboard {
                makeKey()
            } else if isKeyWindow {
                // There is no supported way to simply hand key status back, and
                // this app owns no other window to pass it to. Ordering out and
                // straight back in resigns it; the panel is borderless and the
                // round trip happens within one pass, so nothing flickers.
                orderOut(nil)
                orderFrontRegardless()
            }
        }
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    /// One notch above the status bar, so the panel covers the menu bar
    /// itself. Named because it is set from two places: `init` puts the panel
    /// here, and the lock-screen presence — which raises the level past the
    /// shield while the Mac is locked — needs the exact resting place to put
    /// it back on unlock.
    static var normalLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    }

    /// Physical keys, the fallback for a layout that prints no Latin letter.
    /// A Cyrillic layout answers ⌘C with "с" (U+0441), not "c" (U+0063) —
    /// they are indistinguishable on screen and unequal to every string
    /// comparison, which is why matching on characters alone quietly fails
    /// exactly for the person typing Russian. Key codes name the key, not
    /// what it prints.
    ///
    /// Only the fallback, though: they name the key by where it sits on a US
    /// keyboard, and a Latin layout moves the letters. On German QWERTZ the
    /// key labelled Z is key code 16, so matching code 6 left ⌘Z dead and made
    /// ⌘Y undo; on AZERTY ⌘A did not select all (F-039). A layout that prints
    /// a Latin letter is matched by that letter — see `editingCommand`.
    private enum Key {
        static let a: UInt16 = 0
        static let z: UInt16 = 6
        static let x: UInt16 = 7
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let escape: UInt16 = 53
    }

    /// What an editing key asks for.
    enum EditingCommand: Equatable {
        case selectAll, cut, copy, paste, undo, redo
        /// ⇧⌘C. Raised through `onCopyTranslation` before anything else,
        /// because nothing in the responder chain owns the translation: it is
        /// read-only text in a column beside the field that has the caret.
        case copyTranslation

        /// The responder-chain action, the one the Edit menu would send.
        /// Undo and redo are informal: nothing declares them, the Edit menu
        /// just names the selector and lets the chain find an undo manager.
        /// The translation's fallback is a plain copy, which is what ⇧⌘C did
        /// before it meant anything.
        var action: Selector {
            switch self {
            case .selectAll: return #selector(NSText.selectAll(_:))
            case .cut: return #selector(NSText.cut(_:))
            case .copy, .copyTranslation: return #selector(NSText.copy(_:))
            case .paste: return #selector(NSText.paste(_:))
            case .undo: return Selector(("undo:"))
            case .redo: return Selector(("redo:"))
            }
        }
    }

    /// ⌘A, ⌘X, ⌘C, ⌘V and ⌘Z are ordinarily key equivalents of the Edit menu,
    /// and an `.accessory` app has no menu bar to carry them — so they never
    /// reach the text view on their own. Installing a main menu just for them
    /// would put one in the menu bar the moment the app was ever activated, so
    /// they are dispatched here instead.
    ///
    /// Caught in `sendEvent` rather than in `performKeyEquivalent`: the latter
    /// is only ever called by `NSApplication` for its key window, and while the
    /// app is inactive it does not consider itself to have one. Every event the
    /// window receives passes through here regardless.
    /// Raised on any press inside the panel, before the press is delivered.
    ///
    /// A tap gesture on the text editor never fires — the text view claims the
    /// mouse down first — so the one place a click on the field can reliably
    /// be noticed is here, where every event the window receives passes.
    ///
    /// With the press's point in the window: only a press into the field
    /// asks for the keyboard (`NotchViewModel.pressClaimsKeyboard`).
    var onPress: ((NSPoint) -> Void)?

    /// Raised on Escape, whatever has the keyboard. Collapsing is the one
    /// thing every tab agrees Escape should do, and binding it inside
    /// individual panes meant it worked on two of them and nowhere else.
    var onEscape: (() -> Void)?

    /// Asked before `onEscape`. Returning true means a pane wanted this
    /// Escape — clearing a field, handing the keyboard back — and the panel
    /// stays open.
    var escapeHandled: (() -> Bool)?

    /// Asked on Delete and ⌘⌫ while the panel is key (`isRemoveKey`). True means
    /// the Shelf took the key and removed its selection; false lets it through
    /// to whatever has the caret. The panel is key only on Translate, so this
    /// is the half of "Delete removes the selection while the pointer is on the
    /// Shelf or the panel is key" that a registered hot key does not cover —
    /// kept because it costs a closure and the day a second tab takes the
    /// keyboard it is already right (spec §8.2).
    var removeKeyHandled: (() -> Bool)?

    /// A key that moves through a list or acts on its selection (spec §19.8):
    /// ↑, ↓ and Return, with no modifier.
    enum ListKey: Equatable {
        case up, down, enter
    }

    /// The list key a press is, or nil. ⇧, ⌘, ⌥ and ⌃ disqualify a press —
    /// ⇧↑ extends a selection in the field and ⌘↑ goes to its start — while
    /// Caps Lock, fn and the arrows' own numeric-pad flag do not.
    static func listKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ListKey? {
        guard flags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch Int(keyCode) {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .enter
        default: return nil
        }
    }

    /// Asked on ↑, ↓ and Return while the panel is key. True means the
    /// surface took the key — Clipboard moving its selection, or copying it —
    /// and the field with the caret never hears of it.
    var listKeyHandled: ((ListKey) -> Bool)?

    /// A right-click, or a left click with Control and nothing else held,
    /// which macOS means as one.
    static func isSecondaryClick(type: NSEvent.EventType, flags: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .rightMouseDown: return true
        case .leftMouseDown: return flags.intersection([.command, .control, .option, .shift]) == .control
        default: return false
        }
    }

    /// Asked on a secondary click, with its point in the content view. True
    /// means the island took it — its menu, or the locked island's shake
    /// (spec §19.9) — and nothing under the point hears of it; false passes it
    /// on to a clipboard row's own menu or a tile's Open With.
    var secondaryClickHandled: ((NSPoint) -> Bool)?

    /// Whether a press is ⌘, — Settings, the shortcut every Mac app gives its
    /// settings (spec §19.1). Only ⌘ may be held, Caps Lock aside. The comma
    /// is the one the press printed when it printed something Latin, which
    /// keeps a layout that moves the comma working, and the US comma's key
    /// position otherwise, as the editing keys fall back for Cyrillic.
    static func isSettingsKey(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.intersection([.command, .control, .option, .shift]) == .command else { return false }
        if let first = characters?.first, first.isASCII { return first == "," }
        return keyCode == 43
    }

    /// Asked on ⌘, while the panel is key. It is key only while a surface has
    /// the keyboard, so this is the whole of "⌘, while a surface has the
    /// keyboard": on every other surface ⌘, belongs to the app in front, and
    /// the island never registers it as a global key. True means Settings
    /// opened and the field with the caret never hears of it.
    var settingsKeyHandled: (() -> Bool)?

    /// The page a press turns to (spec §19.16): ⌃Tab one page on, ⌃⇧Tab one
    /// back, as they move between tabs in Safari and Finder; nil for every
    /// other press. Tab is key code 48 on every layout, so only the modifiers
    /// decide, Caps Lock aside.
    static func pageStep(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Int? {
        guard keyCode == 48 else { return nil }
        switch flags.intersection([.command, .control, .option, .shift]) {
        case .control: return 1
        case [.control, .shift]: return -1
        default: return nil
        }
    }

    /// Asked on ⌃Tab and ⌃⇧Tab while the panel is key, with the step. True
    /// means the pages took it; false lets it through — to a shortcut being
    /// recorded in Settings, say. Ahead of the field, which would take ⌃Tab
    /// as a move to the next key view, one nobody can see in this panel.
    var pageKeyHandled: ((Int) -> Bool)?

    /// Raised on ⇧⌘C, before the source field hears of it. Returns true when
    /// a translation was there to copy (or was there, but answers text since
    /// edited, which nothing should copy). False — not on Translate, or no
    /// answer yet — lets the key fall back to an ordinary copy.
    ///
    /// After ⌃⌥⌘T the keyboard loop of copy, hot key, read, copy broke at the
    /// last step: ⌘C and ⇧⌘C both copied the *source*, the only text with a
    /// caret, and the translation took the mouse (H-018). ⌘Return was the
    /// other candidate and was rejected: in a translator it reads as
    /// "translate", not "copy".
    var onCopyTranslation: (() -> Bool)?

    /// True from a left-button press on this panel until its release.
    ///
    /// A press that began here owns the drag that follows it, wherever the
    /// pointer goes. Interactivity used to be decided by where the pointer
    /// *was*, so overshooting the scrubber or the Panel Width slider past the
    /// panel's edge made the window click-through mid-drag and, 0.32 s later,
    /// folded the panel with the slider's change still uncommitted (F-028).
    /// Read through `pressIsHeld()`, never directly: see there.
    private(set) var isPressLatched = false

    /// Whether the primary button is physically down. A seam so a test can
    /// press without a mouse.
    var primaryButtonIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// Whether a press that began on this panel is still being held.
    ///
    /// The latch alone cannot be trusted to end. A control that tracks the
    /// mouse in its own loop dequeues the release itself, so it never passes
    /// through `sendEvent`; nor does a release the window server delivers
    /// elsewhere. Left standing, the latch would claim the *next* press,
    /// wherever it began: the window would turn interactive under a drag in
    /// another app, and a title bar dragged through the notch would be waved
    /// in by the very check that keeps it out. So the button is asked as well,
    /// and a press found to be over is forgotten, not merely masked — the same
    /// lesson as `ShelfDragSource`'s expiry: no latch that eats clicks may
    /// depend on one event arriving.
    func pressIsHeld() -> Bool {
        guard isPressLatched else { return false }
        guard primaryButtonIsDown() else {
            isPressLatched = false
            return false
        }
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        // Ahead of the latch: the menu tracks the mouse in a loop of its own
        // and takes the release, so a press latched here would never end.
        if Self.isSecondaryClick(type: event.type, flags: event.modifierFlags),
           secondaryClickHandled?(event.locationInWindow) == true {
            return
        }
        // First, ahead of every early return below, so no path through here
        // can latch a press and then skip its release.
        switch event.type {
        case .leftMouseDown: isPressLatched = true
        case .leftMouseUp: isPressLatched = false
        default: break
        }
        if event.type == .keyDown, event.keyCode == Key.escape {
            // An input method that is mid-composition owns Escape: it cancels
            // the composition, and the panel must not close underneath
            // somebody typing Cyrillic phonetically or any CJK layout.
            // Swallowing every Escape here also made the panes' own handlers
            // dead code, since nothing ever reached the responder chain.
            if let responder = firstResponder as? NSTextView, responder.hasMarkedText() {
                super.sendEvent(event)
                return
            }
            if escapeHandled?() == true { return }
            onEscape?()
            return
        }
        if event.type == .keyDown, Self.isRemoveKey(keyCode: event.keyCode, flags: event.modifierFlags),
           removeKeyHandled?() == true {
            return
        }
        if event.type == .keyDown, let key = Self.listKey(keyCode: event.keyCode, flags: event.modifierFlags) {
            // A composition in progress owns its arrows and its Return, as it
            // owns Escape: they pick and commit the candidate.
            let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
            if !composing, listKeyHandled?(key) == true { return }
        }
        if event.type == .keyDown,
           Self.isSettingsKey(keyCode: event.keyCode, characters: event.characters, flags: event.modifierFlags),
           settingsKeyHandled?() == true {
            return
        }
        if event.type == .keyDown, let step = Self.pageStep(keyCode: event.keyCode, flags: event.modifierFlags) {
            // A composition owns its keys, as it owns Escape and the arrows.
            let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
            if !composing, pageKeyHandled?(step) == true { return }
        }
        if let command = Self.editingCommand(for: event) {
            if command == .copyTranslation, onCopyTranslation?() == true { return }
            if perform(command) { return }
        }
        // Before `super`, so the window is already key by the time the click
        // reaches the field and places a caret.
        if event.type == .leftMouseDown { onPress?(event.locationInWindow) }
        super.sendEvent(event)
    }

    /// The editing command a key press asks for, or nil for every other press.
    static func editingCommand(for event: NSEvent) -> EditingCommand? {
        // `characters` raises on anything but a key event.
        guard event.type == .keyDown else { return nil }
        return editingCommand(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            flags: event.modifierFlags
        )
    }

    /// The editing command for a key, by its parts, so a test can name a
    /// layout without having one installed.
    ///
    /// Only ⌘, ⌃, ⌥ and ⇧ are read. The device-independent mask used to be
    /// compared exactly, and it carries Caps Lock, so with Caps Lock latched
    /// ⌘A, ⌘X, ⌘C, ⌘V and ⌘Z all failed the test and did nothing (G-006).
    /// ⌥ and ⌃ still disqualify a press: ⌥⌘C and ⌃⌘C mean something else to
    /// somebody.
    ///
    /// The letter is the one the press printed, in order of trust: what ⌘
    /// produced (`characters`), which honours "Dvorak – QWERTY ⌘", the layout
    /// that switches to QWERTY while ⌘ is held and so means ⌘C on the key that
    /// otherwise prints J; then the layout's own letter; and only when neither
    /// is a Latin letter, the key's position, which keeps Cyrillic and every
    /// other non-Latin layout working as it did. A Latin letter that is not an
    /// editing key — QWERTZ's Y, at US Z's position — is no command at all,
    /// never the position's.
    static func editingCommand(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        flags: NSEvent.ModifierFlags
    ) -> EditingCommand? {
        let flags = flags.intersection([.command, .control, .option, .shift])
        guard flags.subtracting(.shift) == .command else { return nil }
        let shifted = flags.contains(.shift)

        let letter = latinLetter(characters) ?? latinLetter(charactersIgnoringModifiers)
        let key: Character?
        if let letter {
            key = letter
        } else {
            switch keyCode {
            case Key.a: key = "a"
            case Key.x: key = "x"
            case Key.c: key = "c"
            case Key.v: key = "v"
            case Key.z: key = "z"
            default: key = nil
            }
        }
        switch key {
        case "a": return .selectAll
        case "x": return .cut
        case "c": return shifted ? .copyTranslation : .copy
        case "v": return .paste
        case "z": return shifted ? .redo : .undo
        default: return nil
        }
    }

    /// The first character, lowercased, when it is an ASCII letter. Shift and
    /// Caps Lock both arrive as a capital, which is the same key.
    private static func latinLetter(_ text: String?) -> Character? {
        guard let first = text?.first, first.isASCII, first.isLetter else { return nil }
        return Character(first.lowercased())
    }

    /// Dispatched from our own first responder, not through `NSApp`: a
    /// nil-targeted `sendAction` starts at `NSApp.keyWindow`, and an inactive
    /// app reports that as nil however key this panel actually is.
    private func perform(_ command: EditingCommand) -> Bool {
        guard let responder = firstResponder else { return false }
        return responder.tryToPerform(command.action, with: self)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // The panel is dark whatever the system is: it lies over the notch,
        // which is black on every Mac that has one. Everything drawn by hand
        // already knows that, but the AppKit views behind SwiftUI's controls do
        // not — a `TextField` asks the effective appearance what colour text
        // is, and on a Mac set to light it is told black. The result is a field
        // one can type into and not read: the caret blinks, the text lands, and
        // none of it is visible against the panel.
        appearance = NSAppearance(named: .darkAqua)

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = Self.normalLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        applyCaptureExclusion()
    }

    /// Screen sharing and recording pick up every ordinary window, this one
    /// included — and this one can be showing clipboard history or a scratch
    /// note. `.none` hides it from capture without hiding it from the screen.
    func applyCaptureExclusion() {
        // `.readOnly`, not the deprecated `.readWrite`: nothing may write into
        // this window, and `.readWrite` warns at the package's own macOS 15
        // minimum.
        sharingType = NotchViewModel.hideFromCaptureEnabled ? .none : .readOnly
    }
}
