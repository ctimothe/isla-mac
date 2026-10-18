import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import IslaKit

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
            // 180 + 70: spec §19.4 — two 35 pt wings. It was 180 + 104 = 284
            // before 2026-10-15 and 180 + 80 until 2026-10-17.
            CGSize(width: 250, height: 32)
        )
    }

    func testPlayingTrackUsesTheSameStableWidthAsPaused() {
        let paused = CompactMediaActivity(hasTrack: true, isPlaying: false)
        let playing = CompactMediaActivity(hasTrack: true, isPlaying: true)
        let notch = CGSize(width: 210, height: 38)

        XCTAssertEqual(playing, .playing)
        XCTAssertTrue(playing.isVisible)
        // 210 + 70: spec §19.4; it was 210 + 104 = 314, then 210 + 80.
        XCTAssertEqual(playing.bodySize(notchSize: notch), CGSize(width: 280, height: 38))
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

    /// Redesign 2026-10-15, spec §3.2: only a playing island draws the equalizer
    /// in the cover's tint; a paused one draws it at rest in tertiary.
    func testOnlyPlayingTintsTheEqualizer() {
        XCTAssertTrue(CompactMediaActivity.playing.tintsEqualizer)
        XCTAssertFalse(CompactMediaActivity.paused.tintsEqualizer)
        XCTAssertFalse(CompactMediaActivity.hidden.tintsEqualizer)
    }

    /// The paused cover darkens to 0.55 of itself and is not made see-through
    /// (redesign 2026-10-15, spec §3.2: it was 0.58 opacity), and the badge is a
    /// 9 pt glyph rather than a circle.
    func testThePausedCoverIsDimmedNotTranslucent() {
        XCTAssertEqual(Theme.pausedCoverBrightness, 0.55)
    }

    func testTheHoverFillIsASolidOneCEOneCEOneEE() throws {
        let hover = try XCTUnwrap(NSColor(Theme.islandHover).usingColorSpace(.sRGB))
        XCTAssertEqual(hover.redComponent, 28.0 / 255, accuracy: 0.002)
        XCTAssertEqual(hover.greenComponent, 28.0 / 255, accuracy: 0.002)
        XCTAssertEqual(hover.blueComponent, 30.0 / 255, accuracy: 0.002)
        XCTAssertEqual(hover.alphaComponent, 1, "solid, not a gradient lift")
        let green = try XCTUnwrap(NSColor(Theme.chargingGreen).usingColorSpace(.sRGB))
        XCTAssertEqual(green.redComponent, 48.0 / 255, accuracy: 0.002)
        XCTAssertEqual(green.greenComponent, 209.0 / 255, accuracy: 0.002)
        XCTAssertEqual(green.blueComponent, 88.0 / 255, accuracy: 0.002)
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

    /// The peek widens the pill and grows it so a title and an artist have somewhere to go, and only then.
    func testPeekingWidensTheCompactPill() {
        let notch = CGSize(width: 200, height: 32)
        let resting = CompactMediaActivity.playing.bodySize(notchSize: notch)
        let peeking = CompactMediaActivity.playing.bodySize(notchSize: notch, peeking: true)

        XCTAssertGreaterThan(peeking.width, resting.width)
        // Redesign 2026-10-15, spec §3.5: a peek now grows to 50 pt for its two
        // lines; it used to widen and never grow taller.
        XCTAssertEqual(resting.height, 32)
        XCTAssertEqual(peeking.height, NotchMetrics.sneakPeekHeight, "a peek widens and grows to 50 pt")
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
