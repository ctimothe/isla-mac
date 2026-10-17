import CoreGraphics
import Foundation

enum NotchMetrics {
    /// The body's width is the one panel dimension a person can set, because it
    /// is the one whose right answer is taste rather than fit. The bounds are
    /// what the content can hold: under 480 the rail and the artwork block start
    /// fighting for the same points, over 620 the panel sprawls far enough past
    /// the notch to read as a window rather than an island.
    static let minimumBodyWidth: CGFloat = 480
    static let maximumBodyWidth: CGFloat = 620
    static let defaultBodyWidth: CGFloat = 560
    static let standardBodyHeight: CGFloat = 208

    static func body(width: CGFloat) -> CGSize {
        CGSize(width: width, height: standardBodyHeight)
    }

    /// The *widest* body, which is what the window is cut for and what the
    /// window arithmetic is written against. The window is never resized — it is
    /// transparent outside the panel, and what is clickable is decided by the
    /// active rect — so a narrower body simply leaves more of it transparent.
    static let standardBody = CGSize(width: maximumBodyWidth, height: standardBodyHeight)
    /// The tallest body the window was ever cut for. The tab that asked for it
    /// — the teleprompter — was removed on 2026-08-22, but the window keeps this
    /// height on purpose: `maximumWindow` is derived from it, and a window that
    /// is never resized is the whole reason the lock transition does not
    /// stretch. Shrinking it is a geometry change, not a cleanup.
    static let tallestBody = CGSize(width: 620, height: 400)
    static let maximumWindow = CGSize(width: 700, height: 444)
    /// Extra room split equally between the two sides of a collapsed notch:
    /// artwork on the left, playback state on the right.
    ///
    /// 104 until 2026-10-15, 52 pt a wing, with a 22 pt cover floating in the
    /// middle of each. The redesign (spec §3.1, owner decision 2) makes the
    /// island 300 pt on a 14-inch MacBook Pro — the notch plus two 40 pt wings —
    /// because a 24 pt cover with 8 pt either side is what a wing needs and the
    /// HIG asks compact content to sit snug against the camera. On a notch of
    /// another width the wings stay 40; the island is `notch.width + 80`.
    static let compactMediaExtension: CGFloat = 80
    /// One wing of the compact island: half of `compactMediaExtension`.
    static let compactWing: CGFloat = compactMediaExtension / 2
    /// How far the cover sits from the island's left edge and the equalizer's
    /// last bar from its right edge (spec §3.1): even margins, so the cover's
    /// 6 pt corner is concentric with the island's 12.
    static let compactEdgeInset: CGFloat = 8
    static let openDelay: TimeInterval = 0.05
    static let closeDelay: TimeInterval = 0.32
    static let fastPointerInterval: TimeInterval = 1.0 / 60.0
    static let idlePointerInterval: TimeInterval = 1.0 / 8.0
    static let restThreshold: TimeInterval = 3.0
    static let warmZoneHeight: CGFloat = 260
    static let coolMargin: CGFloat = 80
    /// Delay before shrinking the panel's interactive rect back down after a
    /// close. Must outlast the close (`Theme.close`) crossing its end, or the
    /// rect shrinks out from under a panel that is still visibly on screen,
    /// opening a window in which clicks land on whatever is behind it instead.
    static let collapseRectShrinkDelay: TimeInterval = 0.45
    /// Delay before `scheduleCollapseIfPointerAway` decides the pointer
    /// really left, after losing the keyboard or a drag exiting. Long enough
    /// to outlast a hand moving from the keyboard back to the trackpad.
    static let pointerAwayCollapseDelay: TimeInterval = 0.6

    /// How long a translation summoned by ⌃⌥⌘T stays up with nobody touching
    /// the trackpad.
    ///
    /// The shortcut exists to be used from the keyboard, so the pointer is
    /// wherever it was left and the ordinary collapse check calls it "away"
    /// immediately. Long enough to read a sentence and reach for the mouse;
    /// still short enough that a translation walked away from is gone.
    static let translateReadDelay: TimeInterval = 6

    /// How long the pointer has to come back after a menu closes. A language
    /// list hangs well below the panel, and the row just chosen is where the
    /// pointer was left — outside. Long enough to move back up; short enough
    /// that walking away from a closed menu still folds the panel.
    static let menuReturnGrace: TimeInterval = 1.2

    /// How long a new track shows itself before folding back. Long enough to
    /// read a title at a glance, short enough that it is over before it can
    /// become an interruption.
    static let sneakPeekDuration: TimeInterval = 2.2
    /// The charger or headphones: long enough to read a percentage or a
    /// name, the same beat as a new track's peek.
    static let ambientDuration: TimeInterval = 2.2

    /// How long a paused track keeps its pill before folding into the notch.
    ///
    /// Only long enough to ride out the pause a skip passes through — a player
    /// reports "paused" for a moment between two songs, and folding for that
    /// would flicker the pill on every skip. It was five seconds, meant to
    /// spare a quick resume; the owner asked on 2026-09-21 for a pause to go
    /// straight under the notch, "without affecting or interrupting the
    /// user", and a paused song has nothing to say on the menu bar.
    @MainActor static var pausedLinger: TimeInterval = 0.4

    /// How far inside the hardware cutout the island rests when nothing plays.
    ///
    /// The cutout is not display — there is no pixel inside it to light — so a
    /// shape drawn wholly within it cannot be seen at all. Drawn exactly to its
    /// edge, anti-aliasing paints a half-pixel line on the far side of the
    /// edge, and the island shows as a faint outline round the notch. One point
    /// in is enough to leave nothing outside.
    static let restingInset: CGFloat = 1
    /// How far the resting island grows past the notch when the pointer finds
    /// it, on each side and below: enough to be unmistakable, small enough to
    /// read as the notch waking rather than as the panel opening.
    static let hoverNudgeWidth: CGFloat = 8
    static let hoverNudgeDepth: CGFloat = 3

    /// How much wider the pill goes while peeking, over the compact width.
    /// Enough for a title beside the artwork without reaching the full body.
    static let sneakPeekExtension: CGFloat = 300
    /// How tall the island grows for a new track's peek (spec §3.5, owner
    /// decision 3). Two lines — a title and an artist — do not fit the notch's
    /// own 38 pt without being squeezed against the camera, so the island grows
    /// 12 pt down into the wallpaper, the way a Live Activity's alert does,
    /// rather than the text being made smaller. The window is never resized
    /// (it is cut for 444 pt), so this is only a drawn height and an active
    /// rect.
    static let sneakPeekHeight: CGFloat = 50
    /// The headphones moment: a glyph in the left wing and a device name in
    /// the right, 104 pt each (spec §3.6) — the same wings the volume pop-up
    /// takes in R5, so every "something happened" moment is one width. Enough
    /// for "AirPods Pro Max" before the name truncates at its tail. 220 until
    /// 2026-10-15, with 110 pt wings.
    static let ambientNameExtension: CGFloat = 208
}
