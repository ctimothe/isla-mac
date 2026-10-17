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
/// and shrinks (spec §19.6–§19.8), and shrink only once the body has stopped
/// moving (review 2026-10-15: a 0.4 s hole where clicks on the still-drawn
/// lower part went to the app beneath, and a pointer resting there folded the
/// panel). The body changes size when the surface does — Tools is 480 × 204 and
/// Settings `bw` × 400 — which is what Expand and Collapse used to do.
@MainActor
final class NotchControllerRectTests: XCTestCase {
    private func rig() throws -> (NotchController, NotchViewModel, NotchRootView) {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isOpen = true
        vm.open(.tools)
        return (controller, vm, root)
    }

    /// Folding the panel gives the keyboard back, whatever surface held it.
    /// Since R8 removed Clipboard's search toggle, `setOpen(false)` is the one
    /// place that does it on a close (R8 review), so it is held here through
    /// ⌃⌥⌘I's route, the command that closes an open panel.
    func testClosingThePanelGivesTheKeyboardBack() throws {
        let (controller, vm, _) = try rig()
        for surface in [NotchViewModel.Surface.clipboard, .translate] {
            vm.isOpen = true
            vm.open(surface)
            XCTAssertTrue(vm.wantsKeyboard, "\(surface)")
            controller.toggle()
            XCTAssertFalse(vm.wantsKeyboard, "closing on \(surface) gives the keyboard back")
        }
    }

    /// ⌃⌥⌘V opens Clipboard with the keyboard, pinned like every command,
    /// from any surface; pressed again on Clipboard it closes and gives the
    /// keyboard back (spec §19.8). Over the lock it opens nothing.
    func testTheClipboardKeyIsTheWholeRoundTrip() throws {
        let (controller, vm, _) = try rig()
        vm.isOpen = false
        controller.toggleClipboard()
        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(vm.presented, .clipboard)
        XCTAssertTrue(vm.wantsKeyboard)
        XCTAssertTrue(vm.isPinnedOpen, "the hand that asked is on the keyboard")

        vm.open(.tray)
        controller.toggleClipboard()
        XCTAssertEqual(vm.presented, .clipboard, "from another surface it goes to Clipboard rather than closing")

        controller.toggleClipboard()
        XCTAssertFalse(vm.isOpen, "pressed again on Clipboard it closes")
        XCTAssertFalse(vm.wantsKeyboard)

        vm.isLockedPresentation = true
        controller.toggleClipboard()
        XCTAssertFalse(vm.isOpen, "nothing opens over the lock")
        XCTAssertEqual(vm.lockedHoverNudges, 1, "the refusal is the island's shake")
    }

    /// The active rect and the close rect a body of `size` should get.
    private func expected(_ vm: NotchViewModel, size: CGSize) -> (active: CGSize, close: CGSize) {
        let slack = vm.openTopRadius
        let active = NotchRootView.reachingTopEdge(
            vm.geometry.contentRect(for: size).insetBy(dx: -slack, dy: 0),
            windowHeight: vm.geometry.windowSize.height
        )
        return (active.size, vm.geometry.hoverRect(for: size).size)
    }

    private func bodySize(_ vm: NotchViewModel, _ surface: NotchViewModel.Surface) -> CGSize {
        SurfaceLayout.bodySize(for: surface, bodyWidth: vm.geometry.expandedSize.width, notch: vm.geometry.notchSize)
    }

    func testTheOpenRectsFollowASurfaceChangeAtOnceAndShrinkOnceTheBodyHasSettled() throws {
        let (controller, vm, root) = try rig()
        let tools = bodySize(vm, .tools)
        let settings = bodySize(vm, .settings)
        XCTAssertLessThan(tools.height, settings.height, "the two surfaces differ in height")
        controller.refreshOpenRects(bodySettled: true)
        XCTAssertEqual(vm.openBodySize, tools)
        XCTAssertEqual(root.activeRect.size, expected(vm, size: tools).active, "open at Tools")
        XCTAssertEqual(controller.pointer.closeRect.size, expected(vm, size: tools).close)

        // Settings, the taller: the rects reach it on the turn the surface changes.
        vm.open(.settings)
        XCTAssertEqual(vm.openBodySize, settings)
        controller.refreshOpenRects()
        XCTAssertEqual(root.activeRect.size, expected(vm, size: settings).active, "growing is immediate")
        XCTAssertEqual(controller.pointer.closeRect.size, expected(vm, size: settings).close)

        // Back to Tools: the body springs for 0.5 s, and the rects keep Settings'
        // size meanwhile.
        vm.open(.tools)
        controller.refreshOpenRects()
        XCTAssertEqual(root.activeRect.size, expected(vm, size: settings).active,
                       "the still-drawn lower half keeps its clicks, and the pointer on it its panel")
        XCTAssertEqual(controller.pointer.closeRect.size, expected(vm, size: settings).close)

        // …and Tools' once it has stopped.
        controller.refreshOpenRects(bodySettled: true)
        XCTAssertEqual(root.activeRect.size, expected(vm, size: tools).active)
        XCTAssertEqual(controller.pointer.closeRect.size, expected(vm, size: tools).close)
    }

    /// The shrink arrives on its own after the spring, and a newer change in
    /// the meantime outdates it.
    func testTheShrinkIsScheduledForTheEndOfTheSpringAndOutdatedByANewerRefresh() async throws {
        let (controller, vm, root) = try rig()
        let tools = bodySize(vm, .tools)
        let settings = bodySize(vm, .settings)
        vm.open(.settings)
        controller.refreshOpenRects()
        vm.open(.tools)
        controller.refreshOpenRects()
        XCTAssertEqual(root.activeRect.size, expected(vm, size: settings).active)
        try await Task.sleep(for: .seconds(Theme.expandSettle + 0.25))
        XCTAssertEqual(root.activeRect.size, expected(vm, size: tools).active, "the pass after the spring shrank it")

        vm.open(.settings)
        controller.refreshOpenRects()
        vm.open(.tools)
        controller.refreshOpenRects()
        vm.open(.settings)
        controller.refreshOpenRects()
        try await Task.sleep(for: .seconds(Theme.expandSettle + 0.25))
        XCTAssertEqual(root.activeRect.size, expected(vm, size: settings).active,
                       "a pass scheduled before the person went back to Settings must not cut a body that is tall")
    }

    /// Width and height each follow the rule on their own: the stage turning
    /// into the player narrows the shape by two hundred points as well.
    func testTheRuleHoldsForWidthAndHeightTogether() {
        let wide = CGSize(width: 620, height: 204)
        let narrow = CGSize(width: 357, height: 400)
        XCTAssertEqual(NotchController.openRectSize(applied: wide, target: narrow, bodySettled: false), CGSize(width: 620, height: 400),
                       "the height grows now, the width waits")
        XCTAssertEqual(NotchController.openRectSize(applied: wide, target: narrow, bodySettled: true), narrow)
        XCTAssertEqual(NotchController.openRectSize(applied: nil, target: narrow, bodySettled: false), narrow)
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
    /// biggest fold a surface change makes — the stage's 400 down to the tray's
    /// 158, 242 pt: from the hold on, no drawn point lies more than half a
    /// point outside the smaller rect.
    func testTheShrinkHoldOutlastsTheIslandSpring() {
        let omega = 2 * Double.pi / Theme.islandResponse
        let zeta = Theme.islandDamping
        let damped = omega * (1 - zeta * zeta).squareRoot()
        func progress(_ t: Double) -> Double {
            1 - exp(-zeta * omega * t) * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
        }
        let travel = Double(SurfaceLayout.stageHeight - SurfaceLayout.trayReference.height)
        XCTAssertEqual(travel, 242)
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
