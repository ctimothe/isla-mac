import SwiftUI
import XCTest
@testable import IslaKit

/// The swipe between pages (spec §19.16), held on the pure engine: what the
/// first 10 pt decide, what never pages, how the content follows the fingers,
/// where a release lands and how it settles.
final class PageSwipeTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    /// Four pages of the widths the board gives them, so a distance between
    /// two is half of each.
    private let strip = PageStrip(pages: Surface.pages, widths: [492, 413, 560, 560])

    private func context(
        at position: CGFloat, over: Bool = true, edge: PageSwipe.StripEdge? = nil
    ) -> PageSwipe.Context {
        PageSwipe.Context(strip: strip, presented: position, over: over, stripEdge: edge)
    }

    private func scroll(
        _ dx: CGFloat, _ dy: CGFloat = 0, _ phase: ScrollSample.Phase = .changed,
        momentum: ScrollSample.Phase = .none, precise: Bool = true, at time: TimeInterval = 0
    ) -> PageScroll {
        PageScroll(deltaX: dx, deltaY: dy, phase: phase, momentumPhase: momentum, precise: precise, time: time)
    }

    /// Drives a sideways gesture past the lock on page `start`: the began, and
    /// one event that crosses the 10 pt. `toward` is the fingers' direction:
    /// negative moves the content left, toward the later pages.
    private func grabbed(at start: CGFloat, toward dx: CGFloat = -1) -> PageSwipe {
        var swipe = PageSwipe()
        _ = swipe.handle(scroll(0, 0, .began), context(at: start))
        let outcome = swipe.handle(scroll(dx < 0 ? -10 : 10, 0), context(at: start))
        XCTAssertEqual(outcome, .grab(position: start))
        return swipe
    }

    // MARK: The strip

    func testAPageRestsWhereTheOneBeforeItEndsAndItsNeighbourBegins() {
        XCTAssertEqual(strip.offset(of: 0), 0)
        XCTAssertEqual(strip.offset(of: 1), (492 + 413) / 2, accuracy: 0.0001)
        XCTAssertEqual(strip.offset(of: 1.5), (492 + 413) / 2 + (413 + 560) / 4, accuracy: 0.0001)
        XCTAssertEqual(strip.offset(of: -0.1), -49.2, accuracy: 0.0001, "past Music, in Music's own width")
        XCTAssertEqual(strip.offset(of: 3.1), strip.offset(of: 3) + 56, accuracy: 0.0001, "past Translate, in its width")
        for position in stride(from: CGFloat(-0.4), through: 3.4, by: 0.1) {
            XCTAssertEqual(strip.position(at: strip.offset(of: position)), position, accuracy: 0.0001)
        }
    }

    /// On the way between two pages they abut: the one leaving and the one
    /// arriving share an edge, and each is centred on the outline at rest.
    func testTwoPagesOnTheWayShareAnEdge() {
        for fraction in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            let position = 1 + fraction
            let width = 413 + (560 - 413) * fraction
            let leaving = strip.x(ofPage: 1, at: position, outlineWidth: width)
            let arriving = strip.x(ofPage: 2, at: position, outlineWidth: width)
            XCTAssertEqual(leaving + 413, arriving, accuracy: 0.0001, "at \(position)")
        }
        XCTAssertEqual(strip.x(ofPage: 1, at: 1, outlineWidth: 413), 0)
        XCTAssertEqual(strip.x(ofPage: 2, at: 2, outlineWidth: 560), 0)
        XCTAssertEqual(strip.mounted(at: 1), [1])
        XCTAssertEqual(strip.mounted(at: 1.3), [1, 2])
        XCTAssertEqual(strip.mounted(at: -0.2), [0])
        XCTAssertEqual(strip.mounted(at: 3.2), [3])
    }

    /// The outline between two pages: each page's size at either end, half of
    /// each half way.
    func testTheOutlineMovesBetweenTwoPagesWithTheTravel() {
        let notch = CGSize(width: 185, height: 38)
        let player = SurfaceLayout.bodySize(for: .player, bodyWidth: 560, notch: notch)
        let tray = SurfaceLayout.bodySize(for: .tray, bodyWidth: 560, notch: notch)
        let pages = Surface.pages
        func size(_ position: CGFloat) -> CGSize {
            SurfaceLayout.travelSize(pages: pages, position: position, bodyWidth: 560, notch: notch)
        }
        XCTAssertEqual(size(0), player)
        XCTAssertEqual(size(1), tray)
        XCTAssertEqual(size(0.5).width, (player.width + tray.width) / 2, accuracy: 0.0001)
        XCTAssertEqual(size(0.5).height, (player.height + tray.height) / 2, accuracy: 0.0001)
        XCTAssertEqual(size(-0.3), player, "a rubber band keeps the end page's size")
        XCTAssertEqual(size(3.3), SurfaceLayout.bodySize(for: .translate, bodyWidth: 560, notch: notch))
    }

    // MARK: Deciding

    func testTheFirstTenPointsDecide() {
        var swipe = PageSwipe()
        XCTAssertEqual(swipe.handle(scroll(-2, 0, .began), context(at: 1)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-4, -1), context(at: 1)), .pass, "6 pt: not yet")
        XCTAssertEqual(swipe.handle(scroll(-4, 0), context(at: 1)), .grab(position: 1), "10 pt sideways pages")
    }

    func testAGestureThatStartsUpOrDownNeverPages() {
        var swipe = PageSwipe()
        XCTAssertEqual(swipe.handle(scroll(-3, 0, .began), context(at: 2)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-2, 9), context(at: 2)), .pass, "more down than sideways at 10 pt")
        for _ in 0..<10 {
            XCTAssertEqual(swipe.handle(scroll(-40, 0), context(at: 2)), .pass, "the rest is the page's")
        }
        XCTAssertEqual(swipe.handle(scroll(0, 0, .ended), context(at: 2)), .pass)
        // The next gesture decides afresh.
        XCTAssertEqual(swipe.handle(scroll(0, 0, .began), context(at: 2)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-12, 0), context(at: 2)), .grab(position: 2))
    }

    func testAWheelNeverPages() {
        var swipe = PageSwipe()
        XCTAssertEqual(swipe.handle(scroll(-40, 0, .none, precise: false), context(at: 1)), .pass, "a notched wheel")
        XCTAssertEqual(swipe.handle(scroll(-40, 0, .none), context(at: 1)), .pass, "precise, but no phase")
        XCTAssertEqual(swipe.handle(scroll(-40, 0, .began, precise: false), context(at: 1)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-40, 0, .changed, precise: false), context(at: 1)), .pass)
    }

    func testAGestureThatBeginsOffThePagesNeverPages() {
        var swipe = PageSwipe()
        XCTAssertEqual(swipe.handle(scroll(0, 0, .began), context(at: 1, over: false)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-30, 0), context(at: 1, over: true)), .pass)
    }

    /// Where a gesture began owns it, as a scroll view's does: the window
    /// server latches a phased gesture to the window it began in, so a pointer
    /// that drifts off the pages before the first 10 pt still sends the rest
    /// here. Refusing then would hand the gesture to the empty window around
    /// the island, and a swipe would turn or not by a point's drift (Codex
    /// review of R8b, P1, answered).
    func testAGestureBegunOnThePagesStaysTheirsWhereverThePointerDrifts() {
        var swipe = PageSwipe()
        XCTAssertEqual(swipe.handle(scroll(-4, 0, .began), context(at: 1, over: true)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-8, 0), context(at: 1, over: false)), .grab(position: 1))
    }

    /// A gesture that ends inside its first 10 pt never paged, and every one
    /// of its events went on to the page: the page had the whole gesture, so
    /// its glide is the page's too. Swallowing it would stop a list's inertial
    /// scroll dead (Codex review of R8b, P2, answered).
    func testAGestureTooShortToDecideIsThePagesGlideAndAll() {
        var swipe = PageSwipe()
        XCTAssertEqual(swipe.handle(scroll(-3, 0, .began), context(at: 2)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-4, 0), context(at: 2)), .pass)
        XCTAssertEqual(swipe.handle(scroll(0, 0, .ended), context(at: 2)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-6, 0, .none, momentum: .began), context(at: 2)), .pass)
        XCTAssertEqual(swipe.handle(scroll(-2, 0, .none, momentum: .changed), context(at: 2)), .pass)
    }

    /// The tray's strip scrolls first: a gesture pages only when the strip
    /// was already at its end, in the direction of travel, when it began.
    func testTheStripScrollsFirst() {
        func outcome(edge: PageSwipe.StripEdge, dx: CGFloat) -> PageSwipe.Outcome {
            var swipe = PageSwipe()
            _ = swipe.handle(scroll(0, 0, .began), context(at: 1, edge: edge))
            return swipe.handle(scroll(dx, 0), context(at: 1, edge: PageSwipe.StripEdge(atStart: false, atEnd: false)))
        }
        let middle = PageSwipe.StripEdge(atStart: false, atEnd: false)
        let start = PageSwipe.StripEdge(atStart: true, atEnd: false)
        let end = PageSwipe.StripEdge(atStart: false, atEnd: true)
        XCTAssertEqual(outcome(edge: middle, dx: -12), .pass, "toward Clipboard, the strip has more")
        XCTAssertEqual(outcome(edge: middle, dx: 12), .pass, "toward Music, the strip has more")
        XCTAssertEqual(outcome(edge: end, dx: -12), .grab(position: 1), "at its end, toward Clipboard")
        XCTAssertEqual(outcome(edge: end, dx: 12), .pass, "at its end, back into the strip")
        XCTAssertEqual(outcome(edge: start, dx: 12), .grab(position: 1), "at its start, toward Music")
        XCTAssertEqual(outcome(edge: start, dx: -12), .pass)
    }

    // MARK: Tracking

    func testTheContentFollowsTheFingersOneToOne() {
        var swipe = grabbed(at: 1)
        let d = strip.distance(after: 1)
        guard case .move(let on) = swipe.handle(scroll(-100, 0), context(at: 1)) else { return XCTFail() }
        XCTAssertEqual(on, 1 + 100 / d, accuracy: 0.0001)
        guard case .move(let less) = swipe.handle(scroll(60, 3), context(at: 1)) else { return XCTFail() }
        XCTAssertEqual(less, 1 + 40 / d, accuracy: 0.0001, "back, and down is ignored")
        guard case .move(let back) = swipe.handle(scroll(80, 0), context(at: 1)) else { return XCTFail() }
        XCTAssertEqual(back, 1 - 40 / strip.distance(after: 0), accuracy: 0.0001, "past the start, toward Music")
    }

    func testPastMusicAndPastTranslateTheTravelRubberBands() {
        var first = grabbed(at: 0, toward: 1)
        guard case .move(let left) = first.handle(scroll(100, 0), context(at: 0)) else { return XCTFail() }
        XCTAssertEqual(left, -PageSwipe.rubberband(100, dimension: 492) / 492, accuracy: 0.0001)
        XCTAssertGreaterThan(left, -100 / 492, "less than the fingers")

        var last = grabbed(at: 3)
        guard case .move(let right) = last.handle(scroll(-100, 0), context(at: 3)) else { return XCTFail() }
        XCTAssertEqual(right, 3 + PageSwipe.rubberband(100, dimension: 560) / 560, accuracy: 0.0001)
    }

    /// One page from where the gesture began is as far as it goes; past it the
    /// travel resists as it does past an end.
    func testTheTravelResistsPastOnePage() {
        var swipe = grabbed(at: 0)
        let one = strip.offset(of: 1)
        guard case .move(let position) = swipe.handle(scroll(-(one + 100), 0), context(at: 0)) else { return XCTFail() }
        let expected = strip.position(at: one + PageSwipe.rubberband(100, dimension: 413))
        XCTAssertEqual(position, expected, accuracy: 0.0001)
    }

    func testTheRubberBandUndoesItself() {
        for overshoot in [CGFloat(1), 20, 100, 300] {
            let banded = PageSwipe.rubberband(overshoot, dimension: 492)
            XCTAssertEqual(PageSwipe.unband(banded, dimension: 492), overshoot, accuracy: 0.001)
        }
    }

    /// A gesture that starts while a page settles picks it up where it is on
    /// screen: no jump, and the fingers carry on from there.
    func testAGestureDuringASettleStartsWhereThePageIs() {
        var swipe = grabbed(at: 1.4)
        let d = strip.distance(after: 1)
        guard case .move(let position) = swipe.handle(scroll(-10, 0), context(at: 1.4)) else { return XCTFail() }
        XCTAssertEqual(position, 1.4 + 10 / d, accuracy: 0.0001)

        // Caught in a rubber band past Music, it does not jump either.
        var band = grabbed(at: -0.05, toward: -1)
        guard case .move(let caught) = band.handle(scroll(0, 0), context(at: -0.05)) else { return XCTFail() }
        XCTAssertEqual(caught, -0.05, accuracy: 0.0001)
    }

    // MARK: Release

    func testTheReleaseChoosesThePageNearestTheProjection() {
        // Slow, a third of the way: back.
        var slow = grabbed(at: 1)
        let d = strip.distance(after: 1)
        _ = slow.handle(scroll(-d / 3, 0, at: 0), context(at: 1))
        let back = slow.handle(scroll(0, 0, .ended, at: 1), context(at: 1))
        XCTAssertEqual(back.target, 1)
        XCTAssertEqual(back.position ?? 0, 1 + 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(back.velocity, 0)

        // Slow, two thirds of the way: on.
        var far = grabbed(at: 1)
        _ = far.handle(scroll(-2 * d / 3, 0, at: 0), context(at: 1))
        XCTAssertEqual(far.handle(scroll(0, 0, .ended, at: 1), context(at: 1)).target, 2)

        // A short flick: on, because the projection crosses the middle.
        var flick = grabbed(at: 1)
        for step in 0..<12 {
            _ = flick.handle(scroll(-5, 0, at: Double(step) / 120), context(at: 1))
        }
        let released = flick.handle(scroll(0, 0, .ended, at: 12.0 / 120), context(at: 1))
        XCTAssertEqual(released.target, 2)
        XCTAssertGreaterThan(released.velocity ?? 0, 0, "toward Clipboard")
    }

    func testAFlingTurnsOnePageAtMost() {
        var fling = grabbed(at: 1)
        for step in 0..<12 {
            _ = fling.handle(scroll(-60, 0, at: Double(step) / 120), context(at: 1))
        }
        XCTAssertEqual(fling.handle(scroll(0, 0, .ended, at: 12.0 / 120), context(at: 1)).target, 2)

        var back = grabbed(at: 2, toward: 1)
        for step in 0..<12 {
            _ = back.handle(scroll(60, 0, at: Double(step) / 120), context(at: 2))
        }
        XCTAssertEqual(back.handle(scroll(0, 0, .ended, at: 12.0 / 120), context(at: 2)).target, 1)

        var end = grabbed(at: 3)
        for step in 0..<12 {
            _ = end.handle(scroll(-60, 0, at: Double(step) / 120), context(at: 3))
        }
        XCTAssertEqual(end.handle(scroll(0, 0, .ended, at: 12.0 / 120), context(at: 3)).target, 3, "no page past Translate")
    }

    /// The projection is Apple's: velocity / 1000 × 0.998 / 0.002 points.
    func testTheProjectionIsTheDecelerationOne() {
        XCTAssertEqual(PageSwipe.projection(velocity: 1000), 499, accuracy: 0.001)
        XCTAssertEqual(PageSwipe.projection(velocity: -200), -99.8, accuracy: 0.001)
    }

    /// Fingers that stopped before they lifted throw nothing.
    func testFingersThatStoppedThrowNothing() {
        var swipe = grabbed(at: 1)
        for step in 0..<12 {
            _ = swipe.handle(scroll(-20, 0, at: Double(step) / 120), context(at: 1))
        }
        let released = swipe.handle(scroll(0, 0, .ended, at: 0.5), context(at: 1))
        XCTAssertEqual(released.velocity, 0)
    }

    func testMomentumAfterAPageTurnIsSwallowed() {
        var swipe = grabbed(at: 1)
        _ = swipe.handle(scroll(-200, 0), context(at: 1))
        _ = swipe.handle(scroll(0, 0, .ended), context(at: 1))
        XCTAssertEqual(swipe.handle(scroll(-30, 0, .none, momentum: .began), context(at: 1.5)), .swallow)
        XCTAssertEqual(swipe.handle(scroll(-10, 0, .none, momentum: .changed), context(at: 1.6)), .swallow)
        XCTAssertEqual(swipe.handle(scroll(0, 0, .none, momentum: .ended), context(at: 1.7)), .swallow)

        // The momentum of a gesture the page kept is the page's.
        var page = PageSwipe()
        _ = page.handle(scroll(0, 0, .began), context(at: 2))
        _ = page.handle(scroll(0, 30), context(at: 2))
        _ = page.handle(scroll(0, 0, .ended), context(at: 2))
        XCTAssertEqual(page.handle(scroll(0, 20, .none, momentum: .changed), context(at: 2)), .pass)
    }

    /// The fingers lift on a page turn and land again: the next gesture is a
    /// gesture, not more of the last one's glide.
    func testANewGestureEndsTheSwallowing() {
        var swipe = grabbed(at: 1)
        _ = swipe.handle(scroll(-200, 0), context(at: 1))
        _ = swipe.handle(scroll(0, 0, .ended), context(at: 1))
        XCTAssertEqual(swipe.handle(scroll(0, 0, .mayBegin), context(at: 1.8)), .pass)
        XCTAssertEqual(swipe.handle(scroll(0, 0, .began), context(at: 1.8)), .pass)
        XCTAssertEqual(swipe.handle(scroll(0, 12), context(at: 1.8)), .pass, "a vertical one, the page's")
        XCTAssertEqual(swipe.handle(scroll(0, 5, .none, momentum: .changed), context(at: 2)), .pass)
    }

    /// A cancelled gesture goes back where it was nearest, without a throw.
    func testACancelledGestureSettlesWithoutAThrow() {
        var swipe = grabbed(at: 1)
        for step in 0..<6 {
            _ = swipe.handle(scroll(-20, 0, at: Double(step) / 120), context(at: 1))
        }
        let cancelled = swipe.handle(scroll(0, 0, .cancelled, at: 6.0 / 120), context(at: 1))
        XCTAssertEqual(cancelled.target, 1)
        XCTAssertEqual(cancelled.velocity, 0)
    }

    // MARK: The settle

    /// On the island's spring: it starts at the fingers' velocity, overshoots
    /// once by a little, and comes to rest on the page.
    func testTheSettleIsTheIslandsSpring() {
        let settle = PageSettle(from: 1.6, to: 2, velocity: 1.5, start: 10, reduceMotion: false)
        XCTAssertEqual(settle.position(at: 10), 1.6, accuracy: 0.0001)
        let h = 0.0005
        XCTAssertEqual((settle.position(at: 10 + h) - settle.position(at: 10)) / h, 1.5, accuracy: 0.05, "handed the velocity")
        let samples = stride(from: 0.0, through: 1.5, by: 1.0 / 240).map { settle.position(at: 10 + $0) }
        XCTAssertGreaterThan(samples.max()!, 2, "one swing past the page")
        XCTAssertLessThan(samples.max()! - 2, 0.06, "a small one")
        XCTAssertTrue(settle.isDone(at: 12))
        XCTAssertEqual(settle.position(at: 12), 2, accuracy: 0.001)
        XCTAssertFalse(settle.isDone(at: 10.1))
    }

    /// Under Reduce Motion: the 0.24 ease-in-out, nothing past the page.
    func testTheSettleUnderReduceMotionIsTheEase() {
        let settle = PageSettle(from: 1.6, to: 2, velocity: 3, start: 0, reduceMotion: true)
        let samples = stride(from: 0.0, through: 0.3, by: 1.0 / 240).map { settle.position(at: $0) }
        XCTAssertLessThanOrEqual(samples.max()!, 2.000_001)
        XCTAssertEqual(settle.position(at: 0.12), 1.8, accuracy: 0.0001, "half way at half time")
        XCTAssertTrue(settle.isDone(at: 0.24))
        XCTAssertFalse(settle.isDone(at: 0.2))
        XCTAssertEqual(settle.position(at: 0.24), 2)
    }
}

private extension PageSwipe.Outcome {
    var target: Int? {
        if case .release(let target, _, _) = self { return target }
        return nil
    }

    var position: CGFloat? {
        if case .release(_, let position, _) = self { return position }
        return nil
    }

    var velocity: CGFloat? {
        if case .release(_, _, let velocity) = self { return velocity }
        return nil
    }
}
