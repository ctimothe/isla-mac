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
        let frame = Self.frame(on: screen.frame, size: LockScreenCard.size)
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
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
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
        panel.setFrame(Self.frame(on: screen.frame, size: LockScreenCard.size), display: true)
    }
}
