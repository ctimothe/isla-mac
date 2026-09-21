import XCTest
@testable import IslaKit

/// With nothing playing, the island rests hidden in the hardware notch and
/// wakes under the pointer.
@MainActor
final class RestingNotchTests: XCTestCase {
    /// The M4 Pro 14" notch, as `NotchGeometry` measures it: the gap between
    /// the two auxiliary menu-bar areas, by the safe-area depth.
    private let notch = CGSize(width: 185, height: 32)

    /// At rest nothing of the island may land outside the cutout, because
    /// outside is where the pixels are. It used to draw 6pt concave shoulders
    /// past each side of the notch — two small black ears on an idle menu bar.
    func testAtRestTheIslandSitsEntirelyInsideTheNotch() {
        let rest = NotchContentView.restingShape(notch: notch)
        XCTAssertLessThan(rest.width, notch.width, "no shoulder may reach past the cutout's sides")
        XCTAssertLessThan(rest.height, notch.height, "and nothing past its bottom edge")
        XCTAssertGreaterThanOrEqual(
            Theme.restingNotchBottomRadius, Theme.collapsedBottomRadius,
            "a corner rounder than the hardware's stays inside it rather than poking a nub past it"
        )
    }

    /// Awake, it has to be *seen* growing: past the notch on both sides and
    /// below, by enough to read as the island rather than a rendering glitch.
    func testAwakeTheIslandGrowsPastTheNotch() {
        let awake = NotchContentView.awakeShape(notch: notch, shoulder: Theme.collapsedTopRadius)
        XCTAssertGreaterThanOrEqual(awake.width - notch.width, 2 * 8, "at least 8pt showing each side")
        XCTAssertGreaterThan(awake.height, notch.height)
        // But it is a nudge, not the panel: nowhere near the compact pill's
        // width, let alone the open body's.
        XCTAssertLessThan(awake.width, notch.width + NotchMetrics.compactMediaExtension)
    }

    /// The hover bump is the owner-requested exception to "critically damped
    /// unless momentum", and it stays a single bump that settles, not a wobble.
    func testTheHoverNudgeIsOneBumpNotAWobble() {
        XCTAssertLessThan(Theme.hoverNudgeDamping, 1.0, "a small bump, on purpose")
        XCTAssertGreaterThanOrEqual(Theme.hoverNudgeDamping, 0.65, "one bump, not a wobble")
        XCTAssertFalse(
            Theme.criticallyDampedSprings.contains { "\($0)" == "\(Theme.hoverNudge)" },
            "it is a named exception, not a critically damped spring"
        )
    }
}

/// A paused track folds into the notch once the pause has settled.
@MainActor
final class PausedFoldTests: XCTestCase {
    /// Spotify keeps a paused track loaded forever, so "has a track" never went
    /// false on an idle Mac, and the island carried a pill with a placeholder
    /// cover and a still equalizer across the menu bar indefinitely.
    func testASettledPauseIsHiddenAndAFreshOneIsNot() {
        XCTAssertEqual(CompactMediaActivity(hasTrack: true, isPlaying: false), .paused,
                       "just paused: the pill stays, so a quick resume never flickers it away")
        XCTAssertEqual(CompactMediaActivity(hasTrack: true, isPlaying: false, pauseHasSettled: true), .hidden,
                       "settled: it folds into the notch like nothing loaded")
        XCTAssertEqual(CompactMediaActivity(hasTrack: true, isPlaying: true, pauseHasSettled: true), .playing,
                       "playing always shows, whatever a stale flag says")
    }

    func testThePauseSettlesAfterTheLingerAndResumingUndoesIt() async throws {
        guard let geometry = NotchGeometry.current() else {
            return XCTFail("a test host always has a screen")
        }
        NotchMetrics.pausedLinger = 0.05
        defer { NotchMetrics.pausedLinger = 5 }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())

        vm.playbackChanged(isPlaying: false, hasTrack: true)
        XCTAssertFalse(vm.pauseHasSettled, "not at once")
        for _ in 0..<50 where !vm.pauseHasSettled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(vm.pauseHasSettled, "after the linger")

        vm.playbackChanged(isPlaying: true, hasTrack: true)
        XCTAssertFalse(vm.pauseHasSettled, "resuming brings the pill straight back")
    }

    /// Nothing loaded at all never starts a countdown — it is already hidden.
    func testNoTrackStartsNoCountdown() async {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        NotchMetrics.pausedLinger = 0.02
        defer { NotchMetrics.pausedLinger = 5 }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.playbackChanged(isPlaying: false, hasTrack: false)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(vm.pauseHasSettled)
    }
}
