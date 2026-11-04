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

    // MARK: The bar and the times (Batch 20)

    /// The labels and the bar are worked out on every tick and published only
    /// when a label's text or the bar's course changes. Before Batch 20 the
    /// times and the scrubber read the position itself, so a tick re-ran both
    /// and the panel's graph, layout and render with them, ten times a second
    /// with nothing new to show nine times out of ten.
    func testATickWithinASecondLeavesTheTimesAndTheBarAlone() async {
        let rig = await playing(elapsed: 30.2)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let times = Flag(), bar = Flag()
        withObservationTracking { _ = rig.media.shownSeconds(nil) } onChange: { times.raised = true }
        withObservationTracking { _ = rig.media.shownMotion(nil) } onChange: { bar.raised = true }
        let before = rig.media.position
        let now = rig.media.monotonicNow()
        rig.media.monotonicNow = { now + 0.1 }
        rig.media.tick()
        XCTAssertGreaterThan(rig.media.position, before, "the tick did not move the clock")
        XCTAssertFalse(times.raised, "a tick inside a second re-runs the times")
        XCTAssertFalse(bar.raised, "a tick re-runs the scrubber")
    }

    /// And they still say what the clock says: the labels turn on the tick
    /// that turns their text, and the bar changes course on a pause.
    func testTheTimesTurnWithTheirTextAndTheBarWithItsCourse() async throws {
        let rig = await playing(elapsed: 30.2)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let times = Flag()
        withObservationTracking { _ = rig.media.shownSeconds(nil) } onChange: { times.raised = true }
        let now = rig.media.monotonicNow()
        rig.media.monotonicNow = { now + 0.5 }
        rig.media.tick()
        XCTAssertTrue(times.raised, "the elapsed time passed 30.5 s and its label did not turn")
        let seconds = rig.media.shownSeconds(nil)
        XCTAssertEqual(formatTime(TimeInterval(seconds.elapsed)), formatTime(rig.media.labelPosition))
        XCTAssertEqual(
            formatTime(TimeInterval(seconds.remaining)), formatTime(max(0, rig.media.duration - rig.media.labelPosition))
        )
        guard case .moving(let clock) = rig.media.shownMotion(nil) else {
            return XCTFail("a playing song's bar is not moving")
        }
        XCTAssertEqual(clock.position(at: rig.media.monotonicNow()), rig.media.extrapolatedPosition(), accuracy: 1e-9)

        let bar = Flag()
        withObservationTracking { _ = rig.media.shownMotion(nil) } onChange: { bar.raised = true }
        LabFixtures.pause(.init(elapsed: 31, cover: nil), on: rig.media)
        XCTAssertTrue(bar.raised, "a pause did not stop the bar")
        XCTAssertEqual(rig.media.shownMotion(nil), .still(rig.media.position))
    }

    /// Every change of the clock that is not a tick reaches the labels and the
    /// bar: a seek, a new rate, a length that arrives late, a new song. Each
    /// is one of the controller's observers calling `publishClockReadings`,
    /// and a dropped call would leave the times and the bar where they were
    /// while the song moved on, with every other test still green.
    func testEveryChangeOfTheClockReachesTheTimesAndTheBar() async {
        let rig = await playing(elapsed: 30.2)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        func apply(_ name: String, elapsed: TimeInterval, duration: TimeInterval, rate: Double, title: String = "Waiting Room") {
            var snapshot = NowPlayingFeed.Snapshot()
            snapshot.title = title
            snapshot.artist = "Halcyon Static"
            snapshot.album = "Low Light"
            snapshot.duration = duration
            snapshot.elapsed = elapsed
            snapshot.rate = rate
            snapshot.isPlaying = true
            snapshot.takenAt = Date()
            snapshot.source = "Music"
            rig.media.apply(snapshot)
            let media = rig.media
            XCTAssertEqual(media.duration, duration, "\(name): the controller did not take the length")
            XCTAssertEqual(
                media.shownSeconds(nil),
                PlaybackClock.Seconds(shown: min(media.labelPosition, media.duration), duration: media.duration),
                "\(name): the labels say something else than the clock"
            )
            guard case .moving(let clock) = media.shownMotion(nil) else {
                return XCTFail("\(name): a playing song's bar is not moving")
            }
            XCTAssertEqual(clock.rate, rate, "\(name): the bar runs at another rate")
            XCTAssertEqual(
                clock.position(at: media.monotonicNow()), media.extrapolatedPosition(), accuracy: 1e-6,
                "\(name): the bar is somewhere else than the song"
            )
        }
        apply("a seek", elapsed: 120, duration: 238, rate: 1)
        apply("a new rate", elapsed: 120, duration: 238, rate: 1.5)
        apply("a length that came late", elapsed: 120, duration: 301, rate: 1.5)
        apply("a new song", elapsed: 12, duration: 190, rate: 1, title: "Another Song")
    }

    /// The labels' seconds round as `formatTime` does, so the text drawn from
    /// them is the text drawn from the exact time, at every hundredth of a
    /// second of a song whose length is not a whole number of seconds.
    func testTheSecondsDrawTheSameTextAsTheExactTime() {
        for duration in [238.0, 238.4, 61.5, 3_725.7] {
            var shown = -0.5
            while shown <= duration + 0.5 {
                let clamped = min(shown, duration)
                let seconds = PlaybackClock.Seconds(shown: clamped, duration: duration)
                XCTAssertEqual(formatTime(TimeInterval(seconds.elapsed)), formatTime(clamped), "elapsed at \(shown) of \(duration)")
                XCTAssertEqual(
                    formatTime(TimeInterval(seconds.remaining)), formatTime(max(0, duration - clamped)),
                    "remaining at \(shown) of \(duration)"
                )
                shown += 0.01
            }
        }
        XCTAssertEqual(formatTime(TimeInterval(PlaybackClock.Seconds(shown: .nan, duration: 10).elapsed)), "--:--")
        // A stream's sentinel length: no trap, and no label pretending to know.
        let sentinel = PlaybackClock.Seconds(shown: 12, duration: 1e19)
        XCTAssertEqual(formatTime(TimeInterval(sentinel.remaining)), "--:--")
        XCTAssertEqual(PlaybackClock.Seconds(shown: 1e19, duration: 1e19).elapsed, -1)
    }

    /// The scrubber's own body: what a tick re-runs of it. Only the hover dot
    /// reads the clock, inside a reader of its own; the slider VoiceOver hears
    /// reads the elapsed label's second, so it turns with the label.
    func testTheScrubbersBodyDoesNotReadThePosition() async {
        let rig = await playing()
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let scrubber = PlaybackScrubber(
            media: rig.media, width: 310, trackHeight: 7, radius: 3.5, track: .white, fill: .white
        )
        let read = Flag()
        withObservationTracking { _ = scrubber.body } onChange: { read.raised = true }
        let now = rig.media.monotonicNow()
        rig.media.monotonicNow = { now + 0.3 }
        rig.media.tick()
        XCTAssertFalse(read.raised, "a position tick re-runs the scrubber to move its fill")
        // The control: the body does watch the clock, through the second
        // VoiceOver reads, so a body that read nothing could not pass.
        rig.media.monotonicNow = { now + 1.3 }
        rig.media.tick()
        XCTAssertTrue(read.raised, "the slider VoiceOver hears no longer turns with the elapsed time")
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
