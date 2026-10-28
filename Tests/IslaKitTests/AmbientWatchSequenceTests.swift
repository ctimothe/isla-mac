import XCTest
@testable import IslaKit

/// The charger and headphones watch played out over time, with a scripted
/// battery, port and Bluetooth list and a clock the test moves (maturity
/// program Batch 1, 2026-10-29).
///
/// `AmbientMomentTests` and `ChargePortTests` hold the pure rules — what a
/// plug-in is, which device is news, the port's words. What happened between
/// readings was held by nothing: a read that failed, a cable pulled before its
/// reading landed, a re-read that came after a pull, a CoreAudio list that
/// came back empty. Each is a bug this watch's comments name (G-033, the 0.6 s
/// settle, the "Not Charging" hold), and each could come back unseen.
@MainActor
final class AmbientWatchSequenceTests: XCTestCase {
    typealias Power = AmbientWatch.Power
    typealias Headphones = AmbientWatch.Headphones

    /// The Mac as the test scripts it.
    @MainActor final class Rig {
        var power: Power? = Power(onExternalPower: false, level: 57)
        var port: (port: ChargePort, watts: Int?, hold: ChargeHold?) = (.usbC, 61, nil)
        var headphones: [Headphones]? = []
        var now = Date(timeIntervalSince1970: 1_000_000)
        /// Off-main reads wait here while `holdReads` is set, so a test can
        /// pull the cable while one is in flight.
        var holdReads = false
        var heldReads: [@Sendable () -> Void] = []
        var portReads = 0
        private var timers: [(at: Date, work: @MainActor @Sendable () -> Void)] = []

        var events: [AmbientActivity] = []
        var updates: [AmbientActivity] = []

        lazy var watch: AmbientWatch = {
            let watch = AmbientWatch(environment: AmbientWatch.Environment(
                // Every read runs on the main thread here (`offMain` runs it in
                // place), so the scripted values are read where they live.
                readPower: { [unowned self] in MainActor.assumeIsolated { self.power } },
                readPort: { [unowned self] _ in
                    MainActor.assumeIsolated { self.portReads += 1; return self.port }
                },
                readHeadphones: { [unowned self] in self.headphones },
                offMain: { [unowned self] read in
                    MainActor.assumeIsolated {
                        if self.holdReads { self.heldReads.append(read) } else { read() }
                    }
                },
                onMain: { work in MainActor.assumeIsolated { work() } },
                after: { [unowned self] delay, work in self.timers.append((self.now.addingTimeInterval(delay), work)) },
                now: { [unowned self] in self.now }
            ))
            watch.onEvent = { [unowned self] in self.events.append($0) }
            watch.onChargeUpdate = { [unowned self] in self.updates.append($0) }
            return watch
        }()

        /// Moves the clock and runs every timer that came due, in order.
        func advance(_ seconds: TimeInterval) {
            let end = now.addingTimeInterval(seconds)
            while let next = timers.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
                timers.remove(at: next.offset)
                now = next.element.at
                next.element.work()
            }
            now = end
        }

        /// The battery changed as IOKit would say it.
        func set(_ power: Power?) {
            self.power = power
            watch.powerChanged()
        }

        func releaseHeldReads() {
            let reads = heldReads
            heldReads = []
            reads.forEach { $0() }
        }
    }

    private let battery = Power(onExternalPower: false, level: 57)
    private let charging = Power(onExternalPower: true, level: 57, isCharging: true)
    private let holding = Power(onExternalPower: true, level: 80, isCharging: false)

    private func rig(_ configure: (Rig) -> Void = { _ in }) -> Rig {
        let rig = Rig()
        configure(rig)
        rig.watch.seed()
        return rig
    }

    // MARK: - The charger

    func testAPlugInIsShownAtTheEdgeWithItsPortAndRating() {
        let rig = rig()
        rig.set(charging)
        XCTAssertEqual(rig.events, [.charging(level: 57, isCharging: true, port: .usbC, watts: 61, hold: nil)])
    }

    /// Launching on the charger is not a plug-in.
    func testAMacLaunchedOnTheChargerShowsNothing() {
        let rig = rig { $0.power = Power(onExternalPower: true, level: 57, isCharging: true) }
        rig.set(Power(onExternalPower: true, level: 58, isCharging: true))
        XCTAssertEqual(rig.events, [])
    }

    /// A loose dock's dropout (G-033) is not news; the owner's own pulls,
    /// 2.3 s and 3.7 s, are.
    func testAReturnWithinTheBlipIsNotNewsButAPullOfTwoSecondsIs() {
        let rig = rig { $0.power = Power(onExternalPower: true, level: 57, isCharging: true) }
        rig.set(battery)
        rig.advance(0.5)
        rig.set(charging)
        XCTAssertEqual(rig.events, [], "back within \(AmbientWatch.blip) s")

        rig.set(battery)
        rig.advance(2.3)
        rig.set(charging)
        XCTAssertEqual(rig.events.count, 1)
    }

    /// A failed read keeps the last good one: stored as nil, it made the next
    /// real plug-in look like the first reading, which shows nothing.
    func testAFailedReadDoesNotSwallowTheNextPlugIn() {
        let rig = rig()
        rig.set(nil)
        rig.set(charging)
        XCTAssertEqual(rig.events.count, 1)
    }

    /// A reading that lands after its cable was pulled shows nothing.
    func testACablePulledBeforeItsReadingLandsShowsNothing() {
        let rig = rig { $0.holdReads = true }
        rig.set(charging)
        rig.set(battery)
        rig.releaseHeldReads()
        XCTAssertEqual(rig.events, [])
    }

    /// Pulled and plugged back two seconds later while the first reading was
    /// still in flight: one moment, the second plug-in's.
    func testOnlyTheNewestPlugInsReadingIsShown() {
        let rig = rig { $0.holdReads = true }
        rig.set(charging)
        rig.set(battery)
        rig.advance(2)
        rig.port = (.magSafe, nil, nil)
        rig.set(charging)
        rig.releaseHeldReads()
        XCTAssertEqual(rig.events, [.charging(level: 57, isCharging: true, port: .magSafe, watts: nil, hold: nil)])
    }

    /// The battery's reason lags the plug: the first reading said "Not
    /// Charging" at an 80 percent hold, and nothing asked again (2026-10-26).
    /// The re-reads correct the moment in place, and end with the cable.
    func testTheReReadsCatchALateHoldAndStopAtThePull() {
        let rig = rig()
        rig.port = (.usbC, 61, .settling)
        rig.set(holding)
        XCTAssertEqual(rig.events, [.charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .settling)])

        rig.port = (.usbC, 61, .onHold)
        rig.advance(0.3)
        XCTAssertEqual(rig.updates.last, .charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold))
        XCTAssertEqual(rig.events.count, 1, "corrected in place, never shown twice")

        let before = rig.updates.count
        rig.advance(0.2)
        rig.set(battery)
        rig.advance(5)
        XCTAssertEqual(rig.updates.count, before, "no re-read after the pull: \(rig.updates)")
    }

    /// Inside the hold a change to the battery updates the moment; past it the
    /// minute-by-minute capacity notifications cost no registry read.
    func testCapacityChangesUpdateTheMomentOnlyWhileItCanBeUp() {
        let rig = rig()
        rig.set(charging)
        rig.advance(0.1)
        let updates = rig.updates.count
        rig.set(Power(onExternalPower: true, level: 58, isCharging: true))
        XCTAssertEqual(rig.updates.count, updates + 1)

        rig.advance(AmbientActivity.chargingHold + 2)
        let reads = rig.portReads
        rig.set(Power(onExternalPower: true, level: 59, isCharging: true))
        XCTAssertEqual(rig.portReads, reads, "a capacity notice past the hold read the registry")
    }

    // MARK: - Headphones

    private let pods = Headphones(uid: "pods", name: "Elshod's AirPods Pro", symbol: "airpodspro")
    private let beats = Headphones(uid: "beats", name: "Beats Studio Pro", symbol: "beats.headphones")

    func testNewHeadphonesAreAnnouncedOnceByTheirModel() {
        let rig = rig()
        rig.headphones = [pods]
        rig.watch.devicesChanged()
        rig.watch.devicesChanged()
        XCTAssertEqual(rig.events, [.headphones(name: "AirPods Pro", symbol: "airpodspro")])
    }

    func testHeadphonesConnectedAtLaunchAreNotNews() {
        let rig = rig { $0.headphones = [self.pods] }
        rig.watch.devicesChanged()
        XCTAssertEqual(rig.events, [])
    }

    /// A list that came back empty is a failed read — a Mac always has
    /// somewhere to play — and taken at its word it announced everything
    /// already connected on the next good one.
    func testAnEmptyReadDoesNotForgetWhatIsConnected() {
        let rig = rig { $0.headphones = [self.pods] }
        rig.headphones = nil
        rig.watch.devicesChanged()
        rig.headphones = [pods]
        rig.watch.devicesChanged()
        XCTAssertEqual(rig.events, [])
    }

    /// A Mac waking with two pairs connected says the first; the second is
    /// known from then on, not announced at the next change.
    func testTwoAtOnceAreOneMomentAndTheSecondIsNotSaidLater() {
        let rig = rig()
        rig.headphones = [pods, beats]
        rig.watch.devicesChanged()
        rig.watch.devicesChanged()
        XCTAssertEqual(rig.events.count, 1)
    }

    /// AirPods hopping to a phone and back within half a minute are not
    /// news; back after it, they are.
    func testAHopAwayAndBackIsQuietForHalfAMinute() {
        let rig = rig()
        rig.headphones = [pods]
        rig.watch.devicesChanged()
        rig.headphones = []
        rig.advance(5)
        rig.watch.devicesChanged()
        rig.headphones = [pods]
        rig.advance(5)
        rig.watch.devicesChanged()
        XCTAssertEqual(rig.events.count, 1, "back within \(AmbientWatch.repeatQuiet) s")

        rig.headphones = []
        rig.watch.devicesChanged()
        rig.advance(AmbientWatch.repeatQuiet)
        rig.headphones = [pods]
        rig.watch.devicesChanged()
        XCTAssertEqual(rig.events.count, 2)
    }
}
