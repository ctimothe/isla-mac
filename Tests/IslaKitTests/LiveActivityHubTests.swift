import XCTest
@testable import IslaKit

/// The hub's one promise beyond publishing: the microphone-and-camera watch
/// and the Downloads watch run only while their switch is on (both off by
/// default, plan `2026-11-14-islandcn-activities`), and a switch turned off
/// stops its listener at once.
@MainActor
final class LiveActivityHubTests: XCTestCase {
    @MainActor private final class Fakes: @unchecked Sendable {
        var captureObserving = 0
        var captureRemoved = 0
        var microphone: [String] = []
        var muted = false
        var muteCalls: [Bool] = []
    }

    private func makeHub(_ defaults: UserDefaults, _ fakes: Fakes, center: NotificationCenter) -> LiveActivityHub {
        LiveActivityHub(environment: LiveActivityHub.Environment(
            defaults: defaults,
            makeCapture: {
                CaptureWatch(environment: CaptureWatch.Environment(
                    readMicrophoneApps: { MainActor.assumeIsolated { fakes.microphone } },
                    readCameraInUse: { false },
                    readMicrophoneMuted: { MainActor.assumeIsolated { fakes.muted } },
                    observe: { _ in
                        fakes.captureObserving += 1
                        return { fakes.captureRemoved += 1 }
                    },
                    offMain: { read in read() },
                    onMain: { work in MainActor.assumeIsolated { work() } },
                    after: { _, work in work() },
                    ownBundleIDs: []
                ))
            },
            makeDownloads: {
                DownloadWatch(environment: DownloadWatch.Environment(
                    folder: URL(fileURLWithPath: "/nonexistent-isla-test"),
                    list: { _ in [] }, attributes: { _ in nil }, readSafariInfo: { _ in nil },
                    quarantineAgent: { _ in nil }, observe: { _, _ in {} },
                    offMain: { read in read() },
                    onMain: { work in MainActor.assumeIsolated { work() } },
                    after: { _, _ in }, now: { Date() }
                ))
            },
            timers: IslandTimerCenter(),
            notificationCenter: center,
            setMicrophoneMuted: { muted, done in
                fakes.muteCalls.append(muted)
                fakes.muted = muted
                done()
            }
        ))
    }

    func testTheWatchesRunOnlyWhileTheirSwitchIsOn() throws {
        let name = "com.ctimothe.isla.livehub.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fakes = Fakes()
        fakes.microphone = ["us.zoom.xos"]
        let hub = makeHub(defaults, fakes, center: NotificationCenter())
        defer { hub.stop() }

        hub.start()
        XCTAssertEqual(fakes.captureObserving, 0, "off by default: nothing listens")
        XCTAssertEqual(hub.live, [])

        SettingsRowID.recording.write(true, in: defaults)
        hub.followSwitches()
        XCTAssertEqual(fakes.captureObserving, 1)
        XCTAssertEqual(hub.live.map(\.kind), ["recording"])

        hub.followSwitches()
        XCTAssertEqual(fakes.captureObserving, 1, "an unrelated defaults change starts nothing twice")

        SettingsRowID.recording.write(false, in: defaults)
        hub.followSwitches()
        XCTAssertEqual(fakes.captureRemoved, 1, "turned off, the listener goes at once")
        XCTAssertEqual(hub.live, [], "and the activity with it")
    }

    /// The island's Mute reaches the device and comes back as a muted
    /// recording at once; Unmute undoes it.
    func testMuteAndUnmuteReachTheDeviceAndTheIsland() throws {
        let name = "com.ctimothe.isla.livehub.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsRowID.recording.write(true, in: defaults)
        let fakes = Fakes()
        fakes.microphone = ["us.zoom.xos"]
        let hub = makeHub(defaults, fakes, center: NotificationCenter())
        defer { hub.stop() }
        hub.start()

        hub.setMicrophoneMuted(true)
        XCTAssertEqual(fakes.muteCalls, [true])
        XCTAssertEqual(hub.live, [.recording(CaptureState(microphone: ["us.zoom.xos"], camera: false, muted: true))])
        hub.setMicrophoneMuted(false)
        XCTAssertEqual(fakes.muteCalls, [true, false])
        XCTAssertEqual(hub.live, [.recording(CaptureState(microphone: ["us.zoom.xos"], camera: false))])
    }

    /// A running timer survives Isla replacing itself for an update.
    func testATimerIsKeptAcrossARestart() throws {
        let name = "com.ctimothe.isla.livehub.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = makeHub(defaults, Fakes(), center: NotificationCenter())
        first.start()
        first.timers.startCountdown(seconds: 600)
        XCTAssertNotNil(defaults.data(forKey: LiveActivityHub.timersKey))
        XCTAssertEqual(first.live.map(\.kind), ["timer"])
        first.stop()
        // Stopped, the first hub no longer writes; its own clock goes quietly.
        first.timers.cancelCountdown()

        let second = makeHub(defaults, Fakes(), center: NotificationCenter())
        second.start()
        defer { second.stop() }
        XCTAssertEqual(second.live.map(\.kind), ["timer"])
        second.timers.cancelCountdown()
        XCTAssertNil(defaults.data(forKey: LiveActivityHub.timersKey), "nothing kept once nothing runs")
    }

    func testAHelpersBundleIdNamesItsApp() {
        let installed: Set<String> = ["com.google.Chrome"]
        XCTAssertEqual(
            LiveActivityHub.owningApp(of: "com.google.Chrome.helper.Renderer") { installed.contains($0) },
            "com.google.Chrome"
        )
        XCTAssertEqual(LiveActivityHub.owningApp(of: "us.zoom.xos") { _ in false }, "us.zoom.xos")
    }
}
