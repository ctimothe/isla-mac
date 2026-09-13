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

    /// The machine's audio state for the length of one lock. Created with the
    /// card, stopped at dismiss — the window is destroyed per lock anyway, so
    /// the watch's lifetime is exactly the card's, and the listeners can never
    /// outlive the surface that drew from them.
    private var audioWatch: AudioWatch?

    /// Puts the card on screen above the shield.
    func present(media: MediaController, lyrics: LyricsStore, on screen: NSScreen, presence: LockScreenPresence) {
        let frame = Self.frame(on: screen.frame, size: Self.windowSize)
        if let panel {
            // Already up — a second lock notification, or a display that
            // changed shape underneath us. The audio watch is still running;
            // one re-read in case the machine moved with the display.
            audioWatch?.systemAudioChanged()
            panel.setFrame(frame, display: true)
            // Straight to full, no fade: this path is a correction to a card
            // that is already being looked at, and re-fading it would read as a
            // flicker for no reason. It also guarantees the card cannot be left
            // part-transparent if the notification lands mid fade-in — the
            // in-flight animation is heading for 1 as well, so whichever writes
            // last, the card ends up visible.
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let watch = AudioWatch()
        watch.start()
        audioWatch = watch

        let panel = NotchPanel(contentRect: frame)
        // The card answers clicks — transport, scrubbing, the output picker —
        // but the app must never activate for them, which the panel's
        // non-activating style already guarantees.
        panel.ignoresMouseEvents = false
        let hosting = NSHostingView(rootView: LockScreenCard(media: media, lyrics: lyrics, audio: watch))
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

        // Fade in rather than cut in. A 484×324 window appearing at full
        // opacity in a single frame is the one moment this app is loudest: the
        // shield has just gone up, the desktop is gone, and a card the size of
        // a postcard simply exists on the next frame. Everything else here
        // arrives on a curve; this did not, and it read as a glitch in the lock
        // screen rather than as the player coming up.
        //
        // Alpha, and nothing but alpha. Not because the frame is immutable —
        // `reposition(on:)` sets it on a screen change, and the re-present
        // branch above sets it on a live window — but because *this fade*
        // touches nothing but alpha. Animating the frame across a lock is what
        // produced stretched window-server snapshots, which is the whole reason
        // this card has a window of its own instead of resizing the panel.
        // window's frame across the lock transition is exactly the bug that put
        // this card in a window of its own — the window server snapshots
        // windows across that transition and stretches a snapshot taken at the
        // old size into the new frame, which is the card drawn at half size and
        // off to one side. `alphaValue` does not change the frame, so none of
        // that applies: the snapshot the server takes is of a correctly sized
        // window, and only its opacity moves. A scale or a slide here would
        // walk straight back into the bug.
        //
        // Set before anything orders the window in, and that means before
        // `presence.apply` — which ends with an `orderFrontRegardless` of its
        // own after lifting the window above the shield. Setting alpha after it
        // would put the card on screen at full opacity for one frame and then
        // blink it out to fade back up, which is worse than the cut it replaces.
        panel.alphaValue = 0
        presence.apply(to: panel, locked: true)
        NSAnimationContext.runAnimationGroup { context in
            // Short. This is an appearance, not a transition between two things
            // the eye is tracking, and the shield's own fade is roughly this
            // long — a slower card would still be arriving after the lock
            // screen had finished settling.
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Takes it away. The window is destroyed rather than hidden: it exists
    /// only for the length of a lock, and a window kept around is a window that
    /// can be found in the wrong state next time. The audio watch goes with it,
    /// before the panel is torn down — its listeners belong to exactly one
    /// lock, and a dismissed card must not keep hearing the machine.
    func dismiss(presence: LockScreenPresence) {
        guard let panel else { return }
        audioWatch?.stop()
        audioWatch = nil
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
