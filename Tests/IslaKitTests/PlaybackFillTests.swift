import QuartzCore
import SwiftUI
import XCTest
@testable import IslaKit

/// The playback bar's fill on Core Animation (Batch 20, 2026-10-30).
///
/// The fill was a SwiftUI shape the position sized, so every 0.1 s tick
/// re-ran the scrubber and drew the panel again to move it a fraction of a
/// pixel. It is now one animation from where the song is to where it ends.
/// These hold that the animation puts the bar where the old shape put it at
/// every moment, and that it is laid again only when the clock changes course.
@MainActor
final class PlaybackFillTests: XCTestCase {
    private static func input(_ motion: PlaybackClock.Motion, duration: TimeInterval = 200) -> PlaybackFill.Input {
        .init(motion: motion, duration: duration, width: 300, height: 7, radius: 3.5, floor: 7)
    }

    /// What the SwiftUI shape drew: the position's share of the width, never
    /// thinner than the bar is tall, and nothing at all before the song starts.
    private static func shapeWidth(_ position: TimeInterval, duration: TimeInterval) -> (width: CGFloat, shown: Bool) {
        let filled = 300 * CGFloat(min(max(position / duration, 0), 1))
        return (max(filled, 7), filled > 0)
    }

    func testAStillBarIsTheShapeTheScrubberDrew() {
        for position in [0.0, 1.0, 4.0, 100.0, 200.0, 250.0] {
            let plan = PlaybackFill.plan(Self.input(.still(position)), monoNow: 5_000)
            let shape = Self.shapeWidth(position, duration: 200)
            XCTAssertEqual(plan.run.start, shape.width, accuracy: 1e-9, "at \(position) s")
            XCTAssertEqual(plan.visible, shape.shown, "at \(position) s")
            XCTAssertTrue(plan.run.keys.isEmpty, "a still bar moves")
        }
    }

    /// Moving, at every moment from now to past the end, the run's width is
    /// the shape's width at the clock's position, the floor included.
    func testAMovingBarIsTheShapeAtEveryMoment() throws {
        for (start, rate) in [(0.5, 1.0), (10.0, 1.0), (60.0, 1.5), (199.0, 1.0)] {
            let clock = SongClock(position: start, atMono: 5_000, rate: rate, cap: 200)
            let plan = PlaybackFill.plan(Self.input(.moving(clock)), monoNow: 5_000)
            XCTAssertTrue(plan.visible)
            XCTAssertNotNil(plan.run.animation(beginTime: 0), "a moving bar has no animation")
            var offset = 0.0
            while offset <= (200 - start) / rate + 2 {
                let mono = 5_000 + offset
                let shape = Self.shapeWidth(clock.position(at: mono), duration: 200)
                XCTAssertEqual(
                    plan.run.width(atMono: mono), shape.width, accuracy: 1e-6,
                    "from \(start) s at \(rate)x, +\(offset) s"
                )
                offset += 0.05
            }
        }
    }

    /// A held song longer than the clock's cap stops where the clock does,
    /// and a still or reversed clock does not move the bar.
    func testTheBarStopsWhereTheClockStops() {
        let capped = SongClock(position: 100, atMono: 0, rate: 1, cap: 150)
        let plan = PlaybackFill.plan(Self.input(.moving(capped)), monoNow: 0)
        XCTAssertEqual(plan.run.width(atMono: 1_000), 225, accuracy: 1e-9, "150 s of 200 is three quarters")
        for rate in [0.0, -1.0] {
            let stopped = PlaybackFill.plan(
                Self.input(.moving(SongClock(position: 100, atMono: 0, rate: rate, cap: 200))), monoNow: 0
            )
            XCTAssertTrue(stopped.run.keys.isEmpty, "a clock at \(rate)x moved the bar")
            XCTAssertEqual(stopped.run.start, 150, accuracy: 1e-9)
        }
    }

    /// The view lays the bar once per course: a reading that agrees with the
    /// one drawn (every tick hands a fresh one) lays nothing; a seek, a pause
    /// and a new width do.
    func testTheBarIsLaidOncePerCourse() async throws {
        let window = present()
        defer { window.orderOut(nil) }
        let view = PlaybackFillView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 7)
        window.contentView?.addSubview(view)
        let now = SongClock.hostNow()
        let clock = SongClock(position: 50, atMono: now, rate: 1, cap: 200)
        view.update(Self.input(.moving(clock)), color: .white)
        XCTAssertEqual(view.installs, 1)
        let animation = try XCTUnwrap(view.runningAnimation as? CAKeyframeAnimation, "the moving bar has no animation")
        XCTAssertEqual(animation.keyPath, "bounds.size.width")
        XCTAssertEqual(view.barWidth, 75, accuracy: 0.01, "a quarter of the way in")
        for step in 1...20 {
            let later = now + 0.1 * Double(step)
            view.update(Self.input(.moving(SongClock(position: 50 + 0.1 * Double(step), atMono: later, rate: 1, cap: 200))), color: .white)
        }
        XCTAssertEqual(view.installs, 1, "a tick's fresh reading of the same clock laid the bar again")

        view.update(Self.input(.moving(SongClock(position: 120, atMono: now + 3, rate: 1, cap: 200))), color: .white)
        XCTAssertEqual(view.installs, 2, "a seek did not move the bar")
        view.update(Self.input(.still(120)), color: .white)
        XCTAssertEqual(view.installs, 3, "a pause did not stop the bar")
        XCTAssertNil(view.runningAnimation, "a paused bar is still animating")
        XCTAssertEqual(view.barWidth, 180, accuracy: 0.01)
        view.update(Self.input(.still(0)), color: .white)
        XCTAssertEqual(view.barOpacity, 0, "nothing is lit at the start, and the floor showed anyway")
    }

    /// The fill hears from SwiftUI only when its course changes, so a bar
    /// that lost its animation would stay still until the next seek or
    /// pause. Moving to another window is when AppKit drops it, and the view
    /// lays it again there.
    func testABarThatLostItsAnimationIsLaidAgainInItsNewWindow() throws {
        let first = present(), second = present()
        defer {
            first.orderOut(nil)
            second.orderOut(nil)
        }
        let view = PlaybackFillView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 7)
        first.contentView?.addSubview(view)
        view.update(Self.input(.moving(SongClock(position: 50, atMono: SongClock.hostNow(), rate: 1, cap: 200))), color: .white)
        XCTAssertEqual(view.installs, 1)
        view.dropAnimationForTests()
        second.contentView?.addSubview(view)
        XCTAssertEqual(view.installs, 2, "a moved bar with no animation was left still")
        XCTAssertNotNil(view.runningAnimation)
        second.contentView?.addSubview(NSView())
        view.removeFromSuperview()
        first.contentView?.addSubview(view)
        XCTAssertEqual(view.installs, 2, "a bar still running was laid again only for moving")
    }

    /// A layer has a presentation copy only once it is in a tree that is
    /// drawn: a borderless window far off every display.
    private func present() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 320, height: 20),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 20))
        window.contentView?.wantsLayer = true
        window.orderFrontRegardless()
        return window
    }
}
