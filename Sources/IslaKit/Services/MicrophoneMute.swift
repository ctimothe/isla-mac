import CoreAudio
import Foundation

/// The island's Mute for the microphone (owner, 2026-11-14), and the promise
/// that it never outlives the moment it was pressed for (owner, 2026-11-15).
///
/// It is the Mac's own input mute — macOS lets no app take the microphone
/// from another — so the apps holding the microphone hear silence while the
/// menu bar's orange dot stays; Quit beside it is what puts the dot out.
///
/// That mute belongs to the device, and the device keeps it: coreaudiod
/// writes it to `/Library/Preferences/Audio` and puts it back at the next
/// start. On 2026-11-15 a Mute pressed during a Granola dictation stayed on
/// after the dictation ended (the activity, and its Unmute, went with it),
/// came back after a restart, and from then on Siri's listener
/// (`corespeechd`) took the muted microphone for the normal one and put the
/// mute back each time it changed mode — the microphone went silent every
/// half a minute or so. So a mute here is *held*, not set: `hold` writes down
/// exactly which device and channel it changed, and `release` gives back
/// those and nothing else. The hub releases it when the last app lets go of
/// the microphone, when Isla quits, and at launch for a run that ended while
/// muted.
///
/// Only real microphones are touched: a virtual device (Microsoft Teams'
/// loopback) carries whatever feeds it, and muting it only leaves one more
/// saved mute behind. A channel already muted is left alone and not written
/// down, so `release` never unmutes what the person muted themself. A device
/// with no mute switch is turned down to zero instead and given its level
/// back. Nothing here asks a permission: any process may set these, as
/// `osascript -e "set volume input volume 0"` does.
enum MicrophoneMute {
    /// One change `hold` made: a mute switch it turned on, or a level it
    /// turned down from `level`.
    struct Change: Codable, Equatable, Sendable {
        var device: String
        var element: UInt32
        var level: Float?
    }

    /// The microphones as `hold` and `release` see them, by device UID — the
    /// one name that survives a restart. The Mac's in the app, a dictionary
    /// in a test.
    struct Hardware: Sendable {
        /// The microphones present: devices with an input stream, virtual and
        /// aggregate ones left out.
        var microphones: @Sendable () -> [String]
        /// The input mute on `element`, or nil where there is no switch Isla
        /// can move.
        var mute: @Sendable (_ device: String, _ element: UInt32) -> Bool?
        var setMute: @Sendable (_ device: String, _ element: UInt32, _ on: Bool) -> Bool
        /// The input level on `element`, or nil where there is none Isla can set.
        var level: @Sendable (_ device: String, _ element: UInt32) -> Float?
        var setLevel: @Sendable (_ device: String, _ element: UInt32, _ level: Float) -> Bool
    }

    /// Where a device keeps its input controls: the whole device, or — on
    /// many USB microphones, which have no master control — each of its
    /// first channels.
    nonisolated static let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

    /// What `hold` changed and `release` has not given back yet, kept in the
    /// defaults so a run that quit or crashed while muted is undone by the next.
    static let heldKey = "microphoneMute.held"

    /// Every hold and release runs here, one at a time and in the order
    /// pressed. Each can block on coreaudiod, so never on the main thread
    /// except at quit.
    static let queue = DispatchQueue(label: "com.ctimothe.isla.microphone-mute")

    /// Mutes every microphone Isla can that is not muted already, writing
    /// each change down as it lands. Says whether a microphone that is here
    /// now is held: a note kept for an unplugged one silences nothing, and
    /// the island must not say Muted on its strength (Codex review,
    /// 2026-11-15).
    @discardableResult
    nonisolated static func hold(_ hardware: Hardware = .live, defaults: UserDefaults = .standard) -> Bool {
        var changes = held(defaults)
        let present = hardware.microphones()
        func isHeld(_ device: String, _ element: UInt32) -> Bool {
            changes.contains { $0.device == device && $0.element == element }
        }
        for device in present {
            let switches = elements.filter { hardware.mute(device, $0) != nil }
            if !switches.isEmpty {
                for element in switches where hardware.mute(device, element) == false && !isHeld(device, element) {
                    guard hardware.setMute(device, element, true) else { continue }
                    changes.append(Change(device: device, element: element, level: nil))
                    save(changes, defaults)
                }
                continue
            }
            for element in elements {
                guard let level = hardware.level(device, element), level > 0, !isHeld(device, element),
                      hardware.setLevel(device, element, 0)
                else { continue }
                changes.append(Change(device: device, element: element, level: level))
                save(changes, defaults)
            }
        }
        return changes.contains { present.contains($0.device) }
    }

    /// Gives back what `hold` changed, in this run or an earlier one. A
    /// microphone that is unplugged keeps its note and is given back by a
    /// later release, once it is there again.
    nonisolated static func release(_ hardware: Hardware = .live, defaults: UserDefaults = .standard) {
        let changes = held(defaults)
        guard !changes.isEmpty else { return }
        let present = Set(hardware.microphones())
        var kept: [Change] = []
        for change in changes {
            guard present.contains(change.device) else {
                kept.append(change)
                continue
            }
            if let level = change.level {
                _ = hardware.setLevel(change.device, change.element, level)
            } else {
                _ = hardware.setMute(change.device, change.element, false)
            }
        }
        save(kept, defaults)
    }

    nonisolated static func held(_ defaults: UserDefaults) -> [Change] {
        guard let data = defaults.data(forKey: heldKey) else { return [] }
        return (try? JSONDecoder().decode([Change].self, from: data)) ?? []
    }

    nonisolated private static func save(_ changes: [Change], _ defaults: UserDefaults) {
        if changes.isEmpty {
            defaults.removeObject(forKey: heldKey)
        } else if let data = try? JSONEncoder().encode(changes) {
            defaults.set(data, forKey: heldKey)
        }
    }
}

// MARK: - CoreAudio

extension MicrophoneMute.Hardware {
    static let live = MicrophoneMute.Hardware(
        microphones: { MicrophoneMute.devices().filter(MicrophoneMute.isMicrophone).compactMap(MicrophoneMute.uid) },
        mute: { uid, element in
            guard let device = MicrophoneMute.device(uid) else { return nil }
            var where_ = MicrophoneMute.address(kAudioDevicePropertyMute, element: element)
            guard MicrophoneMute.settable(device, &where_) else { return nil }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
        },
        setMute: { uid, element, on in
            guard let device = MicrophoneMute.device(uid) else { return false }
            var where_ = MicrophoneMute.address(kAudioDevicePropertyMute, element: element)
            var value: UInt32 = on ? 1 : 0
            return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        },
        level: { uid, element in
            guard let device = MicrophoneMute.device(uid) else { return nil }
            var where_ = MicrophoneMute.address(kAudioDevicePropertyVolumeScalar, element: element)
            guard MicrophoneMute.settable(device, &where_) else { return nil }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
            return value
        },
        setLevel: { uid, element, level in
            guard let device = MicrophoneMute.device(uid) else { return false }
            var where_ = MicrophoneMute.address(kAudioDevicePropertyVolumeScalar, element: element)
            var value = Float32(level)
            return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        }
    )
}

extension MicrophoneMute {
    nonisolated static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Every device with at least one input stream.
    nonisolated fileprivate static func devices() -> [AudioObjectID] {
        let all = CaptureObserver.audioObjectIDs(
            of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices
        ) ?? []
        return all.filter { device in
            var streams = address(kAudioDevicePropertyStreams)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
        }
    }

    /// A device that is a microphone in its own right, not a virtual or
    /// aggregate one built over others.
    nonisolated fileprivate static func isMicrophone(_ device: AudioObjectID) -> Bool {
        var where_ = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &transport) == noErr else { return true }
        return ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAutoAggregate].contains(transport)
    }

    nonisolated fileprivate static func device(_ uid: String) -> AudioObjectID? {
        devices().first { MicrophoneMute.uid($0) == uid }
    }

    nonisolated fileprivate static func settable(_ device: AudioObjectID, _ where_: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &where_) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &where_, &settable) == noErr && settable.boolValue
    }

    nonisolated fileprivate static func uid(_ device: AudioObjectID) -> String? {
        var where_ = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
