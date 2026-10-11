import XCTest
@testable import IslaKit

/// Exactly one Isla runs per login, and the copy that gives way is always the
/// newer one.
///
/// Three Islas were registered with LaunchServices on 2026-09-21, and a second
/// copy, once running, drew a second island, spawned a second media helper and
/// fought the first for the three hot keys and the Spotify callback (F-023).
/// The decision is pure so it can be played out here without a second process;
/// `AppDelegate` supplies the running instances from `NSRunningApplication`.
final class LaunchGuardTests: XCTestCase {

    private let bundle = "com.ctimothe.isla"

    private func instance(pid: pid_t, at seconds: TimeInterval?, bundle: String? = "com.ctimothe.isla")
        -> LaunchGuard.Instance {
        LaunchGuard.Instance(
            pid: pid,
            bundleIdentifier: bundle,
            launchDate: seconds.map { Date(timeIntervalSinceReferenceDate: $0) }
        )
    }

    func testANewerCopyYieldsToTheOneAlreadyRunning() {
        let own = instance(pid: 200, at: 10)
        XCTAssertTrue(
            LaunchGuard.yieldingTo(own: own, running: [instance(pid: 100, at: 5)], environment: [:]),
            "an Isla launched at t=5 is already the island; the copy launched at t=10 hands over"
        )
    }

    func testTheOlderCopyStays() {
        let own = instance(pid: 100, at: 10)
        XCTAssertFalse(
            LaunchGuard.yieldingTo(own: own, running: [instance(pid: 200, at: 15)], environment: [:]),
            "the copy launched later is the one that leaves"
        )
    }

    func testAnotherAppIsNotACopy() {
        let own = instance(pid: 200, at: 10)
        let other = instance(pid: 100, at: 5, bundle: "com.example.other")
        XCTAssertFalse(LaunchGuard.yieldingTo(own: own, running: [other], environment: [:]))
    }

    func testItselfIsNotACopy() {
        // `runningApplications(withBundleIdentifier:)` lists this process too.
        let own = instance(pid: 200, at: 10)
        XCTAssertFalse(LaunchGuard.yieldingTo(own: own, running: [own], environment: [:]))
    }

    /// Two copies started in the same instant must not both leave, nor both
    /// stay: the lower pid stays, and each copy reaches the same answer about
    /// the other.
    func testAnEqualLaunchDateKeepsTheLowerPID() {
        let low = instance(pid: 100, at: 10)
        let high = instance(pid: 200, at: 10)
        XCTAssertFalse(LaunchGuard.yieldingTo(own: low, running: [low, high], environment: [:]))
        XCTAssertTrue(LaunchGuard.yieldingTo(own: high, running: [low, high], environment: [:]))
    }

    /// A binary started straight from a shell — the gate scripts do that — has
    /// no LaunchServices launch date. The pid decides then, the same way from
    /// either side.
    func testAMissingLaunchDateFallsBackToThePID() {
        let dated = instance(pid: 300, at: 10)
        let undated = instance(pid: 100, at: nil)
        XCTAssertFalse(LaunchGuard.yieldingTo(own: undated, running: [dated], environment: [:]))
        XCTAssertTrue(LaunchGuard.yieldingTo(own: dated, running: [undated], environment: [:]))
    }

    /// An unbundled build (`swift run`) has no bundle id and nothing to compare.
    func testNoBundleIdentifierNeverYields() {
        let own = instance(pid: 200, at: 10, bundle: nil)
        XCTAssertFalse(
            LaunchGuard.yieldingTo(own: own, running: [instance(pid: 100, at: 5, bundle: nil)], environment: [:])
        )
    }

    /// The lifecycle gate and the performance harness launch the build while
    /// the owner's installed copy runs; without the override the build would
    /// hand over and exit, and the gate would fail for the wrong reason.
    func testTheOverrideStays() {
        let own = instance(pid: 200, at: 10)
        let older = instance(pid: 100, at: 5)
        XCTAssertFalse(LaunchGuard.yieldingTo(
            own: own, running: [older], environment: [LaunchGuard.allowSecondInstanceKey: "1"]
        ))
        XCTAssertTrue(LaunchGuard.yieldingTo(
            own: own, running: [older], environment: [LaunchGuard.allowSecondInstanceKey: "0"]
        ), "only 1 turns it on, like every other environment hook in this app")
    }

    /// The name the running copy listens on and the handing-over copy posts
    /// is one constant, under the product's bundle id.
    func testTheShowNotificationIsUnderTheBundleIdentifier() {
        XCTAssertEqual(LaunchGuard.showNotification.rawValue, "com.ctimothe.isla.show")
    }
}
