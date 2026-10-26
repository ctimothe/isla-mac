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
