import AppKit
import XCTest
@testable import IslaKit

/// How the panel closes and stays open around the keyboard and the island's
/// menu (R8 review F2, F3).
@MainActor
final class KeyboardAndMenuCloseTests: XCTestCase {
    private static let everywhere = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)

    private func rig() throws -> (NotchController, NotchViewModel) {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        return (controller, vm)
    }

    /// Escape, or Return on a Clipboard row, folds the panel with the pointer
    /// perhaps resting on it. The open body's rect is still cut while it
    /// folds, so a plain `setInside(false)` read that pointer back as an
    /// arrival and, with Open on Hover on, reopened the island 50 ms later —
    /// onto the player or Tools, not the Clipboard that was just closed.
    func testAKeyboardCloseIsNotUndoneByThePointerResting() throws {
        let (controller, vm) = try rig()
        vm.isOpen = true
        vm.open(.clipboard)
        let pointer = controller.pointer
        defer { pointer.stop() }
        var arrivals = 0
        pointer.openDelay = 0
        pointer.closeDelay = 0
        pointer.isPanelOpen = { false }
        pointer.onChange = { if $0 { arrivals += 1 } }

        controller.closeFromKeyboard()
        pointer.openRect = Self.everywhere
        pointer.closeRect = Self.everywhere
        for _ in 0..<3 { pointer.start() }

        XCTAssertFalse(vm.wantsKeyboard)
        XCTAssertEqual(arrivals, 0, "the pointer that rested there is not asking for the panel again")
    }

    /// A row chosen from the header of a panel already open leaves the pointer
    /// in charge (spec §19.1's closing rule): no pin, so walking away still
    /// closes, and no Escape held system-wide. The menu's own return grace
    /// covers a row that hung below the body.
    func testAMenuRowOnAnOpenPanelDoesNotPinIt() throws {
        let (controller, vm) = try rig()
        let rows: [(IslandMenuItem.Kind, NotchViewModel.Surface)] = [
            (.clipboard, .clipboard), (.shelf, .tray), (.settings, .settings),
        ]
        for (kind, surface) in rows {
            vm.isOpen = true
            vm.open(.player)
            vm.isPinnedOpen = false
            controller.performMenu(kind, fromOpenPanel: true)
            XCTAssertEqual(vm.presented, surface, "\(kind)")
            XCTAssertFalse(vm.isPinnedOpen, "\(kind) on an open panel leaves the pointer in charge")
        }
        vm.isOpen = true
        vm.open(.player)
        vm.isPinnedOpen = false
        controller.performMenu(.lyrics, fromOpenPanel: true)
        XCTAssertFalse(vm.isPinnedOpen, "Lyrics from an open panel's menu does not pin either")
    }

    /// From the closed island the menu row is the whole gesture, and the hand
    /// is on the menu rather than on the notch: the open is pinned, as a
    /// command's is.
    func testAMenuRowOnTheClosedIslandPins() throws {
        let (controller, vm) = try rig()
        vm.isOpen = false
        controller.performMenu(.shelf, fromOpenPanel: false)
        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(vm.presented, .tray)
        XCTAssertTrue(vm.isPinnedOpen)
    }

    /// Nothing takes the keyboard over the lock, whichever writer raises the
    /// claim. Clipboard's search field writes `wantsKeyboard` directly when it
    /// takes focus, past `open(_:)`'s lock guard, and the keyboard's own route
    /// opened the panel and made it key with no check of its own (R8 review
    /// F6). Unreachable while the pane is gone over the shield; held here so
    /// the rule does not rest on view lifetime.
    func testTheKeyboardIsNotTakenOverTheLock() throws {
        let (controller, vm) = try rig()
        vm.isLockedPresentation = true
        controller.setKeyboard(true)
        XCTAssertFalse(vm.isOpen, "nothing opens over the lock to take the keyboard")
    }
}
