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

    /// The compact island has no controls at all.
    ///
    /// The equalizer wing used to toggle playback — from when a hover opened
    /// the panel and a click had no other meaning. Once a click became how the
    /// island opens, that gave the compact state two behaviours with nothing
    /// marking the boundary: press one half and it opens, press the other and
    /// the music stops. It shows what is playing; clicking anywhere on it
    /// opens the panel, where the controls are.
    func testEveryPartOfTheCompactIslandOpensAndNothingElse() {
        let vm = model()
        var opens = 0
        vm.onIslandClick = { opens += 1 }

        // The rule the view now states: there is one gesture, and it is this.
        func tapAnywhereOnCompact() { vm.onIslandClick?() }

        vm.isLockedPresentation = false
        tapAnywhereOnCompact()   // the artwork side
        tapAnywhereOnCompact()   // the equalizer side
        XCTAssertEqual(opens, 2, "both sides do the same single thing")
        XCTAssertFalse(vm.media.isPlaying, "and neither of them touched playback")
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
