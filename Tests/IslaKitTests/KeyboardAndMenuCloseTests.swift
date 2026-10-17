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

    // MARK: - Re-review (R-5, R-6, R-8, R-11)

    /// Open on Hover can open the panel behind a menu popped from the closed
    /// island. The row then finds the panel open and leaves the pointer in
    /// charge, rather than pinning a panel the pointer opened (R-5).
    func testAMenuRowAfterTheHoverOpenedThePanelDoesNotPin() throws {
        let (controller, vm) = try rig()
        vm.isOpen = true
        vm.open(.player)
        vm.isPinnedOpen = false
        controller.performMenu(.clipboard, fromOpenPanel: false)
        XCTAssertEqual(vm.presented, .clipboard)
        XCTAssertFalse(vm.isPinnedOpen)
    }

    /// A row chosen on an open panel gives the pointer the menu's return
    /// grace: a row that hung below the body is not a departure.
    func testAMenuRowOnAnOpenPanelGivesThePointerTimeToComeBack() throws {
        let (controller, vm) = try rig()
        vm.isOpen = true
        vm.open(.player)
        let pointer = controller.pointer
        defer { pointer.stop() }
        let far = CGPoint(x: -1_000_000, y: -1_000_000)
        pointer.location = { far }
        controller.pointerLocation = { far }
        pointer.closeDelay = 0
        var changes: [Bool] = []
        pointer.onChange = { changes.append($0) }

        controller.performMenu(.settings, fromOpenPanel: true)
        for _ in 0..<3 { pointer.start() }
        XCTAssertEqual(changes, [], "within the grace the pointer may still be on its way back")
    }

    /// The check `setKeyboard(false)` schedules runs 0.6 s later. After a
    /// keyboard close it found the pointer over where the list had been,
    /// called it inside, and undid `closedByHand()`: with Open on Hover on,
    /// moving onto the island then opened nothing until the pointer had left
    /// that whole rect (R-6). A closed panel is left alone.
    func testTheCollapseCheckLeavesAClosedPanelAlone() throws {
        let (controller, vm) = try rig()
        vm.isOpen = true
        vm.open(.clipboard)
        let onList = CGPoint(
            x: vm.geometry.hoverRect(for: vm.openBodySize).midX,
            y: vm.geometry.hoverRect(for: vm.openBodySize).midY
        )
        controller.pointerLocation = { onList }
        controller.pointer.location = { onList }

        controller.closeFromKeyboard()
        controller.setKeyboard(false)
        let settled = expectation(description: "the check has run")
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.pointerAwayCollapseDelay + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3)

        XCTAssertFalse(vm.isOpen)
        XCTAssertFalse(controller.pointer.isInside, "the pointer that closed it is not counted back in")
    }

    /// A claim refused over the lock is lowered again, a pass later. Left
    /// raised, every later raise was a duplicate the keyboard sink dropped:
    /// the field stayed dead after unlock (R-8).
    func testARefusedKeyboardClaimIsLoweredAgain() throws {
        let (controller, vm) = try rig()
        vm.isLockedPresentation = true
        vm.wantsKeyboard = true
        controller.setKeyboard(true)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(vm.wantsKeyboard)
        XCTAssertFalse(vm.isOpen)
    }

    /// The pin holds Escape, and an open menu takes it back while it tracks:
    /// the registration follows the menu, not only the pin (R-11).
    func testTheEscapeKeyFollowsThePinAndTheMenu() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        let tracking = MenuTracking()
        controller.attachForTesting(viewModel: vm, rootView: root, menuTracking: tracking)
        var live = 0
        controller.escapeKeyRegistrar = { _ in
            live += 1
            return FakeEscapeRegistration { live -= 1 }
        }
        controller.appIsActive = { false }
        let menu = NSMenu()

        vm.isPinnedOpen = true
        XCTAssertEqual(live, 1, "a pinned panel holds Escape")
        tracking.began(ObjectIdentifier(menu))
        XCTAssertEqual(live, 0, "an open menu takes it back")
        tracking.ended(ObjectIdentifier(menu))
        XCTAssertEqual(live, 1, "and returns it when the menu closes")
        vm.isPinnedOpen = false
        XCTAssertEqual(live, 0, "the pin ending gives it up")
    }

    // MARK: - The pages (spec §19.16)

    /// The panel becomes key only when asked. A swipe or a dot to Clipboard
    /// or Translate leaves it as it was, so looking through the pages never
    /// takes typing from the app in front; ⌃⌥⌘V or a click into the field
    /// makes it key; leaving the page by the pointer gives the keyboard back,
    /// and ⌃⇧Tab, which is the keyboard, keeps it.
    func testOnlyAskingMakesThePanelKeyAndLeavingThePageLowersIt() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.pageTravel.clock = ManualPageClock()
        vm.isOpen = true
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        // The controller's one sink, replayed as `ClipboardBrowseTests` does.
        let sink = vm.$wantsKeyboard.removeDuplicates().sink { panel.acceptsKeyboard = $0 }
        defer { sink.cancel() }

        vm.travel(to: .clipboard, reduceMotion: false)
        XCTAssertFalse(panel.canBecomeKey, "a dot to Clipboard")
        vm.travel(to: .translate, reduceMotion: false)
        XCTAssertFalse(panel.canBecomeKey, "a dot to Translate")

        vm.open(.clipboard)
        XCTAssertTrue(panel.canBecomeKey, "⌃⌥⌘V")
        vm.travel(to: .tray, reduceMotion: false)
        XCTAssertFalse(panel.canBecomeKey, "leaving the page gives it back")

        vm.travel(to: .translate, reduceMotion: false)
        // What a click into the field raises (`TranslatePane`, `ClipboardSearchField`).
        vm.wantsKeyboard = true
        XCTAssertTrue(panel.canBecomeKey, "a click into the field")
        XCTAssertTrue(vm.turnPageByKey(-1, reduceMotion: false))
        XCTAssertEqual(vm.surface, .clipboard)
        XCTAssertTrue(panel.canBecomeKey, "⌃⇧Tab keeps it")
    }
}

private final class FakeEscapeRegistration: HotKeyRegistration {
    private let onUnregister: () -> Void
    init(_ onUnregister: @escaping () -> Void) { self.onUnregister = onUnregister }
    func unregister() { onUnregister() }
}
