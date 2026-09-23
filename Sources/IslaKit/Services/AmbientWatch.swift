import CoreAudio
import Foundation
import IOKit.ps

/// Watches the two things the island shows without music: the charger and
/// headphones. It hands each arrival to `onEvent` once and polls nothing.
/// Both sources are notifications from the system.
@MainActor
final class AmbientWatch {
    struct Power: Equatable {
        var onExternalPower: Bool
        var level: Int?
        /// Taking charge, as opposed to plugged in and holding: a battery at
        /// its limit, or with charging paused, says so here.
        var isCharging: Bool = false
    }

    /// A Bluetooth output as the watch tracks it: by UID, which survives a
    /// CoreAudio restart and a reconnect, where the numeric device id does
    /// not.
    struct Headphones: Equatable {
        var uid: String
        var name: String
        var symbol: String
    }

    var onEvent: ((AmbientActivity) -> Void)?

    /// How long after announcing a device the same device stays quiet.
    /// AirPods hopping between a phone and this Mac, or a coreaudiod restart,
    /// reappear within seconds, and each reappearance is not news.
    nonisolated static let repeatQuiet: TimeInterval = 30

    private var powerSource: CFRunLoopSource?
    private var lastPower: Power?
    private var knownHeadphones: Set<String> = []
    private var lastAnnounced: [String: Date] = [:]
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        stop()
        lastPower = Self.readPower()
        if let headphones = Self.readHeadphones() { knownHeadphones = Set(headphones.map(\.uid)) }

        // IOKit calls back on the run loop the source is added to, the main
        // one here, with the context pointer it was given. Unretained is safe:
        // the watch lives as long as the stores, which live as long as the
        // app, and `stop` removes the source first.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watch = Unmanaged<AmbientWatch>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watch.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.devicesChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, listener
        ) == noErr {
            devicesListener = listener
        }
    }

    func stop() {
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
        if let devicesListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, devicesListener
            )
            self.devicesListener = nil
        }
    }

    /// Whether this Mac has a battery to report on, for Settings: a desktop
    /// Mac gets no Show Charging switch that could never do anything.
    /// Read once: a battery does not come and go while the app runs.
    nonisolated static let hasBattery: Bool = readPower() != nil

    // MARK: - Power

    private func powerChanged() {
        // A failed read keeps the last good one. Stored as nil, it made the
        // next real plug-in look like the first reading, which is no event.
        guard let now = Self.readPower() else { return }
        defer { lastPower = now }
        guard Self.pluggedIn(previous: lastPower, now: now) else { return }
        onEvent?(.charging(level: now.level, isCharging: now.isCharging))
    }

    /// Only the moment external power arrives. A level change while charging,
    /// or a desktop Mac that was on AC all along, is not an event.
    nonisolated static func pluggedIn(previous: Power?, now: Power) -> Bool {
        guard let previous else { return false }
        return !previous.onExternalPower && now.onExternalPower
    }

    /// The internal battery, or nil on a Mac that has none.
    nonisolated static func readPower() -> Power? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            var level: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                level = Int((Double(current) / Double(maximum) * 100).rounded())
            }
            return Power(
                onExternalPower: state == kIOPSACPowerValue,
                level: level,
                isCharging: (description[kIOPSIsChargingKey] as? Bool) ?? false
            )
        }
        return nil
    }

    // MARK: - Headphones

    private func devicesChanged() {
        // A read that finds no devices at all is a read that failed (a Mac
        // always has somewhere to play), not headphones going away. Taken at
        // its word, it emptied the known set and the next good read
        // announced everything already connected.
        guard let headphones = Self.readHeadphones() else { return }
        let now = Date()
        let arrived = Self.announcements(
            known: knownHeadphones, now: headphones, lastAnnounced: lastAnnounced, at: now
        )
        knownHeadphones = Set(headphones.map(\.uid))
        // One at a time. Two devices appearing in one change is a Mac waking
        // with both already paired, and the first is enough to say so.
        guard let device = arrived.first else { return }
        lastAnnounced[device.uid] = now
        onEvent?(.headphones(name: Self.shortName(device.name), symbol: device.symbol))
    }

    /// The headphones worth announcing: newly present, and not announced in
    /// the last `repeatQuiet` seconds.
    nonisolated static func announcements(
        known: Set<String>, now: [Headphones], lastAnnounced: [String: Date], at date: Date,
        quiet: TimeInterval = repeatQuiet
    ) -> [Headphones] {
        now.filter { device in
            guard !known.contains(device.uid) else { return false }
            guard let last = lastAnnounced[device.uid] else { return true }
            return date.timeIntervalSince(last) >= quiet
        }
    }

    /// The name without its owner. macOS names headphones after the person
    /// who paired them ("Elshod's AirPods Max"), and in a 90 pt wing the
    /// owner's name is what fit and the model is what got cut. Anything not
    /// shaped like that is left alone.
    nonisolated static func shortName(_ name: String) -> String {
        for mark in ["'s ", "’s "] {
            if let range = name.range(of: mark) {
                let rest = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return name
    }

    /// Bluetooth outputs, or nil when CoreAudio returned no devices at all.
    private static func readHeadphones() -> [Headphones]? {
        let outputs = AudioOutputs.available()
        guard !outputs.isEmpty else { return nil }
        return outputs
            .filter { $0.transport == kAudioDeviceTransportTypeBluetooth || $0.transport == kAudioDeviceTransportTypeBluetoothLE }
            .map { Headphones(uid: uid(of: $0.id) ?? "id-\($0.id)", name: $0.name, symbol: $0.symbol) }
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue()
        else { return nil }
        return value as String
    }
}
