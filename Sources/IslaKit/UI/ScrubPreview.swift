import CoreGraphics

/// Pure math for the scrubber's floating time preview, kept out of the view
/// so hover→time mapping and edge clamping are unit-testable without a view
/// tree.
enum ScrubPreview {
    /// How long the pointer rests on the bar before the elapsed label shows
    /// the time under it. Long enough that crossing the bar shows nothing;
    /// short enough that a deliberate look never feels like a wait.
    static let dwell: Double = 0.25

    /// Cursor x in the bar's own space → playback fraction, clamped to 0...1.
    /// Returns nil when the bar has no width or the track has no duration —
    /// live streams report duration 0 and must show no preview.
    static func fraction(x: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard width > 0, duration > 0 else { return nil }
        return min(max(Double(x / width), 0), 1)
    }
}
