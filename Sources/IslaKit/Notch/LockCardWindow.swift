import AppKit
import SwiftUI

/// The lock screen's player, in a window of its own.
///
/// It used to be the notch panel wearing a different face: on every lock that
/// panel was grown from 700×444 at the top of the display to the size of the
/// whole screen, its hit region re-cut, its content swapped, and all of it
/// across the moment the login shield goes up. That is the worst possible time
/// to resize a live window — the window server snapshots windows across the
/// transition, and a snapshot taken at the old size gets stretched into the new
/// frame, which is precisely the card drawn at half size and off to one side.
///
/// So nothing is resized any more. The notch panel keeps its frame and its one
/// job; this window is made when the shield goes up and destroyed when it comes
/// down. It is exactly the size of the card, which means its hit region is its
/// own frame — there is no rect to cut, nothing to keep in step, and nothing to
/// drift.
@MainActor
final class LockCardWindow {
    private var panel: NotchPanel?

    /// Where the card sits: dead centre of the display the notch is on.
    ///
    /// Pure, so the arithmetic can be tested without a screen. Centred rather
    /// than anchored to the notch, because a locked Mac is looked at from
    /// wherever the person is standing, and the middle of the display is where
    /// the eye goes — the clock above it is centred for the same reason.
    /// A little room around the card, so nothing the material draws at its own
    /// edge is clipped.
    ///
    /// This was 48pt, to hold two drop shadows. Those are gone — the system's
    /// lock player has no drop shadow and neither does this one now. What
    /// remains is a small allowance: a window cut to exactly the card clips
    /// square at its edge, and the antialiased boundary of a rounded pane is
    /// the last thing worth risking to save twelve points.
    ///
    /// It stays a margin rather than dropping to zero because the failure it
    /// prevents is invisible in a screenshot and obvious on a real screen.
    static let shadowMargin: CGFloat = 12

    /// The window is the card plus that margin. The margin is transparent and
    /// takes no clicks — see `LockCardRootView`.
    static var windowSize: CGSize {
        CGSize(
            width: LockScreenCard.size.width + shadowMargin * 2,
            height: LockScreenCard.size.height + shadowMargin * 2
        )
    }

    static func frame(on screen: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: screen.minX + ((screen.width - size.width) / 2).rounded(),
            y: screen.minY + ((screen.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    var isPresenting: Bool { panel != nil }

    /// Puts the card on screen above the shield.
    func present(media: MediaController, lyrics: LyricsStore, on screen: NSScreen, presence: LockScreenPresence) {
        let frame = Self.frame(on: screen.frame, size: Self.windowSize)
        if let panel {
            // Already up — a second lock notification, or a display that
            // changed shape underneath us.
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }

        let panel = NotchPanel(contentRect: frame)
        // The card answers clicks — transport, scrubbing, the output picker —
        // but the app must never activate for them, which the panel's
        // non-activating style already guarantees.
        panel.ignoresMouseEvents = false
        let hosting = NSHostingView(rootView: LockScreenCard(media: media, lyrics: lyrics))
        // The card sits inset inside the window, so its shadow has somewhere to
        // go. Not autoresizing: the card is one fixed size and the window is
        // only ever set to one size, so a stretched card could only ever be a
        // bug arriving quietly.
        let cardRect = CGRect(
            x: Self.shadowMargin, y: Self.shadowMargin,
            width: LockScreenCard.size.width, height: LockScreenCard.size.height
        )
        hosting.frame = cardRect
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        let root = LockCardRootView(frame: CGRect(origin: .zero, size: frame.size))
        root.cardRect = cardRect
        root.autoresizingMask = [.width, .height]
        root.addSubview(hosting)
        panel.contentView = root
        self.panel = panel

        presence.apply(to: panel, locked: true)
        panel.orderFrontRegardless()
    }

    /// Takes it away. The window is destroyed rather than hidden: it exists
    /// only for the length of a lock, and a window kept around is a window that
    /// can be found in the wrong state next time.
    func dismiss(presence: LockScreenPresence) {
        guard let panel else { return }
        presence.apply(to: panel, locked: false)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    /// Re-centres on the display it belongs to, after a screen change.
    func reposition(on screen: NSScreen) {
        guard let panel else { return }
        panel.setFrame(Self.frame(on: screen.frame, size: Self.windowSize), display: true)
    }
}

/// The card's window is larger than the card, so that its shadow can fall
/// outside it. Every point in that margin has to belong to whatever is
/// underneath — which, while the Mac is locked, is the password field.
///
/// The panel takes mouse events because the transport and the scrubber need
/// them; without this the transparent margin would swallow clicks aimed at the
/// login window and there would be nothing on screen to explain why.
final class LockCardRootView: NSView {
    var cardRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard cardRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
