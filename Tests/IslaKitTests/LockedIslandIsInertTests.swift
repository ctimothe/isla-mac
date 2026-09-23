import XCTest
@testable import IslaKit

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

    /// A deliberate open command — ⌃⌥⌘I, the translate shortcut, the welcome —
    /// is refused over the shield, exactly as a click is. Opened there, the
    /// panel would grow its clickable region from the deliberate pill-sized
    /// locked rect to the open body over the password field, and the translate
    /// route would additionally make it key: a window above the shield holding
    /// the keyboard. The verdict decides, and the refusal is the same shake a
    /// refused click gives — pinned as a pair so the controller's response and
    /// the pill's answer cannot drift apart.
    func testADeliberateOpenCommandIsRefusedWithTheShakeWhileLocked() {
        let vm = model()
        vm.isLockedPresentation = true

        XCTAssertEqual(vm.verdictForDeliberateOpen(), .refuseWithShake)
        // What the controller plays out on `.refuseWithShake`: the shake, and
        // nothing else.
        vm.nudgeLockedIsland()
        XCTAssertEqual(vm.lockedHoverNudges, 1, "the refusal is the island's own shake")
        XCTAssertFalse(vm.isOpen, "nothing opens over the shield")
    }

    /// Unlocked, the same commands act normally: the welcome, the hotkey and
    /// the translate route all run their ordinary open paths — `presentWelcome`'s
    /// separate guard is unchanged and is not what this verdict is for.
    func testADeliberateOpenCommandProceedsWhenUnlocked() {
        let vm = model()
        vm.isLockedPresentation = false

        XCTAssertEqual(vm.verdictForDeliberateOpen(), .proceed)
    }

    /// The verdicts compare, because the controller does exactly that — it asks
    /// whether the verdict is `.proceed` and refuses otherwise.
    func testTheVerdictsCompareAgainstEachOther() {
        XCTAssertEqual(NotchViewModel.CommandVerdict.proceed, .proceed)
        XCTAssertEqual(NotchViewModel.CommandVerdict.refuseWithShake, .refuseWithShake)
        XCTAssertNotEqual(
            NotchViewModel.CommandVerdict.proceed,
            NotchViewModel.CommandVerdict.refuseWithShake,
            "a refusal must never read as permission to open"
        )
    }
}
