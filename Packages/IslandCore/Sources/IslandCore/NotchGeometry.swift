import AppKit
import CoreGraphics

public struct NotchGeometry: Equatable {
    public let frameInScreen: CGRect

    public static let fallbackWidth: CGFloat = 185
    public static let fallbackHeight: CGFloat = 32

    public static func compute(
        screenFrame: CGRect,
        topInset: CGFloat,
        auxiliaryLeft: CGRect?,
        auxiliaryRight: CGRect?
    ) -> NotchGeometry? {
        guard topInset > 0 || auxiliaryLeft != nil || auxiliaryRight != nil else { return nil }

        if let left = auxiliaryLeft, let right = auxiliaryRight {
            let rect = CGRect(
                x: left.maxX,
                y: screenFrame.maxY - topInset,
                width: right.minX - left.maxX,
                height: topInset
            )
            return NotchGeometry(frameInScreen: rect)
        }

        let x = screenFrame.midX - fallbackWidth / 2
        let rect = CGRect(
            x: x,
            y: screenFrame.maxY - fallbackHeight,
            width: fallbackWidth,
            height: fallbackHeight
        )
        return NotchGeometry(frameInScreen: rect)
    }

    /// Thin, non-unit-tested wrapper around the real NSScreen API (see `compute`
    /// for the pure, tested logic). Manual QA covers this per the plan.
    public static func detect(for screen: NSScreen) -> NotchGeometry? {
        compute(
            screenFrame: screen.frame,
            topInset: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea,
            auxiliaryRight: screen.auxiliaryTopRightArea
        )
    }
}
