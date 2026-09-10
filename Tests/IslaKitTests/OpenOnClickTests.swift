import XCTest
@testable import IslaKit

/// A click opens the island; a hover only says it is there.
@MainActor
final class OpenOnClickTests: XCTestCase {

    private func withDefault(_ value: Bool?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: NotchViewModel.opensOnHoverKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.opensOnHoverKey) }
            else { defaults.removeObject(forKey: NotchViewModel.opensOnHoverKey) }
        }
        if let value { defaults.set(value, forKey: NotchViewModel.opensOnHoverKey) }
        else { defaults.removeObject(forKey: NotchViewModel.opensOnHoverKey) }
        body()
    }

    /// Off unless asked for. The cursor crosses the top of the screen constantly
    /// — reaching the menu bar, the traffic lights, a tab — and an island that
    /// unfolds every time interrupts whatever is underneath it.
    func testHoverDoesNotOpenUnlessItIsAskedTo() {
        withDefault(nil) {
            XCTAssertFalse(NotchViewModel.opensOnHoverEnabled, "a fresh install clicks to open")
        }
        withDefault(true) {
            XCTAssertTrue(NotchViewModel.opensOnHoverEnabled)
        }
        withDefault(false) {
            XCTAssertFalse(NotchViewModel.opensOnHoverEnabled)
        }
    }

    /// The shake belongs to the click, not the hover. A pointer crossing the
    /// top of a locked screen has not asked for anything, and spending the
    /// refusal on it leaves the real click with nothing to say.
    func testTheRefusalIsSpentOnTheClickAndOnlyWhileLocked() {
        let stores = NotchStores()
        guard let geometry = NotchGeometry.current() else {
            return XCTFail("a test host always has a screen")
        }
        let vm = NotchViewModel(geometry: geometry, stores: stores)

        vm.isLockedPresentation = false
        vm.nudgeLockedIsland()
        XCTAssertEqual(vm.lockedHoverNudges, 0, "unlocked, the island opens instead of refusing")

        vm.isLockedPresentation = true
        vm.nudgeLockedIsland()
        vm.nudgeLockedIsland()
        XCTAssertEqual(vm.lockedHoverNudges, 2, "each refused click shakes once")
    }

    /// Hovering is a state the island draws, not an action it takes.
    func testHoveringIsJustAState() {
        let stores = NotchStores()
        guard let geometry = NotchGeometry.current() else {
            return XCTFail("a test host always has a screen")
        }
        let vm = NotchViewModel(geometry: geometry, stores: stores)

        XCTAssertFalse(vm.isHovering)
        vm.isHovering = true
        XCTAssertFalse(vm.isOpen, "the edge is drawn without anything opening")
    }

    /// A panel opened by a click is handed back to the pointer as soon as the
    /// pointer arrives, whether or not hover-to-open is switched on. The
    /// early return for hover-to-open used to sit above the un-pin, so with
    /// the default settings a clicked-open panel stayed pinned, ignored the
    /// pointer leaving, and could only be dismissed by clicking somewhere else
    /// entirely.
    func testThePointerArrivingUnpinsAClickedOpenPanel() {
        withDefault(false) {
            let stores = NotchStores()
            guard let geometry = NotchGeometry.current() else {
                return XCTFail("a test host always has a screen")
            }
            let vm = NotchViewModel(geometry: geometry, stores: stores)

            vm.isPinnedOpen = true
            XCTAssertTrue(vm.holdsOpen)

            vm.pointerArrived()
            XCTAssertFalse(
                vm.isPinnedOpen,
                "with hover-to-open off the pointer still takes the panel back"
            )
            XCTAssertEqual(vm.tab, .media, "arriving always lands on Music")
        }
    }

    /// Closing is the island's job, not the body's. The gesture that opens the
    /// panel is attached to a view that fills the whole window, so letting it
    /// act while open would turn every click on a control inside the panel into
    /// a click that closes the panel out from under the control.
    func testTheCloseTargetIsTheIslandAndNotTheWholeBody() throws {
        let stores = NotchStores()
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let vm = NotchViewModel(geometry: geometry, stores: stores)

        var clicks = 0
        vm.onIslandClick = { clicks += 1 }
        vm.isOpen = true

        let island = vm.geometry.collapsedIslandRect(for: vm.geometry.notchSize.width)
        let body = vm.geometry.contentRect(for: vm.openBodySize)
        XCTAssertLessThan(
            island.height, body.height,
            "the close target must be the island strip, never the open body"
        )
        XCTAssertEqual(clicks, 0, "nothing has been clicked yet")
    }
}
