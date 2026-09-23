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
    }

    var onEvent: ((AmbientActivity) -> Void)?

    private var powerSource: CFRunLoopSource?
    private var lastPower: Power?
    private var knownBluetooth: Set<AudioDeviceID> = []
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        stop()
        lastPower = Self.readPower()
        knownBluetooth = Set(Self.bluetoothOutputs().map(\.id))

        // IOKit calls back on the run loop the source is added to, the main
        // one here, with the context pointer it was given.
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

    // MARK: - Power

    private func powerChanged() {
        let now = Self.readPower()
        defer { lastPower = now }
        guard let now, Self.pluggedIn(previous: lastPower, now: now) else { return }
        onEvent?(.charging(level: now.level))
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
            return Power(onExternalPower: state == kIOPSACPowerValue, level: level)
        }
        return nil
    }

    // MARK: - Headphones

    private func devicesChanged() {
        let outputs = Self.bluetoothOutputs()
        let arrived = Self.newArrivals(known: knownBluetooth, now: outputs)
        knownBluetooth = Set(outputs.map(\.id))
        // One at a time. Two devices appearing in one change is a Mac waking
        // with both already paired, and the first is enough to say so.
        guard let device = arrived.first else { return }
        onEvent?(.headphones(name: device.name, symbol: device.symbol))
    }

    nonisolated static func newArrivals(known: Set<AudioDeviceID>, now: [AudioOutputs.Output]) -> [AudioOutputs.Output] {
        now.filter { !known.contains($0.id) }
    }

    private static func bluetoothOutputs() -> [AudioOutputs.Output] {
        AudioOutputs.available().filter {
            $0.transport == kAudioDeviceTransportTypeBluetooth || $0.transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }
}
