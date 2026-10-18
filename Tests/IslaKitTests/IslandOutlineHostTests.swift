import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import IslaKit

/// The island's outline on Core Animation (spec §19.12): the layers hold the
/// shape SwiftUI asked for, move to it on one clock the render server runs,
/// and cut the content by the same outline on every frame of the way.
@MainActor
final class IslandOutlineHostTests: XCTestCase {
    private let window = CGSize(width: 700, height: 444)

    /// A stand-in for the SwiftUI hosting view: full-window, flipped as
    /// `NSHostingView` is, with a layer to mask.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func rig(flipped: Bool = true) -> (host: IslandOutlineHost, content: NSView) {
        let host = IslandOutlineHost(windowSize: window)
        let content: NSView = flipped ? FlippedView(frame: CGRect(origin: .zero, size: window)) : NSView(frame: CGRect(origin: .zero, size: window))
        content.wantsLayer = true
        host.attach(content: content)
        return (host, content)
    }

    private func state(
        width: Double = 300, height: Double = 38, top: Double = 8.67, bottom: Double = 12.67,
        shadow: Double = 0, fill: OutlineColor = .black,
        stroke: OutlineColor = OutlineColor(red: 1, green: 1, blue: 1, alpha: 0.14)
    ) -> OutlineState {
        OutlineState(
            width: width, height: height, topRadius: top, bottomRadius: bottom,
            fill: fill, stroke: stroke, strokeWidth: 2, shadowOpacity: shadow
        )
    }

    private let player = OutlineState(
        width: 628, height: 198, topRadius: 34, bottomRadius: 44,
        fill: .black, stroke: OutlineColor(red: 1, green: 1, blue: 1, alpha: 0.14), strokeWidth: 2, shadowOpacity: 0.22
    )

    /// Two paths built the same way are the same path, exactly.
    private func same(_ a: CGPath, _ b: CGPath) -> Bool { a == b }

    private func keyframes(_ layer: CALayer, _ key: String) -> CAKeyframeAnimation? {
        layer.animation(forKey: "outline.\(key)") as? CAKeyframeAnimation
    }

    // MARK: Drawing

    func testTheFirstAskIsDrawnWhereItIsWithNoMotion() {
        let (host, _) = rig()
        XCTAssertFalse(host.isShowing)
        XCTAssertTrue(host.backdrop.isHidden, "nothing is drawn before the shell has asked for anything")

        let first = state()
        host.apply(first, curve: .instant)

        XCTAssertTrue(host.isShowing)
        XCTAssertFalse(host.backdrop.isHidden)
        XCTAssertFalse(host.overlay.isHidden)
        XCTAssertNil(host.fillLayer.animationKeys())
        XCTAssertNil(host.strokeLayer.animationKeys())
        XCTAssertTrue(same(host.fillLayer.path!, OutlinePaths.fill(first, in: window, flipped: false)))
        XCTAssertTrue(same(host.fillLayer.shadowPath!, host.fillLayer.path!), "the shadow is the shape's, explicitly")
        XCTAssertTrue(same(host.strokeLayer.path!, OutlinePaths.stroke(first, in: window, flipped: false)))
    }

    func testTheShapeIsCentredInTheWindowAndHungFromItsTopEdge() {
        let (host, _) = rig()
        host.apply(state(width: 300, height: 38), curve: .instant)
        // Layers here are bottom-left: the top edge of the shape is the
        // window's top, `maxY`.
        let box = host.fillLayer.path!.boundingBox
        XCTAssertEqual(box.midX, window.width / 2, accuracy: 0.001)
        XCTAssertEqual(box.maxY, window.height, accuracy: 0.001)
        XCTAssertEqual(box.width, 300, accuracy: 0.001)
        XCTAssertEqual(box.height, 38, accuracy: 0.001)
    }

    func testTheStrokeIsOpenAlongTheTopAndTheFillIsNot() {
        let (host, _) = rig()
        host.apply(state(), curve: .instant)
        func closes(_ path: CGPath) -> Bool {
            var closed = false
            path.applyWithBlock { element in if element.pointee.type == .closeSubpath { closed = true } }
            return closed
        }
        XCTAssertTrue(closes(host.fillLayer.path!))
        XCTAssertFalse(closes(host.strokeLayer.path!), "a line along the top would be a seam against the bezel")
        XCTAssertEqual(host.strokeLayer.lineWidth, 2)
        XCTAssertNil(host.strokeLayer.fillColor)
    }

    func testTheShadowIsAnExplicitPathAndOnlyAsStrongAsAsked() {
        let (host, _) = rig()
        host.apply(state(shadow: 0), curve: .instant)
        XCTAssertEqual(host.fillLayer.shadowOpacity, 0)
        host.apply(player, curve: .instant)
        XCTAssertEqual(host.fillLayer.shadowOpacity, Float(Theme.islandShadowOpacity), accuracy: 1e-6)
        XCTAssertEqual(host.fillLayer.shadowRadius, Theme.islandShadowRadius)
        XCTAssertEqual(host.fillLayer.shadowOffset, .zero)
        XCTAssertNotNil(host.fillLayer.shadowPath, "no offscreen pass to find the silhouette")
    }

    // MARK: The mask

    func testTheContentIsCutByTheSameOutlineAsTheFill() {
        let (host, content) = rig(flipped: true)
        host.apply(player, curve: .instant)
        XCTAssertTrue(content.layer?.mask === host.maskLayer)
        // The content's layer is flipped, so its mask is top-left; the fill's
        // is bottom-left. Same outline, stood on either.
        XCTAssertTrue(same(host.maskLayer.path!, OutlinePaths.fill(player, in: window, flipped: true)))
        XCTAssertEqual(host.maskLayer.path!.boundingBox.minY, 0, accuracy: 0.001, "top edge at y = 0 in a flipped layer")
        XCTAssertEqual(host.maskLayer.frame, content.layer?.bounds)
    }

    func testAnUnflippedContentViewIsCutBottomLeft() {
        let (host, content) = rig(flipped: false)
        host.apply(player, curve: .instant)
        XCTAssertTrue(content.layer?.mask === host.maskLayer)
        XCTAssertTrue(same(host.maskLayer.path!, host.fillLayer.path!))
    }

    /// What lies beside the island (the Shelf's bubble) is kept off the
    /// island's area by a mask of its own: the window less the outline.
    func testWhatLiesBesideTheIslandIsKeptOffIt() {
        let host = IslandOutlineHost(windowSize: window)
        let content = FlippedView(frame: CGRect(origin: .zero, size: window))
        let bubble = FlippedView(frame: CGRect(origin: .zero, size: window))
        for view in [content, bubble] { view.wantsLayer = true }
        host.attach(content: content)
        host.attach(bubble: bubble)
        host.apply(player, curve: .instant)
        XCTAssertTrue(bubble.layer?.mask === host.bubbleMaskLayer)
        XCTAssertEqual(host.bubbleMaskLayer.fillRule, .evenOdd, "the island's area is the hole")
        XCTAssertTrue(same(host.bubbleMaskLayer.path!, OutlinePaths.outside(player, in: window, flipped: true)))
        let island = OutlinePaths.fill(player, in: window, flipped: true)
        let centre = CGPoint(x: window.width / 2, y: 60)
        let beside = CGPoint(x: window.width / 2 + 330, y: 20)
        XCTAssertTrue(island.contains(centre))
        XCTAssertFalse(host.bubbleMaskLayer.path!.contains(centre, using: .evenOdd), "nothing of the bubble over the island")
        XCTAssertTrue(host.bubbleMaskLayer.path!.contains(beside, using: .evenOdd), "and all of it beside")
        host.hide()
        XCTAssertNil(bubble.layer?.mask)
    }

    func testTheBubblesMaskFollowsTheOutlineOnTheSameKeyframes() throws {
        let host = IslandOutlineHost(windowSize: window)
        let content = FlippedView(frame: CGRect(origin: .zero, size: window))
        let bubble = FlippedView(frame: CGRect(origin: .zero, size: window))
        for view in [content, bubble] { view.wantsLayer = true }
        host.attach(content: content)
        host.attach(bubble: bubble)
        host.apply(state(), curve: .instant)
        host.apply(player, curve: .island)
        let fill = try XCTUnwrap(keyframes(host.fillLayer, "path"))
        let outside = try XCTUnwrap(keyframes(host.bubbleMaskLayer, "path"))
        XCTAssertEqual(fill.values?.count, outside.values?.count)
        XCTAssertEqual(fill.duration, outside.duration)
        let middle = (fill.values?.count ?? 2) / 2
        let (_, progress) = OutlineCurve.island.keyframes()
        let expected = OutlinePaths.outside(state().mixed(to: player, progress[middle]).shape, in: window, flipped: true)
        XCTAssertTrue(same(outside.values?[middle] as! CGPath, expected))
    }

    func testHidingTakesTheMaskAndTheViewsAway() {
        let (host, content) = rig()
        host.apply(player, curve: .instant)
        host.hide()
        XCTAssertFalse(host.isShowing)
        XCTAssertTrue(host.backdrop.isHidden)
        XCTAssertTrue(host.overlay.isHidden)
        XCTAssertNil(content.layer?.mask, "the lock screen's pill is not cut by the island's outline")
        XCTAssertNil(host.fillLayer.animationKeys())
        host.apply(player, curve: .instant)
        XCTAssertTrue(content.layer?.mask === host.maskLayer, "and it comes back with the shell")
    }

    // MARK: Motion

    func testAMoveSetsTheTargetAndRunsEveryPartOnOneClock() throws {
        let (host, _) = rig()
        let from = state()
        host.apply(from, curve: .instant)
        host.apply(player, curve: .island)

        XCTAssertTrue(same(host.fillLayer.path!, OutlinePaths.fill(player, in: window, flipped: false)),
                      "the model is already where it is going: the animation only decorates the way")
        let fill = try XCTUnwrap(keyframes(host.fillLayer, "path"))
        let shadow = try XCTUnwrap(keyframes(host.fillLayer, "shadowPath"))
        let stroke = try XCTUnwrap(keyframes(host.strokeLayer, "path"))
        let mask = try XCTUnwrap(keyframes(host.maskLayer, "path"))
        let opacity = try XCTUnwrap(keyframes(host.fillLayer, "shadowOpacity"))

        let (duration, progress) = OutlineCurve.island.keyframes()
        for animation in [fill, shadow, stroke, mask, opacity] {
            XCTAssertEqual(animation.duration, duration, accuracy: 1e-9)
            XCTAssertEqual(animation.values?.count, progress.count)
            XCTAssertEqual(animation.calculationMode, .linear)
            XCTAssertEqual(animation.keyTimes?.first, 0)
            XCTAssertEqual(animation.keyTimes?.last, 1)
        }
        XCTAssertNil(keyframes(host.fillLayer, "fillColor"), "a colour that does not change is not animated")
    }

    func testTheKeyframesAreTheCurveSampledOverTheTwoShapes() throws {
        let (host, _) = rig()
        let from = state()
        host.apply(from, curve: .instant)
        host.apply(player, curve: .island)
        let animation = try XCTUnwrap(keyframes(host.fillLayer, "path"))
        let values = try XCTUnwrap(animation.values)
        let (_, progress) = OutlineCurve.island.keyframes()
        for index in [0, 1, 7, progress.count / 2, progress.count - 1] {
            let expected = OutlinePaths.fill(from.mixed(to: player, progress[index]), in: window, flipped: false)
            XCTAssertTrue(same(values[index] as! CGPath, expected), "keyframe \(index)")
        }
        // The overshoot is in the shape, not clamped away: the island is a
        // little wider than the player for a moment (§19.3).
        let widest = values.map { ($0 as! CGPath).boundingBox.width }.max() ?? 0
        XCTAssertGreaterThan(widest, player.width)
        XCTAssertLessThan(widest, player.width * 1.04)
    }

    func testTheMaskAndTheFillShareTheirKeyframes() throws {
        let (host, _) = rig(flipped: false)
        host.apply(state(), curve: .instant)
        host.apply(player, curve: .island)
        let fill = try XCTUnwrap(keyframes(host.fillLayer, "path")).values ?? []
        let mask = try XCTUnwrap(keyframes(host.maskLayer, "path")).values ?? []
        XCTAssertEqual(fill.count, mask.count)
        for (a, b) in zip(fill, mask) { XCTAssertTrue(same(a as! CGPath, b as! CGPath)) }
    }

    func testAChangeOfColourAloneMovesNoPath() {
        let (host, _) = rig()
        let a = state()
        host.apply(a, curve: .instant)
        var b = a
        b.fill = OutlineColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1)
        host.apply(b, curve: OutlineCurve.of(Theme.contentAnimation))
        XCTAssertNotNil(keyframes(host.fillLayer, "fillColor"))
        XCTAssertNil(keyframes(host.fillLayer, "path"))
        XCTAssertNil(keyframes(host.strokeLayer, "path"))
        XCTAssertNil(keyframes(host.maskLayer, "path"))
    }

    func testTheStrokeFadesWithTheShapeRatherThanArrivingAfterIt() throws {
        let (host, _) = rig()
        var hidden = state()
        hidden.stroke = hidden.stroke.scalingAlpha(by: 0)
        host.apply(hidden, curve: .instant)
        host.apply(state(), curve: .island)
        let colours = try XCTUnwrap(keyframes(host.strokeLayer, "strokeColor"))
        XCTAssertEqual(colours.values?.count, OutlineCurve.island.keyframes().progress.count)
    }

    func testReduceMotionGetsTheTimingCurveAndNoOvershoot() throws {
        let (host, _) = rig()
        host.apply(state(), curve: .instant)
        host.apply(player, curve: OutlineCurve.of(Theme.island(reduceMotion: true)))
        let animation = try XCTUnwrap(keyframes(host.fillLayer, "path"))
        XCTAssertEqual(animation.duration, Theme.reducedMotionDuration, accuracy: 1 / OutlineCurve.sampleRate)
        let widest = (animation.values ?? []).map { ($0 as! CGPath).boundingBox.width }.max() ?? 0
        XCTAssertEqual(widest, player.width, accuracy: 0.001)
    }

    func testAnInstantAskStopsAMotionInFlight() {
        let (host, _) = rig()
        host.apply(state(), curve: .instant)
        host.apply(player, curve: .island)
        XCTAssertNotNil(host.fillLayer.animationKeys())
        host.apply(state(width: 320), curve: .instant)
        XCTAssertNil(host.fillLayer.animationKeys(), "the lock is a cut")
        XCTAssertNil(host.strokeLayer.animationKeys())
        XCTAssertNil(host.maskLayer.animationKeys())
    }

    func testTheSameAskAgainIsNotAMotionRestarted() {
        let (host, _) = rig()
        host.apply(state(), curve: .instant)
        host.apply(player, curve: .island)
        host.fillLayer.removeAllAnimations()
        host.apply(player, curve: .island)
        XCTAssertNil(host.fillLayer.animationKeys(), "the shell re-renders for other reasons all the time")
    }

    // MARK: Interruption

    func testAnInterruptedMoveContinuesFromWhereTheOutlineIs() throws {
        let (host, _) = rig()
        let closed = state()
        host.apply(closed, curve: .instant, now: 100)
        host.apply(player, curve: .island, now: 100)
        // 150 ms in, the person closes it again.
        let partway = try XCTUnwrap(host.drawn(at: 100.15))
        XCTAssertGreaterThan(partway.width, closed.width)
        XCTAssertLessThan(partway.width, player.width)
        host.apply(closed, curve: .island, now: 100.15)

        let animation = try XCTUnwrap(keyframes(host.fillLayer, "path"))
        let first = try XCTUnwrap((animation.values?.first)) as! CGPath
        XCTAssertTrue(same(first, OutlinePaths.fill(partway, in: window, flipped: false)),
                      "the way back begins where the way out had got to, not at the open or the shut state")
    }

    func testReversingASpringStartsWithTheMomentumItHad() throws {
        let (host, _) = rig()
        let closed = state()
        host.apply(closed, curve: .instant, now: 10)
        host.apply(player, curve: .island, now: 10)
        // 100 ms into the open it is going out fast; the person closes it.
        host.apply(closed, curve: .island, now: 10.1)
        let widths = try XCTUnwrap(keyframes(host.fillLayer, "path")?.values).map { ($0 as! CGPath).boundingBox.width }
        let partway = try XCTUnwrap(host.drawn(at: 10.1)).width
        XCTAssertLessThan(closed.width, partway, "the close has somewhere to go")
        // From rest the first step would already be heading back to the
        // closed width. With the open's momentum the island is still going
        // out for a frame or two before it turns, as a SwiftUI spring turned
        // round is.
        XCTAssertGreaterThan(widths[1], widths[0], "still on its way out")
        XCTAssertLessThan(widths.last ?? .infinity, partway)
    }

    func testATimingCurveStartsAgainFromRest() throws {
        let (host, _) = rig()
        host.apply(state(), curve: .instant, now: 0)
        host.apply(player, curve: .island, now: 0)
        host.apply(state(), curve: OutlineCurve.of(Theme.reducedMotion), now: 0.1)
        let animation = try XCTUnwrap(keyframes(host.fillLayer, "path"))
        let partway = try XCTUnwrap(host.drawn(at: 0.1))
        let first = (animation.values?.first as! CGPath).boundingBox.width
        XCTAssertEqual(first, OutlinePaths.fill(partway, in: window, flipped: false).boundingBox.width, accuracy: 0.001)
    }

    // MARK: Cost

    /// Starting a move builds its keyframes on the main thread, at the click.
    /// That is the one cost the layers add to the main thread, and it is paid
    /// once per change, not per frame; it has to stay small enough that the
    /// click's own frame is not the one that drops.
    ///
    /// It counts this thread's CPU time, not the wall clock. Measured by the
    /// wall clock, the slowest of forty starts took 19–48 ms on a Mac whose
    /// load average stood at 73 (other sessions compiling) and passed one run
    /// in five with the code unchanged: what it measured was the scheduler
    /// handing the core to someone else mid-start, which is not a cost the
    /// start puts on the main thread.
    func testStartingAMoveCostsTheMainThreadWellUnderAFrame() {
        let (host, _) = rig()
        host.apply(state(), curve: .instant)
        var worst = 0.0
        for index in 0..<40 {
            let target = index.isMultiple(of: 2) ? player : state()
            let before = Self.threadCPUMilliseconds()
            host.apply(target, curve: .island)
            worst = max(worst, Self.threadCPUMilliseconds() - before)
        }
        XCTAssertLessThan(worst, 8, "the slowest of forty starts, in a debug build: \(worst) ms of CPU")
    }

    private static func threadCPUMilliseconds() -> Double {
        var now = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now)
        return Double(now.tv_sec) * 1000 + Double(now.tv_nsec) / 1e6
    }

    // MARK: Resize

    func testAResizedWindowRedrawsTheOutlineWhereItWasGoing() {
        let (host, _) = rig()
        host.apply(player, curve: .instant)
        let larger = CGSize(width: 800, height: 500)
        host.backdrop.setFrameSize(larger)
        XCTAssertEqual(host.windowSize, larger)
        XCTAssertTrue(same(host.fillLayer.path!, OutlinePaths.fill(player, in: larger, flipped: false)))
        XCTAssertNil(host.fillLayer.animationKeys())
    }

    // MARK: The views

    func testTheLayerViewsTakeNoEvents() {
        let (host, _) = rig()
        XCTAssertNil(host.backdrop.hitTest(CGPoint(x: 350, y: 20)))
        XCTAssertNil(host.overlay.hitTest(CGPoint(x: 350, y: 20)))
        XCTAssertFalse(host.backdrop.isAccessibilityElement())
        XCTAssertFalse(host.overlay.isAccessibilityElement())
    }
}
