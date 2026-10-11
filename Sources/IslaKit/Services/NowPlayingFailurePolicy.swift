import Foundation

/// Decides what to do when the helper stops working.
///
/// Two counters, not one. Consecutive failures catch a helper that cannot
/// start at all; the running total catches the worse case — a helper that
/// starts, publishes a line or two, and dies. That one used to reset the
/// consecutive count on every snapshot it managed to emit, so it never reached
/// the fallback threshold and the app relaunched perl, `dlopen`ed MediaRemote
/// and re-subscribed every two seconds for as long as it was running.
///
/// The running total is forgiven only by a helper that *survived* the window
/// (K-013). It used to be forgiven by time since the first failure, and the
/// backoff's delays add up to 242 s: a helper killed ten seconds into every
/// life — one player's metadata it cannot encode is enough — crossed the
/// 300 s mark before its ninth death, started a fresh budget at a two-second
/// delay, and was relaunched about 2,000 times a day with the island stale
/// for up to a minute each time and nothing said. Times are awake time, the
/// clock the silence watchdog counts in, so a lid closed over a dying helper
/// cannot count as the helper staying up.
struct NowPlayingFailurePolicy {
    enum Action: Equatable {
        case restart(after: TimeInterval)
        case fallback
    }

    /// Failures with no successful snapshot in between.
    private(set) var consecutiveFailures = 0
    /// Restarts since a helper last stayed up for a whole window, successes
    /// notwithstanding.
    private(set) var restartsInWindow = 0
    /// When the helper now running was launched.
    private var launchedAt: TimeInterval?

    /// How long a helper has to survive for its restarts to be forgiven.
    private let window: TimeInterval
    /// Restarts allowed before giving up on the helper, unless one survives
    /// the window in between.
    private let maximumRestartsInWindow: Int

    init(window: TimeInterval = 300, maximumRestartsInWindow: Int = 8) {
        self.window = window
        self.maximumRestartsInWindow = maximumRestartsInWindow
    }

    /// A helper process started. Its death is measured against this.
    mutating func recordLaunch(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        launchedAt = now
    }

    mutating func recordFailure(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Action {
        if let launchedAt, now - launchedAt >= window {
            // It ran for the whole window: whatever killed it is not the
            // streak the budget is counting.
            restartsInWindow = 0
            consecutiveFailures = 0
        }
        launchedAt = nil
        consecutiveFailures += 1
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

/// Counts the helper's lines that do not decode.
///
/// A helper that stays up but writes nothing the app can read used to look
/// healthy (G-009): any byte refreshed the silence watchdog, and a line that
/// did not decode was dropped without a word, so the failure policy was never
/// asked and the island sat blank. One bad line is a torn write, not a broken
/// helper, so it takes several in a row; a single good one starts the count
/// again.
struct UndecodableLineWatch {
    enum Verdict: Equatable { case keep, restart }

    /// Undecodable lines in a row. The helper writes a record at least every
    /// five seconds, so the limit is reached within half a minute of garbage.
    private(set) var consecutive = 0
    private let limit: Int

    init(limit: Int = 5) {
        self.limit = limit
    }

    mutating func record(decoded: Bool) -> Verdict {
        guard !decoded else {
            consecutive = 0
            return .keep
        }
        consecutive += 1
        guard consecutive >= limit else { return .keep }
        consecutive = 0
        return .restart
    }
}
