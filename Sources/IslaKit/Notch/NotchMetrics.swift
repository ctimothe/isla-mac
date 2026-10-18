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
    /// Each compact activity is the notch plus its own delta, split equally
    /// between the wings: the camera's span never grows, its wings do (spec
    /// §19.2, §19.4). The deltas are the reference's, measured.
    ///
    /// Music: the cover in the left wing, the equalizer in the right. 104 until
    /// 2026-10-15, 80 (two 40 pt wings round a 24 pt cover) until 2026-10-17;
    /// 70 since §19.4, two 35 pt wings round a 22 pt cover.
    static let compactMediaExtension: CGFloat = 70
    /// The Shelf holding files, as the island's live activity when nothing
    /// plays: `tray.full.fill` in the left wing, the count in the right.
    static let compactShelfExtension: CGFloat = 75
    /// The charger: "Charging" in the left wing, the level and a drawn battery
    /// in the right — words, where Music has a picture, so wider.
    static let compactChargingExtension: CGFloat = 180
    /// One wing of the Music island: half of `compactMediaExtension`.
    static let compactWing: CGFloat = compactMediaExtension / 2
    static let openDelay: TimeInterval = 0.05
    static let closeDelay: TimeInterval = 0.32
    static let fastPointerInterval: TimeInterval = 1.0 / 60.0
    static let idlePointerInterval: TimeInterval = 1.0 / 8.0
    static let restThreshold: TimeInterval = 3.0
    static let warmZoneHeight: CGFloat = 260
    static let coolMargin: CGFloat = 80
    /// How far below the warm band a resting pointer still has the movement
    /// monitor standing (`PointerWatcher.updateMovementWatch`): close enough
    /// that a flick to the island crosses it, far enough down that a pointer
    /// at work in the lower half of the screen wakes nothing as it moves.
    static let approachMargin: CGFloat = 300
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
    // The charger's and the headphones' holds are their own since spec §19.1:
    // `AmbientActivity.holdDuration`.

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
    // The headphones and the volume pop-up are expanded alerts since spec
    // §19.5 c and d, sized by `ExpandedAlertShape`, not by wings.
}
