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
    static let teleprompterBody = CGSize(width: 620, height: 400)
    static let maximumWindow = CGSize(width: 700, height: 444)
    /// Extra room split equally between the two sides of a collapsed notch:
    /// artwork on the left, playback state on the right.
    static let compactMediaExtension: CGFloat = 104
    static let openDelay: TimeInterval = 0.05
    static let closeDelay: TimeInterval = 0.32
    static let tabDwell: TimeInterval = 0.15
    static let fastPointerInterval: TimeInterval = 1.0 / 60.0
    static let idlePointerInterval: TimeInterval = 1.0 / 8.0
    static let restThreshold: TimeInterval = 3.0
    static let warmZoneHeight: CGFloat = 260
    static let coolMargin: CGFloat = 80
    /// Delay before shrinking the panel's interactive rect back down after a
    /// close. Must outlast `Theme.openAnimation`'s close, or the rect shrinks
    /// out from under a panel that is still visibly on screen, opening a
    /// window in which clicks land on whatever is behind it instead.
    static let collapseRectShrinkDelay: TimeInterval = 0.45
    /// Delay before `scheduleCollapseIfPointerAway` decides the pointer
    /// really left, after losing the keyboard or a drag exiting. Long enough
    /// to outlast a hand moving from the keyboard back to the trackpad.
    static let pointerAwayCollapseDelay: TimeInterval = 0.6

    /// How long a translation summoned by ⌥⌘T stays up with nobody touching
    /// the trackpad.
    ///
    /// The shortcut exists to be used from the keyboard, so the pointer is
    /// wherever it was left and the ordinary collapse check calls it "away"
    /// immediately. Long enough to read a sentence and reach for the mouse;
    /// still short enough that a translation walked away from is gone.
    static let translateReadDelay: TimeInterval = 6

    /// How long a new track shows itself before folding back. Long enough to
    /// read a title at a glance, short enough that it is over before it can
    /// become an interruption.
    static let sneakPeekDuration: TimeInterval = 2.2

    /// How much wider the pill goes while peeking, over the compact width.
    /// Enough for a title beside the artwork without reaching the full body.
    static let sneakPeekExtension: CGFloat = 300
}
