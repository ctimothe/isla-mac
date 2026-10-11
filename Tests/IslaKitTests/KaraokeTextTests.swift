import SwiftUI
import XCTest
@testable import IslaKit

@MainActor
final class KaraokeTextTests: XCTestCase {

    /// The fraction is animatable, which is exactly why the view has to say,
    /// out loud, that it never animates.
    ///
    /// `TextRenderer` inherits `Animatable`, and `animatableData` maps onto the
    /// fraction. That mapping once carried the sweep: a `.linear(duration: 0.25)`
    /// interpolated it between position publishes, and because every 0.1 s
    /// publish retargeted a ramp that had not finished, the lit edge trailed the
    /// voice by 175 ms at the median (the lyric lab's L5, F-011). The edge is
    /// placed by the clock on every frame now, so an animation can only put it
    /// behind — but any animated transaction from outside (the stage's page turn
    /// runs in one) would still reach an animatable fraction unless the view
    /// pins it with `sweepAnimation`, which is nil. Wiring, asserted as wiring.
    func testTheRendererAnimatesOnTheFraction() {
        var renderer = KaraokeRenderer(fraction: 0.25, accent: .white, base: .gray)
        XCTAssertEqual(renderer.animatableData, 0.25, accuracy: 0.0001)
        renderer.animatableData = 0.75
        XCTAssertEqual(renderer.fraction, 0.75, accuracy: 0.0001)
    }

    /// A clock-driven sweep has nothing to interpolate, and nothing else may
    /// interpolate it either.
    ///
    /// The animation this replaced was a quarter-second ramp re-aimed every
    /// tenth of a second: it never arrived, and the edge sat two and a half
    /// ticks of motion behind the clock (F-011, L-10). Every case is held here,
    /// not just the clock-driven one, because each static case — line timing at
    /// 1, a paused song, Reduce Motion — changes its fraction only by a cut, and
    /// a ramp on a cut is the same lag in miniature. Should one ever come back,
    /// it may not outlast a tick of `MediaController.positionTickInterval`.
    func testAClockDrivenSweepHasNoImplicitAnimation() {
        XCTAssertNil(KaraokeText.sweepAnimation(reduceMotion: false, clockDriven: true))
        for reduceMotion in [false, true] {
            for clockDriven in [false, true] {
                let animation = KaraokeText.sweepAnimation(reduceMotion: reduceMotion, clockDriven: clockDriven)
                XCTAssertNil(
                    animation,
                    "no sweep animates (reduceMotion \(reduceMotion), clockDriven \(clockDriven)); "
                        + "anything longer than \(MediaController.positionTickInterval) s trails the clock"
                )
            }
        }
    }

    /// On a truncated line the edge maps onto the whole line, not onto the
    /// part that fits.
    ///
    /// The fraction is the share of the whole line sung — `wordFraction` counts
    /// every word, the ones past the ellipsis included. The renderer used to
    /// spread it over the runs actually laid out, so on a lock-card line cut to
    /// one row the edge stood at half the *visible* width when the voice was
    /// half way through the *whole* line: well behind it, and the hidden half
    /// never had a place to be sung (G-038, corrected on re-read: behind, not
    /// ahead). The whole line is 250 pt here and 100 pt of it shows.
    func testTheLitWidthFollowsTheWholeLineWhenTruncated() {
        XCTAssertEqual(KaraokeRenderer.litWidth(fraction: 0.5, visible: 100, full: 250), 100, accuracy: 0.0001,
                       "half of 250 pt is past everything shown, so all of it is lit")
        XCTAssertEqual(KaraokeRenderer.litWidth(fraction: 0.2, visible: 100, full: 250), 50, accuracy: 0.0001)
        // A line that fits is the old mapping exactly.
        XCTAssertEqual(KaraokeRenderer.litWidth(fraction: 0.3, visible: 200, full: 200), 60, accuracy: 0.0001)
        // Clamped at both ends, and never lit past what is drawn.
        XCTAssertEqual(KaraokeRenderer.litWidth(fraction: -1, visible: 100, full: 250), 0, accuracy: 0.0001)
        XCTAssertEqual(KaraokeRenderer.litWidth(fraction: 2, visible: 100, full: 250), 100, accuracy: 0.0001)
        // A measurement that has not caught up with a new line (narrower than
        // what is laid out) cannot leave the end of a sung line dark.
        XCTAssertEqual(KaraokeRenderer.litWidth(fraction: 1, visible: 100, full: 80), 100, accuracy: 0.0001)
    }

    /// The renderer itself honours the whole-line width it is handed: the
    /// same truncated line, a quarter sung, lights about half of what shows
    /// when the whole line is twice the visible width, and about a quarter
    /// when it is told nothing.
    func testATruncatedLineIsLitAgainstTheWholeLine() throws {
        let told = try truncatedShare(fraction: 0.25, fullWidth: 300)
        let untold = try truncatedShare(fraction: 0.25, fullWidth: nil)
        XCTAssertGreaterThan(told, 0.38, "a quarter of a 300 pt line is about half of 150 pt shown, was \(told)")
        XCTAssertLessThan(told, 0.68, "and not the whole of it, was \(told)")
        XCTAssertLessThan(untold, 0.36, "with no width the old mapping stands, was \(untold)")
    }

    /// The frame clock reads the running clock, not the last tick.
    ///
    /// This is what moves the edge between publishes. `MediaController.position`
    /// stands still between ticks; `extrapolatedPosition` does not. A sweep
    /// read from the first would step with the tick — the stepping the old
    /// ramp was put there to hide — and one read from the second moves on
    /// every frame and stands where the voice is.
    func testTheFrameClockReadsTheRunningClockBetweenTicks() throws {
        final class Clock { var now: TimeInterval = 1_000 }
        let clock = Clock()
        let media = MediaController()
        media.lyricsShown = { false }
        media.monotonicNow = { clock.now }
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Track"
        snapshot.artist = "Artist"
        snapshot.album = "Album"
        snapshot.duration = 200
        snapshot.elapsed = 10
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 1
        media.apply(snapshot)
        let base = media.extrapolatedPosition()

        // Two words across a second from where the clock stands.
        let line = LyricsStore.Line(at: base, text: "ab cd", words: [
            LyricWord(at: base, text: "ab", end: base + 0.5),
            LyricWord(at: base + 0.5, text: "cd", end: base + 1),
        ])
        let frameClock = try XCTUnwrap(LyricSweep.frameClock(media: media, lead: 0), "a playing song has a frame clock")
        let sweep = try XCTUnwrap(
            LyricSweep.liveFraction(line: line, end: base + 1, wordTiming: true, clock: frameClock),
            "a word-timed line being sung is clock-driven"
        )

        clock.now += 0.25
        XCTAssertEqual(media.position, 10, accuracy: 0.01, "no tick ran, so nothing was published")
        XCTAssertEqual(sweep(), 0.25, accuracy: 0.001, "half through the first of two equal words")
        clock.now += 0.5
        XCTAssertEqual(sweep(), 0.75, accuracy: 0.001)
        XCTAssertEqual(frameClock(), base + 0.75, accuracy: 0.0001, "and the moment it read is the running clock")

        // The lead is added to the moment, as every surface reads it.
        let led = try XCTUnwrap(LyricSweep.frameClock(media: media, lead: 0.2))
        XCTAssertEqual(led(), base + 0.95, accuracy: 0.0001)

        // Nothing moves a sweep that line timing draws whole, or a credit.
        XCTAssertNil(LyricSweep.liveFraction(line: line, end: base + 1, wordTiming: false, clock: frameClock))
        let plain = LyricsStore.Line(at: base, text: "ab cd")
        XCTAssertNil(LyricSweep.liveFraction(line: plain, end: base + 1, wordTiming: true, clock: frameClock))
        var credit = line
        credit.isCredit = true
        XCTAssertNil(LyricSweep.liveFraction(line: credit, end: base + 1, wordTiming: true, clock: frameClock))
        XCTAssertNil(LyricSweep.liveFraction(line: line, end: base + 1, wordTiming: true, clock: nil))

        // Paused, there is no clock to read: the sweep stands still and no
        // frame callback runs for it.
        snapshot.isPlaying = false
        snapshot.rate = 0
        snapshot.elapsed = base + 0.75
        snapshot.takenAt = Date()
        media.apply(snapshot)
        XCTAssertNil(LyricSweep.frameClock(media: media, lead: 0), "a paused song has no frame clock")
    }

    /// A wrapped line fills in reading order: the top row completely, before the
    /// bottom row is touched at all.
    ///
    /// This is the assertion the renderer this replaced could not pass. A single
    /// rectangle mask over the whole text lights the left half of *every* row at
    /// once, so at half-swept a two-row line came out half-lit on both rows — the
    /// reading edge in two places, neither of them where the voice was.
    func testAWrappedLineFillsTheTopRowBeforeTheBottom() throws {
        let halfway = try lit(fraction: 0.5)
        XCTAssertGreaterThan(
            halfway.top, 0.75,
            "at half swept the top row should be essentially complete, was \(halfway.top)"
        )
        XCTAssertLessThan(
            halfway.bottom, 0.15,
            "the bottom row must be untouched while the top is still filling, was \(halfway.bottom)"
        )

        let none = try lit(fraction: 0)
        XCTAssertLessThan(none.top, 0.05)
        XCTAssertLessThan(none.bottom, 0.05)

        let all = try lit(fraction: 1)
        XCTAssertGreaterThan(all.top, 0.75)
        XCTAssertGreaterThan(all.bottom, 0.6)
    }

    // MARK: - Harness

    /// A line far too long for 150 pt, cut to one row, swept red over blue
    /// through the renderer directly so the whole-line width can be handed
    /// in; the share of the row's ink that came out red.
    private func truncatedShare(fraction: Double, fullWidth: CGFloat?) throws -> Double {
        let view = Text("the quick brown fox jumps over the lazy dog and keeps on running")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .textRenderer(KaraokeRenderer(fraction: fraction, accent: .red, base: .blue, fullWidth: fullWidth))
            .frame(width: 150, alignment: .leading)
            .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the line must render")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var red = 0
        var blue = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                let r = c.redComponent, b = c.blueComponent
                guard r > 0.18 || b > 0.18 else { continue }
                if r > b { red += 1 } else if b > r { blue += 1 }
            }
        }
        let ink = red + blue
        return ink == 0 ? 0 : Double(red) / Double(ink)
    }

    /// Renders a deliberately wrapping line with a pure-red sweep over pure-blue
    /// base, and reports the share of each row's ink that came out red.
    private func lit(fraction: Double) throws -> (top: Double, bottom: Double) {
        let view = KaraokeText(
            text: "the quick brown fox jumps over the lazy dog",
            fraction: fraction,
            accent: .red,
            font: .system(size: 15, weight: .bold),
            base: .blue,
            lineLimit: 2
        )
        .frame(width: 150, alignment: .leading)
        .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the line must render")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 20, "the text must have wrapped to two rows")

        func share(rows: Range<Int>) -> Double {
            var red = 0
            var blue = 0
            for y in rows {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                    let r = c.redComponent, b = c.blueComponent
                    guard r > 0.18 || b > 0.18 else { continue }
                    if r > b { red += 1 } else if b > r { blue += 1 }
                }
            }
            let ink = red + blue
            return ink == 0 ? 0 : Double(red) / Double(ink)
        }

        let mid = bitmap.pixelsHigh / 2
        return (share(rows: 0..<mid), share(rows: mid..<bitmap.pixelsHigh))
    }
}
