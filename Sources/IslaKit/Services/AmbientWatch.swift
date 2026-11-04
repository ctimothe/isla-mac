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

    /// What the watch reads and how it waits: the system's own sources in the
    /// app, and a scripted battery, port and Bluetooth list with a clock that
    /// runs at once in a test. Only the sequencing — a failed read, a pull
    /// before the read lands, a re-read after a pull, a CoreAudio read that
    /// came back empty — was untested before this seam (maturity program
    /// Batch 1, 2026-10-29); each of those is a bug this file names.
    struct Environment {
        /// The internal battery, or nil on a Mac that has none or a failed read.
        var readPower: @Sendable () -> Power?
        /// The port, the adapter's rating and, for a battery not charging, the
        /// reason (`ChargeHoldReading`) — `.settling` when it gives none.
        var readPort: @Sendable (Power) -> (port: ChargePort, watts: Int?, hold: ChargeHold?)
        /// Bluetooth outputs, or nil when CoreAudio returned no devices at all.
        var readHeadphones: @MainActor () -> [Headphones]?
        /// Runs a registry read away from the main thread, and hands its answer
        /// back to it.
        var offMain: @Sendable (@escaping @Sendable () -> Void) -> Void
        var onMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        /// Runs `work` on the main actor after `delay` seconds.
        var after: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> Void
        var now: @MainActor () -> Date

        static let live = Environment(
            readPower: { AmbientWatch.readPower() },
            readPort: { power in
                let port = ChargePortReading.read()
                // Only asked of a battery that is not charging: a charging one
                // has no reason to give, and the read is one more registry round
                // trip. A battery not charging with no reason to give is one
                // still settling: every read here is within seconds of a plug-in.
                let hold = power.isCharging ? nil : (ChargeHoldReading.read() ?? .settling)
                return (port.port, port.watts, hold)
            },
            readHeadphones: { AmbientWatch.readHeadphones() },
            // User-initiated, not utility: this read is what stands between
            // the cable and the island.
            offMain: { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
            onMain: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            },
            now: { Date() }
        )
    }

    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    var onEvent: ((AmbientActivity) -> Void)?

    /// A charging moment's reading changed while it may still be on the
    /// island — the battery began taking charge, the adapter reported its
    /// watts. The controller applies it only to a Charging moment that is up,
    /// without announcing it again or restarting its hold.
    var onChargeUpdate: ((AmbientActivity) -> Void)?

    /// How long power must have been away for its return to be a plug-in.
    ///
    /// The moment used to wait 0.6 s after the edge before it was even read
    /// (`chargeSettle`, 2026-10-26), and kept a 30 s quiet window after each
    /// one it showed. The owner, 2026-10-27: the island was visibly late
    /// behind the menu bar's bolt, and a cable pulled and put back sometimes
    /// showed nothing. The recorder (2026-10-26 15:37) showed what the edge
    /// already knows: AC, the adapter's 61 W and the battery's reason all
    /// arrive in the same 100 ms sample, so the moment is read and shown at
    /// the edge, and corrected in place by `chargeRereads`. Every plug-in is
    /// shown; only a return within this blip — a loose dock's dropout (G-033)
    /// — is not news. The owner's own pulls lasted 2.3 s and 3.7 s.
    nonisolated static let blip: TimeInterval = 1

    /// When the charge is read again after the edge, while the moment is up.
    /// The battery's reason lags the plug (owner's recording, 2026-10-26
    /// 15:06, Apple's 61 W USB-C at 80 percent): read at the settle, the
    /// moment said "61 W Not Charging"; the same registry read a moment later
    /// gave the hold, 16777216, and nothing asked again — the level and
    /// `IsCharging` never change across a hold, so no power notification
    /// came to prompt `onChargeUpdate`. The first two catch the adapter's
    /// contract, which powerd has logged as late as 0.53 s after the edge
    /// (2026-10-26 09:55:43). Reads inside the hold, each
    /// one dropped if power left or a newer plug came, and each a no-op when
    /// the answer is unchanged (`NotchController.updateShownCharge`).
    nonisolated static let chargeRereads: [TimeInterval] = [0.3, 0.6, 1, 2, 3]

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
        seed()

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

    /// What is already there when the watch starts is not news: the charger
    /// a Mac launched on, the headphones already connected.
    func seed() {
        lastPower = environment.readPower()
        if let headphones = environment.readHeadphones() { knownHeadphones = Set(headphones.map(\.uid)) }
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

    /// IOKit's power notification. Internal, so a test can send one.
    func powerChanged() {
        // A failed read keeps the last good one. Stored as nil, it made the
        // next real plug-in look like the first reading, which is no event.
        guard let now = environment.readPower() else { return }
        defer { lastPower = now }
        let date = environment.now()
        guard now.onExternalPower else {
            // Pulled: an arrival still settling is not one any more.
            arrivalGeneration &+= 1
            chargeUpdatesUntil = nil
            if lastPower?.onExternalPower == true { unpluggedAt = date }
            return
        }
        if arrives(previous: lastPower, now: now, at: date) {
            scheduleArrival()
        } else if let until = chargeUpdatesUntil, date < until, now != lastPower {
            readCharge { [weak self] activity in self?.onChargeUpdate?(activity) }
        }
    }

    /// When external power last went away, for `blip`.
    private var unpluggedAt: Date?

    /// Whether a reading is a plug-in to show. Its own function so the
    /// measured pulls are a test.
    func arrives(previous: Power?, now: Power, at date: Date) -> Bool {
        Self.pluggedIn(previous: previous, now: now, unpluggedAt: unpluggedAt, at: date)
    }

    /// Reads the charge off the main thread at once and hands it over unless
    /// power left, or a newer edge came, first; the re-reads correct it in
    /// place.
    private func scheduleArrival() {
        arrivalGeneration &+= 1
        let generation = arrivalGeneration
        chargeUpdatesUntil = environment.now().addingTimeInterval(AmbientActivity.chargingHold + 1)
        readCharge { [weak self] activity in
            guard let self, generation == self.arrivalGeneration else { return }
            self.onEvent?(activity)
        }
        for delay in Self.chargeRereads {
            environment.after(delay) { [weak self] in
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
        let environment = self.environment
        environment.offMain {
            guard let power = environment.readPower(), power.onExternalPower else { return }
            let port = environment.readPort(power)
            let activity = Self.chargeActivity(power: power, port: port.port, watts: port.watts, hold: port.hold)
            environment.onMain { deliver(activity) }
        }
    }

    /// The moment a settled reading makes. Pure, so the mapping is a test.
    nonisolated static func chargeActivity(
        power: Power, port: ChargePort, watts: Int?, hold: ChargeHold? = nil
    ) -> AmbientActivity {
        .charging(level: power.level, isCharging: power.isCharging, port: port, watts: watts, hold: hold)
    }

    /// Only the moment external power arrives, and not a return within
    /// `blip` of it leaving. A level change while charging, or a desktop Mac
    /// that was on AC all along, is not an event.
    nonisolated static func pluggedIn(
        previous: Power?, now: Power, unpluggedAt: Date?, at date: Date, blip: TimeInterval = blip
    ) -> Bool {
        guard let previous, !previous.onExternalPower, now.onExternalPower else { return false }
        guard let unpluggedAt else { return true }
        return date.timeIntervalSince(unpluggedAt) >= blip
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

    /// CoreAudio's device-list notification. Internal, so a test can send one.
    func devicesChanged() {
        // A read that finds no devices at all is a read that failed (a Mac
        // always has somewhere to play), not headphones going away. Taken at
        // its word, it emptied the known set and the next good read
        // announced everything already connected.
        guard let headphones = environment.readHeadphones() else { return }
        let now = environment.now()
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
    static func readHeadphones() -> [Headphones]? {
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
