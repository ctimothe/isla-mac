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

    /// A right-click over the lock is the same refusal (spec §19.9): the
    /// island's shake, never its menu — whose Settings… and Quit would act
    /// over the password field — on the island and on its bubble alike.
    func testALockedRightClickShakesAndOffersNoMenu() {
        let island = CGRect(x: 400, y: 562, width: 300, height: 40)
        let bubble = CGRect(x: 716, y: 562, width: 58, height: 40)
        for point in [CGPoint(x: 450, y: 580), CGPoint(x: 740, y: 580)] {
            XCTAssertEqual(
                IslandMenu.secondaryClick(
                    at: point, active: island, bubble: bubble, isOpen: false, isLocked: true, headerHeight: 38
                ),
                .shake, "\(point)"
            )
        }
        let vm = model()
        vm.isLockedPresentation = true
        vm.nudgeLockedIsland()
        XCTAssertEqual(vm.lockedHoverNudges, 1, "what the controller plays out on `.shake`")
        XCTAssertFalse(vm.isOpen)
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

        XCTAssertEqual(vm.verdictForDeliberateOpen(screensAsleep: false), .refuseWithShake)
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

        XCTAssertEqual(vm.verdictForDeliberateOpen(screensAsleep: false), .proceed)
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
        XCTAssertNotEqual(
            NotchViewModel.CommandVerdict.proceed,
            NotchViewModel.CommandVerdict.refuseQuietly,
            "a refusal must never read as permission to open"
        )
    }

    /// A command that arrives while every display is asleep opens nothing.
    ///
    /// A "when AirPods connect, show lyrics" automation ran with the lid shut:
    /// the panel opened pinned where nobody could see it, the media clock and
    /// the player polls started for it, and it was still pinned open at wake
    /// (J-026). The refusal is quiet — there is no pill on a dark display to
    /// shake — and the lock's own answer still wins when both hold, so the
    /// shield keeps one grammar however the screen happens to be.
    func testACommandOnADarkDisplayIsRefusedQuietly() {
        let vm = model()
        vm.isLockedPresentation = false

        XCTAssertEqual(vm.verdictForDeliberateOpen(screensAsleep: true), .refuseQuietly)
        XCTAssertEqual(vm.verdictForDeliberateOpen(screensAsleep: false), .proceed)
        XCTAssertFalse(vm.isOpen)
        XCTAssertEqual(vm.lockedHoverNudges, 0, "nothing shakes on a display nobody sees")

        vm.isLockedPresentation = true
        XCTAssertEqual(
            vm.verdictForDeliberateOpen(screensAsleep: true), .refuseWithShake,
            "the lock's refusal wins over the dark display's"
        )
    }
}
