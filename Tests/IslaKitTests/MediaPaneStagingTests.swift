import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The player's open in two passes (MR-H18, 2026-10-26): the flight's two
/// ends — the cover and the equalizer — in the outline's frame, everything
/// else a run-loop pass later, and the player's questions to the machine
/// asked off the main thread.
///
/// Nothing reaches the machine: the controller is cut from every real player
/// and every audio watch here reads a value it was given.
@MainActor
final class MediaPaneStagingTests: XCTestCase {
    // MARK: - The pane

    func testTheRestIsHeldBackOnlyUntilLetInOnce() {
        XCTAssertTrue(MediaPane.showsRest(holdsBack: false, released: false), "a pane mounted outside an open shows everything")
        XCTAssertFalse(MediaPane.showsRest(holdsBack: true, released: false), "the open's first pass: the cover and the equalizer only")
        XCTAssertTrue(MediaPane.showsRest(holdsBack: false, released: true))
        XCTAssertTrue(MediaPane.showsRest(holdsBack: true, released: true),
                      "a close unstages the panel's body as it removes it: the fading pane keeps its controls")
    }

    func testAHeldBackPaneIsNotEqualToALetInOne() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let audio = MediaPane.quietAudio()
        let held = MediaPane(media: isolated.stores.media, lyrics: isolated.stores.lyrics, audio: audio, holdsBackRest: true)
        let open = MediaPane(media: isolated.stores.media, lyrics: isolated.stores.lyrics, audio: audio, holdsBackRest: false)
        XCTAssertFalse(held == open, "`.equatable()` would skip the pass that lets the rest in")
    }

    /// Held back, the pane is the cover and nothing a person can press
    /// besides it; let in, it is the whole player.
    func testHeldBackThePaneIsTheCoverAlone() async throws {
        for holds in [true, false] {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let media = isolated.stores.media
            await LabFixtures.play(.init(), on: media)
            let pane = MediaPane(
                media: media, lyrics: isolated.stores.lyrics, morph: nil,
                audio: AudioWatch(read: { ([], nil, nil) }, readMuted: { false }, installListeners: {}, removeListeners: {}),
                holdsBackRest: holds, icons: SettingsFixture.macWithApps([:])
            )
            .defaultAppStorage(isolated.suite)
            let root = await AXProbe.tree(of: pane, size: CGSize(width: PlayerLayout.referenceBodyWidth, height: 160))
            let buttons = root.all { $0.role == "AXButton" }
            let titles = root.all { $0.label.contains("Waiting Room") }
            if holds {
                XCTAssertEqual(buttons.map(\.label), [localized("Cover")], "the cover alone\n\(root.dump)")
                XCTAssertTrue(titles.isEmpty, "no title yet\n\(root.dump)")
            } else {
                XCTAssertGreaterThanOrEqual(buttons.count, 6, "cover, title, artist, three transport controls, output\n\(root.dump)")
                XCTAssertEqual(titles.count, 1, root.dump)
            }
        }
    }

    // MARK: - The audio watch's first reading

    /// A `ReadAway` the test steps by hand: the read runs when the test says,
    /// and its answer is delivered when the test says.
    private final class Steps {
        struct Step: @unchecked Sendable {
            let read: () -> AudioWatch.Reading
            let deliver: @MainActor @Sendable (AudioWatch.Reading) -> Void
        }
        var pending: [Step] = []
        var away: AudioWatch.ReadAway {
            { [unowned self] read, deliver in pending.append(Step(read: read, deliver: deliver)) }
        }
        @MainActor func runNext() {
            let next = pending.removeFirst()
            next.deliver(next.read())
        }
    }

    private static let outputs: [AudioOutputs.Output] = [
        .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        .init(id: 42, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
    ]

    private func watch(_ steps: Steps, reads: @escaping () -> Void = {}, installs: @escaping () -> Void = {}) -> AudioWatch {
        AudioWatch(
            read: { reads(); return (Self.outputs, 42, nil) }, readMuted: { false },
            installListeners: installs, removeListeners: {}, followsLevel: false, readAway: steps.away
        )
    }

    func testStartReadsAwayAndPublishesWhenTheAnswerLands() {
        let steps = Steps()
        var reads = 0
        var installs = 0
        let audio = watch(steps, reads: { reads += 1 }, installs: { installs += 1 })
        audio.start()
        XCTAssertEqual(reads, 0, "start() returns before anything is read")
        XCTAssertEqual(installs, 0, "the listeners go on with the answer, so they attach to what was read")
        XCTAssertTrue(audio.outputs.isEmpty)
        steps.runNext()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(audio.outputs, Self.outputs)
        XCTAssertEqual(audio.current, 42)
        XCTAssertEqual(installs, 1)
    }

    func testAnAnswerThatLandsAfterAStopIsDropped() {
        let steps = Steps()
        var installs = 0
        let audio = watch(steps, installs: { installs += 1 })
        audio.start()
        audio.stop()
        steps.runNext()
        XCTAssertTrue(audio.outputs.isEmpty, "the pane it would draw in has gone")
        XCTAssertEqual(installs, 0, "no listener outlives the stop")
    }

    func testOnlyTheLatestStartsAnswerCounts() {
        let steps = Steps()
        var installs = 0
        let audio = watch(steps, installs: { installs += 1 })
        audio.start()
        audio.stop()
        audio.start()
        steps.runNext()
        XCTAssertEqual(installs, 0, "the first start's answer belongs to a start that was stopped")
        steps.runNext()
        XCTAssertEqual(installs, 1, "one registration, for the start that stands")
        XCTAssertEqual(audio.current, 42)
    }

    func testDeliveryRule() {
        XCTAssertTrue(AudioWatch.deliveryCounts(running: true, generation: 3, current: 3))
        XCTAssertFalse(AudioWatch.deliveryCounts(running: false, generation: 3, current: 3))
        XCTAssertFalse(AudioWatch.deliveryCounts(running: true, generation: 2, current: 3))
    }

    /// The lock card's watch keeps its synchronous first reading: its first
    /// frame draws from it.
    func testWithoutAReadAwayStartReadsAtOnce() {
        let audio = AudioWatch(read: { (Self.outputs, 41, 0.5) }, readMuted: { false }, installListeners: {}, removeListeners: {})
        audio.start()
        XCTAssertEqual(audio.current, 41)
        XCTAssertEqual(audio.volume, 0.5)
    }

    /// Under test the player's watch never reaches the machine, off the main
    /// thread or on it.
    func testThePlayersWatchIsQuietUnderTest() {
        let audio = AudioWatch.player()
        audio.start()
        XCTAssertTrue(audio.outputs.isEmpty)
        XCTAssertNil(audio.current)
        audio.stop()
    }
}
