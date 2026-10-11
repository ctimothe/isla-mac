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

    /// Physical keys, so the shortcuts survive a keyboard layout change. A
    /// Cyrillic layout answers ⌘C with "с" (U+0441), not "c" (U+0063) — they
    /// are indistinguishable on screen and unequal to every string comparison,
    /// which is why matching on characters quietly fails exactly for the
    /// person typing Russian. Key codes name the key, not what it prints.
    private enum Key {
        static let a: UInt16 = 0
        static let z: UInt16 = 6
        static let x: UInt16 = 7
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let escape: UInt16 = 53
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
    var onPress: (() -> Void)?

    /// Raised on Escape, whatever has the keyboard. Collapsing is the one
    /// thing every tab agrees Escape should do, and binding it inside
    /// individual panes meant it worked on two of them and nowhere else.
    var onEscape: (() -> Void)?

    /// Asked before `onEscape`. Returning true means a pane wanted this
    /// Escape — clearing a field, handing the keyboard back — and the panel
    /// stays open.
    var escapeHandled: (() -> Bool)?

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
        if event.type == .keyDown, editingAction(for: event) != nil, perform(event) { return }
        // Before `super`, so the window is already key by the time the click
        // reaches the field and places a caret.
        if event.type == .leftMouseDown { onPress?() }
        super.sendEvent(event)
    }

    private func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift) == .command else { return nil }
        switch event.keyCode {
        case Key.a: return #selector(NSText.selectAll(_:))
        case Key.x: return #selector(NSText.cut(_:))
        case Key.c: return #selector(NSText.copy(_:))
        case Key.v: return #selector(NSText.paste(_:))
        // Undo and redo are informal: nothing declares them, the Edit menu just
        // names the selector and lets the chain find an undo manager.
        case Key.z: return flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    /// Dispatched from our own first responder, not through `NSApp`: a
    /// nil-targeted `sendAction` starts at `NSApp.keyWindow`, and an inactive
    /// app reports that as nil however key this panel actually is.
    private func perform(_ event: NSEvent) -> Bool {
        guard let action = editingAction(for: event), let responder = firstResponder else { return false }
        return responder.tryToPerform(action, with: self)
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
