import CoreAudio
import XCTest
@testable import IslaKit

/// The volume bar the lock card and the player share — and the promise that
/// goes with it (spec §4.5, owner decision 8): **nothing writes the system
/// volume, the mute or the default output until a person drags the bar, steps it
/// or picks a device.**
///
/// Nothing here reaches the machine. The model is handed a fake `System` that
/// records every write instead of making one, and an `AudioWatch` whose reading
/// is a value; the clock is a variable and "after" is a list of closures the test
/// runs itself.
@MainActor
final class PlayerVolumeTests: XCTestCase {
    /// A machine that records.
    @MainActor
    final class FakeMachine {
        var levels: [(Float, AudioDeviceID)] = []
        var mutes: [(Bool, AudioDeviceID)] = []
        var level: Float? = 0.5
        var uptime: TimeInterval = 100
        var scheduled: [@MainActor @Sendable () -> Void] = []

        var system: VolumeSliderModel.System {
            VolumeSliderModel.System(
                setLevel: { [unowned self] value, device in
                    self.levels.append((value, device))
                    self.level = value
                    return true
                },
                setMuted: { [unowned self] muted, device in
                    self.mutes.append((muted, device))
                    return true
                },
                currentLevel: { [unowned self] in self.level },
                level: { [unowned self] _ in self.level },
                uptime: { [unowned self] in self.uptime },
                after: { [unowned self] _, work in self.scheduled.append(work) }
            )
        }
    }

    private var reading: (outputs: [AudioOutputs.Output], current: AudioDeviceID?, volume: Float?) =
        ([], 41, 0.5)
    private var muted = false

    private func watch() -> AudioWatch {
        AudioWatch(
            read: { [unowned self] in self.reading },
            readMuted: { [unowned self] in self.muted },
            installListeners: {}, removeListeners: {}
        )
    }

    private func make() -> (VolumeSliderModel, FakeMachine, AudioWatch) {
        let machine = FakeMachine()
        let audio = watch()
        audio.start()
        return (VolumeSliderModel(audio: audio, system: machine.system), machine, audio)
    }

    private func assertNothingWritten(_ machine: FakeMachine, _ message: String, line: UInt = #line) {
        XCTAssertTrue(machine.levels.isEmpty, "\(message): the level was written \(machine.levels)", line: line)
        XCTAssertTrue(machine.mutes.isEmpty, "\(message): the mute was written \(machine.mutes)", line: line)
    }

    // MARK: - Reading is not writing

    /// Drawing the bar reads the level and the mute and writes neither.
    func testBuildingTheBarWritesNothing() {
        muted = true
        let (model, machine, _) = make()
        XCTAssertEqual(model.volume, 0.5)
        XCTAssertTrue(model.muted, "a muted Mac is shown muted")
        XCTAssertEqual(model.level, 0.5, accuracy: 0.0001)
        assertNothingWritten(machine, "building")
    }

    /// The machine moving on its own — the volume keys, AirPods connecting, a
    /// device list changing, a re-read, the watch stopping and starting again — is
    /// mirrored and never written back.
    func testTheMachineMovingIsMirroredAndNeverWrittenBack() {
        let (model, machine, audio) = make()

        reading.volume = 0.8
        audio.volumeChanged()
        XCTAssertEqual(model.volume, 0.8)

        reading = ([], 43, 0.2)
        audio.systemAudioChanged()
        XCTAssertEqual(model.volume, 0.2)

        muted = true
        audio.volumeChanged()
        XCTAssertTrue(model.muted)

        audio.stop()
        audio.start()
        audio.devicesChanged()
        assertNothingWritten(machine, "the machine moved")
    }

    /// A song changing with no finger down writes nothing, and a device with no
    /// volume to give has no bar and no write.
    func testATrackChangeWritesNothingWithoutADrag() {
        let (model, machine, _) = make()
        model.endForTrackChange()
        assertNothingWritten(machine, "a track change")

        reading = ([], 41, nil)
        let (bare, bareMachine, _) = make()
        XCTAssertNil(bare.volume, "no volume to give, so no bar is drawn for anyone to drag")
        assertNothingWritten(bareMachine, "a device with no volume")
    }

    // MARK: - A drag writes, paced, to the device it began on

    func testTheFirstEventOfADragWritesAndTheBarFollowsTheFinger() {
        let (model, machine, _) = make()
        model.dragChanged(fraction: 0.7)
        XCTAssertEqual(model.dragging, 0.7)
        XCTAssertEqual(model.level, 0.7, accuracy: 0.0001, "the bar draws from the finger")
        XCTAssertEqual(machine.levels.count, 1)
        XCTAssertEqual(machine.levels[0].0, 0.7)
        XCTAssertEqual(machine.levels[0].1, 41, "the default output the drag began on")
    }

    /// Fractions are clamped to the bar.
    func testTheFractionIsClamped() {
        let (model, machine, _) = make()
        model.dragChanged(fraction: 1.7)
        XCTAssertEqual(machine.levels.last?.0, 1)
        machine.uptime += 1
        model.dragChanged(fraction: -0.4)
        XCTAssertEqual(machine.levels.last?.0, 0)
        model.dragEnded()
    }

    /// 60 to 120 events a second are paced to about 30 writes (F-045): a level
    /// the gate holds is not lost — it is handed over once the interval has
    /// passed, and at release.
    func testWritesArePacedAndTheHeldLevelAlwaysLands() {
        let (model, machine, _) = make()
        model.dragChanged(fraction: 0.2)
        machine.uptime += 0.005
        model.dragChanged(fraction: 0.3)
        machine.uptime += 0.005
        model.dragChanged(fraction: 0.4)
        XCTAssertEqual(machine.levels.map(\.0), [0.2], "the two events inside the interval are held")
        XCTAssertEqual(machine.scheduled.count, 2, "each asks to be looked at again")

        machine.uptime += VolumeWriteGate.interval
        machine.scheduled.forEach { $0() }
        XCTAssertEqual(machine.levels.map(\.0), [0.2, 0.4], "the held level lands once, the newest of them")

        // Held again, then the finger lifts: the level where it let go lands.
        machine.uptime += 0.005
        model.dragChanged(fraction: 0.9)
        XCTAssertEqual(machine.levels.count, 2)
        model.dragEnded()
        XCTAssertEqual(machine.levels.last?.0, 0.9, "release flushes the held level")
        XCTAssertNil(model.dragging, "the bar goes back to the machine")
    }

    /// AirPods taking over mid-drag must not be sent the finger's level for the
    /// speakers (K-008): the held level lands on the device it was meant for, and
    /// the rest of the gesture writes nothing.
    func testTheDefaultMovingUnderADragEndsIt() {
        let (model, machine, audio) = make()
        model.dragChanged(fraction: 0.2)
        machine.uptime += 0.005
        model.dragChanged(fraction: 0.6)   // held
        XCTAssertEqual(machine.levels.count, 1)

        reading = ([], 99, 0.1)            // AirPods become the default
        audio.systemAudioChanged()
        XCTAssertEqual(machine.levels.count, 2, "the held level lands…")
        XCTAssertEqual(machine.levels.last?.0, 0.6)
        XCTAssertEqual(machine.levels.last?.1, 41, "…on the speakers it was meant for")
        XCTAssertNil(model.dragging)

        machine.uptime += 1
        model.dragChanged(fraction: 0.95)
        model.dragEnded()
        XCTAssertFalse(machine.levels.contains { $0.1 == 99 }, "the AirPods were never written")
        XCTAssertEqual(machine.levels.count, 2, "and the rest of the gesture wrote nothing")
    }

    /// A drag a new song cut short lets go (K-017): the held level lands and the
    /// bar goes back to mirroring.
    func testATrackChangeEndsADragInFlight() {
        let (model, machine, _) = make()
        model.dragChanged(fraction: 0.3)
        machine.uptime += 0.005
        model.dragChanged(fraction: 0.8)
        XCTAssertEqual(machine.levels.count, 1)
        model.endForTrackChange()
        XCTAssertEqual(machine.levels.last?.0, 0.8)
        XCTAssertNil(model.dragging)
    }

    /// While a finger owns the bar the machine's own reports stand down.
    func testTheMirrorStandsDownWhileDragging() {
        let (model, machine, audio) = make()
        model.dragChanged(fraction: 0.7)
        reading.volume = 0.1
        audio.volumeChanged()
        XCTAssertEqual(model.level, 0.7, accuracy: 0.0001)
        XCTAssertEqual(model.volume, 0.5)
        _ = machine
    }

    // MARK: - Mute

    /// Raising the level on a muted output unmutes it, as the volume keys do —
    /// the level goes first, so the sound returns at the new level (G-023). A drag
    /// to the very bottom leaves the mute alone.
    func testRaisingTheLevelUnmutesAndZeroDoesNot() {
        muted = true
        let (model, machine, _) = make()
        model.dragChanged(fraction: 0)
        XCTAssertTrue(machine.mutes.isEmpty, "to the bottom is not an unmute")
        machine.uptime += 1
        model.dragChanged(fraction: 0.4)
        XCTAssertEqual(machine.levels.last?.0, 0.4)
        XCTAssertEqual(machine.mutes.count, 1)
        XCTAssertEqual(machine.mutes[0].0, false)
        XCTAssertFalse(model.muted, "straight into the model, so the next write does not unmute again")
        machine.uptime += 1
        model.dragChanged(fraction: 0.5)
        XCTAssertEqual(machine.mutes.count, 1)
    }

    /// An unmuted output is never written to for its mute.
    func testAnUnmutedDeviceIsNeverMuteWritten() {
        let (model, machine, _) = make()
        model.dragChanged(fraction: 0.6)
        model.dragEnded()
        XCTAssertTrue(machine.mutes.isEmpty)
    }

    // MARK: - VoiceOver's step

    func testAStepWritesOnceToTheCurrentDefault() {
        let (model, machine, _) = make()
        model.step(to: 0.55)
        XCTAssertEqual(machine.levels.count, 1)
        XCTAssertEqual(machine.levels[0].0, 0.55)
        XCTAssertEqual(machine.levels[0].1, 41)
        XCTAssertEqual(model.volume, 0.55, "re-read from the device afterwards")
    }

    func testAStepWithNoDefaultOutputWritesNothing() {
        reading = ([], nil, 0.5)
        let (model, machine, _) = make()
        model.step(to: 0.9)
        assertNothingWritten(machine, "a step with nowhere to write")
    }

    // MARK: - The player: reading until asked

    /// A pane the player builds at the panel's open reads, and does not write.
    /// The audio watch starts when the pane appears and stops when it goes; the
    /// slider drawn on it moves nothing by being drawn.
    func testThePlayersWatchReadsAndInstallsNothingByDefault() {
        let quiet = MediaPane.quietAudio()
        quiet.start()
        XCTAssertTrue(quiet.outputs.isEmpty)
        XCTAssertNil(quiet.current)
        XCTAssertNil(quiet.volume, "a pane built anywhere but the panel has no volume, so no bar")
        quiet.stop()
    }
}
