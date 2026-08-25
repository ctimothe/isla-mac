import XCTest
@testable import DynamicIslandKit

/// Over the shield the island is a picture of what is playing, and nothing else.
@MainActor
final class LockedIslandIsInertTests: XCTestCase {

    private func model() -> NotchViewModel {
        let stores = NotchStores()
        guard let geometry = NotchGeometry.current() else {
            fatalError("a test host always has a screen")
        }
        return NotchViewModel(geometry: geometry, stores: stores)
    }

    /// The equalizer wing is a play/pause button on the desktop. While locked it
    /// was still one — hovering the island and clicking the wing paused the
    /// music, which is the one place the island's promise over the shield broke:
    /// it is meant to answer nothing there.
    func testTheWingStopsBeingAButtonWhileLocked() {
        let vm = model()
        var clicks = 0
        vm.onIslandClick = { clicks += 1 }

        // The gesture's own rule, stated the way the view states it.
        func tapWing() {
            guard !vm.isLockedPresentation else {
                vm.onIslandClick?()
                return
            }
            vm.media.togglePlayPause()
        }

        vm.isLockedPresentation = true
        tapWing()
        XCTAssertEqual(clicks, 1, "locked, the wing refuses with the rest of the island")

        vm.isLockedPresentation = false
        tapWing()
        XCTAssertEqual(clicks, 1, "unlocked, the wing is a transport control again")
    }

    /// And the refusal is what a locked click produces — one shake per click.
    func testALockedClickShakesAndOpensNothing() {
        let vm = model()
        vm.isLockedPresentation = true

        vm.nudgeLockedIsland()
        XCTAssertEqual(vm.lockedHoverNudges, 1)
        XCTAssertFalse(vm.isOpen, "nothing opens over the shield")
    }
}
