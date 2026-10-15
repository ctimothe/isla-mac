import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Which of the three levels a key moves (redesign 2026-10-15, spec §12).
enum HUDKind: Equatable {
    case volume
    case display
    case keyboard
}

extension MediaKey {
    /// The level the key moves.
    var kind: HUDKind {
        switch self {
        case .volumeUp, .volumeDown, .mute: return .volume
        case .brightnessUp, .brightnessDown: return .display
        case .keyboardBrightnessUp, .keyboardBrightnessDown: return .keyboard
        }
    }

    /// Whether the key raises its level (the mute key does neither).
    var raises: Bool? {
        switch self {
        case .volumeUp, .brightnessUp, .keyboardBrightnessUp: return true
        case .volumeDown, .brightnessDown, .keyboardBrightnessDown: return false
        case .mute: return nil
        }
    }
}

/// A level as it stands after a key was applied: what the pop-up draws.
struct HUDReading: Equatable {
    var kind: HUDKind
    /// 0…1, always the level the bar shows — a muted Mac keeps it.
    var level: Float
    var muted: Bool
    /// The output device's own glyph (`AudioOutputs.symbol`), for the volume
    /// only; nil for the two brightnesses. The applier never fills it: finding
    /// it walks CoreAudio, which the tap's callback must not do (each press used
    /// to enumerate every audio device inside the tap just to pick a glyph).
    /// `MediaKeyHUD` fills it after the callback has returned.
    var deviceSymbol: String?
    /// The device the volume was applied to, so the glyph can be looked up
    /// after the callback. Nil for the two brightnesses.
    var outputDevice: AudioDeviceID?

    init(kind: HUDKind, level: Float, muted: Bool, deviceSymbol: String?, outputDevice: AudioDeviceID? = nil) {
        self.kind = kind
        self.level = level
        self.muted = muted
        self.deviceSymbol = deviceSymbol
        self.outputDevice = outputDevice
    }
}

/// The arithmetic of a press. Pure: steps, clamping and what mute does to the
/// level are tests, with no sound card and no display.
enum HUDStep {
    /// Sixteen presses from silence to full, and four times as many with ⌥⇧
    /// (spec §12) — the steps macOS takes. Both are exact in binary floating
    /// point, so sixteen steps land on exactly 1.
    static let coarse: Float = 1.0 / 16.0
    static let fine: Float = 1.0 / 64.0

    static func size(fine isFine: Bool) -> Float { isFine ? fine : coarse }

    /// `level` moved one step, clamped to 0…1.
    static func stepped(_ level: Float, raising: Bool, fine isFine: Bool) -> Float {
        let step = size(fine: isFine)
        return min(max(level + (raising ? step : -step), 0), 1)
    }

    /// The volume after `key`: the level and whether the Mac stays muted.
    ///
    /// - Mute toggles the mute and keeps the level, so the bar shows the level
    ///   the Mac will come back to.
    /// - Volume up while muted unmutes, as macOS does; volume down while muted
    ///   lowers the level behind the mute and leaves it muted.
    static func volume(
        after key: MediaKey, level: Float, muted: Bool, fine isFine: Bool
    ) -> (level: Float, muted: Bool) {
        switch key {
        case .mute:
            return (level, !muted)
        case .volumeUp:
            return (stepped(level, raising: true, fine: isFine), false)
        case .volumeDown:
            return (stepped(level, raising: false, fine: isFine), muted)
        default:
            return (level, muted)
        }
    }
}

// MARK: - The volume

/// The default output as one reading: which device it was, and its level and
/// mute. The device id travels with the numbers so the write can go to the
/// device the numbers came from.
struct VolumeState: Equatable {
    var device: AudioDeviceID
    var level: Float
    var muted: Bool
}

/// How a volume write ended.
enum VolumeWriteResult: Equatable {
    case written
    /// The default output is no longer the device the level was read from
    /// (AirPods connected between the read and the write). Nothing was written.
    case deviceChanged
    case failed
}

/// The default output's volume and mute, read and written. A seam over
/// `SystemVolume`, so a test never touches a real device.
@MainActor
protocol VolumeOutput {
    /// The level and mute of the default output, or nil when it has no volume
    /// Isla can set — an HDMI output, a fixed-level DAC — and the keys are
    /// left to the system, which has a way to move those that Isla does not.
    func read() -> VolumeState?
    /// Writes only what changed, and only to `old.device`, and only while that
    /// is still the default output: a level worked out from one device must
    /// never land on another. This used to read the device, compute, and then
    /// write to "whatever is default now", so a press that straddled AirPods
    /// connecting could set the headphones to the speakers' level.
    func write(level: Float, muted: Bool, from old: VolumeState) -> VolumeWriteResult
}

/// `VolumeOutput` over CoreAudio, through the same `SystemVolume` the lock
/// card's slider uses.
struct SystemVolumeOutput: VolumeOutput {
    nonisolated init() {}

    func read() -> VolumeState? {
        guard let device = AudioOutputs.current(), let level = SystemVolume.level(device: device) else {
            return nil
        }
        return VolumeState(device: device, level: level, muted: SystemVolume.isMuted(device: device))
    }

    func write(level: Float, muted: Bool, from old: VolumeState) -> VolumeWriteResult {
        guard AudioOutputs.current() == old.device else { return .deviceChanged }
        let device = old.device
        // Mute first, then the level: a level written under a mute is silent
        // until the mute lifts, and a mute with nowhere to land (a device with
        // no mute control) must refuse before the level has moved.
        if muted != old.muted, !SystemVolume.setMuted(muted, device: device) { return .failed }
        if level != old.level, !SystemVolume.set(level, device: device) { return .failed }
        return .written
    }
}

// MARK: - Display brightness (DisplayServices, private)

/// What the private DisplayServices entry points do, as plain functions.
protocol DisplayBrightnessClient {
    func brightness(of display: CGDirectDisplayID) -> Float?
    func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool
}

/// Finds the DisplayServices calls, or says they are not there. A seam: a test
/// injects "missing" (the Mac shows its own pop-up) and "present".
protocol DisplayBrightnessResolver {
    func resolve() -> DisplayBrightnessClient?
}

/// `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness`, resolved
/// with `dlopen`/`dlsym` from the private framework — the lock screen's rule
/// (`SkyLight`): a macOS that drops a symbol degrades to the system's own
/// pop-up rather than failing to launch or breaking the keys.
struct DisplayServicesResolver: DisplayBrightnessResolver {
    static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias GetCall = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetCall = @convention(c) (UInt32, Float) -> Int32

    private struct Client: DisplayBrightnessClient {
        let get: GetCall
        let set: SetCall

        func brightness(of display: CGDirectDisplayID) -> Float? {
            var value: Float = 0
            guard get(display, &value) == 0, value.isFinite else { return nil }
            return min(max(value, 0), 1)
        }

        func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool {
            set(display, min(max(value, 0), 1)) == 0
        }
    }

    func resolve() -> DisplayBrightnessClient? {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return Client(get: unsafeBitCast(get, to: GetCall.self), set: unsafeBitCast(set, to: SetCall.self))
    }
}

/// The displays as the brightness key sees them.
struct DisplayTopology: Equatable {
    var builtIn: CGDirectDisplayID?
    var active: [CGDirectDisplayID]
    var main: CGDirectDisplayID
}

/// Which display a brightness key may move.
///
/// Only the built-in one, and only when that is what the person is looking at:
/// the built-in display is the only active one, or it is the main display.
/// With an external monitor as the main display, the key belongs to the system,
/// which routes it to the right monitor (DDC or the monitor's own control);
/// Isla used to dim the closed laptop lid's panel from under an external
/// monitor. No built-in display at all (clamshell on a monitor) is the same
/// answer. A Mac in clamshell mode, and an external display's brightness, are
/// not DisplayServices' to set from here.
enum BuiltInDisplay {
    /// Pure, so each arrangement is a test.
    static func target(_ topology: DisplayTopology) -> CGDirectDisplayID? {
        guard let builtIn = topology.builtIn, topology.active.contains(builtIn) else { return nil }
        return topology.active == [builtIn] || topology.main == builtIn ? builtIn : nil
    }

    /// The live arrangement: the active list and the main display, two cheap
    /// reads that happen only for a brightness key.
    static func topology() -> DisplayTopology {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        let listed = CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success
        let active = listed ? Array(ids.prefix(Int(count))) : []
        return DisplayTopology(
            builtIn: active.first { CGDisplayIsBuiltin($0) != 0 },
            active: active,
            main: CGMainDisplayID()
        )
    }
}

// MARK: - Keyboard backlight (CoreBrightness, private)

/// The keyboard backlight, as a level of 0…1.
protocol KeyboardBrightnessClient {
    func brightness() -> Float?
    func setBrightness(_ value: Float) -> Bool
}

/// Finds CoreBrightness's `KeyboardBrightnessClient`, or says it is not there.
protocol KeyboardBrightnessResolver {
    func resolve() -> KeyboardBrightnessClient?
}

/// `KeyboardBrightnessClient` from CoreBrightness, through `NSClassFromString`
/// after loading the private framework. The two selectors it cannot work
/// without — `brightnessForKeyboard:` and `setBrightness:forKeyboard:` — are
/// checked with `responds(to:)` before anything is called, and the keyboard
/// id comes from `copyKeyboardBacklightIDs` and from nowhere else: a class
/// without that selector, an answer that is not a list, an empty list (a Mac
/// with no backlight) and a list with no number in it are all *no client*, and
/// the two illumination keys are then left to the system. The resolver used to
/// guess keyboard id 1 when the list could not be had, which consumed the
/// illumination keys on a Mac that has no backlight to move.
struct CoreBrightnessResolver: KeyboardBrightnessResolver {
    static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework"

    private typealias GetIMP = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetIMP = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

    private struct Client: KeyboardBrightnessClient {
        let object: NSObject
        let keyboard: UInt64
        let get: GetIMP
        let set: SetIMP

        func brightness() -> Float? {
            let value = get(object, CoreBrightnessResolver.getSelector, keyboard)
            return value.isFinite ? min(max(value, 0), 1) : nil
        }

        func setBrightness(_ value: Float) -> Bool {
            set(object, CoreBrightnessResolver.setSelector, min(max(value, 0), 1), keyboard)
        }
    }

    /// The keyboard to drive, from what `copyKeyboardBacklightIDs` answered.
    /// Pure, so "no list, no client" is held by a test without the private
    /// framework.
    static func keyboardID(responds: Bool, list: Any?) -> UInt64? {
        guard responds, let list = list as? [Any], let first = list.first as? NSNumber else { return nil }
        return first.uint64Value
    }

    func resolve() -> KeyboardBrightnessClient? {
        guard Bundle(path: Self.frameworkPath)?.load() == true,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let object = cls.init()
        guard object.responds(to: Self.getSelector), object.responds(to: Self.setSelector),
              let getMethod = class_getInstanceMethod(cls, Self.getSelector),
              let setMethod = class_getInstanceMethod(cls, Self.setSelector) else { return nil }

        let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
        let responds = object.responds(to: idsSelector)
        let list = responds ? object.perform(idsSelector)?.takeRetainedValue() : nil
        guard let keyboard = Self.keyboardID(responds: responds, list: list) else { return nil }
        return Client(
            object: object, keyboard: keyboard,
            get: unsafeBitCast(method_getImplementation(getMethod), to: GetIMP.self),
            set: unsafeBitCast(method_getImplementation(setMethod), to: SetIMP.self)
        )
    }
}

// MARK: - Applying a key

/// Applies a decoded key to the Mac, or declines.
@MainActor
protocol MediaKeyApplying {
    /// Called once each time the tap starts, never from a press: resolves the
    /// private-framework clients (loading the frameworks, making objects) so the
    /// tap's callback never does. A client that is missing now stays missing
    /// until the next `prepare()`, i.e. until the tap is restarted.
    func prepare()
    /// The level after the key, or nil when Isla cannot apply it — in which
    /// case the event is passed to the system untouched.
    func apply(_ key: MediaKey, fine: Bool) -> HUDReading?
}

/// The real applier. Each of the three families has its own refusal: no
/// settable volume (or the default output changed under the press), no
/// built-in display the person is using or no DisplayServices, no CoreBrightness
/// client. A refusal means *the system keeps the key* and shows its own pop-up
/// (spec §12: a missing private symbol degrades, never breaks).
@MainActor
final class SystemLevelApplier: MediaKeyApplying {
    private let volume: VolumeOutput
    private let displays: DisplayBrightnessResolver
    private let topology: () -> DisplayTopology
    private let keyboards: KeyboardBrightnessResolver
    /// Both clients are resolved by `prepare()` and only there, and a miss is
    /// kept as a miss. They used to be asked for again on every press while
    /// missing — for the keyboard that is `Bundle.load()`, `init()` and
    /// `copyKeyboardBacklightIDs` inside the tap's callback, a stall on the
    /// main run loop in front of every key in every app.
    private var displayClient: DisplayBrightnessClient?
    private var keyboardClient: KeyboardBrightnessClient?
    private var prepared = false

    init(
        volume: VolumeOutput? = nil,
        displays: DisplayBrightnessResolver? = nil,
        topology: (() -> DisplayTopology)? = nil,
        keyboards: KeyboardBrightnessResolver? = nil
    ) {
        self.volume = volume ?? SystemVolumeOutput()
        self.displays = displays ?? DisplayServicesResolver()
        self.topology = topology ?? BuiltInDisplay.topology
        self.keyboards = keyboards ?? CoreBrightnessResolver()
    }

    func prepare() {
        displayClient = displays.resolve()
        keyboardClient = keyboards.resolve()
        prepared = true
    }

    func apply(_ key: MediaKey, fine: Bool) -> HUDReading? {
        // A caller that never prepared (a test, not the app) still resolves
        // once, and only once.
        if !prepared { prepare() }
        switch key.kind {
        case .volume: return applyVolume(key, fine: fine)
        case .display: return applyDisplay(key, fine: fine)
        case .keyboard: return applyKeyboard(key, fine: fine)
        }
    }

    private func applyVolume(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let now = volume.read() else { return nil }
        let next = HUDStep.volume(after: key, level: now.level, muted: now.muted, fine: fine)
        guard volume.write(level: next.level, muted: next.muted, from: now) == .written else { return nil }
        return HUDReading(kind: .volume, level: next.level, muted: next.muted, deviceSymbol: nil, outputDevice: now.device)
    }

    private func applyDisplay(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let raises = key.raises, let display = BuiltInDisplay.target(topology()),
              let client = displayClient, let now = client.brightness(of: display) else { return nil }
        let next = HUDStep.stepped(now, raising: raises, fine: fine)
        guard client.setBrightness(next, of: display) else { return nil }
        return HUDReading(kind: .display, level: next, muted: false, deviceSymbol: nil)
    }

    private func applyKeyboard(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let raises = key.raises, let client = keyboardClient, let now = client.brightness() else { return nil }
        let next = HUDStep.stepped(now, raising: raises, fine: fine)
        guard client.setBrightness(next) else { return nil }
        return HUDReading(kind: .keyboard, level: next, muted: false, deviceSymbol: nil)
    }
}
