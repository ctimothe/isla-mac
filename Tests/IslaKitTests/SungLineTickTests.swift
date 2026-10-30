import Observation
import SwiftUI
import XCTest
@testable import IslaKit

/// The player's sung line turns on its lines, not on the tick (Batch 21,
/// 2026-10-30).
///
/// The sung line read the position in a `ClockReader`, so the 10 Hz tick
/// re-ran it ten times a second, and each time SwiftUI rebuilt the line's
/// text, laid the panel out and rebuilt its key-view loop. Open on the player
/// with a line-timed song, the running Isla spent 7.2 % of a core, against
/// 1.9 % with the band off (B20-H1). What the line draws changes only where a
/// line starts, where its voice ends and where the caption reads ahead, and
/// the clock already wakes on exactly those moments for the lyrics
/// (`setLyricBoundaries`). So the clock keeps a second reading,
/// `PlaybackClock.linePosition`, which moves only when the position crosses
/// one of them or the clock changes course, and the line reads that.
@MainActor
final class SungLineTickTests: XCTestCase {
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

        func advance(by seconds: TimeInterval) {
            let now = media.monotonicNow()
            media.monotonicNow = { now + seconds }
            media.tick()
        }

        /// The lead the pane reads with, and the coordinator registers.
        var lead: TimeInterval {
            LyricSweep.lead(precisionSync: media.precisionSync, userOffset: lyrics.userOffset, trackOffset: lyrics.trackOffset)
        }

        /// The sung line's reading, as the pane asks for it.
        var reading: TimeInterval { media.shownLinePosition(nil, lead: lead) }

        func register(_ lines: [LyricsStore.Line] = SungLineTickTests.lines) {
            let rig = self
            // With the store's own read-ahead, as the coordinator registers.
            media.setLyricBoundaries(LyricsCoordinator.boundaries(of: lines, readAhead: lyrics.readAhead)) { rig.lead }
        }
    }

    /// The lead a fresh rig reads with: no delay, no measured player clock.
    private static let restingLead = LyricSweep.lead(precisionSync: false, userOffset: 0)

    private func playing(elapsed: TimeInterval) async -> Rig {
        let rig = Rig(isolated: ProbeFixtures.isolatedStores())
        // The probe stores keep their delay across tests; two of these set one.
        rig.lyrics.userOffset = 0
        await LabFixtures.play(.init(elapsed: elapsed, cover: nil), on: rig.media)
        rig.lyrics.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        rig.media.setActive(true)
        rig.register()
        return rig
    }

    private func watch(_ rig: Rig) -> Flag {
        let flag = Flag()
        withObservationTracking { _ = rig.reading } onChange: { flag.raised = true }
        return flag
    }

    private func pane(_ rig: Rig) -> MediaPane {
        MediaPane(media: rig.media, lyrics: rig.lyrics, morph: nil, icons: SettingsFixture.macWithApps([:]))
    }

    func testATickInsideALineLeavesTheSungLineAlone() async {
        let rig = await playing(elapsed: 10)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        XCTAssertEqual(rig.lead, Self.restingLead, "the rig does not read with a resting lead")
        let line = watch(rig)
        let before = rig.media.position
        rig.advance(by: 0.3)
        XCTAssertGreaterThan(rig.media.position, before, "the tick did not move the clock")
        XCTAssertFalse(line.raised, "a tick inside a line re-runs the sung line")
    }

    func testATickPastALinesStampTurnsIt() async {
        let rig = await playing(elapsed: 30 - Self.restingLead - 0.15)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let line = watch(rig)
        rig.advance(by: 0.3)
        XCTAssertTrue(line.raised, "the voice reached the next line and the sung line did not turn")
        XCTAssertEqual(rig.reading, rig.media.position)
    }

    /// The lead is asked on every tick, both readings against it, so a Lyric
    /// Delay changed while a line is sung turns the line on the next tick
    /// that the new delay says has crossed, not at the next stamp.
    func testANewLeadIsHonouredOnTheNextTick() async {
        let rig = await playing(elapsed: 29 - Self.restingLead)
        defer {
            rig.media.setActive(false)
            rig.lyrics.userOffset = 0
            rig.isolated.release()
        }
        rig.lyrics.userOffset = -0.9
        rig.advance(by: 0.2)
        XCTAssertEqual(rig.media.clock.lineLead, rig.lead, "the tick kept the reading against the old lead")
        XCTAssertEqual(
            rig.media.clock.linePosition, rig.media.position,
            "29.2 s with 0.9 s more lead is past 30 s, and the line stood still"
        )
    }

    /// Review, Batch 21: a reading kept at a line's turn, read with a delay
    /// added since, named the line before it until the next tick, so the
    /// line turned back and forth. Between the delay and the tick the pane
    /// reads the position.
    func testADelayAddedMidLineNeverShowsTheLineBefore() async {
        let rig = await playing(elapsed: 30 - Self.restingLead + 0.02)
        defer {
            rig.media.setActive(false)
            rig.lyrics.userOffset = 0
            rig.isolated.release()
        }
        let pane = pane(rig)
        XCTAssertEqual(pane.sungLineForTests.index, 2)
        rig.advance(by: 3)
        XCTAssertEqual(rig.media.clock.linePosition, rig.media.position - 3, accuracy: 1e-6, "the reading moved inside a line")
        // A whole second of delay: the kept reading would read 29.02 s, before
        // the second line's read-ahead, while the song is at 32.02 s.
        rig.lyrics.userOffset = 1
        XCTAssertEqual(pane.sungLineForTests.index, 2, "a delay added three seconds into a line showed the line before")
        rig.advance(by: 0.1)
        XCTAssertEqual(rig.media.clock.lineLead, rig.lead)
        XCTAssertEqual(pane.sungLineForTests.index, 2)
    }

    /// A stop re-stamps the reading, since a paused sweep is drawn at it; a
    /// seek while playing re-stamps it only when it lands on another line.
    func testAPauseAndASeekMoveTheSungLine() async {
        let rig = await playing(elapsed: 3)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        rig.advance(by: 0.2)
        let line = watch(rig)
        LabFixtures.pause(.init(elapsed: 3.4, cover: nil), on: rig.media)
        XCTAssertTrue(line.raised, "a pause inside a line left the line's reading where it was")
        XCTAssertEqual(rig.reading, rig.media.position)

        let pane = pane(rig)
        await LabFixtures.play(.init(elapsed: 20, cover: nil), on: rig.media)
        XCTAssertEqual(pane.sungLineForTests.index, 1, "a seek inside the line showed another")
        await LabFixtures.play(.init(elapsed: 31, cover: nil), on: rig.media)
        XCTAssertEqual(rig.reading, rig.media.position, "a seek onto the next line left the reading behind")
        XCTAssertEqual(pane.sungLineForTests.index, 2)
    }

    func testNewBoundariesMoveTheSungLine() async {
        let rig = await playing(elapsed: 10)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        rig.advance(by: 0.2)
        let line = watch(rig)
        rig.register([.init(at: 5, text: "Five"), .init(at: 9, text: "Nine")])
        XCTAssertTrue(line.raised, "new lines kept the last lines' reading")
        XCTAssertEqual(rig.reading, rig.media.position)
    }

    /// With no lyric timeline registered there is nothing to turn on, so the
    /// reading follows every tick, as the position does.
    func testWithoutBoundariesTheReadingFollowsTheClock() async {
        let rig = await playing(elapsed: 10)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let lead = rig
        rig.media.setLyricBoundaries([]) { lead.lead }
        let line = watch(rig)
        rig.advance(by: 0.1)
        XCTAssertTrue(line.raised)
        XCTAssertEqual(rig.reading, rig.media.position)
    }

    /// The invariant the whole change stands on: wherever the reading is left
    /// behind the clock, the caption it draws is the caption the clock would
    /// have drawn. Walked through every kind of boundary — stamps, an honoured
    /// end and its interlude, two lines on one stamp, read-ahead at each
    /// setting, credits and a lead either side of zero — with the boundaries
    /// the coordinator registers, a reading kept by the controller's own rule,
    /// and the caption's own resolution.
    func testTheCaptionAtTheLineReadingIsTheCaptionAtTheClock() {
        let lines: [LyricsStore.Line] = [
            .init(at: 2, text: "Opening line"),
            .init(at: 5, text: "Short", end: 7),
            .init(at: 14, text: "A line long enough to read ahead of"),
            .init(at: 17, text: "Two on"),
            .init(at: 17, text: "one stamp"),
            .init(at: 18.2, text: "Written by somebody", isCredit: true),
            .init(at: 21, text: "Close", end: 22.2),
            .init(at: 23, text: "Last", end: 40),
        ]
        for readAhead in [LyricReadAhead.off, .auto, .threeTenths, .half] {
            let boundaries = LyricsCoordinator.boundaries(of: lines, readAhead: readAhead).sorted()
            for wanted in [0.2, -0.45, 0] {
                // The user's delay that gives this lead, and the lead exactly
                // as the caption will add it, so the two cannot differ by an ulp.
                let delay = LyricSweep.lead(precisionSync: false, userOffset: 0) - wanted
                let lead = LyricSweep.lead(precisionSync: false, userOffset: delay)
                var reading = -1.0
                var position = -1.0
                while position < 45 {
                    reading = MediaController.linePosition(
                        position: position, published: reading, boundaries: boundaries, lead: lead, turned: false
                    )
                    let drawn = caption(lines, at: reading, delay: delay, readAhead: readAhead)
                    let truth = caption(lines, at: position, delay: delay, readAhead: readAhead)
                    XCTAssertEqual(drawn.current, truth.current, "\(readAhead) lead \(lead) at \(position)")
                    XCTAssertEqual(drawn.centre, truth.centre, "\(readAhead) lead \(lead) at \(position)")
                    XCTAssertEqual(drawn.fraction, truth.fraction, "\(readAhead) lead \(lead) at \(position)")
                    if drawn.current != truth.current || drawn.centre != truth.centre { return }
                    position += 0.0037
                }
            }
        }
    }

    /// What the player's subtitle reads: a tick inside a line is not among
    /// it, a tick across a stamp is. Reading `shownPosition` here again would
    /// put the 10 Hz redraw back and leave every other test green.
    func testThePlayersSungLineReadsTheLineReading() async {
        let rig = await playing(elapsed: 10)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let pane = pane(rig)
        XCTAssertEqual(pane.sungLineForTests.index, 1, "the rig's band is not drawing the second line")
        let inside = Flag()
        withObservationTracking { _ = pane.sungLineForTests } onChange: { inside.raised = true }
        rig.advance(by: 0.3)
        XCTAssertFalse(inside.raised, "a tick inside a line re-runs the player's sung line")
        let across = Flag()
        withObservationTracking { _ = pane.sungLineForTests } onChange: { across.raised = true }
        rig.advance(by: 20)
        XCTAssertTrue(across.raised, "the voice reached the next line and the subtitle was not told")
        XCTAssertEqual(pane.sungLineForTests.index, 2)
    }

    /// The sung line on screen still turns, now through the line reading.
    func testTheOpenPlayerTurnsItsLineThroughTheBoundaries() async throws {
        let rig = await playing(elapsed: 26)
        defer {
            rig.media.setActive(false)
            rig.isolated.release()
        }
        let host = AXProbe.present(
            pane(rig).defaultAppStorage(rig.isolated.suite),
            size: CGSize(width: PlayerLayout.referenceBodyWidth, height: 160)
        )
        host.window.orderFrontRegardless()
        defer { host.window.orderOut(nil) }
        func sung() async -> String? {
            await AXProbe.read(host).all { $0.label == "Lyrics" && !$0.value.isEmpty }.first?.value
        }
        let first = await sung()
        let tree = await AXProbe.read(host)
        XCTAssertEqual(first, "Second line", tree.dump)
        rig.advance(by: 0.5)
        await AXProbe.wait(0.3)
        let still = await sung()
        XCTAssertEqual(still, "Second line", "a tick inside the line changed it")
        rig.advance(by: 4)
        var turned: String?
        for _ in 0..<20 {
            await AXProbe.wait(0.1)
            if let line = await sung(), line != first { turned = line; break }
        }
        XCTAssertEqual(turned, "Third line", "the open player's line stood still")
    }

    // MARK: The word sweep without a tick to repair it

    /// The tick used to re-lay a sweep whose layer had lost its animation.
    /// With no tick inside a line, a move to another window does it.
    func testASweepThatLostItsAnimationIsLaidAgainInItsNewWindow() {
        let first = present(), second = present()
        defer {
            first.orderOut(nil)
            second.orderOut(nil)
        }
        let view = KaraokeTrackView()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 20)
        first.contentView?.addSubview(view)
        let words = [LyricWord(at: 10, text: "ab", end: 11), LyricWord(at: 11, text: "cd", end: 12)]
        let clock = SongClock(position: 10.5, atMono: SongClock.hostNow(), rate: 1, cap: 200)
        view.update(.init(
            runs: [CGRect(x: 0, y: 0, width: 120, height: 20)], full: nil,
            sweep: LiveSweep(words: words, end: 12, clock: clock), fraction: 0
        ))
        XCTAssertEqual(view.installs, 1)
        view.dropAnimationsForTests()
        second.contentView?.addSubview(view)
        XCTAssertEqual(view.installs, 2, "a moved sweep with no animation was left still")
        view.removeFromSuperview()
        first.contentView?.addSubview(view)
        XCTAssertEqual(view.installs, 2, "a sweep still running was laid again only for moving")
    }

    private func caption(
        _ lines: [LyricsStore.Line], at position: TimeInterval, delay: TimeInterval, readAhead: LyricReadAhead
    ) -> MediaPane.SungLine {
        let resolution = MediaPane.captionResolution(lines: lines, inputs: LyricInputs(
            position: position, precisionSync: false, userOffset: delay,
            trackOffset: 0, wordTiming: false
        ), readAhead: readAhead)
        return MediaPane.SungLine(isOn: true, lines: lines, resolution: resolution)
    }

    private func present() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 220, height: 20),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 20))
        window.contentView?.wantsLayer = true
        window.orderFrontRegardless()
        return window
    }
}

private extension MediaPane.SungLine {
    var current: Int? { resolution?.current }
    var centre: Int? { resolution?.centre }
}
