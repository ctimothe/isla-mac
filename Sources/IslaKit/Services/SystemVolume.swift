import CoreAudio
import Foundation

/// The default output's volume, read and written.
///
/// Every app follows the system's default output, so this is the one volume a
/// lock-screen card can honestly offer: not "this song's level" — no app's own
/// volume is reachable from outside it — but where the whole machine is set.
///
/// Not every device has one. Some interfaces expose volume per channel and not
/// as a single main control, some expose none at all and are driven from the
/// hardware, and asking those to set a scalar quietly does nothing. So every
/// call answers honestly with nil or false, and the caller hides the control
/// rather than showing a slider that moves and changes nothing.
enum SystemVolume {
    /// 0…1 for the current default output, or nil when it has no volume to give.
    static func current() -> Float? {
        guard let device = AudioOutputs.current() else { return nil }
        if let main = scalar(device: device, channel: kAudioObjectPropertyElementMain) {
            return main
        }
        // Devices that publish no main control often still publish the two
        // stereo channels. Their average is what the system's own slider shows.
        let left = scalar(device: device, channel: 1)
        let right = scalar(device: device, channel: 2)
        switch (left, right) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    /// True when the write landed. Clamped, because a scalar outside 0…1 is
    /// rejected by CoreAudio with an error the caller cannot do anything about.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let device = AudioOutputs.current() else { return false }
        let clamped = min(max(value, 0), 1)
        if write(clamped, device: device, channel: kAudioObjectPropertyElementMain) { return true }
        // Both channels together, so a stereo device does not drift into
        // permanent imbalance from being driven one side at a time.
        let left = write(clamped, device: device, channel: 1)
        let right = write(clamped, device: device, channel: 2)
        return left || right
    }

    // MARK: - One property

    private static func scalar(device: AudioDeviceID, channel: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return Float(value)
    }

    private static func write(
        _ value: Float, device: AudioDeviceID, channel: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var scalar = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalar) == noErr
    }
}
