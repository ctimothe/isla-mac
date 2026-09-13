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
}
