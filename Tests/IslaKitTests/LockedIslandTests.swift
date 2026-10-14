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

    /// The whole table, written out (review 2026-10-15: the loop it replaces
    /// restated the production formula, so it could only agree with it). Each row
    /// is (locked, Show on Lock Screen, a song, the compact island has something)
    /// and the two answers a person would give by looking at the lock screen.
    func testTheRuleRowByRow() {
        // locked, show, track, visible -> presents, wings
        let rows: [(Bool, Bool, Bool, Bool, presents: Bool, wings: Bool)] = [
            (false, false, false, false, presents: false, wings: false),
            (false, false, false, true,  presents: false, wings: true),
            (false, false, true,  false, presents: false, wings: false),
            (false, false, true,  true,  presents: false, wings: true),
            (false, true,  false, false, presents: false, wings: false),
            (false, true,  false, true,  presents: false, wings: true),
            (false, true,  true,  false, presents: false, wings: false),
            (false, true,  true,  true,  presents: false, wings: true),
            (true,  false, false, false, presents: false, wings: false),
            (true,  false, false, true,  presents: false, wings: true),
            (true,  false, true,  false, presents: false, wings: false),
            (true,  false, true,  true,  presents: false, wings: true),
            (true,  true,  false, false, presents: false, wings: false),
            (true,  true,  false, true,  presents: false, wings: true),
            (true,  true,  true,  false, presents: true,  wings: false),
            (true,  true,  true,  true,  presents: true,  wings: false),
        ]
        for (locked, show, track, visible, presents, wings) in rows {
            let label = "locked \(locked) show \(show) track \(track) visible \(visible)"
            XCTAssertEqual(
                LockedIsland.presentsSong(locked: locked, showOnLockScreen: show, hasTrack: track), presents, label
            )
            XCTAssertEqual(
                LockedIsland.showsWings(
                    compactVisible: visible, locked: locked, showOnLockScreen: show, hasTrack: track
                ), wings, label
            )
        }
    }

    /// **The hover rect follows a song that starts mid-lock** (review 2026-10-15).
    /// With no song the locked island answers across its compact width; once the
    /// banner holds the song it rests in the notch and answers across the notch
    /// grown for a hover, and the rect the controller cut for the first must be
    /// re-cut, through `refreshCollapsedRects`, or the nudge would land outside
    /// the rect that heard it. The model's size is computed; the rect is the
    /// controller's to keep in step.
    func testTheLockedHoverRectIsRecutWhenATrackStartsMidLock() async throws {
        guard NotchViewModel.showOnLockScreenEnabled else {
            throw XCTSkip("this machine has Show on Lock Screen off; the rule is held row by row above")
        }
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isLockedPresentation = true

        controller.refreshCollapsedRects()
        let before = root.lockedHoverRect
        XCTAssertEqual(before.width, vm.lockedIslandSize.width, accuracy: 0.5)
        XCTAssertFalse(vm.lockSurfacePresentsSong)
        XCTAssertEqual(before.width, vm.bodySize.width, accuracy: 0.5, "no song: the compact island's own width")

        await LabFixtures.play(LabFixtures.Track(), on: isolated.stores.media)
        XCTAssertTrue(vm.lockSurfacePresentsSong)
        controller.refreshCollapsedRects()
        let after = root.lockedHoverRect
        let notch = vm.geometry.notchSize
        XCTAssertEqual(
            after.width, notch.width + 2 * (Theme.collapsedTopRadius + NotchMetrics.hoverNudgeWidth), accuracy: 0.5,
            "the song is the banner's: the rect is the notch grown for a hover"
        )
        XCTAssertGreaterThan(after.width, before.width, "the hover's room is the notch grown, which the old cut lacked")
        XCTAssertEqual(after.midX, before.midX, accuracy: 0.5, "still centred on the notch")
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 0.5, "and still hung from the top")
    }

    /// A click still refuses and says so, whichever form the lock screen shows.
    func testAClickOnTheRestingNotchStillRefuses() {
        // Fixture geometry: `NotchGeometry.current()` is nil on a headless host
        // (Codex review 2026-10-15).
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        guard let geometry = try? LabGeometry.make(physical: true) else { return XCTFail("no fixture geometry") }
        let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
        vm.isLockedPresentation = true
        vm.nudgeLockedIsland()
        XCTAssertEqual(vm.lockedHoverNudges, 1, "the shake")
        XCTAssertFalse(vm.isOpen, "and nothing opens over the shield")
    }
}
