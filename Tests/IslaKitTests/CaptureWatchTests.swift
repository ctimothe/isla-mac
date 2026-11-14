import XCTest
@testable import IslaKit

/// The Recording activity's watcher played out over time, with a scripted
/// microphone and camera and a clock the test moves (islandcn plan §S4,
/// 2026-11-14). No test installs a real CoreAudio or CoreMediaIO listener or
/// reads a real device: the live readers are exercised on the owner's Mac,
/// where what they see is the owner's.
///
/// The rules this holds each have a cause. A call app that flips its input off
/// and on for 200 ms when the user changes device must not make the island
/// flash; a CoreAudio read that errors must not end a recording that is still
/// going; Isla's own process, which does hold the microphone during a
/// dictation, must never be the thing the island warns about.
@MainActor
final class CaptureWatchTests: XCTestCase {
    /// The Mac as the test scripts it.
    @MainActor final class Rig {
        var microphone: [String]? = []
        var camera: Bool? = false
        var now: TimeInterval = 0
        var observed = 0
        var removed = 0
        /// The callback the system would call.
        var changed: (@Sendable () -> Void)?
        var reports: [CaptureState] = []
        private var timers: [(at: TimeInterval, work: @MainActor @Sendable () -> Void)] = []
        /// Reads wait here while `holdReads` is set, so a test can stop the
        /// watch with one in flight.
        var holdReads = false
        var heldReads: [@Sendable () -> Void] = []
        /// Answers wait here while `holdLanding` is set: the read has run, and
        /// the answer has not reached the main thread yet.
        var holdLanding = false
        var heldLandings: [@MainActor @Sendable () -> Void] = []

        lazy var watch: CaptureWatch = {
            let watch = CaptureWatch(environment: CaptureWatch.Environment(
                readMicrophoneApps: { [unowned self] in MainActor.assumeIsolated { self.microphone } },
                readCameraInUse: { [unowned self] in MainActor.assumeIsolated { self.camera } },
                observe: { [unowned self] changed in
                    self.observed += 1
                    self.changed = changed
                    return { [unowned self] in self.removed += 1; self.changed = nil }
                },
                offMain: { [unowned self] read in
                    MainActor.assumeIsolated {
                        if self.holdReads { self.heldReads.append(read) } else { read() }
                    }
                },
                onMain: { [unowned self] work in
                    MainActor.assumeIsolated {
                        if self.holdLanding { self.heldLandings.append(work) } else { work() }
                    }
                },
                after: { [unowned self] delay, work in self.timers.append((self.now + delay, work)) },
                ownBundleIDs: ["com.ctimothe.isla", "com.test.host"]
            ))
            watch.onChange = { [unowned self] in self.reports.append($0) }
            return watch
        }()

        /// Moves the clock and runs every timer that came due, in order.
        func advance(_ seconds: TimeInterval) {
            let end = now + seconds
            while let next = timers.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
                timers.remove(at: next.offset)
                now = next.element.at
                next.element.work()
            }
            now = end
        }

        /// The system says something changed, after the script was updated.
        func set(microphone: [String]?? = nil, camera: Bool?? = nil) {
            if let microphone { self.microphone = microphone }
            if let camera { self.camera = camera }
            changed?()
        }

        func releaseHeldReads() {
            let reads = heldReads
            heldReads = []
            reads.forEach { $0() }
        }
    }

    private func started(_ configure: (Rig) -> Void = { _ in }) -> Rig {
        let rig = Rig()
        configure(rig)
        rig.watch.start()
        return rig
    }

    // MARK: - Start

    func testStartReadsOnceAndReportsWhatIsAlreadyRecording() {
        let rig = started { $0.microphone = ["us.zoom.xos"]; $0.camera = true }
        XCTAssertEqual(rig.reports, [CaptureState(microphoneApps: ["us.zoom.xos"], cameraInUse: true)])
        XCTAssertEqual(rig.watch.state, rig.reports.last)
        XCTAssertEqual(rig.observed, 1)
    }

    func testStartWithNothingRecordingReportsNothing() {
        let rig = started()
        XCTAssertTrue(rig.reports.isEmpty)
        XCTAssertEqual(rig.watch.state, CaptureState.none)
    }

    func testStartTwiceInstallsOneSetOfListeners() {
        let rig = started { $0.microphone = ["us.zoom.xos"] }
        rig.watch.start()
        XCTAssertEqual(rig.observed, 1)
        XCTAssertEqual(rig.reports.count, 1)
    }

    // MARK: - What counts

    func testIslasOwnBundleIDsAndBlankOnesAreNeverCounted() {
        let rig = started { $0.microphone = ["com.ctimothe.isla", "com.test.host", ""] }
        XCTAssertTrue(rig.reports.isEmpty)
        rig.set(microphone: ["com.ctimothe.isla", "us.zoom.xos"])
        XCTAssertEqual(rig.reports.last?.microphoneApps, ["us.zoom.xos"])
    }

    /// The three processes CoreAudio named on the owner's Mac on 2026-11-14,
    /// while Granola and cmux used the microphone: Siri's listener (no app, and
    /// first in the list), Granola's helper, and WebKit's GPU process recording
    /// for cmux. The island drew an orange dot where an app icon belongs, because
    /// it took the first id, Siri's, and found no app for it. Each process now
    /// counts as the app responsible for it, as macOS's own indicator does, and
    /// one that belongs to no app counts as nothing.
    func testEachProcessCountsAsTheAppResponsibleForIt() {
        let siri: Int32 = 1123, granolaHelper: Int32 = 1554, granola: Int32 = 1505
        let webKitGPU: Int32 = 29739, cmux: Int32 = 5368
        let responsible: [Int32: Int32] = [siri: siri, granolaHelper: granola, webKitGPU: cmux]
        let apps: [Int32: String] = [granola: "com.granola.app", cmux: "com.cmuxterm.app"]
        XCTAssertEqual(
            CaptureWatch.appsRecording(
                [siri, granolaHelper, webKitGPU],
                responsible: { responsible[$0] }, app: { apps[$0] }
            ),
            ["com.granola.app", "com.cmuxterm.app"]
        )
        // No answer about who is responsible: the process itself, if it is an app.
        XCTAssertEqual(
            CaptureWatch.appsRecording([granola, siri], responsible: { _ in nil }, app: { apps[$0] }),
            ["com.granola.app"]
        )
    }

    func testTheListIsSortedAndHasNoDuplicates() {
        let state = CaptureState(microphone: ["com.b", "com.a", "com.b", "com.c"], camera: false, excluding: ["com.c"])
        XCTAssertEqual(state.microphoneApps, ["com.a", "com.b"])
        XCTAssertFalse(state.isEmpty)
        XCTAssertTrue(CaptureState.none.isEmpty)
        XCTAssertFalse(CaptureState(microphoneApps: [], cameraInUse: true).isEmpty)
    }

    func testTheSameAppsInAnotherOrderAreNotAChange() {
        let rig = started { $0.microphone = ["com.b", "com.a"] }
        rig.set(microphone: ["com.a", "com.b", "com.a"])
        XCTAssertEqual(rig.reports.count, 1)
        XCTAssertEqual(rig.reports.first?.microphoneApps, ["com.a", "com.b"])
    }

    func testTheSameStateIsNeverReportedTwice() {
        let rig = started { $0.camera = true }
        rig.set(camera: true)
        rig.set(camera: true)
        XCTAssertEqual(rig.reports.count, 1)
    }

    // MARK: - Starting is immediate

    func testRecordingStartingIsReportedAtOnce() {
        let rig = started()
        rig.set(microphone: ["us.zoom.xos"])
        XCTAssertEqual(rig.reports, [CaptureState(microphoneApps: ["us.zoom.xos"], cameraInUse: false)])
        rig.set(camera: true)
        XCTAssertEqual(rig.reports.last, CaptureState(microphoneApps: ["us.zoom.xos"], cameraInUse: true))
    }

    func testAnAppLeavingWhileAnotherStaysIsReportedAtOnce() {
        let rig = started { $0.microphone = ["com.a", "com.b"] }
        rig.set(microphone: ["com.b"])
        XCTAssertEqual(rig.reports.last?.microphoneApps, ["com.b"])
    }

    // MARK: - Stopping waits

    func testStoppingThenResumingInsideTheDebounceReportsNothing() {
        let rig = started { $0.microphone = ["us.zoom.xos"] }
        rig.set(microphone: [])
        rig.advance(0.3)
        rig.set(microphone: ["us.zoom.xos"])
        rig.advance(2)
        XCTAssertEqual(rig.reports.count, 1, "the flip is not news")
        XCTAssertEqual(rig.watch.state.microphoneApps, ["us.zoom.xos"])
    }

    func testStoppingAndStayingStoppedReportsNoneAfterTheDebounce() {
        let rig = started { $0.microphone = ["us.zoom.xos"] }
        rig.set(microphone: [])
        rig.advance(0.5)
        XCTAssertEqual(rig.reports.count, 1)
        XCTAssertFalse(rig.watch.state.isEmpty, "still shown inside the debounce")
        rig.advance(0.2)
        XCTAssertEqual(rig.reports.last, CaptureState.none)
        XCTAssertEqual(rig.reports.count, 2)
    }

    func testAnotherEmptyReadingDoesNotPushTheDeadlineBack() {
        let rig = started { $0.camera = true }
        rig.set(camera: false)
        rig.advance(0.4)
        rig.set(camera: false)
        rig.advance(0.25)
        XCTAssertEqual(rig.reports.last, CaptureState.none)
    }

    func testResumingWithADifferentAppReportsItAtOnceAndCancelsTheStop() {
        let rig = started { $0.microphone = ["com.a"] }
        rig.set(microphone: [])
        rig.set(microphone: ["com.b"])
        XCTAssertEqual(rig.reports.last?.microphoneApps, ["com.b"])
        rig.advance(2)
        XCTAssertEqual(rig.reports.count, 2)
        XCTAssertEqual(rig.watch.state.microphoneApps, ["com.b"])
    }

    // MARK: - A failed read

    func testAFailedMicrophoneReadKeepsTheLastList() {
        let rig = started { $0.microphone = ["us.zoom.xos"] }
        rig.set(microphone: .some(nil))
        rig.advance(2)
        XCTAssertEqual(rig.reports.count, 1)
        XCTAssertEqual(rig.watch.state.microphoneApps, ["us.zoom.xos"])
        // And the camera is still read while the microphone's read fails.
        rig.set(camera: true)
        XCTAssertEqual(rig.reports.last, CaptureState(microphoneApps: ["us.zoom.xos"], cameraInUse: true))
    }

    func testAFailedCameraReadKeepsTheLastAnswer() {
        let rig = started { $0.camera = true }
        rig.set(camera: .some(nil))
        rig.advance(2)
        XCTAssertTrue(rig.watch.state.cameraInUse)
        XCTAssertEqual(rig.reports.count, 1)
    }

    // MARK: - Stop

    func testStopRemovesTheListenersAndReportsNone() {
        let rig = started { $0.microphone = ["us.zoom.xos"] }
        rig.watch.stop()
        XCTAssertEqual(rig.removed, 1)
        XCTAssertEqual(rig.reports.last, CaptureState.none)
        XCTAssertEqual(rig.watch.state, CaptureState.none)
        XCTAssertNil(rig.changed)
    }

    func testStopWithNothingShownReportsNothing() {
        let rig = started()
        rig.watch.stop()
        XCTAssertEqual(rig.removed, 1)
        XCTAssertTrue(rig.reports.isEmpty)
    }

    func testStopTwiceRemovesOnceAndReportsOnce() {
        let rig = started { $0.camera = true }
        rig.watch.stop()
        rig.watch.stop()
        XCTAssertEqual(rig.removed, 1)
        XCTAssertEqual(rig.reports.count, 2)
    }

    func testStopBeforeStartIsNothing() {
        let rig = Rig()
        rig.watch.stop()
        XCTAssertEqual(rig.removed, 0)
        XCTAssertTrue(rig.reports.isEmpty)
    }

    func testAReadThatLandsAfterStopIsDropped() {
        let rig = Rig()
        rig.microphone = ["us.zoom.xos"]
        rig.holdReads = true
        rig.watch.start()
        rig.watch.stop()
        rig.releaseHeldReads()
        XCTAssertTrue(rig.reports.isEmpty)
        XCTAssertEqual(rig.watch.state, CaptureState.none)
    }

    func testAPendingStopDoesNotFireAfterStop() {
        let rig = started { $0.microphone = ["com.a"] }
        rig.set(microphone: [])
        rig.watch.stop()
        let count = rig.reports.count
        rig.advance(2)
        XCTAssertEqual(rig.reports.count, count, "stop reported none once; the timer adds nothing")
    }

    func testStartAfterStopWatchesAgainFromAClearState() {
        let rig = started { $0.microphone = ["com.a"] }
        rig.watch.stop()
        rig.watch.start()
        XCTAssertEqual(rig.observed, 2)
        XCTAssertEqual(rig.reports.map(\.microphoneApps), [["com.a"], [], ["com.a"]])
    }

    func testTheNewerReadWinsWhenTwoAnswersLandOutOfOrder() {
        let rig = started()
        rig.holdLanding = true
        // Each change hops to the main thread (held first), then reads (runs in
        // place), and its answer is held again on the way back.
        rig.set(microphone: ["com.old"])
        let hops = rig.heldLandings
        rig.heldLandings = []
        hops.forEach { $0() }
        let olderAnswer = rig.heldLandings
        rig.heldLandings = []
        rig.set(microphone: ["com.new"])
        let secondHops = rig.heldLandings
        rig.heldLandings = []
        secondHops.forEach { $0() }
        XCTAssertEqual(olderAnswer.count + rig.heldLandings.count, 2, "two answers are in flight")
        // The newer answer lands first, then the older one, as two reads on a
        // global queue can.
        (rig.heldLandings + olderAnswer).forEach { $0() }
        XCTAssertEqual(rig.watch.state.microphoneApps, ["com.new"])
        XCTAssertEqual(rig.reports.map(\.microphoneApps), [["com.new"]])
    }
}
