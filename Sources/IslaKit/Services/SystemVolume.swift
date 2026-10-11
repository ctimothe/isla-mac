import AudioToolbox
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
    /// The control a write goes through, in the order it is tried.
    enum Control: Equatable {
        /// The virtual main volume (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`):
        /// the system's own scalar over whatever the device has, which keeps
        /// the balance between the channels it drives. The menu bar's slider
        /// and the volume keys move this one.
        case virtualMain
        /// A real main volume element.
        case main
        /// The two stereo channels, scaled together by `channelLevels`.
        case channels
    }

    /// Which control a write goes through, given which ones the device can
    /// set — or nil, and no bar, when it can set none (K-008).
    ///
    /// The bar used to exist whenever a level could be *read*. A fixed-volume
    /// DAC or an HDMI output publishes a level it will not take, so the bar
    /// followed the finger and snapped back at release — the slider that moves
    /// and changes nothing that this file was written to rule out. The virtual
    /// main volume goes first because it keeps a hearing-balance setting
    /// where the user put it (G-023); writing one scalar to both channels
    /// reset it to centre at the first touch.
    static func control(virtualMain: Bool, main: Bool, channels: Bool) -> Control? {
        if virtualMain { return .virtualMain }
        if main { return .main }
        if channels { return .channels }
        return nil
    }

    /// Both channels moved to `setting`, keeping their balance (G-023).
    ///
    /// The level is the two channels' average — what `current()` reads back
    /// for a device like this — so one factor scales both and the bar lands
    /// where the finger asked. Near the top the louder side reaches 1 first;
    /// it stops there and the quieter side keeps its ratio to it, so the
    /// balance outranks the last few percent of level. Silent channels carry
    /// no balance to keep, and both take the level.
    static func channelLevels(
        setting: Float, from current: (left: Float, right: Float)
    ) -> (left: Float, right: Float) {
        let target = min(max(setting, 0), 1)
        let left = max(current.left, 0)
        let right = max(current.right, 0)
        let average = (left + right) / 2
        guard average > 0 else { return (target, target) }
        var factor = target / average
        let louder = max(left, right)
        if louder * factor > 1 { factor = 1 / louder }
        return (min(left * factor, 1), min(right * factor, 1))
    }

    /// Whether moving the level to `newLevel` lifts the mute. Raising the
    /// level of a muted Mac unmutes it, as the volume keys do; a drag to the
    /// very bottom leaves the mute alone, and a device that is not muted is
    /// never written to for it.
    static func unmutes(muted: Bool, newLevel: Float) -> Bool {
        muted && newLevel > 0
    }

    /// 0…1 for the current default output, or nil when it has no volume to
    /// give — including one it would show but not take (K-008).
    static func current() -> Float? {
        guard let device = AudioOutputs.current() else { return nil }
        return level(device: device)
    }

    /// 0…1 for `device`, or nil when nothing on it can be set.
    static func level(device: AudioDeviceID) -> Float? {
        guard let control = control(device: device) else { return nil }
        // Read through the control the write goes through, so the bar at
        // release shows the level the drag set rather than an average that a
        // kept balance pulls off the finger.
        if control == .virtualMain,
           let virtual = scalar(device: device, selector: virtualMainSelector, channel: kAudioObjectPropertyElementMain) {
            return virtual
        }
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

    /// True when the write landed on `device`. The caller names the device —
    /// the lock card latches the one its drag began on (K-008) — because this
    /// used to re-read the default on every call, and AirPods that took over
    /// mid-drag were sent the finger's level for the speakers. Clamped,
    /// because a scalar outside 0…1 is rejected by CoreAudio with an error the
    /// caller cannot do anything about.
    @discardableResult
    static func set(_ value: Float, device: AudioDeviceID) -> Bool {
        let clamped = min(max(value, 0), 1)
        if write(clamped, device: device, selector: virtualMainSelector, channel: kAudioObjectPropertyElementMain) {
            return true
        }
        if write(clamped, device: device, channel: kAudioObjectPropertyElementMain) { return true }
        // Both channels together and in proportion, so a balance set off
        // centre stays where it was put (G-023). A device with one channel
        // settable simply takes the level on that one.
        let left = scalar(device: device, channel: 1)
        let right = scalar(device: device, channel: 2)
        let levels = channelLevels(setting: clamped, from: (left ?? right ?? 0, right ?? left ?? 0))
        let wroteLeft = write(levels.left, device: device, channel: 1)
        let wroteRight = write(levels.right, device: device, channel: 2)
        return wroteLeft || wroteRight
    }

    // MARK: - Mute

    /// Whether `device` is muted. A device with no mute control is not.
    static func isMuted(device: AudioDeviceID) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    /// Whether the default output is muted, for the watch's reads.
    static func isMuted() -> Bool {
        guard let device = AudioOutputs.current() else { return false }
        return isMuted(device: device)
    }

    /// True when the mute landed. Inside the recorded "Output volume"
    /// capability: it is the same system-wide setting the volume keys move.
    @discardableResult
    static func setMuted(_ muted: Bool, device: AudioDeviceID) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - One property

    /// The virtual main volume's selector. It belongs to AudioToolbox, which
    /// answers for it through the ordinary `AudioObject…PropertyData` calls:
    /// the `AudioHardwareService…` functions it was once read through are
    /// deprecated since macOS 10.11 in favour of exactly that.
    private static let virtualMainSelector = AudioObjectPropertySelector(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    )

    /// Which control a write to `device` would go through, read from the
    /// device: the pure `control(virtualMain:main:channels:)` over what it
    /// can actually set.
    private static func control(device: AudioDeviceID) -> Control? {
        control(
            virtualMain: settable(device: device, selector: virtualMainSelector, channel: kAudioObjectPropertyElementMain),
            main: settable(device: device, channel: kAudioObjectPropertyElementMain),
            channels: settable(device: device, channel: 1) || settable(device: device, channel: 2)
        )
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, channel: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
    }

    private static func settable(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar,
        channel: AudioObjectPropertyElement
    ) -> Bool {
        var address = address(selector, channel: channel)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func scalar(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar,
        channel: AudioObjectPropertyElement
    ) -> Float? {
        var address = address(selector, channel: channel)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return Float(value)
    }

    private static func write(
        _ value: Float,
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar,
        channel: AudioObjectPropertyElement
    ) -> Bool {
        guard settable(device: device, selector: selector, channel: channel) else { return false }
        var address = address(selector, channel: channel)
        var scalar = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalar) == noErr
    }
}

/// Which device a lock-card volume drag writes to (K-008).
///
/// `SystemVolume.set` used to re-read the default output on every write, so a
/// drag to 80% for the speakers that AirPods interrupted sent the AirPods —
/// previously at 20% — straight to 80%. The drag latches the default it began
/// on, and a default that moves under it ends the drag: the rest of the
/// gesture writes nothing, and the next touch starts over on the new device.
/// Pure, so the rule is held by a test rather than by the view.
struct VolumeDragLatch {
    /// The device this drag writes to, once its first event has latched it.
    private(set) var device: AudioDeviceID?
    /// The default moved under this drag; it writes nothing more until it ends.
    private(set) var stopped = false

    /// The device to write this event's level to, or nil to write nothing.
    mutating func target(current: AudioDeviceID?) -> AudioDeviceID? {
        guard !stopped else { return nil }
        if device == nil { device = current }
        return device
    }

    /// The default output is now `now`. True when that ends a running drag.
    mutating func defaultMoved(to now: AudioDeviceID?) -> Bool {
        guard let device, !stopped, now != device else { return false }
        self.device = nil
        stopped = true
        return true
    }

    /// The finger lifted, or the drag was cut short: the next touch latches
    /// afresh.
    mutating func end() {
        device = nil
        stopped = false
    }
}

/// Paces the lock card's volume drag to about 30 CoreAudio writes a second
/// (F-045).
///
/// A drag delivers 60 to 120 events a second and each one wrote the device's
/// volume, which fired the watch's listener, which — before `volumeChanged`
/// — enumerated every device. The bar still follows the finger at full rate
/// from the card's own state; only the write is paced, and 33 ms between
/// levels is continuous to an ear.
///
/// The value a write skips is held, never dropped: `due(at:)` hands it over
/// once the interval has passed, so a finger that stops moving but stays down
/// does not leave the speakers a step behind the bar, and `finish()` hands it
/// over at release, so the level always lands where the finger let go. Pure —
/// the clock is the caller's — so the pacing is held by a test.
struct VolumeWriteGate {
    static let interval: TimeInterval = 0.033

    private var lastWrite: TimeInterval?
    private(set) var pending: Float?

    /// The value to write now, or nil when it is held for later.
    mutating func offer(_ value: Float, at time: TimeInterval) -> Float? {
        if let lastWrite, time - lastWrite < Self.interval {
            pending = value
            return nil
        }
        lastWrite = time
        pending = nil
        return value
    }

    /// The held value, once the interval since the last write has passed.
    mutating func due(at time: TimeInterval) -> Float? {
        guard let pending, let lastWrite, time - lastWrite >= Self.interval else { return nil }
        self.lastWrite = time
        self.pending = nil
        return pending
    }

    /// The held value at release, if one is still waiting. The gate starts
    /// over, so the next drag's first touch writes at once.
    mutating func finish() -> Float? {
        defer {
            pending = nil
            lastWrite = nil
        }
        return pending
    }
}
