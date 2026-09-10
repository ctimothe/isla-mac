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

    /// The view model the pointer rules are played out against. `nil` only if
    /// the host has no screen at all.
    private func makeViewModel() -> NotchViewModel? {
        guard let geometry = NotchGeometry.current() else {
            XCTFail("a test host always has a screen")
            return nil
        }
        return NotchViewModel(geometry: geometry, stores: NotchStores())
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
    ///
    /// What this can check: that the strip a click has to hit is a fraction of
    /// the open body, and that the callback the strip's tap target raises is the
    /// one the collapsed pill raises. What it cannot: that the tap target is
    /// where it is drawn. That needs a hosted view and a synthesised click, and
    /// nothing in this suite hosts a view for events — so the hit region itself
    /// is checked by hand on the device, not here.
    func testTheCloseTargetIsTheIslandAndNotTheWholeBody() throws {
        let vm = try XCTUnwrap(makeViewModel())

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
        vm.onIslandClick?()
        XCTAssertEqual(clicks, 1, "the strip raises the same click the pill does")
    }

    /// The whole sequence, in the order a hand performs it: the pointer reaches
    /// the island, the island is clicked, the pointer walks away — and the panel
    /// closes.
    ///
    /// It did not, in the default configuration, until 2026-09-10. The click
    /// pinned the panel, and the pin is only dropped when the pointer *arrives*
    /// — a transition that had already happened on the way to the click, and
    /// cannot happen twice — so the departure was refused by `holdsOpen` and the
    /// panel stood open until something else on screen was clicked.
    func testAClickedOpenPanelClosesWhenThePointerWalksAway() {
        withDefault(false) {
            guard let vm = makeViewModel() else { return }

            // Reaching the island. This arrival is unavoidable: the pointer has
            // to be on the island to click it.
            XCTAssertEqual(
                vm.pointerCrossed(inside: true), .standsAsItIs,
                "with hover-to-open off, arriving says the island is there and nothing more"
            )

            // The click, from a pointer that is therefore on the panel.
            vm.clickOpened(pointerIsOnPanel: true)
            vm.isOpen = true
            XCTAssertFalse(
                vm.holdsOpen,
                "a click the pointer made needs no pin — the pointer is already holding it"
            )
            XCTAssertEqual(vm.tab, .media, "a click opens on Music")

            // Walking away.
            XCTAssertEqual(
                vm.pointerCrossed(inside: false), .closes,
                "walking away from a clicked-open panel closes it"
            )
        }
    }

    /// The routes that have no pointer keep the pin: ⌥⌘I, and the compact
    /// island's accessibility action, which VoiceOver fires from the keyboard.
    /// There the cursor really is wherever it was left, the next sample calls it
    /// away, and without the pin the panel folds a third of a second after it
    /// appeared.
    func testAnOpenWithThePointerElsewhereKeepsItsPin() {
        withDefault(false) {
            guard let vm = makeViewModel() else { return }

            vm.clickOpened(pointerIsOnPanel: false)
            vm.isOpen = true
            XCTAssertTrue(vm.holdsOpen, "nothing else is holding this panel open")
            XCTAssertEqual(
                vm.pointerCrossed(inside: false), .standsAsItIs,
                "a pointer that was never on the panel cannot close it by leaving"
            )

            // Until the pointer comes to it. Then leaving means what it always
            // means.
            XCTAssertEqual(vm.pointerCrossed(inside: true), .standsAsItIs)
            XCTAssertFalse(vm.holdsOpen, "arriving hands the panel back to the pointer")
            XCTAssertEqual(vm.pointerCrossed(inside: false), .closes)
        }
    }

    /// A drag hovering the island keeps the Shelf.
    ///
    /// `onDragEntered` selects the Shelf so the file has somewhere to land. The
    /// pointer arrival that follows roughly `openDelay` later used to run
    /// `select(.media)` anyway, flipping the pane Shelf→Music with the file
    /// still in the air and taking `ShelfPane`'s drop highlight with it; only
    /// the drop put it back. A drag is not a hover — it has already said where
    /// it is going.
    func testADragHoveringTheIslandKeepsTheShelf() {
        withDefault(false) {
            guard let vm = makeViewModel() else { return }

            // What `onDragEntered` does.
            vm.tab = .shelf
            vm.isDropTargeted = true

            XCTAssertEqual(vm.pointerCrossed(inside: true, dragging: true), .standsAsItIs)
            XCTAssertEqual(vm.tab, .shelf, "the file is still over the island")

            // The same arrival without a file in hand is an ordinary hover, and
            // a hover lands on Music.
            XCTAssertEqual(vm.pointerCrossed(inside: true, dragging: false), .standsAsItIs)
            XCTAssertEqual(vm.tab, .media)
        }
    }
}
