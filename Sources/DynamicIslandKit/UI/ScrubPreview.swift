import CoreGraphics

/// Pure math for the scrubber's floating time preview, kept out of the view
/// so hover→time mapping and edge clamping are unit-testable without a view
/// tree.
enum ScrubPreview {
    /// Cursor x in the bar's own space → playback fraction, clamped to 0...1.
    /// Returns nil when the bar has no width or the track has no duration —
    /// live streams report duration 0 and must show no preview.
    static func fraction(x: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard width > 0, duration > 0 else { return nil }
        return min(max(Double(x / width), 0), 1)
    }

    /// Bubble center x, clamped so the bubble never clips the bar's edges.
    /// When the bar is narrower than the bubble, pins to the bar's center.
    static func bubbleCenterX(x: CGFloat, width: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        let half = bubbleWidth / 2
        guard width > bubbleWidth else { return width / 2 }
        return min(max(x, half), width - half)
    }
}
