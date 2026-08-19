import CoreGraphics
import Foundation

enum NotchMetrics {
    static let standardBody = CGSize(width: 620, height: 208)
    static let teleprompterBody = CGSize(width: 620, height: 400)
    static let maximumWindow = CGSize(width: 700, height: 444)
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
}
