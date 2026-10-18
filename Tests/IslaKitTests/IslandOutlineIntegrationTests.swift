import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The bridge between the SwiftUI shell and the layers: what the shell asks
/// the host for, and on which curve, for the changes the controller makes.
@MainActor
final class IslandOutlineIntegrationTests: XCTestCase {
    override func tearDown() {
        SystemAppearance.shared.resetForTests()
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The real shell, in a never-ordered window, with a host to record what it asks.
    private func shell() throws -> (vm: NotchViewModel, host: IslandOutlineHost, asks: Asks) {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let host = IslandOutlineHost(windowSize: vm.geometry.windowSize)
        let asks = Asks()
        host.onApply = { state, curve in
            asks.list.append((state, curve))
            asks.times.append(CACurrentMediaTime())
        }
        let hosting = NSHostingView(rootView: NotchContentView(vm: vm, outline: host))
        hosting.frame = CGRect(origin: .zero, size: vm.geometry.windowSize)
        host.attach(content: hosting)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        addTeardownBlock { @MainActor in window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        spin()
        return (vm, host, asks)
    }

    final class Asks {
        var list: [(state: OutlineState, curve: OutlineCurve)] = []
        var times: [CFTimeInterval] = []
        var last: (state: OutlineState, curve: OutlineCurve)? { list.last }
        /// When the latest ask was made.
        var lastTime: CFTimeInterval { times.last ?? 0 }
        func reset() { list = []; times = [] }
    }

    func testTheShellFirstAsksForWhereTheIslandIsWithNoMotion() throws {
        let (vm, host, asks) = try shell()
        let first = try XCTUnwrap(asks.list.first)
        XCTAssertEqual(first.curve, .instant)
        XCTAssertTrue(host.isShowing)
        let shape = vm.geometry.isPhysical
            ? NotchContentView.restingShape(notch: vm.bodySize)
            : CGSize(width: vm.bodySize.width + 2 * Theme.collapsedTopRadius, height: vm.bodySize.height)
        XCTAssertEqual(first.state.height, Double(shape.height), accuracy: 0.001, "the shape the shell drew before the layers")
        XCTAssertNil(host.fillLayer.animationKeys(), "drawn, not arriving")
    }

    func testOpeningAsksForThePanelOnTheOutlinesSpring() throws {
        let (vm, host, asks) = try shell()
        asks.reset()
        withAnimation(Theme.open(reduceMotion: false)) { vm.isOpen = true }
        spin(0.08)
        let ask = try XCTUnwrap(asks.last)
        XCTAssertEqual(ask.curve, .spring(response: 0.5, damping: 0.75, delay: 0))
        let body = vm.openBodySize
        XCTAssertEqual(ask.state.width, Double(body.width + 2 * vm.openTopRadius), accuracy: 0.001)
        XCTAssertEqual(ask.state.height, Double(body.height), accuracy: 0.001)
        XCTAssertEqual(ask.state.bottomRadius, Double(vm.openBottomRadius), accuracy: 0.001)
        // Part of the way there, on a flight the host keeps and the layers
        // run. (The layers' animations themselves are dropped at the first
        // commit by a process with no window server, as the gate's is, so the
        // host's own account of where the outline is stands in for them.)
        XCTAssertLessThan(try XCTUnwrap(host.drawn(at: asks.lastTime + 0.08)).width, ask.state.width, "80 ms in, still opening")
        XCTAssertEqual(ask.state.shadowOpacity, Theme.islandShadowOpacity, "a panel taller than 68 casts the shadow")
    }

    func testClosingAsksOnTheSameSpringStartedThirtyMillisecondsLate() throws {
        let (vm, _, asks) = try shell()
        withAnimation(Theme.open(reduceMotion: false)) { vm.isOpen = true }
        spin(0.3)
        asks.reset()
        withAnimation(Theme.close(reduceMotion: false)) { vm.isOpen = false }
        spin()
        XCTAssertEqual(asks.last?.curve, .spring(response: 0.5, damping: 0.75, delay: Theme.closeShapeDelay))
    }

    func testReduceMotionAsksForTheTimingCurve() throws {
        SystemAppearance.shared.overrideForTests(reduceTransparency: false, increaseContrast: false, reduceMotion: true)
        let (vm, _, asks) = try shell()
        asks.reset()
        withAnimation(Theme.open(reduceMotion: true)) { vm.isOpen = true }
        spin()
        guard case .bezier(let duration, _, let delay)? = asks.last?.curve else {
            return XCTFail("Reduce Motion's outline is the 0.24 ease-in-out")
        }
        XCTAssertEqual(duration, Theme.reducedMotionDuration, accuracy: 1e-9)
        XCTAssertEqual(delay, 0)
    }

    func testAChangeWithNoAnimationIsACut() throws {
        let (vm, host, asks) = try shell()
        asks.reset()
        var cut = Transaction()
        cut.disablesAnimations = true
        withTransaction(cut) { vm.isOpen = true }
        spin()
        XCTAssertEqual(asks.last?.curve, .instant)
        XCTAssertNil(host.fillLayer.animationKeys())
    }

    /// SwiftUI animates each value that changes on its own: the pointer arriving
    /// on the island changes its fill on a short spring, and the headphones
    /// alert growing the shape on the outline's goes on. The host keeps one
    /// change in flight per part, so the second does not restart the first.
    func testTheHoverBrightensTheFillWithoutRestartingTheShapesMotion() throws {
        let (vm, host, asks) = try shell()
        asks.reset()
        withAnimation(Theme.pill(reduceMotion: false)) {
            vm.ambient = .headphones(name: "AirPods Pro", symbol: "airpods.pro")
        }
        spin(0.05)
        let target = try XCTUnwrap(host.target)
        let began = try XCTUnwrap(asks.times.first, "the alert asked for its shape")
        let before = try XCTUnwrap(host.drawn(at: began + 0.06)).width
        XCTAssertLessThan(before, target.width, "the alert is still growing")
        asks.reset()

        vm.isHovering = true
        spin(0.02)
        let ask = try XCTUnwrap(asks.last, "the fill changed")
        XCTAssertNotEqual(ask.state.fill, target.fill, "the hovered island is lighter")
        XCTAssertEqual(ask.state.shape, target.shape, "the shape is going where it was going")
        // The shape's flight is the one the alert began, not a new one: where it
        // is at a given moment is what it was going to be.
        let expected = OutlineCurve.island.progress(at: 0.07)
        let after = try XCTUnwrap(host.drawn(at: began + 0.07)).width
        let start = try XCTUnwrap(host.drawn(at: began)).width
        XCTAssertGreaterThanOrEqual(after, before, "and has gone on opening, not started again from where it began")
        XCTAssertEqual(after, start + (target.width - start) * expected, accuracy: 4, "on the alert's own spring")
    }

    // MARK: Curves that come from `.animation(_:value:)`, not `withAnimation`

    /// Most of the shell's motion is a modifier's, not the controller's:
    /// the bridge has to see what the shape would have been given. A plain
    /// assignment, no `withAnimation`.
    func testThePointerArrivingBrightensTheFillOnTheHoverSpring() throws {
        let (vm, _, asks) = try shell()
        asks.reset()
        vm.isHovering = true
        spin(0.05)
        let ask = try XCTUnwrap(asks.last, "the resting island wakes under the pointer")
        XCTAssertEqual(ask.curve, OutlineCurve.of(Theme.hoverNudge), "`.animation(Theme.hoverNudge, value: vm.isHovering)`")
    }

    func testAChangeOfSurfaceInAnOpenPanelMovesTheOutlineOnTheIslandSpring() throws {
        let (vm, host, asks) = try shell()
        var cut = Transaction()
        cut.disablesAnimations = true
        withTransaction(cut) { vm.isOpen = true }
        spin(0.3)
        let player = try XCTUnwrap(host.target)
        asks.reset()
        vm.open(.settings)
        spin(0.05)
        let ask = try XCTUnwrap(asks.last)
        XCTAssertNotEqual(ask.state.shape, player.shape, "Settings is taller")
        XCTAssertEqual(
            ask.curve, OutlineCurve.of(Theme.island(reduceMotion: false)),
            "`.animation(Theme.island, value: vm.openBodySize.height)` wins over the surface change's own ease"
        )
    }

    /// The close has a head start of 30 ms (the body leaves before the shape
    /// comes for it), but an outline already moving is not stopped for it: it
    /// turns round at once, with the speed it had.
    func testAClosePressedMidOpenTurnsRoundAtOnceWithItsSpeed() throws {
        let (vm, host, asks) = try shell()
        asks.reset()
        withAnimation(Theme.open(reduceMotion: false)) { vm.isOpen = true }
        spin(0.12)
        let opened = try XCTUnwrap(asks.times.first)
        let open = try XCTUnwrap(asks.last)
        XCTAssertEqual(open.curve, .spring(response: 0.5, damping: 0.75, delay: 0))
        asks.reset()
        withAnimation(Theme.close(reduceMotion: false)) { vm.isOpen = false }
        spin(0.05)
        let closing = try XCTUnwrap(asks.times.first)
        XCTAssertLessThan(closing - opened, 0.5, "the open is still in flight")
        let ask = try XCTUnwrap(asks.last)
        XCTAssertEqual(ask.curve, .spring(response: 0.5, damping: 0.75, delay: Theme.closeShapeDelay), "what the shell asked for")
        // What the outline does with it: from the width it had, at once. A
        // frame after the press it is no longer where it was.
        let atPress = try XCTUnwrap(host.drawn(at: closing)).width
        let frameLater = try XCTUnwrap(host.drawn(at: closing + 1.0 / 120)).width
        XCTAssertNotEqual(atPress, frameLater, "not held still for the delay")
    }

    func testAShellThatLeavesTakesTheOutlineWithIt() throws {
        let (vm, host, _) = try shell()
        XCTAssertTrue(host.isShowing)
        // The lock screen draws its own pill (spec §19.10); the island's shell
        // is not on screen, and an outline left on the layers would sit under it.
        var cut = Transaction()
        cut.disablesAnimations = true
        withTransaction(cut) { vm.isLockedPresentation = true }
        spin()
        XCTAssertFalse(host.isShowing)
        XCTAssertTrue(host.backdrop.isHidden)
        withTransaction(cut) { vm.isLockedPresentation = false }
        spin()
        XCTAssertTrue(host.isShowing, "and it is back, where the island is, with the shell")
    }
}
