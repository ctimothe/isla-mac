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
        /// What a hold says it did: false when no microphone had a mute.
        var holdMutes = true
        /// Every hold and release, in the order the queue ran them, and
        /// whether the caller waited for it.
        var calls: [String] = []
        /// The capture watch's callback, so a test can say the apps changed.
        var changed: (@Sendable () -> Void)?
    }

    private func makeHub(_ defaults: UserDefaults, _ fakes: Fakes, center: NotificationCenter) -> LiveActivityHub {
        LiveActivityHub(environment: LiveActivityHub.Environment(
            defaults: defaults,
            makeCapture: {
                CaptureWatch(environment: CaptureWatch.Environment(
                    readMicrophoneApps: { MainActor.assumeIsolated { fakes.microphone } },
                    readCameraInUse: { false },
                    observe: { changed in
                        fakes.captureObserving += 1
                        fakes.changed = changed
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
            holdMicrophoneMute: { MainActor.assumeIsolated { fakes.calls.append("hold"); return fakes.holdMutes } },
            releaseMicrophoneMute: { MainActor.assumeIsolated { fakes.calls.append("release") } },
            onMicrophoneQueue: { wait, work in
                MainActor.assumeIsolated { if wait { fakes.calls.append("wait") } }
                work()
            },
            onMain: { work in MainActor.assumeIsolated { work() } }
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

    private func recordingHub(_ fakes: Fakes, _ test: (UserDefaults, LiveActivityHub) -> Void) throws {
        let name = "com.ctimothe.isla.livehub.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsRowID.recording.write(true, in: defaults)
        fakes.microphone = ["us.zoom.xos"]
        let hub = makeHub(defaults, fakes, center: NotificationCenter())
        defer { hub.stop() }
        hub.start()
        test(defaults, hub)
    }

    private let zoom = CaptureState(microphone: ["us.zoom.xos"], camera: false)
    private let mutedZoom = CaptureState(microphone: ["us.zoom.xos"], camera: false, muted: true)

    /// The island's Mute holds the microphones and the island says so at
    /// once; Unmute gives them back.
    func testMuteAndUnmuteReachTheDeviceAndTheIsland() throws {
        let fakes = Fakes()
        try recordingHub(fakes) { _, hub in
            XCTAssertEqual(fakes.calls, ["release"], "launch gives back a mute an earlier run left")
            hub.setMicrophoneMuted(true)
            XCTAssertEqual(fakes.calls, ["release", "hold"])
            XCTAssertEqual(hub.live, [.recording(mutedZoom)])
            hub.setMicrophoneMuted(true)
            XCTAssertEqual(fakes.calls, ["release", "hold"], "a second press holds nothing twice")
            hub.setMicrophoneMuted(false)
            XCTAssertEqual(fakes.calls, ["release", "hold", "release"])
            XCTAssertEqual(hub.live, [.recording(zoom)])
        }
    }

    /// The owner's Granola dictation, 2026-11-15: Mute was pressed, the
    /// dictation ended, the activity and its Unmute went with it, and the
    /// Mac stayed muted through a restart. The mute is the recording's: it
    /// is given back as soon as nothing holds the microphone, and the next
    /// recording starts unmuted.
    func testTheMuteEndsWithTheRecording() throws {
        let fakes = Fakes()
        try recordingHub(fakes) { _, hub in
            hub.setMicrophoneMuted(true)
            fakes.microphone = []
            fakes.changed?()
            XCTAssertEqual(fakes.calls, ["release", "hold", "release"])
            XCTAssertEqual(hub.live, [])
            fakes.microphone = ["us.zoom.xos"]
            fakes.changed?()
            XCTAssertEqual(hub.live, [.recording(zoom)], "the next recording is not muted")
        }
    }

    /// Quitting while muted gives the microphones back before the process
    /// goes, and waits for it.
    func testQuittingWhileMutedGivesTheMicrophoneBack() throws {
        let fakes = Fakes()
        try recordingHub(fakes) { _, hub in
            hub.setMicrophoneMuted(true)
            hub.stop()
            XCTAssertEqual(fakes.calls, ["release", "hold", "wait", "release"])
        }
    }

    /// Turning the Recording switch off ends the mute with the activity.
    func testTurningRecordingOffGivesTheMicrophoneBack() throws {
        let fakes = Fakes()
        try recordingHub(fakes) { defaults, hub in
            hub.setMicrophoneMuted(true)
            SettingsRowID.recording.write(false, in: defaults)
            hub.followSwitches()
            XCTAssertEqual(fakes.calls, ["release", "hold", "release"])
        }
    }

    /// A Mute that found nothing to mute must not tell the person the apps
    /// hear silence; with nothing recording there is nothing to mute.
    func testAMuteThatHeldNothingIsNotShown() throws {
        let fakes = Fakes()
        fakes.holdMutes = false
        try recordingHub(fakes) { _, hub in
            hub.setMicrophoneMuted(true)
            XCTAssertEqual(hub.live, [.recording(zoom)])
            fakes.microphone = []
            fakes.changed?()
            fakes.calls = []
            hub.setMicrophoneMuted(true)
            XCTAssertEqual(fakes.calls, [], "nothing recording, nothing to mute")
        }
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
