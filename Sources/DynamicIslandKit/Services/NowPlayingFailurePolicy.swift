import Foundation

/// Decides what to do when the helper stops working.
///
/// Two counters, not one. Consecutive failures catch a helper that cannot
/// start at all; the running total catches the worse case — a helper that
/// starts, publishes a line or two, and dies. That one used to reset the
/// consecutive count on every snapshot it managed to emit, so it never reached
/// the fallback threshold and the app relaunched perl, `dlopen`ed MediaRemote
/// and re-subscribed every two seconds for as long as it was running.
struct NowPlayingFailurePolicy {
    enum Action: Equatable {
        case restart(after: TimeInterval)
        case fallback
    }

    /// Failures with no successful snapshot in between.
    private(set) var consecutiveFailures = 0
    /// Restarts in the current window, successes notwithstanding.
    private(set) var restartsInWindow = 0
    private var windowStart: Date?

    /// How long a helper has to survive for its restart to be forgiven.
    private let window: TimeInterval
    /// Restarts allowed inside one window before giving up on the helper.
    private let maximumRestartsInWindow: Int

    init(window: TimeInterval = 300, maximumRestartsInWindow: Int = 8) {
        self.window = window
        self.maximumRestartsInWindow = maximumRestartsInWindow
    }

    mutating func recordFailure(now: Date = Date()) -> Action {
        consecutiveFailures += 1

        if let start = windowStart, now.timeIntervalSince(start) > window {
            windowStart = now
            restartsInWindow = 0
        } else if windowStart == nil {
            windowStart = now
        }
        restartsInWindow += 1

        guard consecutiveFailures < 3, restartsInWindow <= maximumRestartsInWindow else {
            return .fallback
        }
        // Exponential, capped. A helper dying immediately and repeatedly is
        // usually a macOS release that closed the route, and hammering it once
        // every two seconds costs the user battery to learn nothing.
        let delay = min(2 * pow(2, Double(restartsInWindow - 1)), 60)
        return .restart(after: delay)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }
}
