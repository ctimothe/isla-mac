import SwiftUI
import XCTest
@testable import IslaKit

/// The new live activities in the island's ranking (plan
/// `2026-11-14-islandcn-activities`, spec §19.1 amended 2026-11-14), the
/// bubble that any of them can be, and islandcn's neck between the two.
@MainActor
final class LiveActivityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)
    private var recording: LiveActivity { .recording(CaptureState(microphone: ["com.zoom.us"], camera: false)) }
    private var timer: LiveActivity {
        .timer(IslandTimerState(kind: .countdown(duration: 300), runningSince: now, banked: 0))
    }
    private var stopwatch: LiveActivity { .stopwatch(IslandTimerState(kind: .stopwatch, runningSince: now, banked: 0)) }
    private var downloads: LiveActivity {
        .downloads([DownloadProgress(name: "a.zip", bytesSoFar: 50, totalBytes: 100)])
    }

    func testStandingIsInRankOrderAndDropsWhatIsNotThere() {
        let all = LiveActivity.standing(
            capture: CaptureState(microphone: ["com.zoom.us"], camera: false),
            countdown: IslandTimerState(kind: .countdown(duration: 300), runningSince: now, banked: 0),
            stopwatch: IslandTimerState(kind: .stopwatch, runningSince: now, banked: 0),
            downloads: [DownloadProgress(name: "a.zip", bytesSoFar: 50, totalBytes: 100)]
        )
        XCTAssertEqual(all.map(\.kind), ["recording", "timer", "stopwatch", "downloads"])
        XCTAssertEqual(
            LiveActivity.standing(capture: CaptureState.none, countdown: nil, stopwatch: nil, downloads: []), [],
            "an empty capture, no timers and no downloads stand nothing"
        )
    }

    /// A timer outranks the song, a download does not; the Shelf is last.
    func testTheIslandShowsTheHighestAndTheNextWaitsAsTheBubble() {
        let island = IslandActivity.current(
            hud: nil, ambient: nil, isPeeking: false, musicIsVisible: true, shelfCount: 2, live: [timer, downloads]
        )
        XCTAssertEqual(island, .live(timer))
        XCTAssertEqual(
            IslandActivity.bubbleActivity(
                beside: island, musicIsVisible: true, shelfCount: 2, live: [timer, downloads], isOpen: false, isLocked: false
            ),
            .music, "the song waits beside the timer"
        )
        let underSong = IslandActivity.current(
            hud: nil, ambient: nil, isPeeking: false, musicIsVisible: true, shelfCount: 0, live: [downloads]
        )
        XCTAssertEqual(underSong, .music)
        XCTAssertEqual(
            IslandActivity.bubbleActivity(
                beside: underSong, musicIsVisible: true, shelfCount: 0, live: [downloads], isOpen: false, isLocked: false
            ),
            .live(downloads)
        )
    }

    /// No bubble while open, locked, alone, or beside an alert.
    func testTheBubbleKeepsTheShelfsRules() {
        let island = IslandActivity.live(recording)
        for (open, locked) in [(true, false), (false, true)] {
            XCTAssertNil(IslandActivity.bubbleActivity(
                beside: island, musicIsVisible: true, shelfCount: 0, live: [recording], isOpen: open, isLocked: locked
            ))
        }
        XCTAssertNil(IslandActivity.bubbleActivity(
            beside: island, musicIsVisible: false, shelfCount: 0, live: [recording], isOpen: false, isLocked: false
        ), "one activity has nothing beside it")
        XCTAssertNil(IslandActivity.bubbleActivity(
            beside: .ambient(.timerDone(duration: 60)), musicIsVisible: true, shelfCount: 3, live: [],
            isOpen: false, isLocked: false
        ))
    }

    /// A live activity on the island opens what it is: a timer its controls
    /// in place, never a surface (`IslandClick.live`).
    func testALiveIslandClickIsTheActivitysOwn() {
        XCTAssertEqual(
            NotchViewModel.click(on: .live(timer), live: .live(timer), hasTrack: true), .live(timer),
            "a timer's click is its own"
        )
    }

    func testVoiceOverHearsWhatTheIslandShows() {
        XCTAssertEqual(recording.accessibilityLabel(at: now), localized("Microphone in use"))
        XCTAssertEqual(
            LiveActivity.recording(CaptureState(microphone: [], camera: true)).accessibilityLabel(at: now),
            localized("Camera in use")
        )
        XCTAssertEqual(timer.accessibilityLabel(at: now.addingTimeInterval(60)), localized("Timer, %@ left", "4:00"))
        XCTAssertEqual(downloads.accessibilityLabel(at: now), localized("Downloading %@, %d percent", "a.zip", 50))
    }

    func testTheBubbleIsIslandcnsWidthExceptTheShelfs() {
        XCTAssertEqual(IslandBubbleLayout.width(for: .live(timer)), LiveActivityLayout.bubbleWidth)
        XCTAssertEqual(IslandBubbleLayout.width(for: .shelf(count: 12)), IslandBubbleLayout.width(count: 12))
        XCTAssertEqual(
            IslandBubbleLayout.centreOffset(islandWidth: 300, count: 4),
            IslandBubbleLayout.centreOffset(islandWidth: 300, bubbleWidth: IslandBubbleLayout.width(count: 4)),
            "the count's offset is the width's"
        )
    }

    // MARK: - The neck

    /// islandcn's `bridgePath`: a neck while the gap is under 5 pt, none at 5.
    func testTheNeckThinsToNothingAtFivePoints() {
        let a = IslandNeck.Circle(centre: .zero, radius: 16)
        func b(gap: CGFloat) -> IslandNeck.Circle { IslandNeck.Circle(centre: CGPoint(x: 32 + gap, y: 0), radius: 16) }
        XCTAssertNotNil(IslandNeck.bridge(a, b(gap: -4)), "overlapping")
        XCTAssertNotNil(IslandNeck.bridge(a, b(gap: 2)))
        XCTAssertNil(IslandNeck.bridge(a, b(gap: 5)), "broken at maxGap")
        XCTAssertNil(IslandNeck.bridge(a, b(gap: 16)), "at rest the bubble stands alone")
        XCTAssertNil(IslandNeck.bridge(a, IslandNeck.Circle(centre: CGPoint(x: 2, y: 0), radius: 4)), "one inside the other")

        // Thinner as the gap opens: its height at the middle falls.
        func height(_ gap: CGFloat) -> CGFloat { IslandNeck.bridge(a, b(gap: gap))!.boundingRect.height }
        XCTAssertGreaterThan(height(0), height(3))
    }

    /// Merged at 0, at rest at 1, with the neck only on the way.
    func testTheSplitRunsFromTheIslandsEndToItsPlace() {
        let start = IslandNeck.Split.at(0, height: 32)
        XCTAssertEqual(start.bubble.centre.x, start.island.centre.x, accuracy: 0.001, "merged into the island's end")
        let rest = IslandNeck.Split.at(1, height: 32)
        XCTAssertEqual(rest.shift, 0)
        XCTAssertEqual(rest.scale, 1)
        XCTAssertNil(IslandNeck.bridge(rest.island, rest.bubble), "no neck at rest")
        let opening = (1...99).map { IslandNeck.Split.at(CGFloat($0) / 100, height: 32) }
        XCTAssertTrue(opening.contains { IslandNeck.bridge($0.island, $0.bubble) != nil }, "a neck on the way")
    }
}
