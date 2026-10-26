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

    /// A charging moment's reading changed while it may still be on the
    /// island — the battery began taking charge, the adapter reported its
    /// watts. The controller applies it only to a Charging moment that is up,
    /// without announcing it again or restarting its hold.
    var onChargeUpdate: ((AmbientActivity) -> Void)?

    /// How long after power arrives the moment is read and shown. Measured on
    /// the owner's MacBook Pro (powerd's log, 2026-10-26 09:55:43): the power
    /// source turns AC at .987 with the battery not yet charging, and powerd
    /// reports "State:Charging" 47 ms later and the adapter's contract at
    /// 0.53 s. Read at the edge, every plug-in said "Not Charging" in white —
    /// the plug where "Charging" belongs — for the whole hold. Short enough
    /// to still be the answer to the cable going in.
    nonisolated static let chargeSettle: TimeInterval = 0.6

    /// When the charge is read again after the edge, while the moment is up.
    /// The battery's reason lags the plug (owner's recording, 2026-10-26
    /// 15:06, Apple's 61 W USB-C at 80 percent): read at the settle, the
    /// moment said "61 W Not Charging"; the same registry read a moment later
    /// gave the hold, 16777216, and nothing asked again — the level and
    /// `IsCharging` never change across a hold, so no power notification
    /// came to prompt `onChargeUpdate`. Three more reads inside the hold, each
    /// one dropped if power left or a newer plug came, and each a no-op when
    /// the answer is unchanged (`NotchController.updateShownCharge`).
    nonisolated static let chargeRereads: [TimeInterval] = [1, 2, 3]

    /// How long after announcing a device the same device stays quiet.
    /// AirPods hopping between a phone and this Mac, or a coreaudiod restart,
    /// reappear within seconds, and each reappearance is not news.
    nonisolated static let repeatQuiet: TimeInterval = 30

    private var powerSource: CFRunLoopSource?
    private var lastPower: Power?
    /// Stamps each arrival, so a reading that settles after the charger was
    /// pulled, or after a newer arrival, is dropped.
    private var arrivalGeneration = 0
    /// Until when power notifications may update a charging moment in place:
    /// the settle plus the hold. Past it nothing is on the island to update,
    /// and the minute-by-minute capacity notifications cost no registry read.
    private var chargeUpdatesUntil: Date?
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
        let date = Date()
        guard now.onExternalPower else {
            // Pulled: an arrival still settling is not one any more.
            arrivalGeneration &+= 1
            chargeUpdatesUntil = nil
            return
        }
        if arrives(previous: lastPower, now: now, at: date) {
            scheduleArrival()
        } else if let until = chargeUpdatesUntil, date < until, now != lastPower {
            readCharge { [weak self] activity in self?.onChargeUpdate?(activity) }
        }
    }

    /// When a Charging moment was last on the island, for `repeatQuiet`.
    ///
    /// Stamped by the controller when it shows one (`chargerShown`), never
    /// here at the edge. Stamped here, a plug-in the controller refused — the
    /// pointer on the island, the panel open past its second, a lid opening
    /// as the cable went in — still spent the 30 s window, and the owner's
    /// charger re-negotiates seconds after every plug-in (pmset log,
    /// 2026-10-23 to 26: AC, then Battery 1–5 s later, then AC again): the
    /// edge that came once the island was free fell inside the window of a
    /// moment nobody saw.
    private var lastChargerShown: Date?

    /// The controller put a Charging moment on the island.
    func chargerShown(at date: Date = Date()) {
        lastChargerShown = date
    }

    /// Whether a reading is a plug-in to show, against the last moment that
    /// was actually shown. Its own function so the measured flap is a test.
    func arrives(previous: Power?, now: Power, at date: Date) -> Bool {
        Self.pluggedIn(previous: previous, now: now, lastAnnounced: lastChargerShown, at: date)
    }

    /// Reads the settled charge off the main thread, `chargeSettle` after the
    /// edge, and hands it over unless power left, or a newer edge came, first.
    private func scheduleArrival() {
        arrivalGeneration &+= 1
        let generation = arrivalGeneration
        chargeUpdatesUntil = Date().addingTimeInterval(Self.chargeSettle + AmbientActivity.chargingHold + 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chargeSettle) { [weak self] in
            self?.readCharge { [weak self] activity in
                guard let self, generation == self.arrivalGeneration else { return }
                self.onEvent?(activity)
            }
        }
        for delay in Self.chargeRereads {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.arrivalGeneration else { return }
                self.readCharge { [weak self] activity in
                    guard let self, generation == self.arrivalGeneration else { return }
                    self.onChargeUpdate?(activity)
                }
            }
        }
    }

    /// The battery, the port and the adapter, read on a utility queue — the
    /// registry is IPC to the kernel, and IOPS a round trip to powerd — and
    /// delivered on the main actor. Nothing if power is gone by then.
    private func readCharge(_ deliver: @escaping @MainActor (AmbientActivity) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let power = Self.readPower(), power.onExternalPower else { return }
            let port = ChargePortReading.read()
            // Only asked of a battery that is not charging: a charging one has
            // no reason to give, and the read is one more registry round trip.
            let hold = power.isCharging ? nil : ChargeHoldReading.read()
            let activity = Self.chargeActivity(power: power, port: port.port, watts: port.watts, hold: hold)
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(activity) } }
        }
    }

    /// The moment a settled reading makes. Pure, so the mapping is a test.
    nonisolated static func chargeActivity(
        power: Power, port: ChargePort, watts: Int?, hold: ChargeHold? = nil
    ) -> AmbientActivity {
        .charging(level: power.level, isCharging: power.isCharging, port: port, watts: watts, hold: hold)
    }

    /// Only the moment external power arrives, and not again within `quiet`
    /// of the last time it was announced. A level change while charging, or a
    /// desktop Mac that was on AC all along, is not an event.
    ///
    /// The window is G-033: a loose USB-C dock drops and restores power every
    /// few seconds, each restore is a genuine false-to-true edge, and with no
    /// window each one re-grew the pill. Headphones had the same window from
    /// the start for the same reason; the charger now keeps it too.
    nonisolated static func pluggedIn(
        previous: Power?, now: Power, lastAnnounced: Date?, at date: Date,
        quiet: TimeInterval = repeatQuiet
    ) -> Bool {
        guard let previous, !previous.onExternalPower, now.onExternalPower else { return false }
        guard let lastAnnounced else { return true }
        return date.timeIntervalSince(lastAnnounced) >= quiet
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
