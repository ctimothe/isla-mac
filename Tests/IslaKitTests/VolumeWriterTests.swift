import CoreAudio
import CoreGraphics
import XCTest
@testable import IslaKit

/// An output whose writes wait for the test to let them go: CoreAudio while
/// music plays, as slow as a test wants it. Every member is behind `lock`, and
/// `write` waits outside it, so the test thread can read while a write blocks.
final class BlockingVolumeOutput: VolumeOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var blocking = true
    private var level: Float
    private var muted: Bool
    private var device: AudioDeviceID
    private var writeLog: [(device: AudioDeviceID, level: Float, muted: Bool)] = []
    private var readCount = 0
    /// Signalled as each write begins, so a test can wait for one to be in flight.
    let writeBegan = DispatchSemaphore(value: 0)

    init(level: Float, muted: Bool = false, device: AudioDeviceID = 42) {
        self.level = level
        self.muted = muted
        self.device = device
    }

    var writes: [(device: AudioDeviceID, level: Float, muted: Bool)] { lock.withLock { writeLog } }
    var reads: Int { lock.withLock { readCount } }
    var state: VolumeState { lock.withLock { VolumeState(device: device, level: level, muted: muted) } }

    /// What the machine holds now, set behind Isla's back: the menu-bar slider,
    /// or AirPods becoming the default output.
    func set(level: Float? = nil, muted: Bool? = nil, device: AudioDeviceID? = nil) {
        lock.withLock {
            if let level { self.level = level }
            if let muted { self.muted = muted }
            if let device { self.device = device }
        }
    }

    /// Lets every write through from now on, the one waiting included.
    func unblock() {
        lock.withLock { blocking = false }
        release.signal()
    }

    func read() -> VolumeState? {
        lock.withLock {
            readCount += 1
            return VolumeState(device: device, level: level, muted: muted)
        }
    }

    func write(level: Float, muted: Bool, from old: VolumeState) -> VolumeWriteResult {
        writeBegan.signal()
        if lock.withLock({ blocking }) {
            _ = release.wait(timeout: .now() + 5)
            release.signal()
        }
        return lock.withLock {
            // Written to the device it names, which may no longer be the
            // default: what CoreAudio does with an explicit device id.
            writeLog.append((old.device, level, muted))
            if old.device == device {
                self.level = level
                self.muted = muted
            }
            return .written
        }
    }
}

/// The volume key's path since 2026-10-25 (owner: "only the volume pop-up lags
/// and delays … this needs an architectural fix, like Apple's own sound
/// control"): the pop-up draws the level the press *means* before CoreAudio is
/// asked anything, one writer takes the newest target, and the listeners adopt
/// only what changed outside Isla. Every collaborator is a fake.
@MainActor
final class VolumeWriterTests: XCTestCase {
    private let watch = FakeLevelWatch()
    private let clock = LockedBox<TimeInterval>(100)

    private func applier(_ volume: VolumeOutput) -> SystemLevelApplier {
        let clock = clock
        return SystemLevelApplier(
            volume: volume,
            displays: FakeDisplayResolver(client: nil),
            topology: { DisplayTopology(builtIn: nil, active: [], main: 0) },
            keyboards: FakeKeyboardResolver(client: nil),
            watch: watch,
            describe: { _ in DeviceLabel(symbol: "speaker", name: "Speakers") },
            now: { clock.value }
        )
    }

    private func press(_ sut: SystemLevelApplier, _ key: MediaKey = .volumeUp, into box: LockedBox<[HUDReading]>) {
        sut.submit(key, fine: false) { reading in box.value.append(reading) }
    }

    func testTenPressesAreDrawnBeforeTheFirstWriteReturnsAndCollapseIntoTwoWrites() {
        let volume = BlockingVolumeOutput(level: 0.25)
        let sut = applier(volume)
        sut.prepare()
        let shown = LockedBox<[HUDReading]>([])

        press(sut, into: shown)
        XCTAssertEqual(volume.writeBegan.wait(timeout: .now() + 2), .success, "the first write is in flight")
        for _ in 2...10 { press(sut, into: shown) }

        XCTAssertEqual(shown.value.count, 10, "every press is drawn while the first write still blocks")
        XCTAssertEqual(shown.value.last?.level, 0.25 + 10.0 / 16, "the tenth press's level, predicted")
        XCTAssertEqual(shown.value.last?.deviceName, "Speakers", "with its label, from the cache")

        volume.unblock()
        sut.settle()
        XCTAssertLessThanOrEqual(volume.writes.count, 2, "the first write, then the newest target")
        XCTAssertEqual(volume.state.level, 0.875, "the device ends where the bar did")
        XCTAssertEqual(shown.value.count, 10, "and nothing more is drawn after the presses")
    }

    func testAnEchoReadDuringOrJustAfterIslasOwnWriteLeavesTheIntendedLevel() {
        let volume = BlockingVolumeOutput(level: 0.5)
        let sut = applier(volume)
        sut.prepare()
        let shown = LockedBox<[HUDReading]>([])

        press(sut, into: shown)   // 0.5625, write in flight
        XCTAssertEqual(volume.writeBegan.wait(timeout: .now() + 2), .success)
        press(sut, into: shown)   // 0.625 pending
        // The listener fires mid-write; the device still holds the old level.
        watch.fire(.volume)
        sut.settleListeners()
        XCTAssertEqual(sut.intendedVolume?.level, 0.625, "a read behind Isla's own write is not adopted")

        volume.unblock()
        sut.settle()
        // A late echo of the first write, inside the quiet window.
        volume.set(level: 0.5625)
        clock.value += 0.1
        watch.fire(.volume)
        sut.settleListeners()
        XCTAssertEqual(sut.intendedVolume?.level, 0.625, "an echo of an earlier target is not adopted")

        press(sut, into: shown)
        XCTAssertEqual(shown.value.last?.level, 0.6875, "the next press steps from the intended level")
        sut.settle()
    }

    func testAnOutsideChangeAfterTheQuietWindowIsAdoptedAndTheNextPressStepsFromIt() {
        let volume = BlockingVolumeOutput(level: 0.5)
        volume.unblock()
        let sut = applier(volume)
        sut.prepare()
        let shown = LockedBox<[HUDReading]>([])
        press(sut, into: shown)
        sut.settle()

        clock.value += SystemLevelApplier.echoWindow + 0.05
        volume.set(level: 0.125, muted: true)   // the menu bar slider, then mute
        watch.fire(.volume)
        sut.settleListeners()
        XCTAssertEqual(sut.intendedVolume, VolumeState(device: 42, level: 0.125, muted: true))

        press(sut, into: shown)
        XCTAssertEqual(shown.value.last?.level, 0.1875)
        XCTAssertEqual(shown.value.last?.muted, false, "volume up unmutes")
        sut.settle()
        XCTAssertEqual(volume.state.level, 0.1875)
    }

    func testABurstOfListenerEventsIsOneRead() {
        let volume = BlockingVolumeOutput(level: 0.5)
        volume.unblock()
        let sut = applier(volume)
        sut.prepare()
        let reads = volume.reads
        sut.holdListeners {
            for _ in 0..<5 { watch.fire(.volume) }
        }
        sut.settleListeners()
        XCTAssertEqual(volume.reads, reads + 1, "five events, one read")
    }

    func testADeviceChangeMidHoldNeverWritesTheOldDevicesLevelToTheNewDevice() {
        let volume = BlockingVolumeOutput(level: 0.9, device: 1)
        let sut = applier(volume)
        sut.prepare()
        let shown = LockedBox<[HUDReading]>([])

        press(sut, .volumeDown, into: shown)
        XCTAssertEqual(volume.writeBegan.wait(timeout: .now() + 2), .success)
        press(sut, .volumeDown, into: shown)   // pending, for device 1

        // AirPods take over, at their own level.
        volume.set(level: 0.25, device: 2)
        watch.fire(.defaultOutput)
        sut.settleListeners()
        XCTAssertEqual(sut.intendedVolume?.device, 2)
        XCTAssertEqual(sut.intendedVolume?.level, 0.25)

        volume.unblock()
        sut.settle()
        XCTAssertTrue(volume.writes.filter { $0.device == 2 }.isEmpty, "nothing meant for the speakers reached the AirPods")
        XCTAssertEqual(volume.state.level, 0.25)

        press(sut, .volumeDown, into: shown)
        XCTAssertEqual(shown.value.last?.outputDevice, 2)
        XCTAssertEqual(shown.value.last?.level, 0.1875, "stepped from the AirPods' own level")
        sut.settle()
        XCTAssertEqual(volume.writes.last?.device, 2)
        XCTAssertEqual(volume.writes.last?.level, 0.1875)
    }

    func testMuteTogglesThroughTheSamePath() {
        let volume = BlockingVolumeOutput(level: 0.5)
        volume.unblock()
        let sut = applier(volume)
        sut.prepare()
        let shown = LockedBox<[HUDReading]>([])
        press(sut, .mute, into: shown)
        XCTAssertEqual(shown.value.last?.muted, true)
        XCTAssertEqual(shown.value.last?.level, 0.5)
        sut.settle()
        XCTAssertEqual(volume.state.muted, true)
        press(sut, .mute, into: shown)
        sut.settle()
        XCTAssertEqual(volume.state.muted, false)
    }

    func testAPressReadsNothingAndWritesOffTheCallingThread() {
        let volume = FakeVolumeOutput(level: 0.5)
        let sut = applier(volume)
        sut.prepare()
        let reads = volume.reads
        let shown = LockedBox<[HUDReading]>([])
        for _ in 0..<3 { press(sut, into: shown) }
        XCTAssertEqual(shown.value.map(\.level), [0.5625, 0.625, 0.6875], "drawn in order, at once")
        sut.settle()
        XCTAssertEqual(volume.reads, reads, "no read for any press")
        XCTAssertFalse(volume.writesOnMain.contains(true), "every write on the writer's queue")
        XCTAssertEqual(volume.state?.level, 0.6875)
    }
}

/// The player's Output button follows the route and nothing else
/// (2026-10-25): its watch used to hear every volume and mute change on the
/// main queue, read ~14 properties each time and redraw the player per press,
/// for a volume it has not shown since 2026-10-16.
@MainActor
final class PlayerAudioWatchTests: XCTestCase {
    func testThePlayersWatchNeverFollowsTheVolume() {
        let volumeReads = LockedBox(0)
        let muteReads = LockedBox(0)
        let watch = AudioWatch(
            read: { ([], 7, 0.5) },
            readVolume: { volumeReads.value += 1; return 0.5 },
            readMuted: { muteReads.value += 1; return false },
            installListeners: {}, removeListeners: {},
            followsLevel: false
        )
        watch.start()
        watch.systemAudioChanged()
        watch.volumeChanged()
        XCTAssertNil(watch.volumeListenerDevice, "no volume or mute listener is attached")
        XCTAssertNil(watch.volume, "and no level is published")
        XCTAssertEqual(volumeReads.value, 0)
        XCTAssertEqual(muteReads.value, 0)
        XCTAssertEqual(watch.current, 7, "the route still is")
        XCTAssertFalse(AudioWatch.player(quiet: true).followsLevel)
    }

    func testTheLockCardsWatchStillFollowsTheVolume() {
        let watch = AudioWatch(read: { ([], 7, 0.5) }, installListeners: {}, removeListeners: {})
        watch.start()
        XCTAssertTrue(watch.followsLevel)
        XCTAssertEqual(watch.volumeListenerDevice, 7)
        XCTAssertEqual(watch.volume, 0.5)
    }
}

/// The lyric stage's Mac volume (`MacVolume`) checks the default output on its
/// own queue before it writes, because the control installs no listener and
/// the shared writer no longer re-checks. Real queue, fake output: no
/// CoreAudio is touched.
@MainActor
final class MacVolumeDefaultOutputTests: XCTestCase {
    private func write(_ mac: MacVolume, _ target: VolumeState, from: VolumeState) async -> VolumeWriteResult {
        await withCheckedContinuation { continuation in
            mac.write(target, from: from) { continuation.resume(returning: $0) }
        }
    }

    func testAWriteForADeviceThatIsNoLongerTheDefaultIsNotMade() async {
        let output = BlockingVolumeOutput(level: 0.5, device: 41)
        output.unblock()
        let mac = MacVolume(output: output, currentDevice: { output.state.device })
        let from = VolumeState(device: 41, level: 0.5, muted: false)

        output.set(device: 43)
        let result = await write(mac, VolumeState(device: 41, level: 0.9, muted: false), from: from)

        XCTAssertEqual(result, .deviceChanged)
        XCTAssertTrue(output.writes.isEmpty, "the old device, still present, was not touched")
    }

    func testAWriteForTheDefaultGoesThrough() async {
        let output = BlockingVolumeOutput(level: 0.5, device: 41)
        output.unblock()
        let mac = MacVolume(output: output, currentDevice: { output.state.device })

        let result = await write(
            mac, VolumeState(device: 41, level: 0.9, muted: false), from: VolumeState(device: 41, level: 0.5, muted: false)
        )

        XCTAssertEqual(result, .written)
        XCTAssertEqual(output.writes.map(\.level), [0.9])
    }
}
