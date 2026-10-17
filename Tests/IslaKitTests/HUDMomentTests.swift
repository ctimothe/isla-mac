import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The volume and brightness pop-up as the island draws and prioritises it
/// (redesign 2026-10-15, spec §2.4, §3.3, §12).
@MainActor
final class HUDMomentTests: XCTestCase {

    private func reading(
        _ kind: HUDKind = .volume, _ level: Float = 0.62, muted: Bool = false, symbol: String? = nil
    ) -> HUDReading {
        HUDReading(kind: kind, level: level, muted: muted, deviceSymbol: symbol)
    }

    // MARK: Glyphs

    /// Spec §19.5 d: `speaker.wave.1.fill` … `speaker.wave.3.fill` by level,
    /// in thirds as the Mac's own volume does it.
    func testTheGlyphFollowsTheKindAndTheState() {
        XCTAssertEqual(HUDMoment(reading(.volume, 0.62)).symbol, "speaker.wave.2.fill")
        XCTAssertEqual(HUDMoment(reading(.volume, 0.2)).symbol, "speaker.wave.1.fill")
        XCTAssertEqual(HUDMoment(reading(.volume, 1 / 3)).symbol, "speaker.wave.1.fill", "a third is still one wave")
        XCTAssertEqual(HUDMoment(reading(.volume, 0.9)).symbol, "speaker.wave.3.fill")
        XCTAssertEqual(HUDMoment(reading(.volume, 0)).symbol, "speaker.fill", "level 0")
        XCTAssertEqual(HUDMoment(reading(.volume, 0.62, muted: true)).symbol, "speaker.slash.fill")
        XCTAssertEqual(HUDMoment(reading(.volume, 0, muted: true)).symbol, "speaker.slash.fill", "mute wins over silence")
        XCTAssertEqual(HUDMoment(reading(.display, 0.7)).symbol, "sun.max.fill")
        XCTAssertEqual(HUDMoment(reading(.keyboard, 0.45)).symbol, "light.max")
    }

    func testAirPodsAndHeadphonesWearTheirOwnGlyph() {
        for device in ["airpods", "airpods.pro", "airpods.max", "beats.headphones", "headphones"] {
            XCTAssertEqual(HUDMoment(reading(.volume, 0.4, symbol: device)).symbol, device)
        }
        // The Mac's ordinary outputs say nothing a speaker does not.
        for device in ["laptopcomputer", "hifispeaker", "tv", "airplayaudio", "speaker.wave.2", "waveform"] {
            XCTAssertEqual(HUDMoment(reading(.volume, 0.4, symbol: device)).symbol, "speaker.wave.2.fill", device)
        }
        XCTAssertEqual(HUDMoment(reading(.volume, 0.4, muted: true, symbol: "airpods.pro")).symbol, "speaker.slash.fill")
        XCTAssertEqual(HUDMoment(reading(.volume, 0, symbol: "airpods.pro")).symbol, "speaker.fill")
        // The brightnesses never take a device glyph.
        XCTAssertEqual(HUDMoment(reading(.display, 0.4, symbol: "airpods.pro")).symbol, "sun.max.fill")
    }

    func testEveryGlyphResolves() {
        let all = ["speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill", "speaker.fill",
                   "speaker.slash.fill", "sun.max.fill", "light.max"]
            + Array(HUDSymbol.personalDevices)
        for symbol in all {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    /// Muted keeps the level it will return to, and only the volume mutes.
    /// The bar itself is `ExpandedAlertLayoutTests`'.
    func testMutedKeepsTheLevel() {
        let muted = HUDMoment(reading(.volume, 0.62, muted: true))
        XCTAssertEqual(muted.level, 0.62, "muted keeps the level it will return to")
        XCTAssertFalse(HUDMoment(reading(.display, 0.62, muted: true)).muted)
        XCTAssertEqual(muted.percent, 62)
    }

    // MARK: Accessibility

    func testTheLevelIsSpokenAsAPercentAndMuteIsSpokenAsMuted() {
        let volume = HUDMoment(reading(.volume, 0.62)).accessibilityLabel
        XCTAssertEqual(volume, localized("Volume %@", localized("%d%%", 62)))
        XCTAssertEqual(
            HUDMoment(reading(.display, 0.7)).accessibilityLabel,
            localized("Brightness %@", localized("%d%%", 70))
        )
        XCTAssertEqual(
            HUDMoment(reading(.keyboard, 0.45)).accessibilityLabel,
            localized("Keyboard Brightness %@", localized("%d%%", 45))
        )
        XCTAssertEqual(HUDMoment(reading(.volume, 0.62, muted: true)).accessibilityLabel, localized("Muted"))
        XCTAssertTrue(volume.contains("62"))
        XCTAssertEqual(HUDMoment(reading(.volume, 0.0625)).percent, 6)
    }

    // MARK: Priority

    /// Spec §19.1: the pop-up (rank 3) over the charger (7) over the peek
    /// (10). It no longer hands back what it outranked — the controller drops
    /// that (`testAPopUpOverAChargerDropsIt`) — but whatever the model holds,
    /// the highest is what is drawn.
    func testThePopUpOutranksTheChargerAndThePeek() {
        let hud = HUDMoment(reading())
        let charger = AmbientActivity.charging(level: 80, isCharging: true)
        func current(_ hud: HUDMoment?, _ ambient: AmbientActivity?, peeking: Bool) -> IslandActivity {
            IslandActivity.current(
                hud: hud, ambient: ambient, isPeeking: peeking, musicIsVisible: true, shelfCount: 0
            )
        }
        XCTAssertEqual(current(nil, nil, peeking: false), .music)
        XCTAssertEqual(current(nil, nil, peeking: true), .peek)
        XCTAssertEqual(current(nil, charger, peeking: true), .ambient(charger))
        XCTAssertEqual(current(hud, charger, peeking: true), .hud(hud))
        XCTAssertEqual(current(hud, nil, peeking: true), .hud(hud))
        XCTAssertEqual(current(hud, nil, peeking: false), .hud(hud))
    }

    func testTheViewModelShowsTheHighestActivity() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let charger = AmbientActivity.charging(level: 80, isCharging: true)
        vm.ambient = charger
        XCTAssertEqual(vm.activity, .ambient(charger))

        let hud = HUDMoment(reading())
        vm.hud = hud
        XCTAssertEqual(vm.activity, .hud(hud), "the pop-up takes the pill")
        XCTAssertEqual(
            vm.bodySize,
            ExpandedAlertShape.volume.bodySize(notchSize: vm.geometry.notchSize, bodyWidth: vm.geometry.expandedSize.width)
        )

        vm.hud = nil
        vm.ambient = nil
        vm.isPeeking = true
        XCTAssertEqual(vm.activity, .none, "a peek with no song to widen draws nothing")
    }

    func testOpeningThePanelEndsThePopUp() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.hud = HUDMoment(reading())
        vm.isOpen = true
        XCTAssertNil(vm.hud)
        XCTAssertEqual(vm.bodySize, vm.openBodySize)
    }

    // MARK: Stroke (spec §19.2)

    func testThePopUpIsOutlinedInWhite() {
        // Music or a charger underneath, the pop-up over it: the pop-up is what
        // is drawn, and it has no tint.
        XCTAssertNil(IslandStroke.tint(for: .hud(HUDMoment(reading())), isOpen: false))
        XCTAssertTrue(IslandStroke.isShown(isOpen: false, activityShowing: true, notchAwake: false))
    }

    // MARK: Motion (spec §2.4)

    func testTheMotionValuesAreTheSpecs() {
        XCTAssertEqual(Theme.hudLevel, Animation.easeOut(duration: 0.12))
        XCTAssertEqual(Theme.hudLinger, 1.5)
        // The pop-up widens and folds on the outline's spring (spec §19.3), in
        // the controller and in the shell alike; Reduce Motion crossfades it,
        // and the bar steps.
        XCTAssertEqual(Theme.island(reduceMotion: false), Theme.islandSpring)
        XCTAssertEqual(Theme.island(reduceMotion: true), Theme.reducedMotion)
        XCTAssertEqual(Theme.hudLevel(reduceMotion: false), Theme.hudLevel)
        XCTAssertNil(Theme.hudLevel(reduceMotion: true), "no glide")
    }

    // MARK: Showing and folding

    func testWhereThePopUpMayShow() {
        func allowed(
            open: Bool = false, drop: Bool = false, locked: Bool = false, asleep: Bool = false
        ) -> Bool {
            NotchController.hudAllowed(isOpen: open, isDropTargeted: drop, isLocked: locked, screensAsleep: asleep)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(open: true), "the player has its own slider")
        XCTAssertFalse(allowed(drop: true))
        XCTAssertFalse(allowed(locked: true), "not over the lock screen")
        XCTAssertFalse(allowed(asleep: true))
    }

    private func rig() throws -> (NotchController, NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        controller.hudFoldDelay = 0.15
        return (controller, vm, isolated)
    }

    func testThePopUpFoldsAfterTheLingerAndEachPressRestartsIt() async throws {
        XCTAssertEqual(NotchController().hudFoldDelay, 1.5, "the spec's linger")
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }

        controller.presentHUD(reading(.volume, 0.5))
        XCTAssertEqual(vm.hud?.level, 0.5)
        try await Task.sleep(for: .milliseconds(100))
        controller.presentHUD(reading(.volume, 0.5625))   // a press restarts the wait
        XCTAssertEqual(vm.hud?.level, 0.5625, "the bar follows each press")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(vm.hud, "200 ms after the first press but 100 ms after the last")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(vm.hud, "folded after the last press's linger")
    }

    /// Spec §19.1: a replaced alert is dropped. The charger used to wait
    /// under the pop-up with its own timer and come back when it folded — a
    /// percentage from before the key press, shown again after it.
    func testAPopUpOverAChargerDropsIt() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.ambient = AmbientActivity.charging(level: 80, isCharging: true)
        vm.isPeeking = true
        controller.presentHUD(reading())
        XCTAssertEqual(vm.activity, .hud(HUDMoment(reading())))
        XCTAssertNil(vm.ambient, "replaced, so dropped")
        XCTAssertFalse(vm.isPeeking, "and the peek with it")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(vm.hud)
        XCTAssertEqual(vm.activity, .none, "nothing comes back: the island returns to what is live")
    }

    func testThePopUpIsNotDrawnOverTheOpenPanelOrTheLockScreen() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        controller.presentHUD(reading())
        XCTAssertNil(vm.hud, "the key was applied; nothing is drawn over the open panel")
        vm.isOpen = false
        vm.isLockedPresentation = true
        controller.presentHUD(reading())
        XCTAssertNil(vm.hud, "nothing over the lock screen")
    }

    /// A panel folding still takes its clicks until the fold is done, even
    /// when something re-cuts the shut island's rects meanwhile — an alert
    /// that waited for the panel and is promoted the moment `isOpen` flips is
    /// the usual one. Cut at once, clicks on the visibly folding panel fell
    /// through to the app behind it for about 0.3 s (R7 review).
    func testARecutDuringTheFoldWaitsForItsEnd() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        vm.isPinnedOpen = true
        controller.refreshOpenRects(animated: false)
        let open = try XCTUnwrap(controller.rootView?.activeRect)
        controller.outsideMouseDown()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(vm.isOpen, "the fold has begun")
        controller.refreshCollapsedRects()
        XCTAssertEqual(controller.rootView?.activeRect, open, "the folding panel still answers")
        try await Task.sleep(for: .milliseconds(Int(NotchMetrics.collapseRectShrinkDelay * 1000) + 100))
        XCTAssertLessThan(try XCTUnwrap(controller.rootView?.activeRect).height, open.height, "cut once it has folded")
        controller.refreshCollapsedRects()
        XCTAssertLessThan(try XCTUnwrap(controller.rootView?.activeRect).height, open.height, "and re-cut freely after")
    }

    // MARK: Render

    /// The pop-up draws over each of the three kinds without trapping, and the
    /// island takes the expanded alert's shape (spec §19.5 d).
    func testThePopUpRenders() throws {
        guard let geometry = NotchGeometry.current() else { return XCTFail("a test host always has a screen") }
        for kind in [HUDKind.volume, .display, .keyboard] {
            let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
            vm.hud = HUDMoment(reading(kind, 0.5))
            let view = ZStack(alignment: .top) {
                Color(white: 0.55)
                NotchContentView(vm: vm)
            }
            .frame(width: vm.geometry.expandedSize.width + 80, height: vm.geometry.notchSize.height + 80)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            XCTAssertNotNil(renderer.nsImage, "\(kind)")
            XCTAssertEqual(
                vm.bodySize,
                ExpandedAlertShape.volume.bodySize(
                    notchSize: vm.geometry.notchSize, bodyWidth: vm.geometry.expandedSize.width
                )
            )
        }
    }
}
