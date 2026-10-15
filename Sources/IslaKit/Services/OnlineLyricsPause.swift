import Foundation

/// How long every online lyric lookup stays quiet after the catalogue says
/// "too many requests".
///
/// On 2026-10-15 the gateway in front of LRCLIB answered 429 for hours, and
/// this address was banned. Isla kept asking: each song retried itself after
/// 5 s, 30 s and 2 min, and every new song started its own ladder, so a
/// listener skipping through a playlist sent a request per song into a wall
/// that had said stop. A 429 is about the address, not the recording, so the
/// answer to it belongs to the whole client — which is why this is one value
/// on the one coordinator and not a field of any lookup.
///
/// A value with no clock and no dice of its own: the caller hands in the time
/// and the random draw, so the arithmetic is tested without sleeping.
struct OnlineLyricsPause: Equatable {
    /// When lookups may resume; nil when nothing is holding them back.
    private(set) var until: Date?
    /// 429s in a row. A streak survives answers that slip through between
    /// them; it resets on an answer at least `longestBackoff` after the last
    /// 429 (`answered(at:)`).
    private(set) var consecutive = 0
    /// When the last 429 was read; what a streak decays from.
    private(set) var lastLimited: Date?

    /// The wait after the first 429 that names no time of its own.
    static let firstBackoff: TimeInterval = 60
    /// The most a backoff alone ever waits. Half an hour is long enough to
    /// leave a gateway alone and short enough that a listener who turned
    /// lyrics on at breakfast is not still waiting at lunch.
    static let longestBackoff: TimeInterval = 30 * 60

    func isPaused(at now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// Arms the pause and returns how long it lasts.
    ///
    /// The service's own Retry-After is taken as it comes: it is the one party
    /// that knows. Without one, the wait doubles from a minute to half an hour
    /// and is drawn between half the step and the whole of it ("equal
    /// jitter"). Full jitter, anywhere from zero to the step, was refused on
    /// purpose: a draw near zero re-asks straight into the 429 it is backing
    /// off from, which is the very behaviour that got the address banned.
    ///
    /// A Retry-After of zero or less is no guidance on a 429 — read literally
    /// it re-asks the instant it is read, and a gateway that sent it again
    /// would be asked in a loop — so it is treated as absent.
    mutating func limited(
        retryAfter: TimeInterval?, at now: Date, jitter: (ClosedRange<Double>) -> Double
    ) -> TimeInterval {
        consecutive += 1
        let lasts: TimeInterval
        if let retryAfter, retryAfter > 0 {
            lasts = retryAfter
        } else {
            // The exponent stops growing long before the cap could be missed.
            let step = Self.firstBackoff * pow(2, Double(min(consecutive - 1, 20)))
            let base = min(step, Self.longestBackoff)
            lasts = jitter((base / 2)...base)
        }
        lastLimited = now
        until = now.addingTimeInterval(lasts)
        return lasts
    }

    /// The service answered — a hit, a miss, words the parser refused — so the
    /// pause itself ends, but the streak only decays after a quiet half hour.
    ///
    /// The 2026-10-15 ban was partial limiting: for three hours the gateway
    /// let an occasional probe through (0–5 answers) between its 429s. If any
    /// answer reset the streak, each of those would send the backoff back to
    /// its first step and it would never climb; the address would be asked
    /// again at a minute's pace for the whole of the ban. So an answer clears
    /// `until` always, and clears `consecutive` and `lastLimited` only when
    /// the last 429 is at least `longestBackoff` old — a service that has
    /// stayed quiet that long has earned a fresh start. With nothing ever
    /// limited there is no streak to keep.
    mutating func answered(at now: Date) {
        until = nil
        guard let lastLimited else {
            consecutive = 0
            return
        }
        if now.timeIntervalSince(lastLimited) >= Self.longestBackoff {
            consecutive = 0
            self.lastLimited = nil
        }
    }
}
