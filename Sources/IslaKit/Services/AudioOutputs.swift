import CoreAudio
import Foundation

/// The Mac's audio output devices, and which one is currently in use.
///
/// The lock card's device glyph is the one control on it that is not transport:
/// the reference cards put the output device there, and a glyph that names a
/// device but cannot change it is decoration. Switching the *system's* default
/// output is the honest reading of that button — no app's audio can be moved
/// individually from outside it, but every app follows the default, which is
/// what "play it on the speakers instead" means in practice.
enum AudioOutputs {
    struct Output: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        /// Transport as CoreAudio reports it, for choosing a glyph.
        let transport: UInt32
        /// What the device says it *is*, where it says so. Nil for everything
        /// that publishes no data source, which is most things on a wire.
        var dataSource: UInt32?

        var symbol: String {
            AudioOutputs.symbol(forTransport: transport, dataSource: dataSource, name: name)
        }
    }

    /// Every device that can actually play something.
    static func available() -> [Output] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = name(of: id) else { return nil }
            return Output(id: id, name: name, transport: transport(of: id), dataSource: dataSource(of: id))
        }
    }

    /// The device everything currently plays through.
    static func current() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != 0 else { return nil }
        return id
    }

    /// Sends everything to a different device. Returns whether it took.
    @discardableResult
    static func select(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        ) == noErr
    }

    /// The symbol that says what kind of thing is playing the music. Pure, so
    /// the mapping is testable without a sound card.
    /// Data-source codes CoreAudio publishes for the built-in device. Four
    /// characters, the same shape as a transport type.
    enum DataSource {
        static let internalSpeaker: UInt32 = 0x69737063  // 'ispk'
        static let headphones: UInt32 = 0x6864706E       // 'hdpn'
        static let externalSpeaker: UInt32 = 0x65737063  // 'espk'
    }

    /// The glyph for a device, preferring what it says it *is* over what it is
    /// plugged into.
    ///
    /// Transport alone gets the built-in Mac wrong the moment something is in
    /// the headphone jack: the transport is still `bltn`, and the card would
    /// keep drawing a laptop while the sound went to headphones. The data
    /// source is the field that knows, so it is asked first.
    static func symbol(
        forTransport transport: UInt32, dataSource: UInt32? = nil, name: String? = nil
    ) -> String {
        // The device's own name first, because it is the only thing that tells
        // AirPods Pro from AirPods Max: both arrive over Bluetooth, both publish
        // no data source, and CoreAudio has no notion of a product family. The
        // system's own output menu draws the same distinction, and these are the
        // symbols Apple ships for it — not lookalikes.
        //
        // Matching on a product name is a heuristic, and it is used only to pick
        // a *better* glyph: anything unrecognised falls through to the transport
        // below and is merely generic, never wrong. Product names are the same
        // in every language, which is what makes this survive a localised Mac.
        if let name = name?.lowercased() {
            if name.contains("airpods max") { return "airpods.max" }
            if name.contains("airpods pro") { return "airpods.pro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") || name.contains("powerbeats") { return "beats.headphones" }
            if name.contains("homepod") { return "homepod" }
            if name.contains("apple tv") { return "appletv" }
            if name.contains("studio display") || name.contains("pro display") { return "display" }
            // Wired Apple headphones, and the generic word every third-party
            // headset puts in its name.
            if name.contains("earpods") || name.contains("headphone")
                || name.contains("headset") || name.contains("earbud") {
                return "headphones"
            }
        }
        switch dataSource {
        case DataSource.headphones: return "headphones"
        case DataSource.internalSpeaker: return "laptopcomputer"
        case DataSource.externalSpeaker: return "hifispeaker"
        default: break
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        // Neutral on purpose. USB is a wire, not a kind of thing: USB-C EarPods
        // and a pair of studio monitors arrive identically, publish no data
        // source, and nothing else in CoreAudio distinguishes them. This used
        // to draw a floor-standing speaker, which is confidently wrong for the
        // commonest case of the two. A generic output glyph is merely vague.
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire: return "speaker.wave.2"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2"
        }
    }

    // MARK: - One device

    /// What the device says it is, when it says so. Absent on most things that
    /// arrive over a wire, which is why it is optional rather than a default.
    private static func dataSource(of id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        let string = name as String
        return string.isEmpty ? nil : string
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }
}
