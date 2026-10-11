import Combine
import CoreAudio
import XCTest
@testable import IslaKit

/// The audio state the lock card shows, followed while the card is up.
///
/// The card used to read outputs and volume once on appear and once per pane
/// change, and that was all it knew. Anything the machine did behind its back —
/// AirPods connecting mid-lock, the volume keys — left the picker highlighting
/// a device that was no longer playing and a bar that had drifted, until a pane
/// switch happened to re-read. The system's own lock-screen widgets follow
/// these changes, so the card does too: a small watch the lock-card window
/// holds open for the length of the lock. The machine itself is injected as
/// closures, so every behaviour here is driven without a sound card; the one
/// thing the tests cannot rehearse is the CoreAudio glue the production
/// closures wrap, which stays thin and says so.
@MainActor
final class AudioWatchTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    private func output(_ id: AudioDeviceID, _ name: String) -> AudioOutputs.Output {
        AudioOutputs.Output(id: id, name: name, transport: 0, dataSource: nil)
    }

    /// `start()` reads once, synchronously. The card's first frame is drawn
    /// from what the machine reads as *now* — not from an empty card waiting
    /// for the first listener to fire.
    func testStartPublishesTheReadValuesStraightAway() {
        let device = AudioDeviceID(7)
        let speakers = output(7, "MacBook Pro Speakers")
        let watch = AudioWatch(
            read: { ([speakers], device, 0.4) },
            installListeners: {},
            removeListeners: {}
        )

        watch.start()

        XCTAssertEqual(watch.outputs, [speakers])
        XCTAssertEqual(watch.current, device)
        XCTAssertEqual(watch.volume, 0.4)
    }

    /// A firing listener lands here: the entry the CoreAudio blocks call —
    /// exposed internal so the tests drive it in their place — re-reads the
    /// machine and publishes what moved.
    func testAChangeReReadsAndPublishesNewValues() {
        var machine: (outputs: [AudioOutputs.Output], current: AudioDeviceID?, volume: Float?) = ([], nil, nil)
        let watch = AudioWatch(read: { machine }, installListeners: {}, removeListeners: {})
        watch.start()

        let device = AudioDeviceID(9)
        machine = ([output(9, "AirPods Pro")], device, 0.7)
        watch.systemAudioChanged()

        XCTAssertEqual(watch.outputs.map(\.name), ["AirPods Pro"])
        XCTAssertEqual(watch.current, device)
        XCTAssertEqual(watch.volume, 0.7)
    }

    /// Re-reads are cheap property gets and CoreAudio can deliver a burst of
    /// notifications for one physical change, so nothing debounces the listener
    /// — but a change storm must not republish identical state either, because
    /// `@Published` never compares and every fire is a body evaluation the card
    /// does not need. Assigned only when different, the rule `SystemAppearance
    /// .refresh` states for the same reason.
    func testReadingTheSameValuesDoesNotPublishAgain() {
        var fires = 0
        let device = AudioDeviceID(3)
        let fixed: (outputs: [AudioOutputs.Output], current: AudioDeviceID?, volume: Float?) =
            ([output(3, "MacBook Pro Speakers")], device, 0.5)
        let watch = AudioWatch(read: { fixed }, installListeners: {}, removeListeners: {})
        watch.objectWillChange.sink { _ in fires += 1 }.store(in: &cancellables)

        watch.start()
        let firesAfterStart = fires

        watch.systemAudioChanged()

        XCTAssertGreaterThanOrEqual(firesAfterStart, 1, "start published the first reading")
        XCTAssertEqual(fires, firesAfterStart, "a re-read of identical state must not publish again")
    }

    /// The watch's lifetime is exactly one lock: the window starts it when the
    /// card goes up and stops it at dismiss. So start installs once — never two
    /// listeners answering the same event — stop removes what was installed,
    /// and the next lock starts from nothing again.
    func testListenersFollowThePerLockLifetime() {
        var installs = 0
        var removes = 0
        let watch = AudioWatch(
            read: { ([], nil, nil) },
            installListeners: { installs += 1 },
            removeListeners: { removes += 1 }
        )

        watch.start()
        XCTAssertEqual(installs, 1, "start installs exactly once")
        XCTAssertEqual(removes, 0)

        watch.stop()
        XCTAssertEqual(removes, 1, "stop removes the listeners")

        watch.start()
        XCTAssertEqual(installs, 2, "a second lock installs again")
        XCTAssertEqual(removes, 1)
        watch.stop()
        XCTAssertEqual(removes, 2)
    }

    /// The volume listener is attached to *a device*, and the default moves:
    /// AirPods take over mid-lock and the device the listener sits on is no
    /// longer the one playing. When a re-read finds a different default, the
    /// glue must be re-invoked so the old device's listener is dropped and the
    /// new one's attached; a re-read that finds the same device — a volume key,
    /// a device list that merely grew — must not re-invoke it.
    func testADeviceChangeReinstallsTheListenersAndADuplicateDoesNot() {
        var device: AudioDeviceID? = 3
        var installs = 0
        let watch = AudioWatch(
            read: { ([], device, 0.5) },
            installListeners: { installs += 1 },
            removeListeners: {}
        )

        watch.start()
        XCTAssertEqual(installs, 1)

        watch.systemAudioChanged()
        XCTAssertEqual(installs, 1, "a volume change on the same device moves nothing")

        device = 5
        watch.systemAudioChanged()
        XCTAssertEqual(installs, 2, "the volume listener follows the device")

        watch.systemAudioChanged()
        XCTAssertEqual(installs, 2, "no move when the device did not change")
    }

    /// The move decision itself, pinned purely — it is the one part of the
    /// follows-the-device rule that a test without a sound card can hold
    /// outright. Nil is the one answer that means "stay put"; anything else is
    /// the device the listener must be moved onto.
    func testTheVolumeListenerTargetDecision() {
        XCTAssertNil(
            AudioWatch.volumeListenerTarget(previous: 3, now: 3),
            "same device: the attachment already stands"
        )
        XCTAssertEqual(AudioWatch.volumeListenerTarget(previous: 3, now: 5), 5)
        XCTAssertEqual(
            AudioWatch.volumeListenerTarget(previous: nil, now: 5), 5,
            "a first attachment is a move"
        )
        XCTAssertNil(AudioWatch.volumeListenerTarget(previous: nil, now: nil))

        // The one ambiguity the answer's shape cannot escape: a re-read that
        // finds no default at all reads as "stay put". A stale listener on a
        // vanished device never fires again, the next real change reinstalls
        // onto the new device, and stop() removes what is left — the cheaper
        // mistake, for a question a nil-able answer cannot ask twice.
        XCTAssertNil(AudioWatch.volumeListenerTarget(previous: 3, now: nil))
    }

    // MARK: - A volume change re-reads the volume, and nothing else (F-045)

    /// Every write the lock card's volume bar made fired the volume listener,
    /// and the listener ran the full re-read: every device's streams, name,
    /// transport and data source, the default, and the level — once per
    /// pointer event, 60 to 120 times a second, for a question whose answer
    /// is a single float. The volume listener now asks only for the volume.
    func testAVolumeChangeReadsOnlyTheVolume() {
        var fullReads = 0
        var volumeReads = 0
        var level: Float = 0.3
        let device = AudioDeviceID(4)
        let watch = AudioWatch(
            read: {
                fullReads += 1
                return ([self.output(4, "MacBook Pro Speakers")], device, level)
            },
            readVolume: {
                volumeReads += 1
                return level
            },
            installListeners: {},
            removeListeners: {}
        )
        watch.start()
        let fullAfterStart = fullReads

        level = 0.55
        watch.volumeChanged()

        XCTAssertEqual(fullReads, fullAfterStart, "a volume change must not enumerate the devices")
        XCTAssertEqual(volumeReads, 1, "a volume change reads the volume once")
        XCTAssertEqual(watch.volume, 0.55, "and publishes what it read")
        XCTAssertEqual(watch.current, device, "the rest of the reading stands")
    }

    /// The same compare-before-assign rule as the full read: CoreAudio fires
    /// the wildcard-element listener once per channel for one stereo write,
    /// and the second must not republish the level the first already did.
    func testAnUnchangedVolumeDoesNotPublishAgain() {
        var fires = 0
        let watch = AudioWatch(
            read: { ([], 2, 0.5) },
            readVolume: { 0.5 },
            installListeners: {},
            removeListeners: {}
        )
        watch.start()
        watch.objectWillChange.sink { _ in fires += 1 }.store(in: &cancellables)

        watch.volumeChanged()
        watch.volumeChanged()

        XCTAssertEqual(fires, 0)
    }

    /// A watch built with only `read` injected must never reach the machine's
    /// own volume: the card's render tests build it that way and drive it.
    func testAnInjectedReadAlsoAnswersForTheVolume() {
        var level: Float = 0.2
        let watch = AudioWatch(read: { ([], 2, level) }, installListeners: {}, removeListeners: {})
        watch.start()

        level = 0.9
        watch.volumeChanged()

        XCTAssertEqual(watch.volume, 0.9)
    }

    // MARK: - Mute (G-023)

    /// A muted Mac drew a live-looking bar: mute was never read. The watch
    /// reads it with the level — at start, on a full read, and on the volume
    /// listener, which the mute key fires too — and publishes it beside it.
    func testMuteIsReadWithTheLevel() {
        var muted = true
        var fullReads = 0
        let watch = AudioWatch(
            read: { fullReads += 1; return ([], 4, 0.5) },
            readVolume: { 0.5 },
            readMuted: { muted },
            installListeners: {},
            removeListeners: {}
        )
        watch.start()
        XCTAssertTrue(watch.muted, "the first frame knows the Mac is muted")
        let fullAfterStart = fullReads

        muted = false
        watch.volumeChanged()
        XCTAssertFalse(watch.muted, "the mute key fires the volume listener, and the watch hears it")
        XCTAssertEqual(fullReads, fullAfterStart, "still without enumerating the devices (F-045)")

        muted = true
        watch.systemAudioChanged()
        XCTAssertTrue(watch.muted)
    }

    /// The card's render tests inject only `read`: the mute, like the level,
    /// must then never come from the machine.
    func testAnInjectedReadNeverReadsTheMachinesMute() {
        let watch = AudioWatch(read: { ([], 2, 0.4) }, installListeners: {}, removeListeners: {})
        watch.start()
        watch.volumeChanged()
        XCTAssertFalse(watch.muted)
    }

    // MARK: - Devices that come and go while the card is up (K-009)

    /// Plugging in a USB DAC that macOS does not select changes the device
    /// list and not the default, and the watch listened only to the default:
    /// the picker never heard about the new device. The device-list listener
    /// lands here, and one physical plug sends a burst of notifications, so
    /// the burst is folded into one full read.
    func testADeviceListBurstIsReadOnce() {
        var fullReads = 0
        var scheduled: [() -> Void] = []
        var machine: (outputs: [AudioOutputs.Output], current: AudioDeviceID?, volume: Float?) =
            ([output(1, "MacBook Pro Speakers")], 1, 0.5)
        let watch = AudioWatch(
            read: {
                fullReads += 1
                return machine
            },
            installListeners: {},
            removeListeners: {},
            debounce: { scheduled.append($0) }
        )
        watch.start()
        let fullAfterStart = fullReads

        machine.outputs.append(output(8, "USB Audio DAC"))
        watch.devicesChanged()
        watch.devicesChanged()
        watch.devicesChanged()

        XCTAssertEqual(scheduled.count, 1, "one burst schedules one read")
        XCTAssertEqual(fullReads, fullAfterStart, "nothing is read until the burst settles")

        scheduled.forEach { $0() }

        XCTAssertEqual(fullReads, fullAfterStart + 1)
        XCTAssertEqual(watch.outputs.map(\.name), ["MacBook Pro Speakers", "USB Audio DAC"])

        // The next burst schedules again: the debounce is per burst, not once.
        watch.devicesChanged()
        XCTAssertEqual(scheduled.count, 2)
    }

    /// A read scheduled before the lock ended lands after `stop()`: it must
    /// not publish into a card that has gone, nor reach the machine.
    func testADeviceReadAfterStopIsDropped() {
        var fullReads = 0
        var scheduled: [() -> Void] = []
        let watch = AudioWatch(
            read: { fullReads += 1; return ([], nil, nil) },
            installListeners: {},
            removeListeners: {},
            debounce: { scheduled.append($0) }
        )
        watch.start()
        let fullAfterStart = fullReads
        watch.devicesChanged()
        watch.stop()

        scheduled.forEach { $0() }

        XCTAssertEqual(fullReads, fullAfterStart)
    }

    /// The picker lists only devices the system would let it pick. A Teams or
    /// Loopback sub-device that says it cannot be the default output, or a
    /// device CoreAudio marks hidden, sat in the list as a row that did
    /// nothing when tapped. A device that publishes neither property is
    /// listed, because most real outputs answer neither question.
    func testOnlyDevicesThatCanBeDefaultAreListed() {
        XCTAssertTrue(AudioOutputs.isListable(canBeDefault: true, isHidden: false))
        XCTAssertTrue(AudioOutputs.isListable(canBeDefault: nil, isHidden: nil))
        XCTAssertFalse(AudioOutputs.isListable(canBeDefault: false, isHidden: false))
        XCTAssertFalse(AudioOutputs.isListable(canBeDefault: true, isHidden: true))
        XCTAssertFalse(AudioOutputs.isListable(canBeDefault: nil, isHidden: true))
    }

    // MARK: - Drag writes are coalesced (F-045)

    /// A drag delivers 60 to 120 events a second and each one wrote CoreAudio.
    /// The gate lets one write through per 33 ms and holds the rest, so a
    /// second of dragging at 60 Hz writes at most about 30 times — and the
    /// last position is never the one dropped.
    func testDragWritesAreCoalesced() {
        var gate = VolumeWriteGate()
        var writes: [Float] = []
        let values = (0..<60).map { Float($0) / 59 }
        for (i, value) in values.enumerated() {
            if let write = gate.offer(value, at: Double(i) * 0.016) { writes.append(write) }
        }

        XCTAssertLessThanOrEqual(writes.count, 31, "about 30 Hz, not 60")
        XCTAssertGreaterThan(writes.count, 0)
        XCTAssertEqual(writes.first, values.first, "the first touch lands at once")

        let held = gate.finish()
        if let held { writes.append(held) }
        XCTAssertEqual(writes.last, values.last, "release writes where the finger let go")
        XCTAssertEqual(writes.filter { $0 == values.last }.count, 1, "and writes it exactly once")
        XCTAssertNil(gate.finish(), "a second release has nothing left to write")
    }

    /// A finger that stops moving but stays down must not leave the speakers
    /// at a level up to 33 ms behind the bar until release: the held value is
    /// due once the interval has passed, and is written exactly once.
    func testAHeldValueIsDueOnceTheIntervalPasses() {
        var gate = VolumeWriteGate()
        XCTAssertEqual(gate.offer(0.2, at: 0), 0.2)
        XCTAssertNil(gate.offer(0.3, at: 0.010), "inside the interval: held")
        XCTAssertNil(gate.due(at: 0.020), "not due yet")
        XCTAssertEqual(gate.due(at: 0.045), 0.3, "due once the interval has passed")
        XCTAssertNil(gate.due(at: 0.090), "and written only once")
        XCTAssertNil(gate.finish(), "release has nothing left to write")
        XCTAssertEqual(gate.offer(0.4, at: 0.091), 0.4, "a new drag starts with a write")
    }
}
