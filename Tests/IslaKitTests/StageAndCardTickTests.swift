import Observation
import QuartzCore
import SwiftUI
import XCTest
@testable import IslaKit

/// The lyric stage and the lock card stand still between their lines (Batch
/// 22, 2026-11-05).
///
/// Batch 20 took the player's bar and times off the 0.1 s position tick and
/// Batch 21 its sung line. The stage and the lock card still read the position
/// in their own bodies, so open on the stage, or locked with a song playing,
/// every tick re-ran the whole surface to draw what was already drawn: in the
/// idle-cost lab 3.0 % of a core on the stage, 1.9 % on the card's player and
/// 2.4 % on its lyrics, and 5.2 % and 4.4 % through an instrumental. They now
/// read the clock's line reading (`PlaybackClock.linePosition`), which moves
/// only where a line can turn. The one row that moves between those — the
/// sung line's sweep, a playing rest's fill — reads the clock's course in a
/// reader of its own, and the bar, the ring and the fill run on Core
/// Animation from that course.
///
/// What a tick costs is counted here as the hosting view's layout passes: a
/// body that reads the position is a graph pass and a layout on every tick,
/// and a settled surface with nothing new to show asks for none.
@MainActor
final class StageAndCardTickTests: XCTestCase {
    /// Lines with an honoured end on the second, so the song has a rest from
    /// 5 s to the third line at 30 s, long enough to be an interlude row.
    private static let lines: [LyricsStore.Line] = [
        .init(at: 1, text: "First line"), .init(at: 2.5, text: "Second line", end: 5),
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

        var lead: TimeInterval {
            LyricSweep.lead(precisionSync: media.precisionSync, userOffset: lyrics.userOffset, trackOffset: lyrics.trackOffset)
        }
    }

    /// Playing with the lyric moment at `moment` (the clock plus the lead),
    /// the lines shown and their boundaries registered as the coordinator
    /// registers them.
    private func playing(at moment: TimeInterval, surface: MediaController.Surface = .panel) async -> Rig {
        let rig = Rig(isolated: ProbeFixtures.isolatedStores())
        rig.lyrics.userOffset = 0
        // On the host's clock, as in the app: the bar, the ring and a rest's
        // fill are planned against it, and the probe's own fixed time would
        // put the song hours past its end.
        let base = SongClock.hostNow()
        rig.media.monotonicNow = { base }
        await LabFixtures.play(.init(elapsed: moment - rig.lead, cover: nil), on: rig.media)
        rig.lyrics.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        rig.media.setActive(true, surface: surface)
        let lead = rig.lead
        rig.media.setLyricBoundaries(
            LyricsCoordinator.boundaries(of: Self.lines, readAhead: rig.lyrics.readAhead)
        ) { lead }
        return rig
    }

    private func finish(_ rig: Rig, surface: MediaController.Surface = .panel) {
        rig.media.setActive(false, surface: surface)
        rig.isolated.release()
    }

    // MARK: The stage

    func testATickInsideALineLeavesTheStageStill() async {
        let rig = await playing(at: 2.7)
        defer { finish(rig) }
        let hosted = host(stage(rig), size: Self.stageSize)
        defer { hosted.window.orderOut(nil) }
        let inside = await layouts(hosted, rig, ticks: 5, step: 0.1)
        XCTAssertEqual(inside, 0, "a tick inside a line re-ran the stage")
        // And the stage still turns: the voice reaching the honoured end
        // (5 s) changes what is lit.
        let across = await layouts(hosted, rig, ticks: 1, step: 2.5)
        XCTAssertGreaterThan(across, 0, "the voice left the line and the stage did not turn")
    }

    func testATickThroughARestLeavesTheStageStill() async {
        let rig = await playing(at: 12)
        defer { finish(rig) }
        let hosted = host(stage(rig), size: Self.stageSize)
        defer { hosted.window.orderOut(nil) }
        let inside = await layouts(hosted, rig, ticks: 5, step: 0.1)
        XCTAssertEqual(inside, 0, "a tick through an instrumental re-ran the stage")
    }

    /// What the stage reads the song with: the line reading, and not the
    /// position. Reading the position here again would put the 10 Hz redraw
    /// back with every row still drawing the right line.
    func testTheStageReadsTheLineReading() async {
        let rig = await playing(at: 2.7)
        defer { finish(rig) }
        let stage = stage(rig)
        let inside = Flag()
        withObservationTracking { _ = stage.inputsForTests } onChange: { inside.raised = true }
        rig.advance(by: 0.3)
        XCTAssertFalse(inside.raised, "a tick inside a line reached what the stage reads")
        let across = Flag()
        withObservationTracking { _ = stage.inputsForTests } onChange: { across.raised = true }
        rig.advance(by: 2.5)
        XCTAssertTrue(across.raised, "the voice left the line and the stage was not told")
        XCTAssertEqual(stage.inputsForTests.position, rig.media.position)
    }

    // MARK: The lock card

    func testATickLeavesTheLockCardsPlayerStill() async {
        // Inside a rest, and the elapsed time inside a second, so neither the
        // lyric nor a time has anything new to show.
        let rig = await playing(at: 10.6 + Self.restingLead, surface: .lockCard)
        defer { finish(rig, surface: .lockCard) }
        let hosted = host(card(rig, pane: .player), size: LockScreenCard.size(for: .standard))
        defer { hosted.window.orderOut(nil) }
        let inside = await layouts(hosted, rig, ticks: 5, step: 0.05)
        XCTAssertEqual(inside, 0, "a tick inside a second re-ran the lock card")
        let next = await layouts(hosted, rig, ticks: 1, step: 1)
        XCTAssertGreaterThan(next, 0, "the elapsed time passed a second and the card's times did not turn")
    }

    func testATickLeavesTheLockCardsLyricsStill() async {
        let rig = await playing(at: 2.7, surface: .lockCard)
        defer { finish(rig, surface: .lockCard) }
        let hosted = host(card(rig, pane: .lyrics), size: LockScreenCard.size(for: .standard))
        defer { hosted.window.orderOut(nil) }
        let inside = await layouts(hosted, rig, ticks: 5, step: 0.1)
        XCTAssertEqual(inside, 0, "a tick inside a line re-ran the card's lyrics")
        let across = await layouts(hosted, rig, ticks: 1, step: 2.5)
        XCTAssertGreaterThan(across, 0, "the voice left the line and the card's lyrics did not turn")
    }

    func testATickLeavesTheBannersRingStill() async {
        let rig = await playing(at: 10.55, surface: .lockCard)
        defer { finish(rig, surface: .lockCard) }
        let presentation = LockCardPresentation(restsAsBanner: true)
        let hosted = host(
            LockScreenCard(
                media: rig.media, lyrics: rig.lyrics, audio: MediaPane.quietAudio(), presentation: presentation
            )
            .defaultAppStorage(rig.isolated.suite),
            size: LockScreenCard.size(for: .standard)
        )
        defer { hosted.window.orderOut(nil) }
        let inside = await layouts(hosted, rig, ticks: 5, step: 0.1)
        XCTAssertEqual(inside, 0, "a tick re-ran the banner to turn its ring")
        let ring = hosted.hosting.descendants(of: PlaybackRingView.self).first
        XCTAssertNotNil(ring?.runningAnimation, "the playing banner's ring is not turning")
        XCTAssertEqual(ring?.installs, 1, "a tick laid the banner's ring again")
    }

    // MARK: The ring

    private static func ringInput(_ motion: PlaybackClock.Motion, duration: TimeInterval = 200) -> PlaybackRing.Input {
        .init(motion: motion, duration: duration, side: 40, inset: 1.5, lineWidth: 2)
    }

    /// At every moment the arc's share of the circle is what the trimmed
    /// circle drew: the position's share of the song, clamped to the circle.
    func testTheRingIsTheTrimmedCircleAtEveryMoment() {
        for position in [0.0, 1.0, 50.0, 200.0, 250.0] {
            let plan = PlaybackRing.plan(Self.ringInput(.still(position)), monoNow: 5_000)
            XCTAssertEqual(plan.run.start, CGFloat(min(position / 200, 1)), accuracy: 1e-9, "still at \(position) s")
            XCTAssertEqual(plan.visible, position > 0, "still at \(position) s")
            XCTAssertTrue(plan.run.keys.isEmpty)
        }
        for (start, rate) in [(0.0, 1.0), (10.0, 1.0), (60.0, 1.5), (199.0, 1.0)] {
            let clock = SongClock(position: start, atMono: 5_000, rate: rate, cap: 200)
            let plan = PlaybackRing.plan(Self.ringInput(.moving(clock)), monoNow: 5_000)
            var offset = 0.0
            while offset <= (200 - start) / rate + 2 {
                let mono = 5_000 + offset
                let trimmed = CGFloat(min(max(clock.position(at: mono) / 200, 0), 1))
                XCTAssertEqual(plan.run.width(atMono: mono), trimmed, accuracy: 1e-9, "from \(start) s at \(rate)x, +\(offset) s")
                offset += 0.05
            }
        }
    }

    /// The arc starts at 12 o'clock and runs clockwise as it is seen, for a
    /// layer drawn either way up: the first quarter of it ends at 3 o'clock.
    func testTheRingRunsClockwiseFromTheTop() {
        for flipped in [false, true] {
            let points = Self.endpoints(PlaybackRing.path(side: 40, inset: 1.5, flipped: flipped))
            XCTAssertGreaterThanOrEqual(points.count, 5, "the arc is not a full circle")
            guard points.count >= 2 else { continue }
            // Seen on screen: the top is the high y when y runs up, the low
            // y when it runs down.
            let top = CGPoint(x: 20, y: flipped ? 1.5 : 38.5)
            XCTAssertEqual(points[0].x, top.x, accuracy: 1e-6, "flipped \(flipped): not from 12 o'clock")
            XCTAssertEqual(points[0].y, top.y, accuracy: 1e-6, "flipped \(flipped): not from 12 o'clock")
            XCTAssertEqual(points[1].x, 38.5, accuracy: 1e-6, "flipped \(flipped): the first quarter does not end at 3 o'clock")
            XCTAssertEqual(points[1].y, 20, accuracy: 1e-6, "flipped \(flipped): the first quarter does not end at 3 o'clock")
        }
    }

    /// And on screen, inside SwiftUI as the banner hosts it: a quarter of the
    /// song lights the circle's top right and nothing else.
    func testAQuarterOfTheSongLightsTheTopRightOfTheRing() throws {
        let side: CGFloat = 80
        let hosted = host(
            PlaybackRing(
                input: .init(motion: .still(50), duration: 200, side: side, inset: 4, lineWidth: 6),
                color: .white
            )
            .frame(width: side, height: side)
            .background(Color.black),
            size: CGSize(width: side, height: side)
        )
        defer { hosted.window.orderOut(nil) }
        hosted.hosting.layoutSubtreeIfNeeded()
        let ring = try XCTUnwrap(hosted.hosting.descendants(of: PlaybackRingView.self).first, "no ring was drawn")
        XCTAssertEqual(ring.strokeEnd, 0.25, accuracy: 1e-9)
        let rep = try XCTUnwrap(hosted.hosting.bitmapImageRepForCachingDisplay(in: hosted.hosting.bounds))
        hosted.hosting.cacheDisplay(in: hosted.hosting.bounds, to: rep)
        var lit: [CGPoint] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let colour = rep.colorAt(x: x, y: y), colour.brightnessComponent > 0.5 {
                    lit.append(CGPoint(x: CGFloat(x) / CGFloat(rep.pixelsWide), y: CGFloat(y) / CGFloat(rep.pixelsHigh)))
                }
            }
        }
        XCTAssertFalse(lit.isEmpty, "nothing of the ring was drawn")
        // The bitmap's rows run down from the top.
        let wrong = lit.filter { $0.x < 0.45 || $0.y > 0.55 }
        XCTAssertLessThan(
            Double(wrong.count), Double(lit.count) * 0.05,
            "\(wrong.count) of \(lit.count) lit pixels lie outside the top right"
        )
    }

    /// The ring is laid once per course, and laid again where a seek, a pause
    /// or a new circle puts it; nothing is lit before the song starts.
    func testTheRingIsLaidOncePerCourse() throws {
        let window = present()
        defer { window.orderOut(nil) }
        let view = PlaybackRingView()
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        window.contentView?.addSubview(view)
        let now = SongClock.hostNow()
        view.update(Self.ringInput(.moving(SongClock(position: 50, atMono: now, rate: 1, cap: 200))), color: .white)
        XCTAssertEqual(view.installs, 1)
        let animation = try XCTUnwrap(view.runningAnimation as? CAKeyframeAnimation, "the playing ring has no animation")
        XCTAssertEqual(animation.keyPath, "strokeEnd")
        XCTAssertEqual(view.strokeEnd, 0.25, accuracy: 1e-3)
        for step in 1...20 {
            let later = now + 0.1 * Double(step)
            view.update(Self.ringInput(.moving(SongClock(position: 50 + 0.1 * Double(step), atMono: later, rate: 1, cap: 200))), color: .white)
        }
        XCTAssertEqual(view.installs, 1, "a tick's fresh reading of the same clock laid the ring again")
        view.update(Self.ringInput(.moving(SongClock(position: 150, atMono: now + 3, rate: 1, cap: 200))), color: .white)
        XCTAssertEqual(view.installs, 2, "a seek did not move the ring")
        view.update(Self.ringInput(.still(150)), color: .white)
        XCTAssertEqual(view.installs, 3, "a pause did not stop the ring")
        XCTAssertNil(view.runningAnimation, "a paused ring is still turning")
        XCTAssertEqual(view.strokeEnd, 0.75, accuracy: 1e-9)
        XCTAssertEqual(view.arcOpacity, 1)
        view.update(Self.ringInput(.still(0)), color: .white)
        XCTAssertEqual(view.arcOpacity, 0, "a round cap drew a dot before anything was played")
    }

    /// The ring hears from SwiftUI only when its course changes, so one that
    /// lost its animation would stand still until the next seek. A move to
    /// another window is when AppKit drops it, and the ring is laid again
    /// there, its path built for that window's way up.
    func testARingThatLostItsAnimationIsLaidAgainInItsNewWindow() {
        let first = present(), second = present()
        defer {
            first.orderOut(nil)
            second.orderOut(nil)
        }
        let view = PlaybackRingView()
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        first.contentView?.addSubview(view)
        view.update(Self.ringInput(.moving(SongClock(position: 50, atMono: SongClock.hostNow(), rate: 1, cap: 200))), color: .white)
        XCTAssertEqual(view.installs, 1)
        view.dropAnimationForTests()
        second.contentView?.addSubview(view)
        XCTAssertEqual(view.installs, 2, "a moved ring with no animation was left still")
        XCTAssertNotNil(view.runningAnimation)
        view.removeFromSuperview()
        first.contentView?.addSubview(view)
        XCTAssertEqual(view.installs, 2, "a ring still turning was laid again only for moving")
    }

    // MARK: A rest's fill before the song's start

    /// A rest's fill is a span of its own, and a listener's delay can put the
    /// lyric moment before its start: the fill stays empty until the span's
    /// start comes round, then fills from there, rather than setting off
    /// early from where the clock is now.
    func testAFillReadBeforeItsSpanHoldsEmptyUntilTheSpanStarts() {
        let clock = SongClock(position: -2, atMono: 1_000, rate: 1, cap: 20)
        let plan = PlaybackFill.plan(
            .init(motion: .moving(clock), duration: 20, width: 44, height: 3, radius: 1.5),
            monoNow: 1_000
        )
        XCTAssertTrue(plan.visible)
        for offset in stride(from: 0.0, through: 24, by: 0.25) {
            let mono = 1_000 + offset
            let expected = 44 * CGFloat(min(max(clock.position(at: mono) / 20, 0), 1))
            XCTAssertEqual(plan.run.width(atMono: mono), expected, accuracy: 1e-9, "+\(offset) s")
        }
    }

    // MARK: Helpers

    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    /// The lead a fresh rig reads with: no delay, no measured player clock.
    private static let restingLead = LyricSweep.lead(precisionSync: false, userOffset: 0)

    private static let stageSize = CGSize(width: 504, height: 240)

    private func stage(_ rig: Rig) -> LyricsStage {
        LyricsStage(media: rig.media, lyrics: rig.lyrics, dismiss: {})
    }

    private func card(_ rig: Rig, pane: LockScreenCard.Pane) -> some View {
        LockScreenCard(media: rig.media, lyrics: rig.lyrics, audio: MediaPane.quietAudio(), initialPane: pane)
            .defaultAppStorage(rig.isolated.suite)
    }

    /// A hosting view that counts its layout passes.
    private final class CountingHost: NSHostingView<AnyView> {
        private(set) var layouts = 0

        override func layout() {
            layouts += 1
            super.layout()
        }

        func reset() { layouts = 0 }
    }

    private struct Hosted {
        let window: NSWindow
        let hosting: CountingHost
    }

    private func host(_ view: some View, size: CGSize) -> Hosted {
        let window = NSWindow(
            contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = CountingHost(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return .init(window: window, hosting: hosting)
    }

    /// The layout passes `ticks` ticks of `step` seconds cost a surface left
    /// to settle first, each tick given a turn of the run loop to be drawn.
    private func layouts(_ hosted: Hosted, _ rig: Rig, ticks: Int, step: TimeInterval) async -> Int {
        await AXProbe.wait(0.6)
        hosted.hosting.reset()
        for _ in 0..<ticks {
            rig.advance(by: step)
            await AXProbe.wait(0.06)
        }
        await AXProbe.wait(0.15)
        return hosted.hosting.layouts
    }

    /// The points a path's elements end at, its first move included: a full
    /// circle is a move and four quarter curves.
    private static func endpoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint: points.append(e.points[1])
            case .addCurveToPoint: points.append(e.points[2])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return points
    }

    private func present() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 60, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        window.contentView?.wantsLayer = true
        window.orderFrontRegardless()
        return window
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in ((view as? T).map { [$0] } ?? []) + view.descendants(of: type) }
    }
}
