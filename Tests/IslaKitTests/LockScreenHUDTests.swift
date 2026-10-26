import SwiftUI
import XCTest
@testable import IslaKit

/// The island over the lock screen (spec §3.7, amended 2026-10-26; owner:
/// "the island should work on the lock screen too, especially its HUD
/// controls, as minimal as possible without being weird"). The volume and
/// brightness pop-up and the charger show on the locked island, in the pill's
/// compact form, only while the island is over the shield — the panel in the
/// lock screen's SkyLight space with the card. Otherwise every key is the
/// system's, as before. Nothing here locks the Mac or touches the compositor:
/// SkyLight is a fake, and the tap is the gate it decides from.
@MainActor
final class LockScreenHUDTests: XCTestCase {

    private func reading(_ level: Float = 0.5) -> HUDReading {
        HUDReading(kind: .volume, level: level, muted: false, deviceSymbol: nil)
    }

    private func down(_ key: MediaKey, isRepeat: Bool = false) -> MediaKeyPress {
        MediaKeyPress(key: key, isDown: true, isRepeat: isRepeat)
    }

    private func up(_ key: MediaKey) -> MediaKeyPress {
        MediaKeyPress(key: key, isDown: false, isRepeat: false)
    }

    // MARK: The one answer: is the island over the shield

    /// The SkyLight calls, recorded, with a space id the fake hands out.
    @MainActor
    private final class FakeCompositor {
        var nextSpace: UInt64 = 7
        var created = 0
        var added: [(UInt64, Int)] = []
        var removed: [(UInt64, Int)] = []

        func skyLight() -> SkyLight {
            SkyLight(calls: SkyLight.Calls(
                create: { [unowned self] in created += 1; return nextSpace },
                destroy: { _ in },
                setLevel: { _, _ in },
                show: { _ in },
                hide: { _ in },
                add: { [unowned self] space, window in added.append((space, window)) },
                remove: { [unowned self] space, window in removed.append((space, window)) }
            ))
        }
    }

    func testTheIslandIsOverTheShieldExactlyWhileItsWindowIsInTheLiftedSpace() {
        let compositor = FakeCompositor()
        let skyLight = compositor.skyLight()
        let presence = LockScreenPresence(skyLight: skyLight)
        XCTAssertFalse(presence.isAboveShield(windowNumber: 42), "unlocked: not lifted")
        skyLight.lift(windowNumber: 42)
        skyLight.lift(windowNumber: 43) // the card, in the same space
        XCTAssertTrue(presence.isAboveShield(windowNumber: 42), "the panel, with the card, at level 400")
        XCTAssertTrue(presence.isAboveShield(windowNumber: 43))
        skyLight.lower(windowNumber: 43)
        XCTAssertTrue(presence.isAboveShield(windowNumber: 42), "the card leaving first does not take the panel down")
        skyLight.lower(windowNumber: 42)
        XCTAssertFalse(presence.isAboveShield(windowNumber: 42))
    }

    func testASpaceTheCompositorRefusedIsNotOverTheShield() {
        let compositor = FakeCompositor()
        compositor.nextSpace = 0
        let skyLight = compositor.skyLight()
        let presence = LockScreenPresence(skyLight: skyLight)
        skyLight.lift(windowNumber: 42)
        XCTAssertFalse(presence.isAboveShield(windowNumber: 42), "no space, no island over the shield")
        XCTAssertFalse(LockScreenPresence(skyLight: nil).isAboveShield(windowNumber: 42), "a macOS without the SPI")
    }

    // MARK: What may show there

    func testOnlyThePopUpAndTheChargerShowOverTheShield() {
        let hud = IslandActivity.hud(HUDMoment(reading()))
        let charger = IslandActivity.ambient(.charging(level: 80, isCharging: true, port: .magSafe))
        XCTAssertTrue(LockedIsland.showsAlert(hud, overShield: true))
        XCTAssertTrue(LockedIsland.showsAlert(charger, overShield: true))
        XCTAssertFalse(LockedIsland.showsAlert(hud, overShield: false), "not over the shield: nothing")
        XCTAssertFalse(LockedIsland.showsAlert(charger, overShield: false))
        XCTAssertFalse(LockedIsland.showsAlert(.ambient(.headphones(name: "AirPods", symbol: "airpods")), overShield: true))
        XCTAssertFalse(LockedIsland.showsAlert(.confirmation(IslandConfirmation(.copied)), overShield: true))
        XCTAssertFalse(LockedIsland.showsAlert(.peek, overShield: true))
    }

    func testThePopUpsPlacementOverTheLockScreen() {
        func place(locked: Bool, over: Bool, open: Bool = false, asleep: Bool = false) -> NotchController.HUDPlacement? {
            NotchController.hudPlacement(
                isOpen: open, isDropTargeted: false, isLocked: locked, screensAsleep: asleep, overShield: over
            )
        }
        XCTAssertEqual(place(locked: true, over: true), .locked, "the locked island's compact pill")
        XCTAssertNil(place(locked: true, over: false), "not over the shield: the system's own pop-up")
        XCTAssertNil(place(locked: true, over: true, asleep: true), "a dark display draws nothing")
        XCTAssertEqual(place(locked: false, over: false), .pill, "unlocked: as before")
        XCTAssertEqual(place(locked: false, over: false, open: true), .strip)
        XCTAssertFalse(NotchController.hudAllowed(isOpen: false, isDropTargeted: false, isLocked: true, screensAsleep: false))
        XCTAssertTrue(NotchController.hudAllowed(
            isOpen: false, isDropTargeted: false, isLocked: true, screensAsleep: false, overShield: true
        ))
    }

    // MARK: The tap: a locked key is Isla's only while the island can show it

    func testTheGatePassesALockedKeyUnlessTheIslandIsOverTheShield() {
        let gate = MediaKeyGate()
        gate.mirror(enabled: true, locked: true)
        XCTAssertEqual(gate.decide(down(.volumeUp), modifiers: .none, capable: true, now: 1), .pass, "the system's")
        XCTAssertEqual(gate.decide(up(.volumeUp), modifiers: .none, capable: true, now: 1.1), .pass)

        gate.mirror(enabled: true, locked: true, drawsWhileLocked: true)
        XCTAssertEqual(gate.decide(down(.volumeUp), modifiers: .none, capable: true, now: 2), .consume(apply: true))
        XCTAssertEqual(
            gate.decide(down(.volumeUp, isRepeat: true), modifiers: .none, capable: true, now: 2.03),
            .consume(apply: true), "a held key steps over the shield too"
        )
        XCTAssertEqual(gate.decide(up(.volumeUp), modifiers: .none, capable: true, now: 2.1), .consume(apply: false))
        XCTAssertEqual(gate.decide(down(.brightnessDown), modifiers: .none, capable: true, now: 3), .consume(apply: true))
        _ = gate.decide(up(.brightnessDown), modifiers: .none, capable: true, now: 3.1)
        XCTAssertEqual(
            gate.decide(down(.volumeUp), modifiers: MediaKeyModifiers(flags: .maskAlternate), capable: true, now: 4),
            .pass, "the system's chords stay the system's"
        )
        _ = gate.decide(up(.volumeUp), modifiers: .none, capable: true, now: 4.1)
        XCTAssertEqual(gate.decide(down(.volumeUp), modifiers: .none, capable: false, now: 5), .pass, "nothing to apply")
        _ = gate.decide(up(.volumeUp), modifiers: .none, capable: false, now: 5.1)

        let heard = gate.takeLockedPresses()
        XCTAssertEqual(heard.total, 5, "every fresh press heard while locked is counted, for the log")
        XCTAssertEqual(heard.consumed, 2)
        XCTAssertEqual(gate.takeLockedPresses().total, 0, "and the count starts again")
    }

    func testOverTheShieldOnlyWhileLocked() {
        let gate = MediaKeyGate()
        gate.mirror(enabled: true, locked: false, drawsWhileLocked: true)
        XCTAssertEqual(gate.decide(down(.volumeUp), modifiers: .none, capable: true, now: 1), .consume(apply: true))
        _ = gate.decide(up(.volumeUp), modifiers: .none, capable: true, now: 1.1)
        XCTAssertEqual(gate.takeLockedPresses().total, 0, "unlocked presses are not counted")
    }

    /// A Mac that locks mid-hold with the island not over the shield keeps
    /// the old rule: the hold stays consumed so its key-up pairs, and nothing
    /// changes.
    func testALockMidHoldWithoutTheIslandStillSwallowsWithoutApplying() {
        let gate = MediaKeyGate()
        gate.mirror(enabled: true, locked: false)
        XCTAssertEqual(gate.decide(down(.volumeUp), modifiers: .none, capable: true, now: 1), .consume(apply: true))
        gate.mirror(enabled: true, locked: true)
        XCTAssertEqual(
            gate.decide(down(.volumeUp, isRepeat: true), modifiers: .none, capable: true, now: 1.03),
            .consume(apply: false)
        )
        gate.mirror(enabled: true, locked: true, drawsWhileLocked: true)
        XCTAssertEqual(
            gate.decide(down(.volumeUp, isRepeat: true), modifiers: .none, capable: true, now: 1.06),
            .consume(apply: true), "the island came over the shield: the hold steps again"
        )
    }

    // MARK: The pop-up and the charger on the locked island

    private func lockedRig(overShield: Bool) throws -> (NotchController, NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        controller.hudFoldDelay = 0.15
        controller.overShieldForTesting = overShield
        controller.momentsQuietForTesting = false
        vm.isLockedPresentation = true
        return (controller, vm, isolated)
    }

    func testAKeyOverTheShieldShowsTheCompactPillAndFolds() throws {
        let (controller, vm, isolated) = try lockedRig(overShield: true)
        defer { isolated.release() }
        XCTAssertTrue(controller.islandIsOverShield)
        controller.presentHUD(reading(0.5))
        XCTAssertEqual(vm.hud?.level, 0.5)
        XCTAssertEqual(vm.lockedAlert, .hud(try XCTUnwrap(vm.hud)))
        XCTAssertNil(vm.hudStrip, "never the capsule: nothing opens over the shield")
        XCTAssertEqual(
            vm.bodySize,
            LockedHUDLayout.bodySize(notchSize: vm.geometry.notchSize, bodyWidth: vm.geometry.expandedSize.width),
            "the pill's own height, not the 103 pt alert over the lock screen's clock"
        )
        XCTAssertEqual(vm.bodySize.height, vm.geometry.notchSize.height)
        XCTAssertFalse(vm.isOpen, "inert: nothing opened")
        let deadline = Date().addingTimeInterval(3)
        while vm.hud != nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNil(vm.hud, "folds on its own")
    }

    func testNotOverTheShieldNothingIsDrawn() throws {
        let (controller, vm, isolated) = try lockedRig(overShield: false)
        defer { isolated.release() }
        controller.presentHUD(reading())
        XCTAssertNil(vm.hud)
        XCTAssertNil(vm.lockedAlert)
    }

    func testTheChargerPluggedInWhileLockedShowsOnTheLockedIsland() throws {
        try XCTSkipUnless(NotchViewModel.chargingEnabled, "Show Charging is off in this host's defaults")
        let (controller, vm, isolated) = try lockedRig(overShield: true)
        defer { isolated.release() }
        let charge = AmbientActivity.charging(level: 80, isCharging: false, port: .magSafe, hold: .onHold)
        controller.presentAmbient(charge)
        XCTAssertEqual(vm.ambient, charge)
        XCTAssertEqual(vm.lockedAlert, .ambient(charge))
        controller.presentHUD(reading())
        XCTAssertNil(vm.ambient, "the pop-up outranks it")
        controller.presentAmbient(charge)
        XCTAssertNil(vm.ambient, "and a charge under a standing pop-up is not shown")
    }

    func testHeadphonesAndConfirmationsStillWaitForTheUnlock() throws {
        let (controller, vm, isolated) = try lockedRig(overShield: true)
        defer { isolated.release() }
        controller.presentAmbient(.headphones(name: "AirPods", symbol: "airpods"))
        XCTAssertNil(vm.ambient)
        XCTAssertNil(vm.lockedAlert)
        controller.presentConfirmation(IslandConfirmation(.copied))
        XCTAssertNil(vm.confirmation)
        XCTAssertNil(vm.stripNotice)
    }

    func testTheLockedPillRendersWithEachAlert() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        for set in [
            { (vm: NotchViewModel) in vm.hud = HUDMoment(HUDReading(kind: .volume, level: 0.6, muted: false, deviceSymbol: nil)) },
            { (vm: NotchViewModel) in vm.ambient = .charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold) },
        ] {
            let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
            vm.isLockedPresentation = true
            set(vm)
            XCTAssertNotNil(vm.lockedAlert)
            let view = NotchContentView(vm: vm).frame(width: vm.geometry.expandedSize.width + 80, height: 80)
            XCTAssertNotNil(ImageRenderer(content: view).nsImage)
        }
    }
}
