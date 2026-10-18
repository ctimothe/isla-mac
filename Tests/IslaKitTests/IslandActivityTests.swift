import XCTest
@testable import IslaKit

/// What the island shows, and when (redesign spec §19.1): one activity at a
/// time, chosen by rank; a higher alert replaces a lower at once, an equal one
/// replaces the older, and an alert that cannot show within a second of its
/// cause is dropped. Pure — no view, no timer; the clock is a `Date` handed in.
final class IslandActivityTests: XCTestCase {
    private let hud = IslandActivity.hud(HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil)))
    private let headphones = IslandActivity.ambient(.headphones(name: "AirPods Pro", symbol: "airpods.pro"))
    private let charging = IslandActivity.ambient(.charging(level: 67, isCharging: true))
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: The table

    func testTheRanksAreTheSpecsTable() {
        XCTAssertEqual(hud.rank, 3, "volume or brightness")
        XCTAssertEqual(headphones.rank, 6)
        XCTAssertEqual(charging.rank, 7)
        XCTAssertEqual(IslandActivity.peek.rank, 10, "the new-track peek")
        XCTAssertEqual(IslandActivity.music.rank, 11)
        XCTAssertEqual(IslandActivity.shelf(count: 3).rank, 12)
        XCTAssertNil(IslandActivity.none.rank, "the bare notch is not an activity")

        for alert in [hud, headphones, charging, .peek] {
            XCTAssertTrue(alert.isAlert, "\(alert)")
            XCTAssertFalse(alert.isLive, "\(alert)")
        }
        for live in [IslandActivity.music, .shelf(count: 1)] {
            XCTAssertTrue(live.isLive, "\(live)")
            XCTAssertFalse(live.isAlert, "\(live)")
        }
        XCTAssertFalse(IslandActivity.none.isAlert)
        XCTAssertFalse(IslandActivity.none.isLive)
    }

    /// Every pair: whatever is standing, the island shows the highest.
    func testTheIslandShowsTheHighestOfWhatIsStanding() {
        func current(
            hud: HUDMoment? = nil, ambient: AmbientActivity? = nil, peeking: Bool = false,
            music: Bool = false, shelf: Int = 0
        ) -> IslandActivity {
            IslandActivity.current(hud: hud, ambient: ambient, isPeeking: peeking, musicIsVisible: music, shelfCount: shelf)
        }
        let volume = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        let charger = AmbientActivity.charging(level: 67, isCharging: true)
        XCTAssertEqual(current(), .none, "nothing: the bare notch")
        XCTAssertEqual(current(shelf: 2), .shelf(count: 2))
        XCTAssertEqual(current(music: true), .music)
        XCTAssertEqual(current(music: true, shelf: 2), .music, "Music outranks the Shelf; the Shelf waits as the bubble")
        XCTAssertEqual(current(peeking: true, music: true, shelf: 2), .peek)
        XCTAssertEqual(current(peeking: true, music: false), .none, "a peek needs a song to show")
        XCTAssertEqual(current(ambient: charger, peeking: true, music: true), .ambient(charger))
        XCTAssertEqual(current(hud: volume, ambient: charger, peeking: true, music: true, shelf: 2), .hud(volume))
        XCTAssertEqual(current(ambient: charger, shelf: 4), .ambient(charger), "an alert over the Shelf alone")
        XCTAssertEqual(current(shelf: 0), .none, "an empty Shelf is not live")
    }

    // MARK: The bubble

    /// Only Music and the Shelf are live, so only the Shelf can be the bubble,
    /// and only beside a compact live activity: never during an alert, a
    /// surface or the lock.
    func testTheBubbleIsTheShelfBesideMusicAndNowhereElse() {
        func bubble(_ activity: IslandActivity, shelf: Int = 3, open: Bool = false, locked: Bool = false) -> Int? {
            IslandActivity.bubble(beside: activity, shelfCount: shelf, isOpen: open, isLocked: locked)
        }
        XCTAssertEqual(bubble(.music), 3, "Music holds the island; the Shelf waits beside it")
        XCTAssertNil(bubble(.music, shelf: 0), "an empty Shelf")
        XCTAssertNil(bubble(.shelf(count: 3)), "the Shelf is the island itself")
        XCTAssertNil(bubble(.none, shelf: 0))
        for alert in [hud, headphones, charging, .peek] {
            XCTAssertNil(bubble(alert), "never during an alert: \(alert)")
        }
        XCTAssertNil(bubble(.music, open: true), "never while a surface is open")
        XCTAssertNil(bubble(.music, locked: true), "never while locked")
    }

    // MARK: Replacement

    func testAHigherAlertReplacesALowerAtOnce() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(headphones, showing: charging, blocked: false, at: t0), .show)
        XCTAssertEqual(queue.post(hud, showing: headphones, blocked: false, at: t0), .show)
        XCTAssertEqual(queue.post(charging, showing: .peek, blocked: false, at: t0), .show)
        XCTAssertEqual(queue.post(.peek, showing: .music, blocked: false, at: t0), .show, "an alert over a live activity")
        XCTAssertEqual(queue.post(.peek, showing: .shelf(count: 1), blocked: false, at: t0), .show)
        XCTAssertEqual(queue.post(charging, showing: .none, blocked: false, at: t0), .show)
        XCTAssertTrue(queue.waiting.isEmpty, "a replaced alert is dropped, not queued")
    }

    func testAnEqualAlertReplacesTheOlder() {
        var queue = IslandAlertQueue()
        let replugged = IslandActivity.ambient(.charging(level: 68, isCharging: true))
        XCTAssertEqual(queue.post(replugged, showing: charging, blocked: false, at: t0), .show)
        XCTAssertEqual(queue.post(hud, showing: hud, blocked: false, at: t0), .show, "each press replaces the pop-up")
        XCTAssertTrue(queue.waiting.isEmpty)
    }

    // MARK: The one-second rule

    /// A lower alert waits behind a higher one, and shows if the island is free
    /// within a second of its cause.
    func testALowerAlertWaitsASecondBehindAHigherOne() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(charging, showing: headphones, blocked: false, at: t0), .wait)
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(0.6)), charging, "the headphones folded inside the second")
        XCTAssertNil(queue.next(at: t0.addingTimeInterval(0.7)), "and it was taken off the queue")
    }

    func testOneThatCannotShowWithinTheSecondIsDropped() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(.peek, showing: charging, blocked: false, at: t0), .wait)
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(1.0)), .peek, "at the second, not past it")

        XCTAssertEqual(queue.post(.peek, showing: charging, blocked: false, at: t0), .wait)
        XCTAssertNil(queue.next(at: t0.addingTimeInterval(1.01)), "past it: dropped")
        XCTAssertTrue(queue.waiting.isEmpty)
    }

    /// An open surface or the lock blocks every alert the same way: it waits a
    /// second for the island, and is then dropped.
    func testASurfaceOrTheLockHoldsAnAlertForASecond() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(headphones, showing: .none, blocked: true, at: t0), .wait)
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(0.4)), headphones, "the surface closed in time")

        XCTAssertEqual(queue.post(charging, showing: .none, blocked: true, at: t0), .wait)
        XCTAssertNil(queue.next(at: t0.addingTimeInterval(3)), "it stayed open")
    }

    /// Volume and brightness are never queued: while they cannot show, the key
    /// applies and nothing is drawn (R5).
    func testThePopUpIsNeverQueued() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(hud, showing: .none, blocked: true, at: t0), .drop)
        XCTAssertTrue(queue.waiting.isEmpty)
        XCTAssertNil(queue.next(at: t0))
    }

    /// The highest waiting alert goes first; of two equal, the newer — an equal
    /// one replaces the older while it waits, too.
    func testTheHighestWaitingAlertGoesFirstAndAnEqualOneReplacesTheOlder() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(.peek, showing: hud, blocked: false, at: t0), .wait)
        XCTAssertEqual(queue.post(charging, showing: hud, blocked: false, at: t0.addingTimeInterval(0.1)), .wait)
        let replugged = IslandActivity.ambient(.charging(level: 68, isCharging: true))
        XCTAssertEqual(queue.post(replugged, showing: hud, blocked: false, at: t0.addingTimeInterval(0.2)), .wait)
        XCTAssertEqual(queue.waiting.count, 2, "the older charger was replaced in the queue")
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(0.5)), replugged, "Charging outranks the peek")
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(0.5)), .peek)
        XCTAssertNil(queue.next(at: t0.addingTimeInterval(0.5)))
    }

    /// An alert that shows clears an equal one still waiting: it is older.
    func testShowingAnAlertClearsAnEqualOneWaiting() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(charging, showing: hud, blocked: false, at: t0), .wait)
        XCTAssertEqual(queue.post(charging, showing: .music, blocked: false, at: t0.addingTimeInterval(0.2)), .show)
        XCTAssertTrue(queue.waiting.isEmpty)
    }

    /// The two exceptions R9 brings (Battery Low and the update choice) are a
    /// policy: an alert that outlives the second waits until the island is
    /// free, and one that returns when replaced goes back on the queue. Proved
    /// here with stand-ins, since R7 has neither alert.
    func testTheExceptionsOutliveTheSecondAndReturnWhenReplaced() {
        let lowBattery = charging   // stands in for Battery Low
        let update = IslandActivity.peek // stands in for the update choice
        var queue = IslandAlertQueue(policy: .init(
            outlivesPatience: { $0 == lowBattery || $0 == update },
            returnsWhenReplaced: { $0 == update }
        ))
        XCTAssertEqual(queue.post(lowBattery, showing: .none, blocked: true, at: t0), .wait)
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(60)), lowBattery, "waits until the surface closes")

        XCTAssertEqual(queue.post(hud, showing: update, blocked: false, at: t0), .show)
        XCTAssertEqual(queue.waiting.map(\.alert), [update], "the update choice waits for the next idle moment")
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(30)), update)

        var standard = IslandAlertQueue()
        XCTAssertEqual(standard.post(hud, showing: .peek, blocked: false, at: t0), .show)
        XCTAssertTrue(standard.waiting.isEmpty, "every R7 alert is simply dropped")
    }

    func testThePatienceIsOneSecond() {
        XCTAssertEqual(IslandAlertQueue.patience, 1)
    }

    // MARK: Holds

    /// §19.1's holds: the charger 3 s, headphones 4 s, the peek its
    /// `sneakPeekDuration`, the pop-up 1.5 s after the last press.
    func testEachAlertHoldsForTheSpecsTime() {
        XCTAssertEqual(AmbientActivity.charging(level: 50, isCharging: true).holdDuration, 3)
        XCTAssertEqual(AmbientActivity.charging(level: nil, isCharging: false).holdDuration, 3)
        XCTAssertEqual(AmbientActivity.headphones(name: "AirPods", symbol: "airpods").holdDuration, 4)
        XCTAssertEqual(NotchMetrics.sneakPeekDuration, 2.2)
        XCTAssertEqual(Theme.hudLinger, 1.5)
    }

    // MARK: Blocking

    func testWhatBlocksAnAlert() {
        XCTAssertFalse(NotchController.alertsBlocked(isOpen: false, isDropTargeted: false, isLocked: false))
        XCTAssertTrue(NotchController.alertsBlocked(isOpen: true, isDropTargeted: false, isLocked: false), "a surface")
        XCTAssertTrue(NotchController.alertsBlocked(isOpen: false, isDropTargeted: true, isLocked: false), "the drop surface")
        XCTAssertTrue(NotchController.alertsBlocked(isOpen: false, isDropTargeted: false, isLocked: true), "the lock")
    }
}
