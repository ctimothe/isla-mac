import CoreGraphics
import XCTest
@testable import DynamicIslandKit

final class CompactMediaActivityTests: XCTestCase {
    func testNoTrackKeepsThePhysicalNotchSize() {
        let activity = CompactMediaActivity(hasTrack: false, isPlaying: false)

        XCTAssertEqual(activity, .hidden)
        XCTAssertFalse(activity.isVisible)
        XCTAssertFalse(activity.animatesEqualizer)
        XCTAssertEqual(
            activity.bodySize(notchSize: CGSize(width: 180, height: 32)),
            CGSize(width: 180, height: 32)
        )
    }

    func testPausedTrackKeepsAVisibleCompactActivity() {
        let activity = CompactMediaActivity(hasTrack: true, isPlaying: false)

        XCTAssertEqual(activity, .paused)
        XCTAssertTrue(activity.isVisible)
        XCTAssertFalse(activity.animatesEqualizer)
        XCTAssertEqual(
            activity.bodySize(notchSize: CGSize(width: 180, height: 32)),
            CGSize(width: 284, height: 32)
        )
    }

    func testPlayingTrackUsesTheSameStableWidthAsPaused() {
        let paused = CompactMediaActivity(hasTrack: true, isPlaying: false)
        let playing = CompactMediaActivity(hasTrack: true, isPlaying: true)
        let notch = CGSize(width: 210, height: 38)

        XCTAssertEqual(playing, .playing)
        XCTAssertTrue(playing.isVisible)
        XCTAssertEqual(playing.bodySize(notchSize: notch), CGSize(width: 314, height: 38))
        XCTAssertEqual(playing.bodySize(notchSize: notch), paused.bodySize(notchSize: notch))
    }

    func testOnlyPlayingTrackAnimatesTheEqualizer() {
        XCTAssertTrue(CompactMediaActivity.playing.animatesEqualizer)
        XCTAssertFalse(CompactMediaActivity.paused.animatesEqualizer)
        XCTAssertFalse(CompactMediaActivity.hidden.animatesEqualizer)
    }

    func testOnlyPausedTrackShowsAPlayBadgeOverTheArtwork() {
        XCTAssertTrue(CompactMediaActivity.paused.showsArtworkPlayBadge)
        XCTAssertFalse(CompactMediaActivity.playing.showsArtworkPlayBadge)
        XCTAssertFalse(CompactMediaActivity.hidden.showsArtworkPlayBadge)
    }

    func testInvalidPlayingFlagCannotExposeAnActivityWithoutATrack() {
        XCTAssertEqual(CompactMediaActivity(hasTrack: false, isPlaying: true), .hidden)
    }

    func testPausedEqualizerStopsAtTheSameRestingPatternImmediately() {
        XCTAssertEqual(EqualizerMotion.restingHeights, [4, 7, 5])
    }

    func testEqualizerUsesARemovableAnimatedViewOnlyWhilePlaying() {
        XCTAssertEqual(EqualizerPresentation(isPlaying: false, reduceMotion: false), .resting)
        XCTAssertEqual(EqualizerPresentation(isPlaying: true, reduceMotion: false), .animated)
        XCTAssertEqual(EqualizerPresentation(isPlaying: true, reduceMotion: true), .resting)
    }

    /// The peek widens the pill so a title has somewhere to go, and only then.
    func testPeekingWidensTheCompactPill() {
        let notch = CGSize(width: 200, height: 32)
        let resting = CompactMediaActivity.playing.bodySize(notchSize: notch)
        let peeking = CompactMediaActivity.playing.bodySize(notchSize: notch, peeking: true)

        XCTAssertGreaterThan(peeking.width, resting.width)
        XCTAssertEqual(peeking.height, resting.height, "a peek widens, it never grows taller")
        XCTAssertLessThanOrEqual(
            peeking.width,
            NotchMetrics.standardBody.width,
            "and never past the body the open panel uses"
        )
    }

    /// Nothing playing means nothing to peek at.
    func testHiddenActivityIgnoresPeeking() {
        let notch = CGSize(width: 200, height: 32)
        XCTAssertEqual(
            CompactMediaActivity.hidden.bodySize(notchSize: notch, peeking: true),
            notch
        )
    }
}
