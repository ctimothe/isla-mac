import CoreAudio
import XCTest
@testable import IslaKit

/// The decisions behind the lock card's volume bar, held without a sound card.
///
/// Every function here is pure. The CoreAudio reads and writes that act on
/// them are the one layer a test cannot rehearse without moving the owner's
/// real output volume, so nothing here touches a device: the levels, the
/// write order and the drag's device are all values handed in.
final class SystemVolumeTests: XCTestCase {

    // MARK: - Balance (G-023)

    /// A device with no main control was driven by writing the same scalar to
    /// both channels, so one touch of the bar put a hearing-balance setting
    /// back to centre. Scaling both channels by one factor keeps the offset,
    /// and the level the bar shows — the two channels' average, as
    /// `current()` reads it — lands where the finger asked.
    func testSettingALevelKeepsTheBalance() {
        let kept = SystemVolume.channelLevels(setting: 0.3, from: (left: 0.8, right: 0.4))
        XCTAssertEqual(kept.left, 0.4, accuracy: 0.0001)
        XCTAssertEqual(kept.right, 0.2, accuracy: 0.0001)

        // Silent channels carry no balance to keep: both take the level.
        let fromSilence = SystemVolume.channelLevels(setting: 0.3, from: (left: 0, right: 0))
        XCTAssertEqual(fromSilence.left, 0.3, accuracy: 0.0001)
        XCTAssertEqual(fromSilence.right, 0.3, accuracy: 0.0001)

        // Near the top the louder side reaches 1 first. It stops there and the
        // quieter side keeps its ratio, so the louder ear stays louder — the
        // balance outranks the last few percent of level.
        let topped = SystemVolume.channelLevels(setting: 0.95, from: (left: 0.8, right: 0.4))
        XCTAssertEqual(topped.left, 1, accuracy: 0.0001)
        XCTAssertEqual(topped.right, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(topped.left, topped.right, "the left/right order holds when clamped at 1")
        let mirrored = SystemVolume.channelLevels(setting: 1, from: (left: 0.1, right: 0.6))
        XCTAssertLessThan(mirrored.left, mirrored.right)
        XCTAssertLessThanOrEqual(mirrored.right, 1)

        // Out-of-range asks are clamped, never handed to CoreAudio, which
        // rejects them with an error nobody can act on.
        let below = SystemVolume.channelLevels(setting: -0.5, from: (left: 0.8, right: 0.4))
        XCTAssertEqual(below.left, 0, accuracy: 0.0001)
        XCTAssertEqual(below.right, 0, accuracy: 0.0001)
    }

    // MARK: - Mute (G-023)

    /// A muted Mac drew a live-looking bar, and a drag on it moved a level
    /// nobody could hear. Raising the level unmutes, as the volume keys do;
    /// a drag to the very bottom leaves the mute alone, and a device that is
    /// not muted is never written to for it.
    func testRaisingTheLevelUnmutes() {
        XCTAssertTrue(SystemVolume.unmutes(muted: true, newLevel: 0.2))
        XCTAssertFalse(SystemVolume.unmutes(muted: true, newLevel: 0))
        XCTAssertFalse(SystemVolume.unmutes(muted: false, newLevel: 0.5))
    }

    // MARK: - Which control a write goes through (G-023, K-008)

    /// The virtual main volume is the system's own balance-keeping control,
    /// so it goes first; a real main element next; the two channels scaled
    /// together last. A device that cannot be set by any of them gets no bar
    /// at all: it used to show one that followed the finger and snapped back
    /// on release, because the read never asked whether the write could land.
    func testTheWriteGoesThroughTheFirstSettableControl() {
        XCTAssertEqual(SystemVolume.control(virtualMain: true, main: true, channels: true), .virtualMain)
        XCTAssertEqual(SystemVolume.control(virtualMain: false, main: true, channels: true), .main)
        XCTAssertEqual(SystemVolume.control(virtualMain: false, main: false, channels: true), .channels)
        XCTAssertNil(
            SystemVolume.control(virtualMain: false, main: false, channels: false),
            "a fixed-volume DAC or HDMI output shows no bar"
        )
    }

    // MARK: - The drag keeps the device it started on (K-008)

    /// `set()` re-read the default output on every call, so AirPods taking
    /// over mid-drag were sent the finger's level for the speakers: 20% to
    /// 80% in one event. The drag latches the device it began on, and a
    /// default that moves under it ends the drag rather than following.
    func testADragWritesToTheDeviceItStartedOn() {
        var latch = VolumeDragLatch()
        XCTAssertEqual(latch.target(current: 4), 4, "the first event latches the default")
        XCTAssertEqual(latch.target(current: 4), 4)
        XCTAssertFalse(latch.defaultMoved(to: 4), "a re-read that finds the same default is no move")

        XCTAssertTrue(latch.defaultMoved(to: 9), "AirPods took over: the drag stops")
        XCTAssertNil(latch.target(current: 9), "and the rest of the gesture writes nothing")
        XCTAssertNil(latch.device)

        latch.end()
        XCTAssertEqual(latch.target(current: 9), 9, "the next drag starts on the new default")
    }

    /// No default output, no write; and a default moving while no finger is
    /// down is not a drag to stop.
    func testALatchWithNothingToLatchWritesNothing() {
        var latch = VolumeDragLatch()
        XCTAssertFalse(latch.defaultMoved(to: 3), "no drag is running")
        XCTAssertNil(latch.target(current: nil))
        XCTAssertEqual(latch.target(current: 3), 3, "a default that arrives later is latched then")
    }
}
