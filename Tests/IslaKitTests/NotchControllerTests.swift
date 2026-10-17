import XCTest
@testable import IslaKit

final class NotchControllerTests: XCTestCase {
    /// The Edit Lyrics sheet holds the panel open. The pointer watcher counted
    /// drags, menus and held presses as reasons to stay, but not a sheet, so
    /// moving down to the editor's lower fields left the hover rect and folded
    /// the panel, unsaved edits and all (G-012).
    func testAnAttachedSheetHoldsThePanelOpen() {
        XCTAssertTrue(NotchController.holdsOpen(
            receivingDrag: false, draggingOut: false, menuOpen: false, pressHeld: false, sheetAttached: true
        ))
        XCTAssertFalse(NotchController.holdsOpen(
            receivingDrag: false, draggingOut: false, menuOpen: false, pressHeld: false, sheetAttached: false
        ), "and nothing at all holds nothing")
        for reason in 0..<4 {
            XCTAssertTrue(NotchController.holdsOpen(
                receivingDrag: reason == 0, draggingOut: reason == 1, menuOpen: reason == 2,
                pressHeld: reason == 3, sheetAttached: false
            ), "the reasons that held it before still do")
        }
    }
}

/// The rects the controller cuts for an open panel follow the body as it grows
/// and shrinks (spec §6), and shrink only once the body has stopped moving
/// (review 2026-10-15: a 0.4 s hole where clicks on the still-drawn lower part
/// went to the app beneath, and a pointer resting there folded the panel).
@MainActor
final class NotchControllerRectTests: XCTestCase {
    private func rig() throws -> (NotchController, NotchViewModel, NotchRootView) {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isOpen = true
        vm.tab = .shelf
        return (controller, vm, root)
    }

    /// The active rect and the close rect a body of `height` should get.
    private func expected(_ vm: NotchViewModel, height: CGFloat) -> (active: CGFloat, close: CGFloat) {
        let size = CGSize(width: vm.geometry.expandedSize.width, height: height)
        let slack = Theme.openTopRadius
        let active = NotchRootView.reachingTopEdge(
            vm.geometry.contentRect(for: size).insetBy(dx: -slack, dy: 0),
            windowHeight: vm.geometry.windowSize.height
        )
        return (active.height, vm.geometry.hoverRect(for: size).height)
    }

    func testTheOpenRectsFollowExpandAtOnceAndCollapseOnceTheBodyHasSettled() throws {
        let (controller, vm, root) = try rig()
        controller.refreshOpenRects(bodySettled: true)
        XCTAssertEqual(root.activeRect.height, expected(vm, height: 208).active, "open at the standard body")
        XCTAssertEqual(controller.pointer.closeRect.height, expected(vm, height: 208).close)

        // Expand: the rects reach 400 on the turn the state changes.
        vm.setExpanded(true, for: .shelf)
        XCTAssertEqual(vm.openBodySize.height, 400)
        controller.refreshOpenRects()
        XCTAssertEqual(root.activeRect.height, expected(vm, height: 400).active, "growing is immediate")
        XCTAssertEqual(controller.pointer.closeRect.height, expected(vm, height: 400).close)

        // Collapse: the body springs for 0.4 s, and the rects keep 400 meanwhile.
        vm.setExpanded(false, for: .shelf)
        controller.refreshOpenRects()
        XCTAssertEqual(root.activeRect.height, expected(vm, height: 400).active,
                       "the still-drawn lower half keeps its clicks, and the pointer on it its panel")
        XCTAssertEqual(controller.pointer.closeRect.height, expected(vm, height: 400).close)

        // …and 208 once it has stopped.
        controller.refreshOpenRects(bodySettled: true)
        XCTAssertEqual(root.activeRect.height, expected(vm, height: 208).active)
        XCTAssertEqual(controller.pointer.closeRect.height, expected(vm, height: 208).close)
    }

    /// The shrink arrives on its own after the spring, and a re-expand in the
    /// meantime outdates it.
    func testTheShrinkIsScheduledForTheEndOfTheSpringAndOutdatedByANewerRefresh() async throws {
        let (controller, vm, root) = try rig()
        vm.setExpanded(true, for: .shelf)
        controller.refreshOpenRects()
        vm.setExpanded(false, for: .shelf)
        controller.refreshOpenRects()
        XCTAssertEqual(root.activeRect.height, expected(vm, height: 400).active)
        try await Task.sleep(for: .seconds(Theme.expandSettle + 0.25))
        XCTAssertEqual(root.activeRect.height, expected(vm, height: 208).active, "the pass after the spring shrank it")

        vm.setExpanded(true, for: .shelf)
        controller.refreshOpenRects()
        vm.setExpanded(false, for: .shelf)
        controller.refreshOpenRects()
        vm.setExpanded(true, for: .shelf)
        controller.refreshOpenRects()
        try await Task.sleep(for: .seconds(Theme.expandSettle + 0.25))
        XCTAssertEqual(root.activeRect.height, expected(vm, height: 400).active,
                       "a pass scheduled before the person expanded again must not cut a body that is tall")
    }

    func testTheRuleInIsolation() {
        XCTAssertEqual(NotchController.openRectHeight(applied: nil, target: 208, bodySettled: false), 208)
        XCTAssertEqual(NotchController.openRectHeight(applied: 208, target: 400, bodySettled: false), 400, "grow now")
        XCTAssertEqual(NotchController.openRectHeight(applied: 400, target: 208, bodySettled: false), 400, "shrink later")
        XCTAssertEqual(NotchController.openRectHeight(applied: 400, target: 208, bodySettled: true), 208)
        XCTAssertEqual(NotchController.openRectHeight(applied: 400, target: 400, bodySettled: false), 400)
        XCTAssertGreaterThanOrEqual(Theme.expandSettle, Theme.expandResponse, "the spring has stopped by then")
    }

    /// The body shrinks on the outline's spring (spec §19.3), which overshoots
    /// — inward, on a shrink: past its first crossing the shape is smaller than
    /// the body it is going to, so inside the rect cut for it, and the swing
    /// back out is a tenth of a point. Held from the closed form over the
    /// 192 pt fold from 400 to 208: from the hold on, no drawn point lies more
    /// than half a point outside the smaller rect.
    func testTheShrinkHoldOutlastsTheIslandSpring() {
        let omega = 2 * Double.pi / Theme.islandResponse
        let zeta = Theme.islandDamping
        let damped = omega * (1 - zeta * zeta).squareRoot()
        func progress(_ t: Double) -> Double {
            1 - exp(-zeta * omega * t) * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
        }
        let travel = 192.0
        for t in stride(from: Theme.expandSettle, through: 3, by: 0.001) {
            // Progress short of 1 is a body still taller than its end.
            let outside = (1 - progress(t)) * travel
            XCTAssertLessThan(outside, 0.5, "at \(t) s the body is \(outside) pt outside its rect")
        }
        XCTAssertLessThan(
            Theme.springRiseTime(response: Theme.islandResponse, damping: zeta, level: 1), Theme.expandSettle,
            "it has crossed its end before the hold ends"
        )
    }

    /// How long a shrink waits for the drawn body (review 2026-10-15).
    func testTheShrinkHoldFollowsTheMotionTheBodyActuallyMakes() {
        XCTAssertEqual(NotchController.shrinkHold(reduceMotion: false, animated: true), Theme.expandSettle)
        XCTAssertEqual(NotchController.shrinkHold(reduceMotion: true, animated: true), Theme.reducedMotionDuration,
                       "the crossfade is 0.24 s, not the spring's 0.5")
        XCTAssertEqual(NotchController.shrinkHold(reduceMotion: false, animated: false), 0)
        XCTAssertEqual(NotchController.shrinkHold(reduceMotion: true, animated: false), 0)
        XCTAssertLessThan(Theme.reducedMotionDuration, Theme.expandSettle)
    }
}
