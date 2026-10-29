import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// A scrolling line travels on Core Animation (Batch 11, 2026-10-29).
///
/// The marquee was a SwiftUI offset animation, and SwiftUI animates on the
/// main thread: with the player open on a line too long for its room, which
/// with lyrics on is many songs, every frame of every pass laid out and
/// re-rendered the whole panel. The idle-cost lab put it at 100–121 main-thread
/// wake-ups a second and 4–5 % of a core, against 0.7 and 0.05 % now
/// (`Scripts/measure-idle-lab.sh`, `lyrics-arrive`). These hold the mechanism:
/// a long line is a layer with one repeating animation, the loop is the one the
/// SwiftUI version ran, and the caller's font reaches the drawn line.
@MainActor
final class MarqueeTrackTests: XCTestCase {
    private static let long = "Lover, You Should've Come Over – Jeff Buckley"
    /// Not the player's 13 pt, which is also a hosting view's default: a
    /// font that did not reach the drawn line would not show at that size.
    private static let size: CGFloat = 20
    private static let font = NSFont.systemFont(ofSize: size, weight: .medium)

    private final class Words: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    private struct Line: View {
        @ObservedObject var words: Words
        let room: CGFloat
        var isActive = true

        var body: some View {
            MarqueeLine(room: room, isActive: isActive, text: words.text) { Text(words.text) }
                .font(.system(size: MarqueeTrackTests.size, weight: .medium))
                .lineLimit(1)
        }
    }

    private static func tracks(in view: NSView) -> [MarqueeTrackView] {
        (view as? MarqueeTrackView).map { [$0] } ?? view.subviews.flatMap { tracks(in: $0) }
    }

    /// On screen, far off every display and never key, so the layers are the
    /// ones the window server would composite.
    private func present(_ line: Line) async -> AXProbe.Host {
        let host = AXProbe.present(line, size: CGSize(width: line.room, height: 40))
        host.hosting.wantsLayer = true
        host.window.orderFrontRegardless()
        await AXProbe.wait(0.2)
        return host
    }

    func testALongLineTravelsOnCoreAnimationAfterItsRest() async throws {
        let host = await present(Line(words: Words(Self.long), room: 160))
        defer { host.window.orderOut(nil) }
        let track = try XCTUnwrap(Self.tracks(in: host.hosting).first, "a line longer than its room drew no track")
        let layer = try XCTUnwrap(track.layer)
        let travel = try XCTUnwrap(
            layer.animation(forKey: MarqueeTrackView.travelKey) as? CAKeyframeAnimation,
            "the track does not move"
        )
        XCTAssertEqual(travel.repeatCount, .infinity)
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        XCTAssertEqual(travel.beginTime - now, MarqueeTiming.rest, accuracy: 0.5, "it rests before its first pass")
        XCTAssertNotNil(layer.mask?.animation(forKey: MarqueeTrackView.fadeKey), "the near end never fades")

        // The caller's font reached the copies the layer moves: in any other
        // they would not be the line SwiftUI measured, and the loop's jump
        // back would show (a 9 pt font here drew 449 pt of a 879 pt pair).
        let width = (Self.long as NSString).size(withAttributes: [.font: Self.font]).width
        XCTAssertEqual(track.run?.contentWidth ?? 0, width, accuracy: 1)
        XCTAssertEqual(track.drawnWidth, 2 * (track.run?.contentWidth ?? 0) + MarqueeTiming.gap, accuracy: 1)

        // And the animation moves the line: half a second into the first
        // pass, the drawn copies stand 15 pt left of where they rested.
        await AXProbe.wait(travel.beginTime - layer.convertTime(CACurrentMediaTime(), from: nil) + 0.5)
        let shift = try XCTUnwrap(layer.presentation()?.sublayerTransform.m41)
        XCTAssertEqual(shift, -MarqueeTiming.speed * 0.5, accuracy: 4, "the line is not travelling at the reading pace")
        XCTAssertEqual(layer.sublayerTransform.m41, 0, "the line's own place is its rest")
    }

    func testALineThatFitsOrIsNotLiveDrawsNoTrack() async {
        let short = await present(Line(words: Words("Be a Ghost – M25"), room: 160))
        XCTAssertTrue(Self.tracks(in: short.hosting).isEmpty, "a line that fits was set moving")
        short.window.orderOut(nil)

        let resting = await present(Line(words: Words(Self.long), room: 160, isActive: false))
        XCTAssertTrue(Self.tracks(in: resting.hosting).isEmpty, "a line off screen or under Reduce Motion was set moving")
        resting.window.orderOut(nil)
    }

    func testANewLineStartsOverFromRest() async throws {
        let words = Words(Self.long)
        let host = await present(Line(words: words, room: 160))
        defer { host.window.orderOut(nil) }
        let first = try XCTUnwrap(Self.tracks(in: host.hosting).first?.layer?.animation(forKey: MarqueeTrackView.travelKey))
        await AXProbe.wait(0.4)
        words.text = "Hallelujah (Live at Sin-é) – Jeff Buckley, Live at Sin-é"
        await AXProbe.wait(0.2)
        let second = try XCTUnwrap(Self.tracks(in: host.hosting).first?.layer?.animation(forKey: MarqueeTrackView.travelKey))
        XCTAssertGreaterThan(second.beginTime - first.beginTime, 0.3, "the new line did not begin with a rest of its own")
    }

    /// The visual lab draws into bitmaps, which cannot draw a layer: there the
    /// line is SwiftUI's picture of its rest.
    func testTheLabsRenderersGetTheRestingPicture() async {
        MarqueeTiming.travelsOnCoreAnimation = false
        defer { MarqueeTiming.travelsOnCoreAnimation = true }
        let host = await present(Line(words: Words(Self.long), room: 160))
        defer { host.window.orderOut(nil) }
        XCTAssertTrue(Self.tracks(in: host.hosting).isEmpty)
    }

    /// The loop is the SwiftUI one it replaced: a linear pass of the line and
    /// its gap at 30 pt a second, the jump back to the identical picture, a
    /// 2.5 s rest; the near end fades in over the pass's first 0.2 s and back
    /// over the rest's.
    func testTheLoopIsTheOneItReplaced() throws {
        let (travel, fade) = MarqueeTrackView.animations(contentWidth: 300)
        let pass = 332.0 / 30
        let cycle = pass + 2.5
        func numbers(_ values: [Any]?) -> [Double] { (values ?? []).compactMap { ($0 as? NSNumber)?.doubleValue } }

        XCTAssertEqual(travel.keyPath, "sublayerTransform.translation.x")
        XCTAssertEqual(numbers(travel.values), [0, -332, 0, 0])
        for (time, expected) in zip(numbers(travel.keyTimes), [0, pass / cycle, pass / cycle, 1]) {
            XCTAssertEqual(time, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(travel.duration, cycle, accuracy: 1e-9)

        XCTAssertEqual(fade.keyPath, "colors")
        for (time, expected) in zip(numbers(fade.keyTimes), [0, 0.2 / cycle, pass / cycle, (pass + 0.2) / cycle, 1]) {
            XCTAssertEqual(time, expected, accuracy: 1e-9)
        }
        let colors = try XCTUnwrap(fade.values as? [[CGColor]])
        XCTAssertEqual(colors.map { $0.map(\.alpha) }, [
            [1, 1, 1, 0], [0, 1, 1, 0], [0, 1, 1, 0], [1, 1, 1, 0], [1, 1, 1, 0],
        ], "at rest only the far end fades; a pass fades the near end too")
        for animation in [travel, fade] {
            XCTAssertEqual(animation.repeatCount, .infinity)
            XCTAssertFalse(animation.isRemovedOnCompletion)
        }
    }
}
