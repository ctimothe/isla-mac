import AppKit
import XCTest
@testable import IslaKit

/// Since R8 every surface has its own width, and two things that open one are
/// wider than it: the new-track peek, notch + 300 wide (spec §3.5), opens the
/// player, 357.4 wide (§19.6); and the far end of the Shelf's bubble sits past
/// the tray's edge under a 200 pt notch (§19.7). A pointer that opened the
/// panel from there stood outside the body it opened. Clicked, the panel was
/// pinned (the pin decision measured the surface shown *before* the click) or
/// folded `closeDelay` later; hovered with Open on Hover on, it folded, and the
/// island under the pointer opened it again (R8 review F1).
@MainActor
final class OpenFromAWiderIslandTests: XCTestCase {
    private static let everywhere = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
    private static let nowhere = CGRect(x: -1_000_000, y: -1_000_000, width: 10, height: 10)

    /// Two samples make a verdict; see `PointerWatcherTests.sample`.
    private func sample(_ watcher: PointerWatcher, times: Int) {
        for _ in 0..<times { watcher.start() }
    }

    /// The click route: the controller tells the watcher the pointer is inside
    /// before the panel opens, with the collapsed island still cut.
    func testAClickOnTheIslandsFarEndHoldsThePanelUntilThePointerReachesTheBody() {
        let watcher = PointerWatcher.withNoButtonHeld()
        defer { watcher.stop() }
        var changes: [Bool] = []
        var open = false
        var point = CGPoint(x: 50, y: 50)
        watcher.location = { point }
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { open }
        watcher.onChange = { changes.append($0) }
        // The peek, under the pointer; the player it opens does not reach it.
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.nowhere

        watcher.setInside(true)
        open = true
        watcher.openRect = Self.nowhere
        sample(watcher, times: 3)
        XCTAssertEqual(changes, [], "the pointer is still on the island it clicked")

        // It reaches the body, and from then the body alone holds the panel:
        // leaving it is leaving, wherever the island once was. The pointer
        // moves off; the body is not taken from under it, which is a shrink
        // and holds (`PagesOnHardwareTests`).
        watcher.closeRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        sample(watcher, times: 2)
        point = CGPoint(x: 500, y: 500)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "once on the body, leaving the body closes")
    }

    /// The hover route, Open on Hover on: the arrival on the peek opens the
    /// player, and the narrower player must not fold it again.
    func testAHoverArrivalOnTheIslandsFarEndIsNotUndoneByTheNarrowerBody() {
        let watcher = PointerWatcher.withNoButtonHeld()
        defer { watcher.stop() }
        var changes: [Bool] = []
        var open = false
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { open }
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.nowhere
        watcher.onChange = { inside in
            changes.append(inside)
            // What the controller does with an arrival: open, re-cut the rects.
            if inside {
                open = true
                watcher.openRect = Self.nowhere
            }
        }

        sample(watcher, times: 2)
        XCTAssertEqual(changes, [true], "the arrival opens")
        sample(watcher, times: 3)
        XCTAssertEqual(changes, [true], "and the body it opened does not fold it under the same pointer")
    }

    /// A forced state that is not an arrival from the island — a close, or an
    /// open made while the panel was already open — carries no island with it.
    func testOnlyAnOpenFromTheClosedIslandCarriesTheIsland() {
        let watcher = PointerWatcher.withNoButtonHeld()
        defer { watcher.stop() }
        var changes: [Bool] = []
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        watcher.onChange = { changes.append($0) }
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.nowhere

        watcher.setInside(true)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "already open, the pointer off the body is away")
    }

    /// The pin is decided against the body that is opening. Asked before the
    /// choice, it measured the surface shown last.
    func testTheClickAsksAboutTheBodyThatIsOpening() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        vm.open(.settings)
        var asked: CGSize?
        vm.clickOpened(opening: .tray) { body in
            asked = body
            return true
        }
        XCTAssertEqual(
            asked,
            SurfaceLayout.bodySize(for: .tray, bodyWidth: vm.geometry.expandedSize.width, notch: vm.geometry.notchSize)
        )
        XCTAssertFalse(vm.isPinnedOpen)
    }

    /// The whole route at the controller: a click 8 pt in from the far end of
    /// a peek opens the player unpinned, and the watcher holds the panel on
    /// the island the click came from.
    func testAClickOnThePeeksFarEndOpensThePlayerUnpinned() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.pointer.buttonsHeld = { false }
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.open(.player)
        vm.isOpen = false

        let notch = vm.geometry.notchSize
        let peek = vm.geometry.collapsedHoverRect(
            for: notch.width + NotchMetrics.sneakPeekExtension, height: NotchMetrics.sneakPeekHeight
        )
        controller.pointer.collapsedIsland = { peek }
        let point = CGPoint(x: peek.minX + 6 + 8, y: peek.maxY - 10)
        controller.pointerLocation = { point }
        let player = SurfaceLayout.bodySize(
            for: .player, bodyWidth: vm.geometry.expandedSize.width, notch: notch
        )
        XCTAssertFalse(
            vm.geometry.hoverRect(for: player).contains(point),
            "the case at hand: the player does not reach the peek's far end"
        )

        controller.islandClicked(opening: .player)

        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(vm.presented, .player)
        XCTAssertFalse(vm.isPinnedOpen, "the pointer that clicked is on the island; no pin, so walking away closes")
        XCTAssertTrue(controller.pointer.landingRect.contains(point), "and the island it clicked holds the panel")
    }

    // MARK: - Re-review (R-1 … R-4)

    /// With Open on Hover off an arrival opens nothing. The island it arrived
    /// on must not hold the pointer "inside" once the peek has folded and the
    /// pointer rests on bare menu bar: the inside flag refuses the next peek
    /// and the charger's moment, and keeps one already showing up (R-1).
    func testOnAClosedPanelTheIslandHoldsNothing() {
        let watcher = PointerWatcher.withNoButtonHeld()
        defer { watcher.stop() }
        var changes: [Bool] = []
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { false }
        watcher.onChange = { changes.append($0) }
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.nowhere

        sample(watcher, times: 2)
        XCTAssertEqual(changes, [true], "the arrival")
        watcher.openRect = Self.nowhere
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [true, false], "the peek folded: the pointer on the menu bar is away")
    }

    /// The collapse check resyncs with `setInside(true)` on an open panel. It
    /// must keep the island it just counted as "on the panel", or the next
    /// sample folds what the check had decided to keep (R-4).
    func testAResyncOnTheOpenPanelKeepsTheIsland() {
        let watcher = PointerWatcher.withNoButtonHeld()
        defer { watcher.stop() }
        var changes: [Bool] = []
        var open = false
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { open }
        watcher.onChange = { changes.append($0) }
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.nowhere

        watcher.setInside(true)
        open = true
        watcher.openRect = Self.nowhere
        watcher.setInside(true)
        sample(watcher, times: 3)
        XCTAssertEqual(changes, [], "still on the island the panel opened from")
    }

    /// The click lands anywhere the window takes it: the island's shoulders
    /// reach `closedTopRadius` past the body, past the 6 pt the hover rect
    /// pads. A click on that sliver of a peek is on the island too, and the
    /// panel it opens stays open on the next samples under the same pointer
    /// (R-3, and the controller half R-11 asked for).
    func testAClickOnThePeeksShoulderOpensThePlayerAndItStaysOpen() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.pointer.buttonsHeld = { false }
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.open(.settings)
        vm.isOpen = false

        let notch = vm.geometry.notchSize
        let peek = CGSize(
            width: notch.width + NotchMetrics.sneakPeekExtension,
            height: max(notch.height, NotchMetrics.sneakPeekHeight)
        )
        let shoulder = IslandShapeRadii.closed(for: .peek).top
        controller.pointer.collapsedIsland = {
            NotchController.collapsedIslandRect(geometry: vm.geometry, body: peek, shoulder: shoulder, bubble: .zero)
        }
        let drawn = vm.geometry.contentScreenRect(for: peek)
        let point = CGPoint(x: drawn.minX - shoulder + 1, y: drawn.maxY - 10)
        XCTAssertFalse(
            vm.geometry.collapsedHoverRect(for: peek.width, height: peek.height).contains(point),
            "the case at hand: the hover rect stops short of the shoulder"
        )
        controller.pointerLocation = { point }
        controller.pointer.location = { point }
        var changes: [Bool] = []
        controller.pointer.onChange = { changes.append($0) }
        controller.pointer.openDelay = 0
        controller.pointer.closeDelay = 0
        defer { controller.pointer.stop() }

        controller.islandClicked(opening: .player)
        XCTAssertEqual(vm.presented, .player)
        XCTAssertFalse(vm.isPinnedOpen, "a mouse click on the shoulder is on the island")

        for _ in 0..<3 { controller.pointer.start() }
        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(changes, [], "the panel stays open under the pointer that opened it")
    }
}
