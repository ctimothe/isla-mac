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
    /// only; nil for the two brightnesses.
    var deviceSymbol: String?
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

/// The default output's volume and mute, read and written. A seam over
/// `SystemVolume`, so a test never touches a real device.
@MainActor
protocol VolumeOutput {
    /// The level and mute of the default output, or nil when it has no volume
    /// Isla can set — an HDMI output, a fixed-level DAC — and the keys are
    /// left to the system, which has a way to move those that Isla does not.
    func read() -> (level: Float, muted: Bool, deviceSymbol: String?)?
    /// Whether every write needed landed. Writes only what changed.
    func write(level: Float, muted: Bool, from old: (level: Float, muted: Bool)) -> Bool
}

/// `VolumeOutput` over CoreAudio, through the same `SystemVolume` the lock
/// card's slider uses.
struct SystemVolumeOutput: VolumeOutput {
    nonisolated init() {}

    func read() -> (level: Float, muted: Bool, deviceSymbol: String?)? {
        guard let device = AudioOutputs.current(), let level = SystemVolume.level(device: device) else {
            return nil
        }
        let symbol = AudioOutputs.available().first { $0.id == device }?.symbol
        return (level, SystemVolume.isMuted(device: device), symbol)
    }

    func write(level: Float, muted: Bool, from old: (level: Float, muted: Bool)) -> Bool {
        guard let device = AudioOutputs.current() else { return false }
        // Mute first, then the level: a level written under a mute is silent
        // until the mute lifts, and a mute with nowhere to land (a device with
        // no mute control) must refuse before the level has moved.
        if muted != old.muted, !SystemVolume.setMuted(muted, device: device) { return false }
        if level != old.level, !SystemVolume.set(level, device: device) { return false }
        return true
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

/// The built-in display, if one is active (`CGDisplayIsBuiltin` over the
/// active list). A Mac in clamshell mode on a monitor has none, and an
/// external display's brightness is not DisplayServices' to set.
enum BuiltInDisplay {
    static func current() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
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
/// id comes from `copyKeyboardBacklightIDs` where the class has it (a Mac with
/// no backlight answers an empty list, which is no client at all). Anything
/// missing resolves to nil, and the two illumination keys are then left to the
/// system.
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

    func resolve() -> KeyboardBrightnessClient? {
        guard Bundle(path: Self.frameworkPath)?.load() == true,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let object = cls.init()
        guard object.responds(to: Self.getSelector), object.responds(to: Self.setSelector),
              let getMethod = class_getInstanceMethod(cls, Self.getSelector),
              let setMethod = class_getInstanceMethod(cls, Self.setSelector) else { return nil }

        var keyboard: UInt64 = 1
        let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
        if object.responds(to: idsSelector),
           let list = object.perform(idsSelector)?.takeRetainedValue() as? [Any] {
            // An empty list is a Mac with no keyboard backlight.
            guard let first = list.first as? NSNumber else { return nil }
            keyboard = first.uint64Value
        }
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
    /// The level after the key, or nil when Isla cannot apply it — in which
    /// case the event is passed to the system untouched.
    func apply(_ key: MediaKey, fine: Bool) -> HUDReading?
}

/// The real applier. Each of the three families has its own refusal: no
/// settable volume, no built-in display or no DisplayServices, no CoreBrightness
/// client. A refusal means *the system keeps the key* and shows its own pop-up
/// (spec §12: a missing private symbol degrades, never breaks).
@MainActor
final class SystemLevelApplier: MediaKeyApplying {
    private let volume: VolumeOutput
    private let displays: DisplayBrightnessResolver
    private let builtInDisplay: () -> CGDirectDisplayID?
    private let keyboards: KeyboardBrightnessResolver
    /// A client once found is kept: resolving loads a framework and makes an
    /// object, which is not work to repeat on every press of a held key. A
    /// missing one is asked for again — a framework that was not loadable a
    /// minute ago has not changed, but costs nothing to ask.
    private var displayClient: DisplayBrightnessClient?
    private var keyboardClient: KeyboardBrightnessClient?

    init(
        volume: VolumeOutput? = nil,
        displays: DisplayBrightnessResolver? = nil,
        builtInDisplay: (() -> CGDirectDisplayID?)? = nil,
        keyboards: KeyboardBrightnessResolver? = nil
    ) {
        self.volume = volume ?? SystemVolumeOutput()
        self.displays = displays ?? DisplayServicesResolver()
        self.builtInDisplay = builtInDisplay ?? BuiltInDisplay.current
        self.keyboards = keyboards ?? CoreBrightnessResolver()
    }

    func apply(_ key: MediaKey, fine: Bool) -> HUDReading? {
        switch key.kind {
        case .volume: return applyVolume(key, fine: fine)
        case .display: return applyDisplay(key, fine: fine)
        case .keyboard: return applyKeyboard(key, fine: fine)
        }
    }

    private func applyVolume(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let now = volume.read() else { return nil }
        let next = HUDStep.volume(after: key, level: now.level, muted: now.muted, fine: fine)
        guard volume.write(level: next.level, muted: next.muted, from: (now.level, now.muted)) else { return nil }
        return HUDReading(kind: .volume, level: next.level, muted: next.muted, deviceSymbol: now.deviceSymbol)
    }

    private func applyDisplay(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let raises = key.raises, let display = builtInDisplay() else { return nil }
        if displayClient == nil { displayClient = displays.resolve() }
        guard let client = displayClient, let now = client.brightness(of: display) else { return nil }
        let next = HUDStep.stepped(now, raising: raises, fine: fine)
        guard client.setBrightness(next, of: display) else { return nil }
        return HUDReading(kind: .display, level: next, muted: false, deviceSymbol: nil)
    }

    private func applyKeyboard(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let raises = key.raises else { return nil }
        if keyboardClient == nil { keyboardClient = keyboards.resolve() }
        guard let client = keyboardClient, let now = client.brightness() else { return nil }
        let next = HUDStep.stepped(now, raising: raises, fine: fine)
        guard client.setBrightness(next) else { return nil }
        return HUDReading(kind: .keyboard, level: next, muted: false, deviceSymbol: nil)
    }
}
