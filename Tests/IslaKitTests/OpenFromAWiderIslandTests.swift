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
        let watcher = PointerWatcher()
        defer { watcher.stop() }
        var changes: [Bool] = []
        var open = false
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
        // leaving it is leaving, wherever the island once was.
        watcher.closeRect = Self.everywhere
        sample(watcher, times: 2)
        watcher.closeRect = Self.nowhere
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "once on the body, leaving the body closes")
    }

    /// The hover route, Open on Hover on: the arrival on the peek opens the
    /// player, and the narrower player must not fold it again.
    func testAHoverArrivalOnTheIslandsFarEndIsNotUndoneByTheNarrowerBody() {
        let watcher = PointerWatcher()
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
        let watcher = PointerWatcher()
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
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.open(.player)
        vm.isOpen = false

        let notch = vm.geometry.notchSize
        let peek = vm.geometry.collapsedHoverRect(
            for: notch.width + NotchMetrics.sneakPeekExtension, height: NotchMetrics.sneakPeekHeight
        )
        controller.pointer.openRect = peek
        controller.pointer.bubbleRect = .zero
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
}
