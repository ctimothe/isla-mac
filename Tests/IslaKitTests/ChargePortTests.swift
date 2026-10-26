import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The charger's two live activities (owner, 2026-10-26): which port the power
/// came in by, what the battery is doing, what the island says and what
/// VoiceOver hears — and the reason the activity was so rarely seen at all.
@MainActor
final class ChargePortTests: XCTestCase {

    // MARK: Fixtures, as `ioreg -r -c IOPortTransportStateCC -w0 -l` printed them

    private func cc(_ parent: String, port: Int, active: Bool) -> [String: Any] {
        [
            "ParentBuiltInPortTypeDescription": parent,
            "ParentPortTypeDescription": parent,
            "TransportDescription": "Port-\(parent)@\(port)/CC",
            "TransportTypeDescription": "CC",
            "Active": active,
        ]
    }

    /// The owner's MacBook Pro: three USB-C ports and MagSafe 3.
    private func macBookPro(magSafe: Bool, usbC3: Bool) -> [ChargePortReading.Transport] {
        [
            cc("USB-C", port: 1, active: false),
            cc("USB-C", port: 2, active: false),
            cc("MagSafe 3", port: 1, active: magSafe),
            cc("USB-C", port: 3, active: usbC3),
        ].compactMap(ChargePortReading.Transport.init(properties:))
    }

    private let adapter61: [String: Any] = [
        "Name": "61W USB-C Power Adapter", "Watts": 61, "Description": "pd charger", "FamilyCode": 18446744073172697098 as UInt64,
    ]

    func testTheMeasuredRegistryEntryParses() throws {
        let transport = try XCTUnwrap(ChargePortReading.Transport(properties: cc("MagSafe 3", port: 1, active: true)))
        XCTAssertTrue(transport.isMagSafe)
        XCTAssertTrue(transport.isActive)
        // Only the transport's own description, as an older macOS may give it.
        let bare = try XCTUnwrap(ChargePortReading.Transport(properties: [
            "TransportDescription": "Port-USB-C@3/CC", "Active": NSNumber(value: true),
        ]))
        XCTAssertTrue(bare.isUSBC)
        XCTAssertTrue(bare.isActive, "an NSNumber flag counts")
        XCTAssertNil(ChargePortReading.Transport(properties: ["Active": true]), "no port named, no transport")
        let older = try XCTUnwrap(ChargePortReading.Transport(properties: [
            "ParentBuiltInPortTypeDescription": "MagSafe 3", "ConnectionActive": true,
        ]))
        XCTAssertTrue(older.isActive, "ConnectionActive is read where Active is missing")
    }

    func testMagSafeActiveIsMagSafe() {
        XCTAssertEqual(
            ChargePortReading.classify(onExternalPower: true, transports: macBookPro(magSafe: true, usbC3: false), adapter: adapter61),
            .magSafe
        )
    }

    func testUSBCActiveIsUSBC() {
        XCTAssertEqual(
            ChargePortReading.classify(onExternalPower: true, transports: macBookPro(magSafe: false, usbC3: true), adapter: adapter61),
            .usbC
        )
    }

    /// A USB-C display or hub makes its port's CC line active too. With MagSafe
    /// charging beside it, the charger is still MagSafe.
    func testMagSafeWinsOverAnActiveUSBCDisplay() {
        XCTAssertEqual(
            ChargePortReading.classify(onExternalPower: true, transports: macBookPro(magSafe: true, usbC3: true), adapter: adapter61),
            .magSafe
        )
    }

    /// A USB-C display alone, on battery: an active CC line and no power. No
    /// activity — the rule needs external power first.
    func testAUSBCDisplayOnBatteryIsNoCharger() {
        XCTAssertNil(ChargePortReading.classify(
            onExternalPower: false, transports: macBookPro(magSafe: false, usbC3: true), adapter: nil
        ))
    }

    /// A MacBook Air with two USB-C ports and no MagSafe: every charge is USB-C,
    /// even one whose CC line the registry has not yet marked.
    func testAMacWithoutMagSafeChargesOverUSBC() {
        let air = [cc("USB-C", port: 1, active: false), cc("USB-C", port: 2, active: false)]
            .compactMap(ChargePortReading.Transport.init(properties:))
        XCTAssertEqual(ChargePortReading.classify(onExternalPower: true, transports: air, adapter: nil), .usbC)
    }

    /// No port controller in the registry (an Intel Mac), or an adapter that
    /// says it is wireless: a power adapter, unnamed.
    func testUnknownOrWirelessIsAPowerAdapter() {
        XCTAssertEqual(ChargePortReading.classify(onExternalPower: true, transports: [], adapter: nil), .adapter)
        XCTAssertEqual(
            ChargePortReading.classify(
                onExternalPower: true, transports: macBookPro(magSafe: true, usbC3: false), adapter: ["IsWireless": true]
            ),
            .adapter
        )
    }

    func testWattsComeFromTheAdapterWhenItSays() {
        XCTAssertEqual(ChargePortReading.watts(from: adapter61), 61)
        XCTAssertEqual(ChargePortReading.watts(from: ["Watts": NSNumber(value: 140)]), 140)
        XCTAssertNil(ChargePortReading.watts(from: ["Watts": 0]), "still negotiating")
        XCTAssertNil(ChargePortReading.watts(from: ["Name": "Adapter"]))
        XCTAssertNil(ChargePortReading.watts(from: nil))
    }

    // MARK: What the battery is doing

    func testStateMapping() {
        XCTAssertEqual(ChargeState(level: 64, isCharging: true), .charging)
        XCTAssertEqual(ChargeState(level: 80, isCharging: false), .notCharging, "held at the Optimized Charging limit")
        XCTAssertEqual(ChargeState(level: 100, isCharging: false), .charged)
        XCTAssertEqual(ChargeState(level: 100, isCharging: true), .charging, "the last percent still charging says so")
    }

    func testTintIsGreenWhileChargingRedWhenLowWhiteWhenHeld() {
        XCTAssertEqual(AmbientActivity.charging(level: 64, isCharging: true, port: .magSafe).chargeTint, .green)
        XCTAssertEqual(AmbientActivity.charging(level: 20, isCharging: true, port: .usbC).chargeTint, .red, "20 percent is low")
        XCTAssertEqual(AmbientActivity.charging(level: 21, isCharging: true).chargeTint, .green)
        XCTAssertEqual(AmbientActivity.charging(level: 12, isCharging: false).chargeTint, .red)
        XCTAssertNil(AmbientActivity.charging(level: 80, isCharging: false).chargeTint, "held: white")
        XCTAssertNil(AmbientActivity.charging(level: 100, isCharging: false).chargeTint, "charged: white")
        XCTAssertNil(AmbientActivity.charging(level: nil, isCharging: true).chargeTint)

        let low = IslandActivity.ambient(.charging(level: 15, isCharging: true, port: .magSafe))
        XCTAssertEqual(IslandStroke.tint(for: low, isOpen: false), Theme.lowBatteryRed, "the stroke wears the red")
        XCTAssertEqual(
            IslandStroke.tint(for: .ambient(.charging(level: 64, isCharging: true, port: .usbC)), isOpen: false),
            Theme.chargingGreen
        )
        XCTAssertNil(IslandStroke.tint(for: low, isOpen: true))
    }

    func testTheLeftWingSaysWhatIsTrue() {
        XCTAssertEqual(AmbientActivity.charging(level: 64, isCharging: true, port: .magSafe, watts: 140).chargeHeadline, "MagSafe")
        XCTAssertEqual(AmbientActivity.charging(level: 64, isCharging: true, port: .usbC, watts: 61).chargeHeadline, "61 W")
        XCTAssertEqual(AmbientActivity.charging(level: 64, isCharging: true, port: .usbC).chargeHeadline, "Charging")
        XCTAssertEqual(AmbientActivity.charging(level: 64, isCharging: true).chargeHeadline, "Charging")
        // The source stays on the leading side whatever the battery does
        // (owner on hardware, 2026-10-26); the state follows it.
        XCTAssertEqual(AmbientActivity.charging(level: 80, isCharging: false, port: .magSafe).chargeHeadline, "MagSafe Not Charging")
        XCTAssertEqual(AmbientActivity.charging(level: 100, isCharging: false, port: .usbC, watts: 61).chargeHeadline, "61 W Charged")
        XCTAssertEqual(AmbientActivity.charging(level: 80, isCharging: false, port: .adapter).chargeHeadline, "Not Charging")
        XCTAssertNil(AmbientActivity.headphones(name: "AirPods", symbol: "airpods").chargeHeadline)
    }

    // MARK: Charging On Hold (owner on hardware, 2026-10-26)

    /// The owner's Mac, as `ioreg -rn AppleSmartBattery` printed it: Apple's
    /// 61 W USB-C charger, 80 percent, `ExternalConnected` Yes, `IsCharging`
    /// No, `FullyCharged` No, `ChargerData.NotChargingReason` 16777216. The
    /// pill read "Not Charging · 80%" with no port and no watts.
    func testTheOwnersHeldChargeReadsChargingOnHoldWithItsWatts() {
        let chargerData: [String: Any] = ["NotChargingReason": NSNumber(value: 16_777_216 as UInt64)]
        let raw = ChargeHoldReading.reason(fromChargerData: chargerData)
        XCTAssertEqual(raw, 16_777_216)
        let hold = ChargeHoldReading.classify(raw, encoding: .bitfield)
        XCTAssertEqual(hold, .onHold)
        let usbC = AmbientWatch.chargeActivity(
            power: .init(onExternalPower: true, level: 80, isCharging: false), port: .usbC, watts: 61, hold: hold
        )
        XCTAssertEqual(usbC.chargeState, .onHold)
        XCTAssertEqual(usbC.chargeSource, "61 W", "the port's identity keeps the leading side")
        XCTAssertEqual(usbC.chargeStatus, "On Hold", "and the state is secondary, in Apple's words")
        XCTAssertEqual(usbC.chargeHeadline, "61 W On Hold")
        XCTAssertNil(usbC.chargeTint, "white: a held charge says nothing it would take back")
        XCTAssertEqual(usbC.chargeSymbol, "powerplug.fill")
        XCTAssertEqual(usbC.accessibilityLabel, "Power adapter connected, charging on hold, 80 percent")

        let magSafe = AmbientActivity.charging(level: 80, isCharging: false, port: .magSafe, watts: 140, hold: .onHold)
        XCTAssertEqual(magSafe.chargeHeadline, "MagSafe On Hold")
        let unplaced = AmbientActivity.charging(level: 80, isCharging: false, port: .adapter, hold: .onHold)
        XCTAssertNil(unplaced.chargeSource)
        XCTAssertEqual(unplaced.chargeHeadline, "Charging On Hold", "alone, the whole phrase")
    }

    /// Apple silicon's bitfield: only the bits the published decoder names,
    /// plus the owner's measured one, are holds; a stop bit wins over a hold;
    /// an unknown bit is "Not Charging"; zero is no reason at all.
    func testTheBitfieldNamesOnlyWhatItCanStandBehind() {
        func classify(_ raw: UInt64?) -> ChargeHold? { ChargeHoldReading.classify(raw, encoding: .bitfield) }
        XCTAssertNil(classify(nil), "no field: the IOPS state alone decides")
        XCTAssertNil(classify(0), "zero: no reason given")
        XCTAssertEqual(classify(1 << 0), .full)
        XCTAssertEqual(classify(1 << 14), .onHold, "charging inhibited by a client: a charge limit")
        XCTAssertEqual(classify(1 << 15), .onHold, "predictive charging: Optimized Battery Charging")
        XCTAssertEqual(classify(1 << 22), .onHold, "the battery requests no charge")
        XCTAssertEqual(classify(1 << 24), .onHold, "the owner's measured hold")
        XCTAssertEqual(classify(1 << 2), .notCharging, "too hot to charge")
        XCTAssertEqual(classify(1 << 3), .notCharging, "too cold to start")
        XCTAssertEqual(classify(1 << 6), .notCharging, "no battery")
        XCTAssertEqual(classify(1 << 21), .notCharging, "a cell's voltage too high")
        XCTAssertEqual(classify(0x10 << 56), .notCharging, "a permanent fault")
        XCTAssertEqual(classify((1 << 15) | (1 << 2)), .notCharging, "a hold beside heat is not the news")
        XCTAssertEqual(classify((1 << 24) | (1 << 0)), .full, "full and held: full")
        XCTAssertEqual(classify(1 << 30), .notCharging, "a bit nobody has named")
        XCTAssertEqual(classify((1 << 30) | (1 << 15)), .onHold, "a named hold beside an unknown bit")
    }

    /// Intel Macs with a T2 report one enumerated value.
    func testTheEnumeratedReasonOfAT2Mac() {
        func classify(_ raw: UInt64) -> ChargeHold? { ChargeHoldReading.classify(raw, encoding: .enumerated) }
        XCTAssertEqual(classify(4), .full)
        for hold: UInt64 in [5, 13, 14, 16] { XCTAssertEqual(classify(hold), .onHold, "\(hold)") }
        for other: UInt64 in [1, 2, 3, 9, 17, 23, 99] { XCTAssertEqual(classify(other), .notCharging, "\(other)") }
        XCTAssertNil(ChargeHoldReading.classify(0, encoding: .enumerated))
    }

    /// The state from the three readings together.
    func testTheStateWeighsTheReasonAfterTheCharge() {
        XCTAssertEqual(ChargeState(level: 80, isCharging: true, hold: .onHold), .charging, "charging is charging")
        XCTAssertEqual(ChargeState(level: 80, isCharging: false, hold: .onHold), .onHold)
        XCTAssertEqual(ChargeState(level: 99, isCharging: false, hold: .full), .charged, "the battery says full")
        XCTAssertEqual(ChargeState(level: 100, isCharging: false, hold: .onHold), .charged, "a full battery is charged")
        XCTAssertEqual(ChargeState(level: 80, isCharging: false, hold: .notCharging), .notCharging)
        XCTAssertEqual(ChargeState(level: 80, isCharging: false, hold: nil), .notCharging, "no reason: as before")
    }

    /// Both languages have all three words, and the Russian is not the
    /// English.
    func testTheHoldIsWordedInBothLanguages() {
        defer { LabLocalization.use("en") }
        LabLocalization.use("ru")
        let held = AmbientActivity.charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold)
        XCTAssertEqual(held.chargeStatus, "Пауза")
        XCTAssertEqual(held.chargeSource, "61 Вт")
        XCTAssertEqual(
            AmbientActivity.charging(level: 80, isCharging: false, hold: .onHold).chargeStatus, "Зарядка приостановлена"
        )
    }

    /// VoiceOver hears it once (`presentAmbient` announces after the guard),
    /// and what it hears names the port.
    func testAccessibilityText() {
        XCTAssertEqual(
            AmbientActivity.charging(level: 64, isCharging: true, port: .magSafe).accessibilityLabel,
            "Charging over MagSafe, 64 percent"
        )
        XCTAssertEqual(
            AmbientActivity.charging(level: 64, isCharging: true, port: .usbC, watts: 61).accessibilityLabel,
            "Charging over USB-C, 64 percent"
        )
        XCTAssertEqual(AmbientActivity.charging(level: 64, isCharging: true).accessibilityLabel, "Charging, 64 percent")
        XCTAssertEqual(
            AmbientActivity.charging(level: 80, isCharging: false, port: .magSafe).accessibilityLabel,
            "Power adapter connected, not charging, 80 percent"
        )
        XCTAssertEqual(
            AmbientActivity.charging(level: 100, isCharging: false).accessibilityLabel,
            "Power adapter connected, charged, 100 percent"
        )
        XCTAssertEqual(AmbientActivity.charging(level: nil, isCharging: true).accessibilityLabel, "Power adapter connected")
    }

    // MARK: Why the activity was so rarely seen

    /// The owner's charger, from the pmset log (2026-10-23 to 26): power
    /// arrives, drops to battery one to five seconds later as the adapter
    /// renegotiates, and arrives again. The first edge was often refused — a
    /// lid opening as the cable went in, the pointer on the island, the panel
    /// open past its second — and the watch had already spent its 30 s quiet
    /// window on it, so the edge that came once the island was free was
    /// swallowed too. The window now counts only from a moment shown.
    func testARefusedPlugInDoesNotSilenceTheNextEdge() {
        let watch = AmbientWatch()
        let battery = AmbientWatch.Power(onExternalPower: false, level: 19)
        let ac = AmbientWatch.Power(onExternalPower: true, level: 19, isCharging: true)
        let t0 = Date()
        XCTAssertTrue(watch.arrives(previous: battery, now: ac, at: t0), "09:55:44, power arrives")
        // Refused: the controller never calls `chargerShown`.
        XCTAssertTrue(
            watch.arrives(previous: battery, now: ac, at: t0.addingTimeInterval(7)),
            "09:55:51, the edge after the renegotiation is shown"
        )
        watch.chargerShown(at: t0.addingTimeInterval(7))
        XCTAssertFalse(
            watch.arrives(previous: battery, now: ac, at: t0.addingTimeInterval(12)),
            "a flap after a moment that was shown stays quiet (G-033)"
        )
        XCTAssertTrue(watch.arrives(previous: battery, now: ac, at: t0.addingTimeInterval(7 + AmbientWatch.repeatQuiet + 1)))
    }

    /// The first reading at the edge has the battery not yet charging (powerd
    /// said "State:Charging" 47 ms after the source turned AC), and the moment
    /// was drawn from it: a white plug and no "Charging", every time. It is
    /// read after a settle, and later readings update it in place.
    func testTheMomentIsReadOnceTheChargeHasSettled() {
        XCTAssertGreaterThan(AmbientWatch.chargeSettle, 0.047)
        XCTAssertLessThan(AmbientWatch.chargeSettle, 1, "still the answer to the cable going in")
        let settled = AmbientWatch.chargeActivity(
            power: .init(onExternalPower: true, level: 64, isCharging: true), port: .magSafe, watts: 96
        )
        XCTAssertEqual(settled, .charging(level: 64, isCharging: true, port: .magSafe, watts: 96))
        XCTAssertEqual(settled.chargeState, .charging)
        XCTAssertEqual(AmbientActivity.chargingHold, 3, "the hold is today's ambient alert's")
    }

    // MARK: Drawing

    func testTheRingDrawsToTheLevel() {
        XCTAssertEqual(MagSafeRing.fraction(level: 64), 0.64, accuracy: 0.0001)
        XCTAssertEqual(MagSafeRing.fraction(level: 140), 1)
        XCTAssertEqual(MagSafeRing.fraction(level: -3), 0)
        for symbol in ["bolt.fill"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
        }
    }

    /// "Not Charging" in Russian is wider than the wing; it may shrink but
    /// never run under the notch.
    func testTheLeftWingStopsShortOfTheNotch() {
        let notch: CGFloat = 185
        let width = notch + NotchMetrics.compactChargingExtension
        let room = CompactIslandLayout.chargingWingTextWidth(islandWidth: width, notchWidth: notch)
        XCTAssertEqual(room, NotchMetrics.compactChargingExtension / 2 - CompactIslandLayout.chargingTextInset - 4)
        XCTAssertGreaterThan(room, 0)
    }

    func testBothVariantsRender() throws {
        guard let geometry = NotchGeometry.current() else { return XCTFail("a test host always has a screen") }
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        for activity in [
            AmbientActivity.charging(level: 64, isCharging: true, port: .magSafe),
            .charging(level: 64, isCharging: true, port: .usbC, watts: 61),
            .charging(level: 12, isCharging: true, port: .magSafe),
            .charging(level: 80, isCharging: false, port: .usbC),
            .charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold),
            .charging(level: 80, isCharging: false, port: .magSafe, hold: .onHold),
        ] {
            let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
            vm.ambient = activity
            let view = NotchContentView(vm: vm).frame(width: vm.geometry.expandedSize.width + 80, height: 80)
            let renderer = ImageRenderer(content: view)
            XCTAssertNotNil(renderer.nsImage, "\(activity) renders")
        }
    }
}
