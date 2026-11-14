import CoreAudio
import Foundation

/// The island's Mute for the microphone (owner, 2026-11-14): every input
/// device on the Mac muted, so the apps holding the microphone hear silence.
///
/// It is the Mac's own input mute, the switch Sound settings and Audio MIDI
/// Setup move, not anything per app: macOS lets no app take the microphone
/// from another. So the menu bar's orange dot stays while the app keeps its
/// input open, and goes only when that app lets go or quits — which is why
/// the island's card offers Quit beside Mute. Nothing here asks a permission:
/// a device's mute and volume are settable by any process, as `osascript -e
/// "set volume input volume 0"` is.
///
/// A device with no mute of its own (some USB microphones) is turned down to
/// zero instead, and its level is kept in the defaults, keyed to the device,
/// so Unmute — in this run or the next — gives it back rather than leaving it
/// at zero. The mute is the device's, so it outlives Isla: the island shows a
/// muted microphone whenever one is in use, wherever the mute came from.
enum MicrophoneMute {
    /// Whether the default input is muted (or turned down to zero), or nil
    /// when CoreAudio could not say or there is no input at all.
    nonisolated static func isMuted() -> Bool? {
        guard let device = defaultInput() else { return nil }
        if let mute = uint32(device, kAudioDevicePropertyMute) { return mute != 0 }
        if let volume = volume(device) { return volume <= 0 }
        return false
    }

    /// Mutes or unmutes every input device. Can block on coreaudiod: call it
    /// off the main thread.
    nonisolated static func setMuted(_ muted: Bool, defaults: UserDefaults = .standard) {
        for device in inputDevices() {
            var mute = address(kAudioDevicePropertyMute)
            if settable(device, &mute) {
                var value: UInt32 = muted ? 1 : 0
                AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
                continue
            }
            var level = address(kAudioDevicePropertyVolumeScalar)
            guard settable(device, &level), let key = uid(device).map({ savedLevelKey + $0 }) else { continue }
            if muted {
                if let current = volume(device), current > 0 { defaults.set(Double(current), forKey: key) }
                var zero: Float32 = 0
                AudioObjectSetPropertyData(device, &level, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero)
            } else if defaults.object(forKey: key) != nil {
                var restored = Float32(defaults.double(forKey: key))
                AudioObjectSetPropertyData(device, &level, 0, nil, UInt32(MemoryLayout<Float32>.size), &restored)
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Where a device without a mute keeps its level while turned down.
    static let savedLevelKey = "microphoneMute.savedLevel."

    // MARK: - CoreAudio

    nonisolated static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated static func defaultInput() -> AudioObjectID? {
        var where_ = address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    /// Every device with at least one input stream.
    nonisolated private static func inputDevices() -> [AudioObjectID] {
        let all = CaptureObserver.audioObjectIDs(
            of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices
        ) ?? []
        return all.filter { device in
            var streams = address(kAudioDevicePropertyStreams)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
        }
    }

    nonisolated private static func settable(_ device: AudioObjectID, _ where_: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &where_) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &where_, &settable) == noErr && settable.boolValue
    }

    nonisolated private static func uint32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var where_ = address(selector)
        guard AudioObjectHasProperty(device, &where_) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    nonisolated private static func volume(_ device: AudioObjectID) -> Float32? {
        var where_ = address(kAudioDevicePropertyVolumeScalar)
        guard AudioObjectHasProperty(device, &where_) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    nonisolated private static func uid(_ device: AudioObjectID) -> String? {
        var where_ = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
