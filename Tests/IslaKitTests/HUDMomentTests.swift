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

    func testTheLeftWingGlyphFollowsTheKindAndTheState() {
        XCTAssertEqual(HUDMoment(reading(.volume, 0.62)).symbol, "speaker.wave.2.fill")
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
        let all = ["speaker.wave.2.fill", "speaker.fill", "speaker.slash.fill", "sun.max.fill", "light.max"]
            + Array(HUDSymbol.personalDevices)
        for symbol in all {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testSymbolSizeIs13AndADeviceGlyphIs12() {
        XCTAssertEqual(HUDMoment(reading()).symbolPointSize, 13)
        XCTAssertEqual(HUDMoment(reading(.volume, 0.4, symbol: "airpods.pro")).symbolPointSize, 12, "the AirPods board")
    }

    // MARK: The bar

    func testTheBarIsATrackOf80By6AtTheRightWing() {
        // 428 wide: a 220 notch and two 104 wings. Track x is 220 + 104 + 12.
        let track = HUDLayout.trackFrame(islandWidth: 428, height: 38)
        XCTAssertEqual(track.minX, 336)
        XCTAssertEqual(track.width, 80)
        XCTAssertEqual(track.height, 6)
        XCTAssertEqual(track.minY, 16, "centred at 19, as the board's y of 16")
        XCTAssertEqual(HUDLayout.barRadius, 3)
        XCTAssertEqual(HUDLayout.trackOpacity, 0.18)
        XCTAssertEqual(track.maxX, 428 - 12, "12 from the edge")
        // Centred in a taller or shorter island too.
        XCTAssertEqual(HUDLayout.trackFrame(islandWidth: 428, height: 32).midY, 16)
    }

    func testTheFillIsTheLevelOfTheTrackAndMutedKeepsTheLevel() {
        XCTAssertEqual(HUDLayout.fillFrame(level: 0.5, islandWidth: 428, height: 38).width, 40)
        XCTAssertEqual(HUDLayout.fillFrame(level: 0, islandWidth: 428, height: 38).width, 0)
        XCTAssertEqual(HUDLayout.fillFrame(level: 1, islandWidth: 428, height: 38).width, 80)
        XCTAssertEqual(HUDLayout.fillFrame(level: 1.4, islandWidth: 428, height: 38).width, 80, "clamped")
        let muted = HUDMoment(reading(.volume, 0.62, muted: true))
        XCTAssertEqual(muted.level, 0.62, "muted keeps the level it will return to")
        XCTAssertEqual(muted.fillOpacity, 0.32)
        XCTAssertEqual(HUDMoment(reading(.volume, 0.62)).fillOpacity, 1)
        // Only the volume mutes.
        XCTAssertFalse(HUDMoment(reading(.display, 0.62, muted: true)).muted)
    }

    func testThePopUpIsTheNotchPlusTwo104Wings() throws {
        XCTAssertEqual(HUDLayout.wing, 104)
        let hud = HUDMoment(reading())
        XCTAssertEqual(hud.extensionWidth, 208)
        let media = CGSize(width: 300, height: 38)
        let notch = CGSize(width: 220, height: 38)
        let size = NotchViewModel.hudBodySize(hud, media: media, notchSize: notch, bodyWidth: 560)
        XCTAssertEqual(size, CGSize(width: 428, height: 38), "428 wide, the closed island's height")
        // Never wider than the panel it turns into, never narrower than the pill under it.
        XCTAssertEqual(NotchViewModel.hudBodySize(hud, media: media, notchSize: notch, bodyWidth: 400).width, 400)
        XCTAssertEqual(
            NotchViewModel.hudBodySize(hud, media: CGSize(width: 520, height: 50), notchSize: notch, bodyWidth: 560),
            CGSize(width: 520, height: 38), "a peek's height is not taken, and its width is not shrunk"
        )
        // It is the headphones' width: one width for every "something happened" moment.
        XCTAssertEqual(hud.extensionWidth, NotchMetrics.ambientNameExtension)
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

    func testThePopUpOutranksTheChargerAndThePeekAndHandsBack() {
        let hud = HUDMoment(reading())
        let charger = AmbientActivity.charging(level: 80, isCharging: true)
        XCTAssertEqual(IslandMoment.current(hud: nil, ambient: nil, isPeeking: false), .none)
        XCTAssertEqual(IslandMoment.current(hud: nil, ambient: nil, isPeeking: true), .peek)
        XCTAssertEqual(IslandMoment.current(hud: nil, ambient: charger, isPeeking: true), .ambient(charger))
        XCTAssertEqual(IslandMoment.current(hud: hud, ambient: charger, isPeeking: true), .hud(hud))
        XCTAssertEqual(IslandMoment.current(hud: hud, ambient: nil, isPeeking: true), .hud(hud))
        XCTAssertEqual(IslandMoment.current(hud: hud, ambient: nil, isPeeking: false), .hud(hud))
        // And back down the stack as each one ends.
        XCTAssertEqual(IslandMoment.current(hud: nil, ambient: charger, isPeeking: true), .ambient(charger))
        XCTAssertEqual(IslandMoment.current(hud: nil, ambient: nil, isPeeking: true), .peek)
    }

    func testTheViewModelShowsTheHighestMomentAndHandsBackTheRest() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let charger = AmbientActivity.charging(level: 80, isCharging: true)
        vm.isPeeking = true
        vm.ambient = charger
        XCTAssertEqual(vm.moment, .ambient(charger))

        let hud = HUDMoment(reading())
        vm.hud = hud
        XCTAssertEqual(vm.moment, .hud(hud), "the pop-up takes the pill")
        XCTAssertEqual(vm.ambient, charger, "the charger is not cancelled — it keeps its own timer")
        XCTAssertTrue(vm.isPeeking)
        let width = vm.bodySize.width
        XCTAssertEqual(width, min(vm.geometry.notchSize.width + 208, vm.geometry.expandedSize.width))

        vm.hud = nil
        XCTAssertEqual(vm.moment, .ambient(charger), "handed back to what was showing")
        vm.ambient = nil
        XCTAssertEqual(vm.moment, .peek)
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

    func testAPopUpOverAChargerHandsItBackWhenItFolds() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        let charger = AmbientActivity.charging(level: 80, isCharging: true)
        vm.ambient = charger
        controller.presentHUD(reading())
        XCTAssertEqual(vm.moment, .hud(HUDMoment(reading())))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(vm.hud)
        XCTAssertEqual(vm.moment, .ambient(charger), "what was showing comes back")
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

    // MARK: Render

    /// The pop-up draws over each of the four kinds without trapping, and the
    /// island at its width is wide enough for its track.
    func testThePopUpRenders() throws {
        guard let geometry = NotchGeometry.current() else { return XCTFail("a test host always has a screen") }
        for kind in [HUDKind.volume, .display, .keyboard] {
            let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
            vm.hud = HUDMoment(reading(kind, 0.5))
            let view = ZStack(alignment: .top) {
                Color(white: 0.55)
                NotchContentView(vm: vm)
            }
            .frame(width: vm.geometry.expandedSize.width + 80, height: vm.geometry.notchSize.height + 30)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            XCTAssertNotNil(renderer.nsImage, "\(kind)")
            XCTAssertGreaterThan(vm.bodySize.width, vm.geometry.notchSize.width + 200)
        }
    }
}
