import Foundation
import IOKit
import IOKit.ps

/// Which way the power is coming in (owner, 2026-10-26): MagSafe and USB-C get
/// a Charging activity each, because on a Mac with both the two are different
/// gestures — a magnet that clicks on, a cable that pushes in — and the island
/// should name the one that just happened.
///
/// `adapter` is the honest answer when the Mac cannot say: a Mac with no port
/// controller in the registry (Intel, or a macOS that renamed the classes), or
/// an adapter that calls itself wireless. It draws the USB-C layout without
/// naming a port.
enum ChargePort: Equatable, Sendable {
    case magSafe
    case usbC
    case adapter
}

/// Reads the port and the adapter's wattage from the I/O Registry. Every read
/// is synchronous IPC to the kernel's registry and is made off the main thread
/// (`AmbientWatch.scheduleArrival`); the decisions are pure functions over
/// plain dictionaries so each case is a test fixture, not a cable.
///
/// What was measured on a MacBook Pro with MagSafe 3 (macOS 27.0.1, 2026-10-26),
/// with `ioreg -r -c IOPortTransportStateCC -w0 -l`:
///
/// - One `IOPortTransportStateCC` per port: `ParentBuiltInPortTypeDescription`
///   "USB-C" or "MagSafe 3", `TransportDescription` "Port-USB-C@3/CC", and
///   `Active` Yes on the port whose CC line is connected — USB-C@3 alone while
///   charging over USB-C. The key is `Active`; the `ConnectionActive` keys
///   elsewhere in the tree read No on every port while charging, as did
///   `IOPortFeaturePowerIn`'s, so neither is used.
/// - `AppleSmartBattery`'s `AdapterDetails` carries `Watts` 61 and `Name`
///   "61W USB-C Power Adapter"; `IOPSCopyExternalPowerAdapterDetails` returns
///   the same dictionary where powerd answers, and nil from a sandboxed probe,
///   so the registry is the fallback.
///
/// A CC line is active for anything plugged into the port, a display or a hub
/// as much as a charger, so the port alone never says power arrived: external
/// power comes from IOPS, and the port only says which way.
enum ChargePortReading {
    /// One port's CC transport, as the registry describes it.
    struct Transport: Equatable, Sendable {
        /// "MagSafe 3", "USB-C", or the transport's own description when the
        /// parent type is missing.
        var portType: String
        var isActive: Bool

        var isMagSafe: Bool { portType.localizedCaseInsensitiveContains("MagSafe") }
        var isUSBC: Bool { portType.localizedCaseInsensitiveContains("USB-C") }

        /// From one service's properties, or nil for a dictionary that names
        /// no port at all.
        init?(properties: [String: Any]) {
            let type = properties["ParentBuiltInPortTypeDescription"] as? String
                ?? properties["ParentPortTypeDescription"] as? String
                ?? properties["TransportDescription"] as? String
            guard let type, !type.isEmpty else { return nil }
            portType = type
            isActive = Self.flag(properties["Active"]) || Self.flag(properties["ConnectionActive"])
        }

        init(portType: String, isActive: Bool) {
            self.portType = portType
            self.isActive = isActive
        }

        private static func flag(_ value: Any?) -> Bool {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            return false
        }
    }

    /// The rule. Nil off external power: a USB-C display makes a CC line
    /// active without a watt going into the battery.
    ///
    /// - MagSafe's CC line active → MagSafe, even with a USB-C display or hub
    ///   active beside it: only a charger uses the MagSafe port.
    /// - Otherwise a Mac with USB-C ports is charging over one of them; with a
    ///   MagSafe port present but idle, there is nowhere else it could be.
    /// - No port controller in the registry, or an adapter that says it is
    ///   wireless, is a power adapter the Mac cannot place.
    static func classify(onExternalPower: Bool, transports: [Transport], adapter: [String: Any]?) -> ChargePort? {
        guard onExternalPower else { return nil }
        if let adapter, (adapter["IsWireless"] as? Bool) == true { return .adapter }
        if transports.contains(where: { $0.isMagSafe && $0.isActive }) { return .magSafe }
        if transports.contains(where: { $0.isUSBC || $0.isMagSafe }) { return .usbC }
        return .adapter
    }

    /// The adapter's rating in whole watts, or nil when it does not say.
    /// A 0 or a negative rating is a reading still settling, not a charger.
    static func watts(from adapter: [String: Any]?) -> Int? {
        guard let adapter else { return nil }
        let raw = (adapter["Watts"] as? NSNumber)?.intValue ?? (adapter["Watts"] as? Int)
        guard let raw, raw > 0, raw < 1000 else { return nil }
        return raw
    }

    // MARK: - The registry (off the main thread)

    /// The port and wattage now, for a Mac already on external power.
    static func read() -> (port: ChargePort, watts: Int?) {
        let adapter = readAdapter()
        let port = classify(onExternalPower: true, transports: readTransports(), adapter: adapter) ?? .adapter
        return (port, watts(from: adapter))
    }

    static func readTransports() -> [Transport] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOPortTransportStateCC"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var transports: [Transport] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            // Key by key, not the whole property table: the table carries an
            // `IOGeneralInterest` entry that is not serializable, and four
            // values is all the rule reads.
            var properties: [String: Any] = [:]
            for key in ["ParentBuiltInPortTypeDescription", "ParentPortTypeDescription",
                        "TransportDescription", "Active", "ConnectionActive"] {
                if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() {
                    properties[key] = value
                }
            }
            if let transport = Transport(properties: properties) { transports.append(transport) }
        }
        return transports
    }

    static func readAdapter() -> [String: Any]? {
        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            return details
        }
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        return IORegistryEntryCreateCFProperty(battery, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}

/// Why a battery on external power is not taking charge, as the island words
/// it (owner on hardware, 2026-10-26): plugged into Apple's 61 W USB-C
/// charger at 80 percent with the charge held, the pill read "Not Charging ·
/// 80%" and dropped the watts. macOS's own battery menu says "Charging On
/// Hold" for a charge the Mac holds on purpose, and that is what the island
/// says now; "Not Charging" is left for the other reasons.
enum ChargeHold: Equatable, Sendable {
    /// The Mac holds the charge on purpose: Optimized Battery Charging, a
    /// charge limit, a battery topped up that asks for no more.
    case onHold
    /// The battery reports itself full.
    case full
    /// Anything else, an unknown reason included: too hot or too cold, a
    /// fault, no battery, a charger it will not take power from.
    case notCharging
}

/// `AppleSmartBattery`'s `ChargerData.NotChargingReason`, read and sorted.
///
/// **The field is not public API.** IOKit's headers (`IOPSKeys.h`,
/// `IOPMPowerSource.h`) and Apple's open-source PowerManagement and IOKitUser
/// trees name no such key and no value for it (searched 2026-10-26). What the
/// values mean comes from the one public decoder that names them, Battman's
/// `not_charging_reason.h` (github.com/Torrekie/Battman, read 2026-10-26),
/// and from the owner's own Mac: on a MacBook Pro with MagSafe 3, macOS
/// 27.0.1, held at 80 percent on a 61 W USB-C adapter, `ioreg -rn
/// AppleSmartBattery` read `ExternalConnected` Yes, `IsCharging` No,
/// `FullyCharged` No and `NotChargingReason` 16777216 (bit 24), a bit
/// Battman's table does not list.
///
/// So the rule names only what it can stand behind, and everything else is
/// "Not Charging", which is never untrue of a battery that is not charging:
///
/// - Apple silicon reports a bitfield (Battman's "version 2", the SMC's
///   CHNC). Bit 0 is full. Bits 14 (charging inhibited by a client — a charge
///   limit), 15 (predictive charging: Optimized Battery Charging), 22 (the
///   battery requests no charge) and 24 (the owner's measured hold) are
///   holds. Temperature, timer, presence and fault bits make it "Not
///   Charging" whatever else is set, because a hold beside a fault is not
///   the news.
/// - Intel Macs with a T2 report an enumerated value (Battman's "version 1",
///   BNCR): 4 is full; 5 (no charge requested), 13 (the OS asked for none),
///   14 (the charge limit, BCLM, reached) and 16 (power management asked for
///   none) are holds.
/// - Zero, or no field at all, is no reason: the IOPS state alone decides.
enum ChargeHoldReading {
    enum Encoding: Equatable, Sendable {
        case bitfield
        case enumerated
    }

    /// The encoding this Mac's battery firmware uses.
    static var native: Encoding {
        #if arch(arm64)
        return .bitfield
        #else
        return .enumerated
        #endif
    }

    static let fullBit: UInt64 = 1 << 0
    /// 14 inhibited by a client, 15 predictive charging, 22 no charge
    /// requested, 24 the owner's measured hold (2026-10-26).
    static let holdBits: UInt64 = (1 << 14) | (1 << 15) | (1 << 22) | (1 << 24)
    /// 1–4 temperature, 5 the charge timer, 6 no battery, 7 no bus power,
    /// 9 the controller unreachable, 21 a cell's voltage too high, and the
    /// permanent faults in the top byte.
    static let stopBits: UInt64 = (0b1111 << 1) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 9) | (1 << 21)
        | (0xFF << 56)

    static let enumeratedFull: UInt64 = 4
    static let enumeratedHolds: Set<UInt64> = [5, 13, 14, 16]

    /// Nil when the battery gives no reason (zero or no field); otherwise
    /// what the island calls it. Pure, so every measured and published value
    /// is a fixture.
    static func classify(_ raw: UInt64?, encoding: Encoding = native) -> ChargeHold? {
        guard let raw, raw != 0 else { return nil }
        switch encoding {
        case .bitfield:
            if raw & stopBits != 0 { return .notCharging }
            if raw & fullBit != 0 { return .full }
            if raw & holdBits != 0 { return .onHold }
            return .notCharging
        case .enumerated:
            if raw == enumeratedFull { return .full }
            return enumeratedHolds.contains(raw) ? .onHold : .notCharging
        }
    }

    /// The raw reason from a `ChargerData` dictionary.
    static func reason(fromChargerData data: [String: Any]?) -> UInt64? {
        guard let number = data?["NotChargingReason"] as? NSNumber else { return nil }
        return number.uint64Value
    }

    /// The battery's reason now. IPC to the kernel's registry: off the main
    /// thread only (`AmbientWatch.readCharge`).
    static func read() -> ChargeHold? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        let data = IORegistryEntryCreateCFProperty(battery, "ChargerData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return classify(reason(fromChargerData: data))
    }
}
