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
        defer { NotchMetrics.pausedLinger = 0.4 }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())

        vm.playbackChanged(isPlaying: true, hasTrack: true)
        vm.playbackChanged(isPlaying: false, hasTrack: true)
        XCTAssertFalse(vm.pauseHasSettled, "not at once")
        for _ in 0..<50 where !vm.pauseHasSettled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(vm.pauseHasSettled, "after the linger")

        vm.playbackChanged(isPlaying: true, hasTrack: true)
        XCTAssertFalse(vm.pauseHasSettled, "resuming brings the pill straight back")
    }

    /// A paused song the island only learned about — adopted after a relaunch,
    /// or re-described while a film owns Now Playing — has nothing to announce.
    /// It used to wake the island for the whole linger each time.
    func testAPausedTrackNobodyWasSeenPausingRestsAtOnce() {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.playbackChanged(isPlaying: false, hasTrack: true)
        XCTAssertTrue(vm.pauseHasSettled)
        XCTAssertEqual(vm.compactMediaActivity, .hidden)
    }

    /// A pause re-described mid-linger — the same song's key rebuilt from
    /// another source — neither restarts the linger nor cuts it short.
    func testALingerSurvivesTheSamePauseBeingDescribedAgain() async {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        NotchMetrics.pausedLinger = 0.15
        defer { NotchMetrics.pausedLinger = 0.4 }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.playbackChanged(isPlaying: true, hasTrack: true)
        vm.playbackChanged(isPlaying: false, hasTrack: true)
        try? await Task.sleep(for: .milliseconds(60))
        vm.playbackChanged(isPlaying: false, hasTrack: true)
        XCTAssertFalse(vm.pauseHasSettled, "not cut short")
        for _ in 0..<40 where !vm.pauseHasSettled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(vm.pauseHasSettled, "and it still settles")
    }

    /// Pausing the song and starting a film: the pill has nothing left to say
    /// once the film plays, so it folds into the notch then and there. It used
    /// to hang over the film for the rest of its five seconds.
    func testAFilmStartingFoldsALingeringPause() {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.playbackChanged(isPlaying: true, hasTrack: true)
        vm.playbackChanged(isPlaying: false, hasTrack: true)
        XCTAssertFalse(vm.pauseHasSettled, "the fixture: a fresh pause lingers")
        vm.otherMediaStartedPlaying()
        XCTAssertTrue(vm.pauseHasSettled)
    }

    /// Pausing the song while a film is already playing: nothing starts, so
    /// the fold above never fires — and the pill hung over the film for the
    /// whole linger. A pause made while other media plays rests at once.
    func testAPauseWhileAFilmPlaysRestsAtOnce() {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        let media = vm.media
        media.isolateFromPlayers()
        media.musicOnly = { true }
        media.bundleIdentifierForPID = { $0 == 1 ? "com.spotify.client" : "org.mozilla.firefox" }
        media.isProcessRunning = { _ in true }
        func report(pid: pid_t, title: String) -> NowPlayingFeed.Snapshot {
            var s = NowPlayingFeed.Snapshot()
            s.title = title
            s.duration = 200
            s.elapsed = 40
            s.isPlaying = true
            s.rate = 1
            s.takenAt = Date()
            s.playerPID = pid
            return s
        }
        media.receive(report(pid: 1, title: "Song"))
        media.receive(report(pid: 2, title: "Film"))
        XCTAssertTrue(media.otherMediaIsPlaying, "the fixture: a film plays over the song")

        vm.playbackChanged(isPlaying: true, hasTrack: true)
        vm.playbackChanged(isPlaying: false, hasTrack: true)
        XCTAssertTrue(vm.pauseHasSettled)
    }

    /// The same, in the order the reports really arrive: the film's report
    /// first, and the song's pause learned from its own player after it.
    func testASongPausedUnderAPlayingFilmRestsAtOnceThroughTheFeed() {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        let media = vm.media
        media.isolateFromPlayers()
        media.musicOnly = { true }
        media.isProcessRunning = { _ in true }
        media.bundleIdentifierForPID = { $0 == 1 ? "com.spotify.client" : "com.google.Chrome" }
        media.heldPlayerState = { (_: PlayerApp, reply: @escaping (PlayerBridge.StateReply) -> Void) in
            reply(.loaded(PlayerState(
                app: .spotify, isPlaying: false, title: "Song", artist: "",
                album: "", duration: 200, position: 41
            )))
        }
        func report(pid: pid_t, title: String) -> NowPlayingFeed.Snapshot {
            var s = NowPlayingFeed.Snapshot()
            s.title = title
            s.duration = 200
            s.elapsed = 40
            s.isPlaying = true
            s.rate = 1
            s.takenAt = Date()
            s.playerPID = pid
            return s
        }
        media.receive(report(pid: 1, title: "Song"))
        media.receive(report(pid: 2, title: "Film"))
        XCTAssertFalse(media.isPlaying, "the fixture: the song's player says it is paused")
        XCTAssertTrue(vm.pauseHasSettled)
    }

    /// A different song arriving paused rests like any other paused song. It
    /// used to glance for the linger; the owner asked on 2026-09-21 for a
    /// paused island to stay under the notch.
    func testANewSongArrivingPausedRestsToo() {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.playbackChanged(isPlaying: false, hasTrack: true, title: "One")
        vm.playbackChanged(isPlaying: false, hasTrack: true, title: "Two")
        XCTAssertTrue(vm.pauseHasSettled)
    }

    /// A pause folds within a skip's breath, not five seconds: long enough to
    /// ride out the pause a skip passes through, and no longer.
    func testAPauseFoldsAlmostAtOnce() {
        XCTAssertLessThanOrEqual(NotchMetrics.pausedLinger, 0.5)
        XCTAssertGreaterThan(NotchMetrics.pausedLinger, 0.2, "a skip's own pause must not flicker the pill")
    }

    /// The pointer thrown to the top of the display parks on its very edge,
    /// under the notch — the one place a pointer reaches the island from, and
    /// the one place it was not counted as on it.
    func testThePointerParkedOnTheTopEdgeIsOnTheIsland() {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        let top = CGPoint(x: geometry.notchCenterX, y: geometry.screen.frame.maxY)
        XCTAssertTrue(geometry.collapsedIslandHoverRect(for: 200).contains(top), "the hover lift")
        let window = NotchRootView.reachingTopEdge(
            CGRect(x: 100, y: 10, width: 200, height: 32), windowHeight: 42)
        XCTAssertTrue(window.contains(CGPoint(x: 150, y: 42)), "the click")
        let inside = NotchRootView.reachingTopEdge(
            CGRect(x: 100, y: 0, width: 200, height: 32), windowHeight: 42)
        XCTAssertEqual(inside.height, 32, "a rect short of the top is left alone")
    }

    /// A playing song is not folded by a film starting alongside it.
    func testAFilmStartingLeavesAPlayingSongAlone() {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.playbackChanged(isPlaying: true, hasTrack: true)
        vm.otherMediaStartedPlaying()
        XCTAssertFalse(vm.pauseHasSettled)
    }

    /// Nothing loaded at all never starts a countdown — it is already hidden.
    func testNoTrackStartsNoCountdown() async {
        guard let geometry = NotchGeometry.current() else { return XCTFail("screen") }
        NotchMetrics.pausedLinger = 0.02
        defer { NotchMetrics.pausedLinger = 0.4 }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.playbackChanged(isPlaying: false, hasTrack: false)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(vm.pauseHasSettled)
    }
}
