import XCTest
@testable import IslaKit

final class ReportedPlaybackTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The regression this type exists to prevent: on a real pause the flag
    /// flips ~550ms before the rate settles (measured against Spotify), and
    /// counting that stale rate as playing is a visible lag.
    func testStaleRateDoesNotKeepAPausedSessionPlaying() {
        var reader = ReportedPlayback()
        XCTAssertTrue(reader.resolve(isPlaying: true, rate: 1, at: t0))
        // Flag has flipped, rate has not caught up yet.
        XCTAssertFalse(reader.resolve(isPlaying: false, rate: 1, at: t0.addingTimeInterval(0.165)))
        XCTAssertFalse(reader.resolve(isPlaying: false, rate: 0, at: t0.addingTimeInterval(0.712)))
    }

    /// The reason the rate is consulted at all: some sessions never set the
    /// flag, and for those a positive rate is the only sign audio is moving.
    func testPositiveRateCountsForASessionThatNeverClaimsToBePlaying() {
        var reader = ReportedPlayback()
        XCTAssertTrue(reader.resolve(isPlaying: false, rate: 1, at: t0))
        XCTAssertTrue(reader.resolve(isPlaying: false, rate: 1, at: t0.addingTimeInterval(2)))
    }

    func testRateIsTrustedAgainOnceTheFlagHasSettled() {
        var reader = ReportedPlayback()
        _ = reader.resolve(isPlaying: true, rate: 1, at: t0)
        XCTAssertFalse(reader.resolve(isPlaying: false, rate: 1, at: t0.addingTimeInterval(0.2)))
        // Well past the settle window with the rate still up: this is no
        // longer a lagging field, it is a session reporting the flag badly.
        XCTAssertTrue(reader.resolve(isPlaying: false, rate: 1, at: t0.addingTimeInterval(5)))
    }

    func testResumingClearsTheSuppression() {
        var reader = ReportedPlayback()
        _ = reader.resolve(isPlaying: true, rate: 1, at: t0)
        XCTAssertFalse(reader.resolve(isPlaying: false, rate: 1, at: t0.addingTimeInterval(0.2)))
        XCTAssertTrue(reader.resolve(isPlaying: true, rate: 1, at: t0.addingTimeInterval(0.4)))
        // A second pause suppresses from its own moment, not the first one's.
        XCTAssertFalse(reader.resolve(isPlaying: false, rate: 1, at: t0.addingTimeInterval(0.5)))
    }

    func testAPausedSessionWithNoRateStaysPaused() {
        var reader = ReportedPlayback()
        XCTAssertFalse(reader.resolve(isPlaying: false, rate: 0, at: t0))
        XCTAssertFalse(reader.resolve(isPlaying: false, rate: 0, at: t0.addingTimeInterval(10)))
    }
}
