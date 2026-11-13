import XCTest
@testable import IslaKit

/// Battery Low and Full Battery (spec §19.5 a, b): when each fires, and that
/// each fires once.
final class BatteryAlertsTests: XCTestCase {
    private func battery(_ level: Int) -> AmbientWatch.Power {
        AmbientWatch.Power(onExternalPower: false, level: level, isCharging: false)
    }

    private func power(_ level: Int, charging: Bool = true) -> AmbientWatch.Power {
        AmbientWatch.Power(onExternalPower: true, level: level, isCharging: charging)
    }

    func testLowFiresAtTwentyAndAgainAtTenOncePerDischarge() {
        var alerts = BatteryAlerts(seed: battery(40))
        XCTAssertNil(alerts.reading(battery(30), lowPowerMode: false))
        XCTAssertEqual(alerts.reading(battery(20), lowPowerMode: false), .batteryLow(level: 20, lowPowerMode: false))
        XCTAssertNil(alerts.reading(battery(19), lowPowerMode: false), "once per discharge")
        XCTAssertNil(alerts.reading(battery(20), lowPowerMode: false), "a level that wobbles back is not a second crossing")
        XCTAssertEqual(alerts.reading(battery(10), lowPowerMode: true), .batteryLow(level: 10, lowPowerMode: true))
        XCTAssertNil(alerts.reading(battery(9), lowPowerMode: true))
    }

    /// A drop straight past both thresholds (a sleep) says so once, at the
    /// lower one.
    func testAFallPastBothThresholdsWarnsOnce() {
        var alerts = BatteryAlerts(seed: battery(25))
        XCTAssertEqual(alerts.reading(battery(8), lowPowerMode: false), .batteryLow(level: 8, lowPowerMode: false))
        XCTAssertNil(alerts.reading(battery(7), lowPowerMode: false))
    }

    func testPluggingInResetsBothThresholds() {
        var alerts = BatteryAlerts(seed: battery(25))
        XCTAssertNotNil(alerts.reading(battery(20), lowPowerMode: false))
        XCTAssertNil(alerts.reading(power(20), lowPowerMode: false), "plugging in is not low")
        XCTAssertNil(alerts.reading(battery(20), lowPowerMode: false), "still at the threshold, not crossing it")
        XCTAssertNotNil(alerts.reading(battery(19), lowPowerMode: false), "a new discharge warns again")
    }

    /// Isla launching on a battery already under 20 has missed the crossing:
    /// the phone would have warned already, and a warning at launch is about
    /// Isla starting, not the battery.
    func testTheSeedNeverWarnsAndCountsCrossingsAlreadyMade() {
        var alerts = BatteryAlerts(seed: battery(15))
        XCTAssertNil(alerts.reading(battery(14), lowPowerMode: false))
        XCTAssertNotNil(alerts.reading(battery(10), lowPowerMode: false), "the 10 crossing is still ahead")
    }

    func testFullFiresWhenAChargeReachesAHundredOnce() {
        var alerts = BatteryAlerts(seed: power(97))
        XCTAssertNil(alerts.reading(power(99), lowPowerMode: false))
        XCTAssertEqual(alerts.reading(power(100, charging: false), lowPowerMode: false), .batteryFull(level: 100))
        XCTAssertNil(alerts.reading(power(99, charging: false), lowPowerMode: false), "a level that wobbles is not news")
        XCTAssertNil(alerts.reading(power(100, charging: false), lowPowerMode: false), "once per charge")
    }

    /// Plugging in a full battery is the charger's moment (rank 7), not a
    /// charge that just finished.
    func testPluggingInAFullBatteryIsNotFull() {
        var alerts = BatteryAlerts(seed: battery(100))
        XCTAssertNil(alerts.reading(power(100, charging: false), lowPowerMode: false))
    }

    func testUnpluggingOrFallingUnderNinetyFiveResetsFull() {
        var alerts = BatteryAlerts(seed: power(98))
        XCTAssertNotNil(alerts.reading(power(100), lowPowerMode: false))
        XCTAssertNil(alerts.reading(power(94, charging: true), lowPowerMode: false))
        XCTAssertNotNil(alerts.reading(power(100), lowPowerMode: false), "under 95 starts a new charge")

        var unplugged = BatteryAlerts(seed: power(98))
        XCTAssertNotNil(unplugged.reading(power(100), lowPowerMode: false))
        XCTAssertNil(unplugged.reading(battery(100), lowPowerMode: false))
        XCTAssertNil(unplugged.reading(power(99), lowPowerMode: false))
        XCTAssertNotNil(unplugged.reading(power(100), lowPowerMode: false), "unplugging starts a new charge")
    }

    /// Optimised Battery Charging holding at 80 percent is not full (§19.5 b).
    func testAChargeHeldAtEightyIsNotFull() {
        var alerts = BatteryAlerts(seed: power(78))
        XCTAssertNil(alerts.reading(power(80, charging: false), lowPowerMode: false))
    }

    func testAMacWithNoLevelNeverWarns() {
        var alerts = BatteryAlerts(seed: nil)
        let none = AmbientWatch.Power(onExternalPower: false, level: nil)
        XCTAssertNil(alerts.reading(none, lowPowerMode: false))
    }

    func testRanksHoldsAndTheQueueFollowTheSpec() {
        XCTAssertEqual(IslandActivity.ambient(.batteryLow(level: 20, lowPowerMode: false)).rank, 4)
        XCTAssertEqual(IslandActivity.ambient(.batteryFull(level: 100)).rank, 8)
        XCTAssertEqual(AmbientActivity.batteryLow(level: 20, lowPowerMode: false).holdDuration, 5)
        XCTAssertEqual(AmbientActivity.batteryFull(level: 100).holdDuration, 5)
        // Battery Low waits for a surface to close rather than lapsing after
        // the second (§19.1's exception); Full Battery does not.
        var queue = IslandAlertQueue()
        let start = Date()
        let low = IslandActivity.ambient(.batteryLow(level: 20, lowPowerMode: false))
        let full = IslandActivity.ambient(.batteryFull(level: 100))
        XCTAssertEqual(queue.post(low, showing: .none, blocked: true, at: start), .wait)
        XCTAssertEqual(queue.post(full, showing: .none, blocked: true, at: start), .wait)
        XCTAssertEqual(queue.next(at: start.addingTimeInterval(60)), low)
        XCTAssertNil(queue.next(at: start.addingTimeInterval(60)))
    }

    func testTheyAreExpandedAlertsInTheirTints() {
        XCTAssertEqual(
            IslandMotion.presentation(of: .ambient(.batteryLow(level: 20, lowPowerMode: false))), .expanded("batteryLow")
        )
        XCTAssertEqual(IslandMotion.presentation(of: .ambient(.batteryFull(level: 100))), .expanded("batteryFull"))
        XCTAssertEqual(AmbientActivity.batteryLow(level: 20, lowPowerMode: false).chargeTint, .red)
        XCTAssertEqual(AmbientActivity.batteryFull(level: 100).chargeTint, .green)
    }
}
