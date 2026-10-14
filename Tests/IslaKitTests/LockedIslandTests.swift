import XCTest
@testable import IslaKit

/// The island over the lock screen (redesign 2026-10-15, spec §3.7, owner
/// decision 1): while the banner or the card is on screen the island has no
/// wings and rests in the notch; hovered it nudges, clicked it refuses; with
/// Show on Lock Screen off nothing changes.
@MainActor
final class LockedIslandTests: XCTestCase {
    /// The rule, over every combination: wings are drawn when the compact island
    /// has something to show and the banner or card is not already showing it.
    func testWingsAreHiddenWhileTheBannerOrTheCardIsPresenting() {
        // Locked, card on, a song: the banner or the card is the song's surface.
        XCTAssertTrue(LockedIsland.presentsSong(locked: true, showOnLockScreen: true, hasTrack: true))
        XCTAssertFalse(LockedIsland.showsWings(
            compactVisible: true, locked: true, showOnLockScreen: true, hasTrack: true
        ), "one surface per activity: the banner holds the song, the island has no wings")
    }

    func testWingsAreShownOtherwise() {
        // Unlocked: the island is the song's surface, as it always was.
        XCTAssertTrue(LockedIsland.showsWings(
            compactVisible: true, locked: false, showOnLockScreen: true, hasTrack: true
        ))
        // Nothing for the compact island to show: nothing to draw either way.
        XCTAssertFalse(LockedIsland.showsWings(
            compactVisible: false, locked: false, showOnLockScreen: true, hasTrack: false
        ))
        XCTAssertFalse(LockedIsland.showsWings(
            compactVisible: false, locked: true, showOnLockScreen: true, hasTrack: true
        ))
        // Locked with no song: the card draws nothing without a track (F-026), so
        // there is no surface for the island to defer to.
        XCTAssertFalse(LockedIsland.presentsSong(locked: true, showOnLockScreen: true, hasTrack: false))
        XCTAssertTrue(LockedIsland.showsWings(
            compactVisible: true, locked: true, showOnLockScreen: true, hasTrack: false
        ))
    }

    /// With Show on Lock Screen off the island behaves as today: no banner and no
    /// card exist to defer to, so the wings are whatever the compact island says.
    func testWithShowOnLockScreenOffTheIslandBehavesAsToday() {
        XCTAssertFalse(LockedIsland.presentsSong(locked: true, showOnLockScreen: false, hasTrack: true))
        XCTAssertTrue(LockedIsland.showsWings(
            compactVisible: true, locked: true, showOnLockScreen: false, hasTrack: true
        ))
        XCTAssertFalse(LockedIsland.showsWings(
            compactVisible: false, locked: true, showOnLockScreen: false, hasTrack: true
        ))
    }

    func testTheRuleIsTotal() {
        for locked in [false, true] {
            for show in [false, true] {
                for track in [false, true] {
                    for visible in [false, true] {
                        let wings = LockedIsland.showsWings(
                            compactVisible: visible, locked: locked, showOnLockScreen: show, hasTrack: track
                        )
                        let presenting = LockedIsland.presentsSong(locked: locked, showOnLockScreen: show, hasTrack: track)
                        XCTAssertEqual(wings, visible && !presenting)
                        XCTAssertEqual(presenting, locked && show && track)
                        if presenting { XCTAssertFalse(wings) }
                    }
                }
            }
        }
    }

    /// A click still refuses and says so, whichever form the lock screen shows.
    func testAClickOnTheRestingNotchStillRefuses() {
        let stores = NotchStores()
        guard let geometry = NotchGeometry.current() else { return XCTFail("a test host always has a screen") }
        let vm = NotchViewModel(geometry: geometry, stores: stores)
        vm.isLockedPresentation = true
        vm.nudgeLockedIsland()
        XCTAssertEqual(vm.lockedHoverNudges, 1, "the shake")
        XCTAssertFalse(vm.isOpen, "and nothing opens over the shield")
    }
}
