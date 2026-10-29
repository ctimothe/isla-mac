import Combine
import Observation
import SwiftUI
import XCTest
@testable import IslaKit

/// A position tick redraws what moves, not the whole player (Batch 18,
/// 2026-10-29).
///
/// While the panel is open on the player, the stage or the lock card,
/// `MediaController` publishes its position ten times a second. It was
/// `@Published` on the controller itself, so every tick announced a change of
/// the whole controller and every view watching it ran its body again: the
/// player's cover, title, transport and their tooltips, ten times a second, to
/// move a bar and two labels. The running Isla, open on the player and left
/// alone, spent 6.9 % of a core on it (B17-H1, `measure-idle.sh`); the
/// idle-cost lab, which until then never started the clock, had read 0.2 % at
/// most. The position now lives on `PlaybackClock`, which is `@Observable`, so
/// a tick reaches exactly the views whose bodies read it.
@MainActor
final class PlayerTickTests: XCTestCase {
    /// Set from Observation's change callback, which is `@Sendable`.
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    private static let lines: [LyricsStore.Line] = [
        .init(at: 1, text: "First line"), .init(at: 2.5, text: "Second line"),
        .init(at: 30, text: "Third line"),
    ]

    @MainActor private struct Rig {
        let isolated: ProbeStores
        var media: MediaController { isolated.stores.media }
        var lyrics: LyricsStore { isolated.stores.lyrics }
    }

    private func playing(elapsed: TimeInterval = 30, lyrics: Bool = false) async -> Rig {
        let rig = Rig(isolated: ProbeFixtures.isolatedStores())
        await LabFixtures.play(.init(elapsed: elapsed, cover: nil), on: rig.media)
        if lyrics {
            rig.lyrics.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        }
        rig.media.setActive(true)
        return rig
    }

    private func pane(_ rig: Rig) -> MediaPane {
        MediaPane(
            media: rig.media, lyrics: rig.lyrics, morph: nil,
            icons: SettingsFixture.macWithApps([:])
        )
    }

    func testATickDoesNotAnnounceOnTheController() async {
        let rig = await playing()
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        var announced = 0
        let watch = rig.media.objectWillChange.sink { _ in announced += 1 }
        defer { watch.cancel() }
        let now = rig.media.monotonicNow()
        for step in 1...5 {
            rig.media.monotonicNow = { now + 0.1 * Double(step) }
            rig.media.tick()
        }
        XCTAssertEqual(announced, 0, "every position tick re-runs every view that watches the controller")
    }

    func testATickReachesWhatReadsThePosition() async {
        let rig = await playing()
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let bar = Flag()
        withObservationTracking { _ = rig.media.shownPosition(nil) } onChange: { bar.raised = true }
        let label = Flag()
        withObservationTracking { _ = rig.media.shownLabelPosition(nil) } onChange: { label.raised = true }
        let now = rig.media.monotonicNow()
        rig.media.monotonicNow = { now + 1.2 }
        rig.media.tick()
        XCTAssertTrue(bar.raised, "a tick does not reach the scrubber and the lyrics")
        XCTAssertTrue(label.raised, "a tick does not reach the elapsed label")
    }

    /// Only the player's own body: its children's bodies are not run by
    /// building it, so this is what a tick would re-run if it read the clock.
    func testThePlayersOwnBodyDoesNotReadThePosition() async {
        let rig = await playing(elapsed: 1.5, lyrics: true)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let pane = pane(rig)
        let read = Flag()
        withObservationTracking { _ = pane.body } onChange: { read.raised = true }
        let now = rig.media.monotonicNow()
        rig.media.monotonicNow = { now + 1.2 }
        rig.media.tick()
        XCTAssertFalse(read.raised, "a position tick re-runs the whole player, not just what moves")
    }

    /// And what moves still moves: open, playing and left alone, the sung
    /// line turns when the voice reaches the next one, with nothing but the
    /// position tick to turn it.
    func testTheOpenPlayerStillTurnsItsLine() async throws {
        let rig = await playing(elapsed: 1.5, lyrics: true)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let host = AXProbe.present(
            pane(rig).defaultAppStorage(rig.isolated.suite),
            size: CGSize(width: PlayerLayout.referenceBodyWidth, height: 160)
        )
        // On screen, far off every display and never key, so the display
        // cycle runs as it does for the panel.
        host.window.orderFrontRegardless()
        defer { host.window.orderOut(nil) }
        func sung() async -> String? {
            await AXProbe.read(host).all { $0.label == "Lyrics" && !$0.value.isEmpty }.first?.value
        }
        let first = await sung()
        let tree = await AXProbe.read(host)
        XCTAssertEqual(first, "First line", tree.dump)
        // The probe's stores hold the controller's clock still; a second and
        // a bit later the voice is past the next line's stamp, and one tick
        // (the ticker's callback) publishes it.
        let now = rig.media.monotonicNow()
        rig.media.monotonicNow = { now + 1.2 }
        rig.media.tick()
        var turned: String?
        for _ in 0..<20 {
            await AXProbe.wait(0.1)
            if let line = await sung(), line != first { turned = line; break }
        }
        XCTAssertEqual(turned, "Second line", "the open player's line stood still")
    }

    /// The stage and the lock card read the clock in their own bodies, so the
    /// tick still reaches them: the lab put them at 0.3 % after this change
    /// against 3.5 % before, which a frozen clock would also explain.
    func testTheStageStillMovesWithTheTick() async throws {
        let rig = await playing(elapsed: 1.5, lyrics: true)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let stage = LyricsStage(media: rig.media, lyrics: rig.lyrics, dismiss: {})
            .defaultAppStorage(rig.isolated.suite)
        // The stage has no slider; the sung row is the selected one.
        try await assertMoves(stage, size: CGSize(width: 504, height: 240), rig, "the stage") {
            $0.all { $0.role == "AXButton" && $0.selected }.first?.label
        }
    }

    func testTheLockCardStillMovesWithTheTick() async throws {
        let rig = await playing()
        defer {
            rig.media.setActive(false, surface: .lockCard)
            rig.isolated.release()
        }
        rig.media.setActive(true, surface: .lockCard)
        let card = LockScreenCard(
            media: rig.media, lyrics: rig.lyrics, audio: MediaPane.quietAudio(), initialPane: .player
        )
        .defaultAppStorage(rig.isolated.suite)
        try await assertMoves(card, size: LockScreenCard.size(for: .standard), rig, "the lock card") {
            $0.first(label: "Playback Position")?.value
        }
    }

    /// On screen, a few seconds on and one tick later, what VoiceOver reads
    /// of the position says something else.
    private func assertMoves(
        _ view: some View, size: CGSize, _ rig: Rig, _ name: String, reading: @escaping (AXNode) -> String?
    ) async throws {
        let host = AXProbe.present(view, size: size)
        host.window.orderFrontRegardless()
        defer { host.window.orderOut(nil) }
        func position() async -> String? {
            reading(await AXProbe.read(host))
        }
        let tree = await AXProbe.read(host)
        let shown = await position()
        let before = try XCTUnwrap(shown, "\(name) shows no position\n\(tree.dump)")
        // Past the second line's stamp and into the next whole second.
        let now = rig.media.monotonicNow()
        rig.media.monotonicNow = { now + 2 }
        rig.media.tick()
        var after: String?
        for _ in 0..<20 {
            await AXProbe.wait(0.1)
            if let value = await position(), value != before { after = value; break }
        }
        XCTAssertNotNil(after, "\(name)'s position stood still at \(before)")
    }
}
