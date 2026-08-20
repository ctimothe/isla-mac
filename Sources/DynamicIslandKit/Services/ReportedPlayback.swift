import Foundation

/// Resolves what a snapshot's `playing` flag and `rate` actually mean together.
///
/// Neither field is sufficient alone. Some sessions — browser tabs especially —
/// never set the flag, and report a positive rate for as long as audio moves;
/// ignoring the rate would show those as paused throughout. But the rate is
/// also the slower of the two to settle: on a real pause the flag flips first
/// and the rate follows about half a second later (measured at 165ms versus
/// 712ms against Spotify), and reading that gap as "still playing" leaves the
/// island animating after the music has already stopped.
///
/// So the flag wins for a moment after it changes, and the rate only speaks for
/// a session whose flag was never raised in the first place.
struct ReportedPlayback {
    /// How long a freshly-lowered flag suppresses a rate that has not caught up.
    /// Comfortably past the measured settle time without being long enough to
    /// matter for a session that reports the flag badly.
    private static let settleWindow: TimeInterval = 1.5

    private var pausedAt: Date?
    private var lastFlag = false

    mutating func resolve(isPlaying: Bool, rate: Double, at now: Date) -> Bool {
        if isPlaying != lastFlag {
            // Only a genuine true→false transition starts the window; a
            // session that has reported false all along never opens one.
            pausedAt = isPlaying ? nil : now
            lastFlag = isPlaying
        }

        if isPlaying { return true }
        if let pausedAt, now.timeIntervalSince(pausedAt) < Self.settleWindow { return false }
        return rate > 0
    }
}
