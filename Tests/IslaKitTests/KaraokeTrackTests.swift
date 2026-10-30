import QuartzCore
import SwiftUI
import XCTest
@testable import IslaKit

/// The word sweep on Core Animation (Batch 19, 2026-10-30).
///
/// A word-timed line used to be swept by a `TimelineView` that asked SwiftUI
/// for every display frame, and each frame laid out and rendered the whole
/// panel: 6.2 % of a core on the running Isla open on the player (B18-H1),
/// 7.14 % and 7.65 % in the idle-cost lab's `open-player-words` and
/// `open-stage-words`. The line is now drawn once and Core Animation moves its
/// edge from keyframes worked out from the word stamps and the song's clock.
/// These hold that the keyframes put the edge exactly where the renderer put
/// it, frame by frame, so nothing the voice does is drawn later than before.
@MainActor
final class KaraokeTrackTests: XCTestCase {

    // MARK: The clock as a value

    /// `SongClock` is the arithmetic `extrapolatedPosition` runs, not a copy of
    /// it: the two agree at any moment, rate and cap included.
    func testTheSongClockIsTheControllersClock() throws {
        final class Clock { var now: TimeInterval = 1_000 }
        let clock = Clock()
        let media = playing(now: { clock.now }, elapsed: 10, duration: 12, rate: 1.5)
        let song = try XCTUnwrap(media.songClock, "a playing song has a clock")
        for step in [0.0, 0.4, 1.0, 1.3, 5.0] {
            clock.now = 1_000 + step
            XCTAssertEqual(song.position(at: clock.now), media.extrapolatedPosition(), accuracy: 1e-9, "at +\(step) s")
        }
        XCTAssertEqual(song.position(at: 1_000 + 100), 12, accuracy: 1e-9, "capped at the track's end")
        XCTAssertNil(song.mono(atSong: 12.5), "a moment past the end never comes")
        let reached = try XCTUnwrap(song.mono(atSong: 11))
        XCTAssertEqual(song.position(at: reached), 11, accuracy: 1e-9)

        let led = song.leading(0.2)
        XCTAssertEqual(led.position(at: 1_001), song.position(at: 1_001) + 0.2, accuracy: 1e-9)
        XCTAssertEqual(led.position(at: 1_100), 12.2, accuracy: 1e-9, "the lead moves the cap with the line")

        var paused = NowPlayingFeed.Snapshot.playing(elapsed: 11, duration: 12)
        paused.isPlaying = false
        paused.rate = 0
        media.apply(paused)
        XCTAssertNil(media.songClock, "a paused song has no clock to run")
    }

    /// Two readings of one clock agree; a re-anchor that moves the song by
    /// more than two milliseconds does not, and nor does a new rate.
    func testReadingsOfOneClockAgree() {
        let clock = SongClock(position: 10, atMono: 100, rate: 1, cap: 200)
        let later = SongClock(position: 12.5, atMono: 102.5, rate: 1, cap: 200)
        XCTAssertTrue(clock.agrees(with: later))
        XCTAssertTrue(clock.agrees(with: SongClock(position: 10.001, atMono: 100, rate: 1, cap: 200)))
        XCTAssertFalse(clock.agrees(with: SongClock(position: 10.01, atMono: 100, rate: 1, cap: 200)))
        XCTAssertFalse(clock.agrees(with: SongClock(position: 10, atMono: 100, rate: 1.5, cap: 200)))
        XCTAssertFalse(clock.agrees(with: SongClock(position: 10, atMono: 100, rate: 1, cap: 150)))
    }

    /// Core Animation's media time and the media clock are one machine clock,
    /// so a moment on the one is the same moment on the other: a reading of
    /// the media clock falls between two of Core Animation's taken around it.
    /// The track begins each animation at its first key's moment on that
    /// clock, so a second clock here would shift every edge by the gap.
    func testCoreAnimationAndTheMediaClockShareOneClock() {
        for _ in 0..<100 {
            let before = CACurrentMediaTime()
            let media = SongClock.hostNow()
            let after = CACurrentMediaTime()
            XCTAssertGreaterThanOrEqual(media, before - 1e-6)
            XCTAssertLessThanOrEqual(media, after + 1e-6)
        }
        XCTAssertEqual(MediaController().monotonicNow(), SongClock.hostNow(), accuracy: 0.005)
    }

    // MARK: The keyframes against the renderer

    /// Through a line of uneven words with a silence in it, on one row, every
    /// moment the keyframes describe is the width the renderer lit at that
    /// moment: `litWidth` of `wordFraction`, the arithmetic every frame ran.
    func testTheKeyframesAreTheRenderersEdgeOnOneRow() {
        let words = [
            LyricWord(at: 10, text: "I", end: 10.2),
            LyricWord(at: 10.2, text: "get", end: 10.8),
            LyricWord(at: 11.5, text: "up,", end: 12.0),
            LyricWord(at: 12.0, text: "dressed", end: nil),
        ]
        assertMatchesRenderer(words: words, end: 13.5, runs: [CGRect(x: 0, y: 0, width: 180, height: 20)], full: nil)
    }

    /// Wrapped to two rows, the top row fills completely before the bottom
    /// is touched, as `KaraokeRenderer` has done since it replaced the mask
    /// that lit both rows at once.
    func testTheKeyframesFillTheTopRowBeforeTheBottom() {
        let words = (0..<8).map { LyricWord(at: 20 + Double($0) * 0.5, text: "word\($0)", end: nil) }
        let runs = [CGRect(x: 0, y: 0, width: 150, height: 22), CGRect(x: 0, y: 22, width: 90, height: 22)]
        assertMatchesRenderer(words: words, end: 24.2, runs: runs, full: nil)
        let clock = SongClock(position: 22, atMono: 500, rate: 1, cap: nil)
        let plan = KaraokePlan.make(
            runs: runs, full: nil, sweep: LiveSweep(words: words, end: 24.2, clock: clock), fraction: 0, monoNow: 500
        )
        XCTAssertEqual(plan[0].width(atMono: 500), 120, accuracy: 0.0001, "half sung is half of both rows' 240 pt")
        XCTAssertEqual(plan[1].width(atMono: 500), 0, accuracy: 0.0001, "and the bottom row untouched")
    }

    /// A line cut short by its line limit maps the edge onto the whole line
    /// (G-038): half sung lights everything shown when the whole is twice it.
    func testTheKeyframesFollowTheWholeLineWhenTruncated() {
        let words = (0..<6).map { LyricWord(at: Double($0), text: "longword\($0)", end: nil) }
        let runs = [CGRect(x: 0, y: 0, width: 100, height: 20)]
        assertMatchesRenderer(words: words, end: 6, runs: runs, full: 250)
    }

    /// A song played faster or slower runs its clock at that rate, and the
    /// keyframes with it.
    func testTheKeyframesFollowTheSongsRate() {
        let words = [
            LyricWord(at: 10, text: "I", end: 10.2),
            LyricWord(at: 10.2, text: "get", end: 10.8),
            LyricWord(at: 11.5, text: "up,", end: 12.0),
            LyricWord(at: 12.0, text: "dressed", end: nil),
        ]
        let runs = [CGRect(x: 0, y: 0, width: 90, height: 20), CGRect(x: 0, y: 20, width: 70, height: 20)]
        for rate in [0.5, 1.5, 2] {
            assertMatchesRenderer(words: words, end: 13.5, runs: runs, full: nil, rate: rate)
        }
    }

    /// A word that takes no time lights at once: two keyframes at one moment,
    /// not a ramp across the next frame (the lab's L5 blink, 0.099 to 0.5).
    func testAZeroLengthWordLightsAtOnce() {
        let words = [LyricWord(at: 0, text: "ab", end: 0), LyricWord(at: 0, text: "cd", end: 0.5)]
        assertMatchesRenderer(words: words, end: 1, runs: [CGRect(x: 0, y: 0, width: 100, height: 20)], full: nil, from: -0.2)
    }

    /// At the track's end the clock stops, and so does the edge: every 2 ms
    /// up to the end and long after it, the renderer's width at the capped
    /// position.
    func testTheEdgeStopsWhereTheTrackEnds() {
        let words = (0..<4).map { LyricWord(at: 10 + Double($0), text: "w\($0)", end: nil) }
        let runs = [CGRect(x: 0, y: 0, width: 60, height: 20), CGRect(x: 0, y: 20, width: 40, height: 20)]
        let clock = SongClock(position: 10, atMono: 0, rate: 1, cap: 12)
        let plan = KaraokePlan.make(
            runs: runs, full: nil, sweep: LiveSweep(words: words, end: 14, clock: clock), fraction: 0, monoNow: 0
        )
        var worst: CGFloat = 0
        for step in 0...2_000 {
            let mono = Double(step) * 0.002
            let expected = Self.rendererWidths(words: words, end: 14, at: min(10 + mono, 12), runs: runs, full: nil)
            for (run, want) in zip(plan, expected) { worst = max(worst, abs(run.width(atMono: mono) - want)) }
        }
        XCTAssertLessThan(worst, 0.01, "the edge left the renderer's by \(worst) pt")
        XCTAssertEqual(plan[0].width(atMono: 2) + plan[1].width(atMono: 2), 50, accuracy: 0.0001)
        XCTAssertEqual(
            plan[0].width(atMono: 600) + plan[1].width(atMono: 600), 50, accuracy: 0.0001,
            "a capped song never sings past its end"
        )
    }

    /// With no clock — paused, or the song held while the next one loads —
    /// the edge stands at the published fraction and nothing is animated.
    func testAStillSongDrawsThePublishedFraction() {
        let words = (0..<4).map { LyricWord(at: Double($0), text: "w\($0)", end: nil) }
        let runs = [CGRect(x: 0, y: 0, width: 80, height: 20), CGRect(x: 0, y: 20, width: 40, height: 20)]
        let plan = KaraokePlan.make(
            runs: runs, full: nil, sweep: LiveSweep(words: words, end: 4, clock: nil), fraction: 0.75, monoNow: 9
        )
        XCTAssertEqual(plan.map(\.start), [80, 10])
        XCTAssertTrue(plan.allSatisfy(\.keys.isEmpty), "a still song asks Core Animation for nothing")
    }

    /// The keyframes Core Animation is given are the plan's, in the layer's
    /// time: normalised over the run, linear, and held once they end. Core
    /// Animation itself, asked for the bar's width at moments through the
    /// line, answers what the plan says, jumps and plateaus included.
    func testTheAnimationIsThePlan() async throws {
        let words = [
            LyricWord(at: 0, text: "ab", end: 1), LyricWord(at: 1, text: "cd", end: 1),
            LyricWord(at: 1.4, text: "ef", end: 2),
        ]
        let runs = [CGRect(x: 0, y: 0, width: 60, height: 20), CGRect(x: 0, y: 20, width: 40, height: 20)]
        let clock = SongClock(position: 0.25, atMono: 100, rate: 1, cap: nil)
        let plan = KaraokePlan.make(
            runs: runs, full: nil, sweep: LiveSweep(words: words, end: 2, clock: clock), fraction: 0, monoNow: 100
        )
        // A layer has a presentation copy only once it is in a tree that is
        // drawn.
        let window = present(Color.clear, size: CGSize(width: 100, height: 40))
        defer { window.orderOut(nil) }
        let tree = try XCTUnwrap(window.contentView?.layer)
        for run in plan {
            let animation = try XCTUnwrap(run.animation(beginTime: 7))
            let first = try XCTUnwrap(run.keys.first), last = try XCTUnwrap(run.keys.last)
            let values = try XCTUnwrap(animation.values as? [CGFloat])
            let times = try XCTUnwrap(animation.keyTimes?.map(\.doubleValue))
            XCTAssertEqual(values, run.keys.map(\.width), "every key's width, in order")
            XCTAssertEqual(times.count, run.keys.count)
            for (time, key) in zip(times, run.keys) {
                XCTAssertEqual(first.mono + time * animation.duration, key.mono, accuracy: 1e-9, "every key's moment")
            }
            XCTAssertEqual(animation.duration, last.mono - first.mono, accuracy: 1e-9)

            // Core Animation's own reading, on a layer whose clock is stopped
            // at the moment asked about.
            let bar = CALayer()
            bar.bounds = CGRect(x: 0, y: 0, width: run.start, height: run.rect.height)
            bar.speed = 0
            tree.addSublayer(bar)
            defer { bar.removeFromSuperlayer() }
            bar.add(try XCTUnwrap(run.animation(beginTime: 1_000)), forKey: KaraokeTrackView.sweepKey)
            try await AXProbe.wait(0.05)
            var step = 0
            while true {
                let offset = Double(step) * 0.004
                step += 1
                guard offset <= animation.duration + 0.2 else { break }
                bar.timeOffset = 1_000 + offset
                CATransaction.flush()
                let drawn = try XCTUnwrap(bar.presentation(), "no presentation layer").bounds.width
                let planned = run.width(atMono: first.mono + offset)
                if run.keys.contains(where: { abs($0.mono - (first.mono + offset)) < 1e-6 }) { continue }
                XCTAssertEqual(drawn, planned, accuracy: 0.01, "Core Animation drew \(drawn) pt at +\(offset) s")
            }
        }
        let animation = try XCTUnwrap(plan[0].animation(beginTime: 7))
        XCTAssertEqual(animation.keyPath, "bounds.size.width")
        XCTAssertEqual(animation.beginTime, 7)
        XCTAssertEqual(animation.calculationMode, .linear)
        XCTAssertEqual(animation.fillMode, .forwards)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        let values = try XCTUnwrap(animation.values as? [CGFloat])
        let times = try XCTUnwrap(animation.keyTimes?.map(\.doubleValue))
        XCTAssertEqual(values.first ?? -1, 100.0 / 12, accuracy: 0.0001, "a quarter into the first of three words")
        XCTAssertEqual(values.last ?? -1, 60, accuracy: 0.0001, "the top row full")
        XCTAssertEqual(times.first ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(times.last ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(times, times.sorted(), "key times never run backwards")
    }

    // MARK: On screen

    /// The sung line on screen: the bright copy sits in a layer whose bars are
    /// the line's runs, each with its keyframes, and SwiftUI asks for no
    /// display frame to move them. A tick with the same clock leaves the
    /// running animation alone; a re-anchor replaces it.
    func testTheSungLineRunsOnCoreAnimation() async throws {
        let words = (0..<6).map { LyricWord(at: 10 + Double($0) * 0.5, text: "word\($0)", end: nil) }
        let host = Host()
        host.input = .init(
            words: words, clock: SongClock(position: 11, atMono: SongClock.hostNow(), rate: 1, cap: nil)
        )
        let window = present(host.view, size: CGSize(width: 220, height: 60))
        defer { window.orderOut(nil) }
        let track = try await settledTrack(in: window)
        XCTAssertGreaterThan(track.barCount, 0, "the line's runs reached the layer")
        XCTAssertNotNil(track.runningAnimation, "the sweep is Core Animation's")
        XCTAssertFalse(track.isAccessibilityElement(), "VoiceOver would read the line twice")
        XCTAssertEqual(track.accessibilityChildren()?.count ?? 0, 0, "VoiceOver would read the line twice")
        let installs = track.installs

        // A tick: the same clock read again a tenth of a second later.
        host.input?.fraction = 0.3
        host.input?.clock = SongClock(position: 11.1, atMono: host.input!.clock!.atMono + 0.1, rate: 1, cap: nil)
        try await AXProbe.wait(0.2)
        XCTAssertEqual(track.installs, installs, "a tick re-aimed an animation that was right")
        XCTAssertNotNil(track.runningAnimation)

        // A correction of 50 ms is a different line, and the edge follows it.
        host.input?.clock = SongClock(position: 11.15, atMono: host.input!.clock!.atMono, rate: 1, cap: nil)
        try await AXProbe.wait(0.2)
        XCTAssertEqual(track.installs, installs + 1, "a re-anchored clock left the edge on the old one")
        XCTAssertNotNil(track.runningAnimation)

        // Paused: the edge stands still where it was published.
        host.input?.clock = nil
        try await AXProbe.wait(0.2)
        XCTAssertNil(track.runningAnimation, "a paused song is still animating")
    }

    /// The bars are where the runs are: a two-row line's first bar is over
    /// its top row, and the layer they are laid out in draws top-down, so
    /// what is top in the layer is top on screen.
    func testTheBarsSitOverTheirRows() async throws {
        let words = (0..<12).map { LyricWord(at: Double($0) * 0.3, text: "word\($0)", end: nil) }
        let host = Host()
        host.input = .init(words: words, clock: nil, fraction: 1, lineLimit: 2)
        let window = present(host.view, size: CGSize(width: 160, height: 80))
        defer { window.orderOut(nil) }
        let track = try await settledTrack(in: window)
        let bars = track.barFrames
        let rows = Set(bars.map { $0.minY.rounded() }).sorted()
        XCTAssertGreaterThanOrEqual(rows.count, 2, "the line wrapped to two rows, \(bars)")
        XCTAssertEqual(try XCTUnwrap(bars.first).minY, rows[0], accuracy: 1, "the first run is the top row")
        XCTAssertTrue(bars.allSatisfy { $0.maxY <= track.bounds.height + 1 }, "a bar left the line, \(bars)")
        XCTAssertTrue(
            try XCTUnwrap(track.layer).contentsAreFlipped(),
            "the bars are laid out top-down, so the layer has to draw top-down"
        )
    }

    // MARK: - Harness

    private func playing(
        now: @escaping () -> TimeInterval, elapsed: TimeInterval, duration: TimeInterval, rate: Double
    ) -> MediaController {
        let media = MediaController()
        media.lyricsShown = { false }
        media.monotonicNow = now
        var snapshot = NowPlayingFeed.Snapshot.playing(elapsed: elapsed, duration: duration)
        snapshot.rate = rate
        media.apply(snapshot)
        return media
    }

    /// The width the renderer lit at song time `t`, run by run.
    private static func rendererWidths(
        words: [LyricWord], end: TimeInterval, at t: TimeInterval, runs: [CGRect], full: CGFloat?
    ) -> [CGFloat] {
        let total = runs.reduce(0) { $0 + $1.width }
        let fraction = LyricSweep.wordFraction(words: words, at: t, lineEnd: end)
        var remaining = KaraokeRenderer.litWidth(fraction: fraction, visible: total, full: full ?? total)
        return runs.map { run in
            let lit = min(max(remaining, 0), run.width)
            remaining -= lit
            return lit
        }
    }

    /// Samples the line every 2 ms, from `from` seconds before its first word
    /// to past its end, against the renderer.
    private func assertMatchesRenderer(
        words: [LyricWord], end: TimeInterval, runs: [CGRect], full: CGFloat?, from: TimeInterval = 0,
        rate: Double = 1, file: StaticString = #filePath, line: UInt = #line
    ) {
        let start = (words.first?.at ?? 0) + from
        // A clock read mid-line, on a monotonic clock that is not the song's.
        let monoNow: TimeInterval = 4_321
        let clock = SongClock(position: start, atMono: monoNow, rate: rate, cap: nil)
        let plan = KaraokePlan.make(
            runs: runs, full: full, sweep: LiveSweep(words: words, end: end, clock: clock), fraction: 0, monoNow: monoNow
        )
        XCTAssertEqual(plan.count, runs.count, file: file, line: line)
        // Exactly at a stamp the renderer and the keyframes may round to either
        // side of a word that takes no time; a microsecond off it they agree.
        let stamps = words.flatMap { [$0.at] + ($0.end.map { [$0] } ?? []) } + [end]
        var worst: CGFloat = 0
        var step = 0
        while true {
            let t = start + Double(step) * 0.002
            step += 1
            guard t <= end + 0.5 else { break }
            if stamps.contains(where: { abs($0 - t) < 1e-6 }) { continue }
            let expected = Self.rendererWidths(words: words, end: end, at: t, runs: runs, full: full)
            for (run, want) in zip(plan, expected) {
                worst = max(worst, abs(run.width(atMono: monoNow + (t - start) / rate) - want))
            }
        }
        XCTAssertLessThan(
            worst, 0.01, "the keyframes left the renderer's edge by \(worst) pt at rate \(rate)", file: file, line: line
        )
    }

    private func present(_ view: some View, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        window.orderFrontRegardless()
        return window
    }

    private func settledTrack(in window: NSWindow) async throws -> KaraokeTrackView {
        for _ in 0..<30 {
            try await AXProbe.wait(0.05)
            if let track = window.contentView.flatMap(Self.find), track.barCount > 0 { return track }
        }
        // A failure, not a skip: a sweep that never reaches the layer is the
        // regression these tests are here for.
        struct NeverLaidOut: Error {}
        XCTFail("the track never laid out")
        throw NeverLaidOut()
    }

    private static func find(_ view: NSView) -> KaraokeTrackView? {
        if let track = view as? KaraokeTrackView { return track }
        for child in view.subviews { if let track = find(child) { return track } }
        return nil
    }

    /// A sung line whose inputs a test can change after it is on screen.
    @MainActor
    private final class Host: ObservableObject {
        struct Input {
            var words: [LyricWord]
            var clock: SongClock?
            var fraction: Double = 0
            var lineLimit = 1
        }
        @Published var input: Input?

        var view: some View { HostView(host: self) }

        private struct HostView: View {
            @ObservedObject var host: Host
            var body: some View {
                if let input = host.input {
                    KaraokeText(
                        text: input.words.map(\.text).joined(separator: " "),
                        fraction: input.fraction,
                        sweep: LiveSweep(words: input.words, end: (input.words.last?.at ?? 0) + 1, clock: input.clock),
                        font: .system(size: 15, weight: .bold),
                        lineLimit: input.lineLimit
                    )
                }
            }
        }
    }
}

private extension NowPlayingFeed.Snapshot {
    static func playing(elapsed: TimeInterval, duration: TimeInterval) -> Self {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Track"
        snapshot.artist = "Artist"
        snapshot.album = "Album"
        snapshot.duration = duration
        snapshot.elapsed = elapsed
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 1
        return snapshot
    }
}
