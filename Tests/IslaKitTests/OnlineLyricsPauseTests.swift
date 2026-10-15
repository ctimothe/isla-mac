import XCTest
@testable import IslaKit

/// How long every lookup stays quiet after the catalogue says "too many
/// requests". Pure: the clock and the dice are handed in, so no test sleeps.
///
/// On 2026-10-15 LRCLIB's gateway answered 429 for hours and this address was
/// banned, because each song, and each song's retry ladder, asked again.
final class OnlineLyricsPauseTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let upper: (ClosedRange<Double>) -> Double = { $0.upperBound }
    private let lower: (ClosedRange<Double>) -> Double = { $0.lowerBound }

    /// A Retry-After is the service's own word for when to come back, so the
    /// pause is that and nothing invented: no jitter, no backoff on top.
    func testRetryAfterSetsThePauseExactly() {
        var pause = OnlineLyricsPause()
        XCTAssertFalse(pause.isPaused(at: start), "a fresh pause holds nothing back")
        let lasts = pause.limited(retryAfter: 120, at: start, jitter: upper)
        XCTAssertEqual(lasts, 120)
        XCTAssertEqual(pause.until, start.addingTimeInterval(120))
        XCTAssertTrue(pause.isPaused(at: start.addingTimeInterval(119.9)))
        XCTAssertFalse(pause.isPaused(at: start.addingTimeInterval(120)))
    }

    /// With no Retry-After the wait doubles from a minute to half an hour. The
    /// draw is "equal jitter" — between half the step and the whole of it — so
    /// a roll near zero can never re-ask straight into the same 429, which a
    /// full-jitter draw would.
    func testBackoffDoublesAndCapsWithoutRetryAfter() {
        var top = OnlineLyricsPause()
        var bottom = OnlineLyricsPause()
        var steps: [TimeInterval] = []
        for _ in 0..<8 {
            let high = top.limited(retryAfter: nil, at: start, jitter: upper)
            let low = bottom.limited(retryAfter: nil, at: start, jitter: lower)
            XCTAssertEqual(low, high / 2, "the draw never goes below half the step")
            steps.append(high)
        }
        XCTAssertEqual(steps, [60, 120, 240, 480, 960, 1800, 1800, 1800])
        XCTAssertEqual(top.consecutive, 8)

        // And the draw is asked for exactly that range.
        var asked: ClosedRange<Double>?
        var pause = OnlineLyricsPause()
        _ = pause.limited(retryAfter: nil, at: start) { range in asked = range; return range.lowerBound }
        XCTAssertEqual(asked, 30...60)
    }

    /// An answer ends the pause itself at once — the service is listening —
    /// but not the streak: see the two tests after this one. With nothing ever
    /// limited there is nothing to keep, and an answer is a no-op.
    func testAnAnswerResetsTheBackoff() {
        var pause = OnlineLyricsPause()
        pause.answered(at: start)
        XCTAssertEqual(pause.consecutive, 0)

        _ = pause.limited(retryAfter: nil, at: start, jitter: upper)
        XCTAssertTrue(pause.isPaused(at: start))
        pause.answered(at: start.addingTimeInterval(10))
        XCTAssertNil(pause.until, "any answer ends the pause itself")
        XCTAssertFalse(pause.isPaused(at: start.addingTimeInterval(10)))
    }

    /// The 2026-10-15 ban was partial limiting: for three hours the gateway
    /// let an occasional probe through between its 429s. An answer five
    /// minutes after a limit must not send the backoff back to its first
    /// step, or it would never climb and the address would be asked at a
    /// minute's pace for the whole ban.
    func testAnAnswerSoonAfterALimitKeepsTheStreak() {
        var pause = OnlineLyricsPause()
        XCTAssertEqual(pause.limited(retryAfter: nil, at: start, jitter: upper), 60)
        pause.answered(at: start.addingTimeInterval(5 * 60))
        XCTAssertNil(pause.until)
        XCTAssertEqual(pause.consecutive, 1, "the streak survives an answer")
        XCTAssertEqual(
            pause.limited(retryAfter: nil, at: start.addingTimeInterval(5 * 60 + 1), jitter: upper), 120,
            "the next 429 continues the streak"
        )
    }

    /// A service quiet for the whole of the longest backoff has earned a
    /// fresh start: the first answer after that resets the streak.
    func testAQuietHalfHourResetsTheStreak() {
        var pause = OnlineLyricsPause()
        _ = pause.limited(retryAfter: nil, at: start, jitter: upper)
        _ = pause.limited(retryAfter: nil, at: start, jitter: upper)
        XCTAssertEqual(pause.consecutive, 2)

        pause.answered(at: start.addingTimeInterval(OnlineLyricsPause.longestBackoff - 1))
        XCTAssertEqual(pause.consecutive, 2, "a second short of half an hour is not quiet enough")

        pause.answered(at: start.addingTimeInterval(OnlineLyricsPause.longestBackoff))
        XCTAssertEqual(pause.consecutive, 0)
        XCTAssertNil(pause.lastLimited)
        XCTAssertEqual(
            pause.limited(retryAfter: nil, at: start.addingTimeInterval(3600), jitter: upper), 60,
            "and the next 429 starts again from the first step"
        )
    }

    /// The pause is a point in time, not a countdown: it ends when its time has
    /// come, whoever is asking.
    func testThePauseEndsWhenItsTimeHasCome() {
        var pause = OnlineLyricsPause()
        _ = pause.limited(retryAfter: 30, at: start, jitter: upper)
        XCTAssertTrue(pause.isPaused(at: start))
        XCTAssertTrue(pause.isPaused(at: start.addingTimeInterval(29.999)))
        XCTAssertFalse(pause.isPaused(at: start.addingTimeInterval(30)))
        XCTAssertFalse(pause.isPaused(at: start.addingTimeInterval(3600)))
    }

    /// A Retry-After of zero is no guidance: taken literally it would re-ask
    /// the instant it was read, which is the loop the pause exists to stop. It
    /// falls to the backoff like an absent header.
    func testARetryAfterOfZeroFallsToTheBackoff() {
        var pause = OnlineLyricsPause()
        XCTAssertEqual(pause.limited(retryAfter: 0, at: start, jitter: upper), 60)
    }
}
