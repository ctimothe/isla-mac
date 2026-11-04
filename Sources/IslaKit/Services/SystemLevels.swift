import AppKit
import AudioToolbox
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
    /// only; nil for the two brightnesses. The applier fills it from its
    /// per-device cache (`DeviceLabel`), which the default-output and
    /// data-source listeners keep current — never from a lookup made for the
    /// press. Each press used to enumerate every audio device inside the tap
    /// just to pick a glyph, and later cost a second main-queue turn to look
    /// one device up before the pop-up could appear.
    var deviceSymbol: String?
    /// The device the volume was applied to. Nil for the two brightnesses.
    var outputDevice: AudioDeviceID?
    /// The output's name ("MacBook Pro Speakers"), which the pop-up shows
    /// above its bar (spec §19.5 d). From the same cache as the glyph; nil for
    /// the two brightnesses.
    var deviceName: String?

    init(
        kind: HUDKind, level: Float, muted: Bool, deviceSymbol: String?, outputDevice: AudioDeviceID? = nil,
        deviceName: String? = nil
    ) {
        self.kind = kind
        self.level = level
        self.muted = muted
        self.deviceSymbol = deviceSymbol
        self.outputDevice = outputDevice
        self.deviceName = deviceName
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
///
/// Not main-actor: every call is made off the main thread — reads on the
/// applier's listener queue, writes on its one writer
/// (`SystemLevelApplier.writeQueue`), or on the main thread while the tap is
/// being prepared. CoreAudio's property calls are thread-safe; the main
/// thread and the tap's thread are exactly where a key press must not wait
/// for them.
protocol VolumeOutput: Sendable {
    /// The level and mute of the default output, or nil when it has no volume
    /// Isla can set — an HDMI output, a fixed-level DAC — and the keys are
    /// left to the system, which has a way to move those that Isla does not.
    func read() -> VolumeState?
    /// `read()`, and with `resolving` also works out again which control the
    /// writes to that device go through (the tap starting, the default output
    /// moving). A conformer with nothing to resolve just reads.
    func read(resolving: Bool) -> VolumeState?
    /// Writes only what changed, and only to `old.device`: a level worked out
    /// from one device must never land on another. This used to read the
    /// device, compute, and then write to "whatever is default now", so a
    /// press that straddled AirPods connecting could set the headphones to the
    /// speakers' level. `.deviceChanged` says `old.device` cannot take it any
    /// more (it went away); the applier then re-aims the key at the device
    /// that is current.
    func write(level: Float, muted: Bool, from old: VolumeState) -> VolumeWriteResult
}

extension VolumeOutput {
    func read(resolving: Bool) -> VolumeState? { read() }
}

/// `VolumeOutput` over CoreAudio, through the same `SystemVolume` the lock
/// card's slider uses.
///
/// **The control is resolved once per device** (2026-10-25). Each write used
/// to look up the default output, then ask `HasProperty` and
/// `IsPropertySettable` of the virtual main volume before setting it — four
/// HAL calls where one does, and slower still while the device is playing.
/// `read(resolving:)` finds the control (and whether the mute is settable)
/// when the tap starts and when the default output changes, and a write is
/// then the set call alone. It no longer re-checks that `old.device` is still
/// the default: the level was stepped from that device and is written to it by
/// id, which is harmless, and the default-output listener re-aims the next
/// press within milliseconds. A device that has gone answers the set with
/// `kAudioHardwareBadObjectError`, which is `.deviceChanged`.
final class SystemVolumeOutput: VolumeOutput, @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`, held only to copy it, never across a CoreAudio call.
    private var resolved: SystemVolume.Resolved?

    init() {}

    func read() -> VolumeState? { read(resolving: false) }

    func read(resolving: Bool) -> VolumeState? {
        guard let device = AudioOutputs.current() else { return nil }
        var control = lock.withLock { resolved }
        if resolving || control?.device != device {
            control = SystemVolume.resolve(device: device)
            lock.withLock { resolved = control }
        }
        guard let control, let level = SystemVolume.level(control) else { return nil }
        return VolumeState(device: device, level: level, muted: SystemVolume.isMuted(control))
    }

    func write(level: Float, muted: Bool, from old: VolumeState) -> VolumeWriteResult {
        let cached = lock.withLock { resolved?.device == old.device ? resolved : nil }
        guard let control = cached ?? SystemVolume.resolve(device: old.device) else { return .failed }
        // Mute first, then the level: a level written under a mute is silent
        // until the mute lifts, and a mute with nowhere to land (a device with
        // no mute control) must refuse before the level has moved.
        if muted != old.muted {
            let status = SystemVolume.setMuted(muted, control)
            if status != noErr { return Self.result(of: status) }
        }
        if level != old.level {
            let status = SystemVolume.set(level, control)
            if status != noErr { return Self.result(of: status) }
        }
        return .written
    }

    /// A device that is gone, or a write that did not take.
    static func result(of status: OSStatus) -> VolumeWriteResult {
        status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError ? .deviceChanged : .failed
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
///
/// Split in two since 2026-10-18, because the two halves have different
/// deadlines. `canApply` is asked on the event tap's own thread, inside the
/// callback, in front of every media key in every app: it reads cached state
/// under a lock and nothing else. `submit` does the hardware write, later, on
/// the applier's serial queue. The tap used to run on the main run loop and
/// call one `apply` that read CoreAudio (or DisplayServices) and wrote it
/// before the callback could answer; with the main thread busy drawing, the
/// key waited behind it, and past the system's timeout macOS disabled the tap
/// and the presses in between went to the system's own pop-up (the owner's
/// "heavy and laggy while the Mac is loaded" report).
///
/// Not main-actor: every member is safe from any thread, as each conformer
/// documents.
protocol MediaKeyApplying: AnyObject, Sendable {
    /// Called once each time the tap starts, never from a press, on the main
    /// actor: resolves the private-framework clients (loading the frameworks,
    /// making objects), reads the levels it will step from, and starts the
    /// listeners that keep them current. A client that is missing now stays
    /// missing until the next `prepare()`, i.e. until the tap is restarted.
    func prepare()
    /// The tap is gone: every listener `prepare()` started is removed before
    /// this returns.
    func stop()
    /// Whether a key of this family can be applied, from cached state only —
    /// asked on the tap's thread, so it never touches hardware. False until
    /// `prepare()` has run. A false answer leaves the key to the system, which
    /// shows its own pop-up.
    func canApply(_ key: MediaKey) -> Bool
    /// Applies the key on the applier's own queue and hands the resulting level
    /// to `deliver`, on that queue, when there is one to show. Returns at once.
    func submit(_ key: MediaKey, fine: Bool, deliver: @escaping @Sendable (HUDReading) -> Void)
}

/// What the volume pop-up names the output by: its glyph and its name, found
/// together because they are the same CoreAudio walk over one device.
struct DeviceLabel: Equatable, Sendable {
    var symbol: String?
    var name: String?

    /// One device, asked of CoreAudio. Only ever called off the tap's thread:
    /// at `prepare()` and from the listeners, on the applier's queue.
    static let live: @Sendable (AudioDeviceID) -> DeviceLabel = { id in
        let output = AudioOutputs.output(id: id)
        return DeviceLabel(symbol: output?.symbol, name: output?.name)
    }
}

/// Something about a level changed outside Isla, or under it.
enum LevelEvent: Equatable, Sendable {
    /// `kAudioHardwarePropertyDefaultOutputDevice`: AirPods connected, the
    /// picker chose another device.
    case defaultOutput
    /// The followed device's volume or mute (the menu bar slider, another app,
    /// and Isla's own writes).
    case volume
    /// The followed device's data source: a headphone jack switching between
    /// the speakers and headphones with the device id unchanged, which changes
    /// the glyph and the name.
    case dataSource
    /// The display arrangement: a monitor plugged in, the main display moved.
    case displays
}

/// The listeners that keep the applier's cache current. A seam, so no test
/// ever registers a real CoreAudio or display listener.
protocol LevelWatching: AnyObject, Sendable {
    /// Starts listening. Every event is delivered on `queue`.
    func start(on queue: DispatchQueue, events: @escaping @Sendable (LevelEvent) -> Void)
    /// Moves the per-device listeners (volume, mute, data source) to `device`.
    func follow(_ device: AudioDeviceID?)
    /// Removes every listener before it returns.
    func stop()
}

/// The real applier. Each of the three families has its own refusal: no
/// settable volume, no built-in display the person is using or no
/// DisplayServices, no CoreBrightness client. A refusal means *the system
/// keeps the key* and shows its own pop-up (spec §12: a missing private symbol
/// degrades, never breaks).
///
/// **The volume, since 2026-10-25: predicted, then written by one writer.**
/// The owner: "only the volume pop-up lags and delays … with or without
/// earphones, while music plays … this needs an architectural fix, like
/// Apple's own sound control". Until then a press queued one write on a serial
/// queue and the pop-up waited for it; each write was some ten CoreAudio calls
/// (the default output, `HasProperty`, `IsPropertySettable`, the set), each
/// one fired Isla's own listener two or three times on the same queue, and
/// every one of those re-read the device — 26 to 37 HAL calls a press, in
/// line. CoreAudio is slower while a device is running, so with music playing
/// a held key outran the queue: the bar fell behind the finger, and after the
/// key was let go it kept stepping for a second or two (the hitch lab's
/// `hud-hold`, 50 ms writes: press-to-frame p50 1.1 s, 42 frames changed after
/// release). Brightness never lagged: one call, a cached read, no listener.
/// Now, as the system's own control does:
///
/// 1. **The press is drawn first.** The level it means is worked out from
///    the *intended* state (`volumeState`: device, level, mute) under `lock`,
///    on the tap's thread, and handed to `deliver` there and then — before
///    any CoreAudio call. The next press steps from that intention, never
///    from what the device has caught up to.
/// 2. **One writer, newest wins.** The target goes into a single slot
///    (`pendingVolume`) that a press overwrites; `writeQueue` drains it, so
///    however long a write takes, the device gets at most the write in flight
///    and then the newest level. The control a write goes through was resolved
///    once, by `prepare()` or on a default-output change
///    (`VolumeOutput.read(resolving:)`), so a write is one set call. A target
///    stamped with an older `volumeGeneration` — the default output moved
///    since — is dropped, never written to the device that replaced it.
/// 3. **Only changes from outside are adopted.** The listeners run on
///    `listenQueue`, never the writer's, and a burst of them is one read. A
///    read is ignored while a write is pending or in flight, and within
///    `echoWindow` of one when it matches a level Isla just wrote or left
///    (its own echo, or the device lagging behind it); a check at the end of
///    that window catches a real change that happened to look like one. Any
///    other read — the menu bar slider, another app — becomes the intended
///    state, and the next press steps from it.
///
/// **Threads.** `canApply` and the volume half of `submit` run on the tap's
/// thread, `prepare`/`stop` on the main actor, volume writes on `writeQueue`,
/// listener events on `listenQueue`, and the two brightnesses (through
/// `submit`) on `queue`. Everything they share lives behind `lock`, which is
/// held only to copy a value in or out — never across a CoreAudio or
/// DisplayServices call, so the tap's thread can never wait on hardware
/// through it. That discipline is why `@unchecked Sendable` is safe here.
///
/// **What is cached.** The intended volume, what the device was last known to
/// hold, and the generation of the default output they belong to; the label
/// of each device the pop-up has named; the built-in display the brightness
/// keys may move, refreshed by the display-reconfiguration listener; and the
/// last brightness and backlight level written or read, trusted for
/// `levelTrustedFor` seconds (nothing announces a change to those, and
/// auto-brightness moves them on its own).
final class SystemLevelApplier: MediaKeyApplying, @unchecked Sendable {
    /// How long a brightness or backlight level Isla wrote or read is used for
    /// the next step without reading it again. A held key repeats far inside
    /// this, so a hold costs one read at most; a press after a pause reads
    /// first — on the queue, never in front of the key — because the ambient
    /// light sensor may have moved the level since, and stepping from a stale
    /// one makes the screen jump.
    static let levelTrustedFor: TimeInterval = 1.5

    /// How long after one of Isla's own volume writes a read that matches a
    /// level it wrote (or wrote over) is taken for that write's echo rather
    /// than a change made elsewhere. A write fires the device's listeners two
    /// or three times, and on a running device the last of them can arrive
    /// well after the set returned; a person moving the menu-bar slider in
    /// the same quarter second is caught by the check at the window's end.
    static let echoWindow: TimeInterval = 0.25

    /// Two levels closer than this are the same level: a device stores its
    /// volume in its own steps (decibels), so the scalar read back is rarely
    /// the float written. Half of the finest step a key takes.
    static let levelTolerance: Float = HUDStep.fine / 2

    /// The two brightnesses' writes, in order, at the priority of the key
    /// press that caused them.
    let queue = DispatchQueue(label: "com.ctimothe.isla.levels", qos: .userInteractive)
    /// The volume's one writer (see the type's note). Never runs a listener.
    let writeQueue = DispatchQueue(label: "com.ctimothe.isla.levels.volume-writer", qos: .userInteractive)
    /// Every listener event, and the reads they cause.
    let listenQueue = DispatchQueue(label: "com.ctimothe.isla.levels.listen", qos: .userInitiated)

    private let volume: VolumeOutput
    private let displays: DisplayBrightnessResolver
    /// Called at `prepare()` (main actor) and on `.displays` events (the
    /// listen queue). The real one is two CoreGraphics reads, which are
    /// thread-safe.
    private let topology: () -> DisplayTopology
    private let keyboards: KeyboardBrightnessResolver
    private let watch: LevelWatching
    private let describe: @Sendable (AudioDeviceID) -> DeviceLabel
    private let now: @Sendable () -> TimeInterval

    /// A volume level waiting for the writer: the newest press's target, the
    /// generation of the default output it was stepped on, and the key that
    /// made it (a write the device refuses as `.deviceChanged` applies that
    /// key once to the device that is current now).
    private struct VolumeJob {
        var target: VolumeState
        var generation: Int
        var key: MediaKey
        var fine: Bool
        var deliver: (@Sendable (HUDReading) -> Void)?
    }

    private let lock = NSLock()
    // Everything below is read and written only while holding `lock`.
    /// Both clients are resolved by `prepare()` and only there, and a miss is
    /// kept as a miss. They used to be asked for again on every press while
    /// missing — for the keyboard that is `Bundle.load()`, `init()` and
    /// `copyKeyboardBacklightIDs` inside the tap's callback.
    private var displayClient: DisplayBrightnessClient?
    private var keyboardClient: KeyboardBrightnessClient?
    private var prepared = false
    private var watching = false
    /// The volume the presses mean: the last press's target, or the last
    /// change adopted from outside. Nil when the default output has no volume
    /// Isla can set. A press steps from this and nothing else.
    private var volumeState: VolumeState?
    /// What the device was last known to hold — written by Isla or read from
    /// it. The `from` of the next write, so only what changed is written.
    private var deviceVolume: VolumeState?
    /// Bumped whenever the default output is replaced (or the tap restarts):
    /// a target from before is for a device that is no longer the one shown.
    private var volumeGeneration = 0
    private var pendingVolume: VolumeJob?
    /// A drain of `pendingVolume` is queued or running on `writeQueue`.
    private var writerScheduled = false
    private var writeInFlight = false
    /// Bumped by every press and every write that starts: a read that began
    /// before either may have caught the device mid-change.
    private var volumeEpoch = 0
    private var lastWriteEnded: TimeInterval?
    /// The levels Isla's last few writes left and wrote, for `echoWindow`.
    private var recentVolumes: [VolumeState] = []
    private var reconcileScheduled = false
    private var settleCheckScheduled = false
    private var displayTarget: CGDirectDisplayID?
    private var displayLevel: (value: Float, at: TimeInterval)?
    private var keyboardLevel: (value: Float, at: TimeInterval)?
    private var labels: [AudioDeviceID: DeviceLabel] = [:]

    init(
        volume: VolumeOutput? = nil,
        displays: DisplayBrightnessResolver? = nil,
        topology: (() -> DisplayTopology)? = nil,
        keyboards: KeyboardBrightnessResolver? = nil,
        watch: LevelWatching? = nil,
        describe: (@Sendable (AudioDeviceID) -> DeviceLabel)? = nil,
        now: (@Sendable () -> TimeInterval)? = nil
    ) {
        self.volume = volume ?? SystemVolumeOutput()
        self.displays = displays ?? DisplayServicesResolver()
        self.topology = topology ?? BuiltInDisplay.topology
        self.keyboards = keyboards ?? CoreBrightnessResolver()
        // Under XCTest nothing registers a real listener or asks CoreAudio
        // about a device, whatever else the test forgot to fake.
        self.watch = watch ?? (PlayerBridge.isRunningTests ? InertLevelWatch() : SystemLevelWatch())
        let unnamed: @Sendable (AudioDeviceID) -> DeviceLabel = { _ in DeviceLabel() }
        self.describe = describe ?? (PlayerBridge.isRunningTests ? unnamed : DeviceLabel.live)
        self.now = now ?? { ProcessInfo.processInfo.systemUptime }
    }

    func prepare() {
        // Stop any watch a previous prepare started: `start` is not stacked.
        stop()
        let display = displays.resolve()
        let keyboard = keyboards.resolve()
        // Resolves the control the writes will go through, once per tap.
        let state = volume.read(resolving: true)
        let label = state.map { describe($0.device) }
        let target = BuiltInDisplay.target(topology())
        lock.withLock {
            displayClient = display
            keyboardClient = keyboard
            volumeState = state
            deviceVolume = state
            volumeGeneration += 1
            pendingVolume = nil
            recentVolumes = []
            lastWriteEnded = nil
            displayTarget = target
            displayLevel = nil
            keyboardLevel = nil
            labels = [:]
            if let state, let label { labels[state.device] = label }
            prepared = true
            watching = true
        }
        watch.start(on: listenQueue) { [weak self] event in self?.levelChanged(event) }
        watch.follow(state?.device)
    }

    func stop() {
        let wasWatching = lock.withLock {
            let was = watching
            watching = false
            return was
        }
        if wasWatching { watch.stop() }
    }

    func canApply(_ key: MediaKey) -> Bool {
        lock.withLock {
            switch key.kind {
            case .volume: return volumeState != nil
            case .display: return key.raises != nil && displayClient != nil && displayTarget != nil
            case .keyboard: return key.raises != nil && keyboardClient != nil
            }
        }
    }

    func submit(_ key: MediaKey, fine: Bool, deliver: @escaping @Sendable (HUDReading) -> Void) {
        guard key.kind == .volume else {
            queue.async { [self] in
                let signpostID = HUDSignpost.signposter.makeSignpostID()
                let interval = HUDSignpost.signposter.beginInterval("level write", id: signpostID)
                let reading = apply(key, fine: fine)
                HUDSignpost.signposter.endInterval("level write", interval)
                if let reading { deliver(reading) }
            }
            return
        }
        // On the tap's thread: a lock, some arithmetic, the hand-off. No
        // CoreAudio until the writer runs.
        guard let (reading, kick) = enqueueVolume(key, fine: fine, deliver: deliver) else { return }
        deliver(reading)
        if kick { writeQueue.async { [self] in _ = drainVolumeWrites() } }
    }

    /// The level after the key, or nil when it could not be applied — in which
    /// case nothing is shown. Synchronous: the brightnesses' body of `submit`,
    /// and the tests' way to step a volume press through the writer and see
    /// what it ended as (the reading a refused or re-aimed write corrected).
    func apply(_ key: MediaKey, fine: Bool) -> HUDReading? {
        // A caller that never prepared (a test, not the app) still resolves
        // once, and only once.
        if !lock.withLock({ prepared }) { prepare() }
        switch key.kind {
        case .volume:
            let corrected = ReadingSlot()
            guard let (predicted, _) = enqueueVolume(key, fine: fine, deliver: { corrected.value = $0 }) else {
                return nil
            }
            let landed = writeQueue.sync { drainVolumeWrites() }
            return landed ? (corrected.value ?? predicted) : nil
        case .display: return applyDisplay(key, fine: fine)
        case .keyboard: return applyKeyboard(key, fine: fine)
        }
    }

    // MARK: The volume

    /// The intended volume, for the tests.
    var intendedVolume: VolumeState? { lock.withLock { volumeState } }

    /// Waits for every listener read and every volume write queued so far.
    /// For the tests; the app never waits on either.
    func settle() {
        listenQueue.sync {}
        writeQueue.sync {}
        queue.sync {}
    }

    /// Waits for the listener reads queued so far. For the tests.
    func settleListeners() { listenQueue.sync {} }

    /// Runs `body` with the listener queue held, so the events it fires queue
    /// up as a real burst does. For the tests.
    func holdListeners(_ body: () -> Void) {
        listenQueue.suspend()
        body()
        listenQueue.resume()
    }

    /// Steps the intended volume and leaves the target in the writer's slot,
    /// over any target still waiting there. Returns the reading to draw and
    /// whether the writer must be started. Touches no hardware.
    private func enqueueVolume(
        _ key: MediaKey, fine: Bool, deliver: (@Sendable (HUDReading) -> Void)?
    ) -> (HUDReading, Bool)? {
        let result = lock.withLock { () -> (HUDReading, Bool)? in
            guard prepared, let from = volumeState else { return nil }
            let next = HUDStep.volume(after: key, level: from.level, muted: from.muted, fine: fine)
            let target = VolumeState(device: from.device, level: next.level, muted: next.muted)
            volumeState = target
            volumeEpoch += 1
            pendingVolume = VolumeJob(target: target, generation: volumeGeneration, key: key, fine: fine, deliver: deliver)
            let kick = !writerScheduled
            writerScheduled = true
            let label = labels[target.device]
            return (Self.reading(target, label), kick)
        }
        if result != nil { HUDSignpost.signposter.emitEvent("level queued") }
        return result
    }

    private static func reading(_ state: VolumeState, _ label: DeviceLabel?) -> HUDReading {
        HUDReading(
            kind: .volume, level: state.level, muted: state.muted, deviceSymbol: label?.symbol,
            outputDevice: state.device, deviceName: label?.name
        )
    }

    /// On `writeQueue`: writes the newest target until the slot stays empty.
    /// False when the last write did not land.
    private func drainVolumeWrites() -> Bool {
        var landed = true
        while true {
            let next = lock.withLock { () -> (job: VolumeJob, from: VolumeState)?? in
                guard let job = pendingVolume else {
                    writerScheduled = false
                    return .none
                }
                pendingVolume = nil
                // Stepped on a default output that has since been replaced:
                // dropped, never written to the device that replaced it.
                guard job.generation == volumeGeneration else { return .some(nil) }
                writeInFlight = true
                volumeEpoch += 1
                // A device whose holding is not known gets both the mute and
                // the level written.
                let known = deviceVolume.flatMap { $0.device == job.target.device ? $0 : nil }
                let from = known ?? VolumeState(device: job.target.device, level: -1, muted: !job.target.muted)
                return .some((job, from))
            }
            guard let next else { return landed }
            guard let (job, from) = next else { continue }
            landed = writeVolume(job, from: from)
        }
    }

    /// One write, and what follows from how it ended.
    private func writeVolume(_ job: VolumeJob, from: VolumeState) -> Bool {
        let signpostID = HUDSignpost.signposter.makeSignpostID()
        let interval = HUDSignpost.signposter.beginInterval("level write", id: signpostID)
        let result = volume.write(level: job.target.level, muted: job.target.muted, from: from)
        HUDSignpost.signposter.endInterval("level write", interval)
        switch result {
        case .written:
            let named = lock.withLock { () -> Bool in
                finishWrite(from: from, wrote: job.target, generation: job.generation)
                return labels[job.target.device] != nil
            }
            if !named { remember(describe(job.target.device), for: job.target.device) }
            return true
        case .deviceChanged:
            // The device the level was stepped on is gone (AirPods
            // disconnected) and its listener has not run yet. The key was
            // already consumed, so it is applied to the device that is current
            // now, stepped from *that* device's own level: a level worked out
            // from one device must never land on another.
            lock.withLock { writeInFlight = false }
            guard let fresh = adoptVolume(volume.read(resolving: true), describing: true) else { return false }
            let next = HUDStep.volume(after: job.key, level: fresh.level, muted: fresh.muted, fine: job.fine)
            let target = VolumeState(device: fresh.device, level: next.level, muted: next.muted)
            let generation = lock.withLock { () -> Int in
                volumeState = target
                writeInFlight = true
                volumeEpoch += 1
                return volumeGeneration
            }
            guard volume.write(level: target.level, muted: target.muted, from: fresh) == .written else {
                lock.withLock { writeInFlight = false }
                _ = adoptVolume(volume.read(resolving: true), describing: false)
                return false
            }
            let label = lock.withLock { () -> DeviceLabel? in
                finishWrite(from: fresh, wrote: target, generation: generation)
                return labels[target.device]
            }
            job.deliver?(Self.reading(target, label))
            return true
        case .failed:
            // A refused write leaves Isla unsure of what the device holds: it
            // reads it, and the bar drawn for the press goes back to it.
            lock.withLock { writeInFlight = false }
            if let fresh = adoptVolume(volume.read(resolving: true), describing: false) {
                let label = lock.withLock { labels[fresh.device] }
                job.deliver?(Self.reading(fresh, label))
            }
            return false
        }
    }

    /// Under `lock`: a write landed.
    private func finishWrite(from: VolumeState, wrote: VolumeState, generation: Int) {
        writeInFlight = false
        lastWriteEnded = now()
        recentVolumes = Array((recentVolumes + [from, wrote]).suffix(8))
        if generation == volumeGeneration { deviceVolume = wrote }
    }

    /// Stores a fresh read of the default output as both the intention and
    /// what the device holds, drops any target still waiting (it was stepped
    /// from something else), and moves the per-device listeners when the
    /// device changed. `describing` re-reads the label even for a device
    /// already known (the default-output listener: a device that came back may
    /// not be the one that left).
    @discardableResult
    private func adoptVolume(_ fresh: VolumeState?, describing: Bool) -> VolumeState? {
        let (moved, known, isWatching) = lock.withLock {
            let moved = volumeState?.device != fresh?.device
            if moved {
                volumeGeneration += 1
                recentVolumes = []
            }
            volumeState = fresh
            deviceVolume = fresh
            pendingVolume = nil
            return (moved, fresh.flatMap { labels[$0.device] }, watching)
        }
        if let fresh, describing || moved || known == nil {
            remember(describe(fresh.device), for: fresh.device)
        }
        if moved, isWatching { watch.follow(fresh?.device) }
        return fresh
    }

    @discardableResult
    private func remember(_ label: DeviceLabel, for device: AudioDeviceID) -> DeviceLabel {
        lock.withLock { labels[device] = label }
        return label
    }

    /// A listener fired. On `listenQueue` in the app (synchronously on the
    /// test's thread with the fake watch); one that was already queued when the
    /// tap stopped is ignored.
    private func levelChanged(_ event: LevelEvent) {
        guard lock.withLock({ watching }) else { return }
        switch event {
        case .defaultOutput:
            // A burst of these comes with one real change, and some come with
            // none (a device's streams settling). Only a new device replaces
            // the intention; the same one is a volume event like any other,
            // which a press in progress must survive.
            let fresh = volume.read(resolving: true)
            let same = lock.withLock { fresh != nil && volumeState?.device == fresh?.device }
            if same, let fresh {
                remember(describe(fresh.device), for: fresh.device)
                scheduleReconcile()
            } else {
                adoptVolume(fresh, describing: true)
            }
        case .volume:
            scheduleReconcile()
        case .dataSource:
            guard let device = lock.withLock({ volumeState?.device }) else { return }
            remember(describe(device), for: device)
        case .displays:
            let target = BuiltInDisplay.target(topology())
            lock.withLock {
                displayTarget = target
                displayLevel = nil
            }
        }
    }

    /// One read for a burst: the events already queued behind this one find
    /// it scheduled and add nothing.
    private func scheduleReconcile() {
        let schedule = lock.withLock { () -> Bool in
            guard !reconcileScheduled else { return false }
            reconcileScheduled = true
            return true
        }
        if schedule { listenQueue.async { [weak self] in self?.reconcileVolume(settling: false) } }
    }

    /// One more look once `echoWindow` has passed, for a change that a write
    /// in flight, or one that looked like an echo, kept from being adopted.
    private func scheduleSettleCheck() {
        let schedule = lock.withLock { () -> Bool in
            guard !settleCheckScheduled else { return false }
            settleCheckScheduled = true
            return true
        }
        guard schedule else { return }
        listenQueue.asyncAfter(deadline: .now() + Self.echoWindow) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.settleCheckScheduled = false }
            self.reconcileVolume(settling: true)
        }
    }

    private enum Reconciled { case kept, adopted, later, moved }

    /// Reads the device and adopts what it holds only when that is a change
    /// made outside Isla (see the type's note, point 3). Never steps from a
    /// value read back after Isla's own write.
    private func reconcileVolume(settling: Bool) {
        let ticket = lock.withLock { () -> Int? in
            if !settling { reconcileScheduled = false }
            return watching ? volumeEpoch : nil
        }
        guard let ticket else { return }
        let fresh = volume.read()
        let moment = now()
        let outcome = lock.withLock { () -> Reconciled in
            guard watching else { return .kept }
            // A press or a write began while the device was being read: the
            // value may be from either side of it.
            if volumeEpoch != ticket || writeInFlight || pendingVolume != nil { return .later }
            guard let fresh, let intended = volumeState else {
                return fresh == nil && volumeState == nil ? .kept : .moved
            }
            guard fresh.device == intended.device else { return .moved }
            if Self.same(fresh, intended) {
                deviceVolume = fresh
                return .kept
            }
            if !settling, let ended = lastWriteEnded, moment - ended < Self.echoWindow,
               recentVolumes.contains(where: { Self.same($0, fresh) }) {
                return .later
            }
            volumeState = fresh
            deviceVolume = fresh
            return .adopted
        }
        switch outcome {
        case .kept, .adopted: break
        case .later: scheduleSettleCheck()
        case .moved: adoptVolume(fresh, describing: false)
        }
    }

    private static func same(_ a: VolumeState, _ b: VolumeState) -> Bool {
        a.device == b.device && a.muted == b.muted && abs(a.level - b.level) <= levelTolerance
    }

    // MARK: The two brightnesses

    private func applyDisplay(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let raises = key.raises else { return nil }
        let (client, target, cached) = lock.withLock { (displayClient, displayTarget, displayLevel) }
        guard let client, let target else { return nil }
        let moment = now()
        let current: Float
        if let cached, moment - cached.at <= Self.levelTrustedFor {
            current = cached.value
        } else {
            guard let read = client.brightness(of: target) else { return nil }
            current = read
        }
        let next = HUDStep.stepped(current, raising: raises, fine: fine)
        let written = client.setBrightness(next, of: target)
        lock.withLock { displayLevel = written ? (next, moment) : nil }
        guard written else { return nil }
        return HUDReading(kind: .display, level: next, muted: false, deviceSymbol: nil)
    }

    private func applyKeyboard(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard let raises = key.raises else { return nil }
        let (client, cached) = lock.withLock { (keyboardClient, keyboardLevel) }
        guard let client else { return nil }
        let moment = now()
        let current: Float
        if let cached, moment - cached.at <= Self.levelTrustedFor {
            current = cached.value
        } else {
            guard let read = client.brightness() else { return nil }
            current = read
        }
        let next = HUDStep.stepped(current, raising: raises, fine: fine)
        let written = client.setBrightness(next)
        lock.withLock { keyboardLevel = written ? (next, moment) : nil }
        guard written else { return nil }
        return HUDReading(kind: .keyboard, level: next, muted: false, deviceSymbol: nil)
    }
}

// MARK: - The listeners

/// A watch that hears nothing: what a test process gets by default.
final class InertLevelWatch: LevelWatching, @unchecked Sendable {
    func start(on queue: DispatchQueue, events: @escaping @Sendable (LevelEvent) -> Void) {}
    func follow(_ device: AudioDeviceID?) {}
    func stop() {}
}

/// The real listeners: the default output on the system object; volume, mute
/// and data source on the device it names; and the display reconfiguration
/// callback. Installed by `prepare()` when a tap starts and removed by
/// `stop()` when it ends — a switched-off Isla has none.
///
/// Deliberately thin and untested, like `AudioWatch`'s glue: it holds no
/// decisions, only registrations, and every event is handed to the applier on
/// its queue. The CoreAudio registrations are confined to `registrations`, a
/// private serial queue, so no lock is ever held across a CoreAudio call:
/// `follow` arrives from the applier's queue (inside a listener event) as well
/// as from the main actor, and a lock held there while
/// `AudioObjectRemovePropertyListenerBlock` waited on an in-flight listener
/// block could deadlock the two. `stop()` waits for that queue, which itself
/// never waits on anything, so the registrations are gone when it returns.
/// The display callback is registered and removed on the main actor
/// (`start`/`stop`), and its flag sits behind `displayLock`. That confinement
/// is why `@unchecked Sendable` is safe.
final class SystemLevelWatch: LevelWatching, @unchecked Sendable {
    private let registrations = DispatchQueue(label: "com.ctimothe.isla.levels.listeners", qos: .userInteractive)
    // Confined to `registrations` (or to `deinit`, when nothing else is left).
    private var queue: DispatchQueue?
    private var events: (@Sendable (LevelEvent) -> Void)?
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var sourceBlock: AudioObjectPropertyListenerBlock?
    private var followed: AudioDeviceID?

    private let displayLock = NSLock()
    // Guarded by `displayLock`.
    private var displaysRegistered = false
    private var displayEvents: (queue: DispatchQueue, events: @Sendable (LevelEvent) -> Void)?

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The level and the mute, on the wildcard element: the level can live on
    /// the main control or on the two channels `SystemVolume` averages. And
    /// the virtual main volume, which is what the keys read and write first
    /// (`SystemVolume.Control.virtualMain`): an output that has only that one
    /// — AirPlay among them — never reported a change made elsewhere, so a
    /// press stepped from a stale level (R8c review, L3). A device without a
    /// property refuses its listener, and the refusal is ignored like the
    /// rest.
    private static var deviceAddresses: [AudioObjectPropertyAddress] {
        [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
            AudioObjectPropertyAddress(
                mSelector: $0, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementWildcard
            )
        } + [
            AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
            ),
        ]
    }

    private static var dataSourceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func start(on queue: DispatchQueue, events: @escaping @Sendable (LevelEvent) -> Void) {
        registrations.sync {
            self.queue = queue
            self.events = events
            let block: AudioObjectPropertyListenerBlock = { _, _ in events(.defaultOutput) }
            systemBlock = block
            var address = Self.defaultOutputAddress
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        let register = displayLock.withLock {
            displayEvents = (queue, events)
            let first = !displaysRegistered
            displaysRegistered = true
            return first
        }
        // The reconfiguration callback runs on the main thread; it only hops.
        if register {
            CGDisplayRegisterReconfigurationCallback(levelWatchDisplaysChanged, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func follow(_ device: AudioDeviceID?) {
        registrations.async { [weak self] in self?.attach(device) }
    }

    func stop() {
        registrations.sync { detachAll() }
        let registered = displayLock.withLock {
            let was = displaysRegistered
            displaysRegistered = false
            displayEvents = nil
            return was
        }
        if registered {
            CGDisplayRemoveReconfigurationCallback(levelWatchDisplaysChanged, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// On `registrations`. A follow that arrives after `stop()` finds no queue
    /// and installs nothing.
    private func attach(_ device: AudioDeviceID?) {
        guard device != followed, let queue, let events else { return }
        detachDevice()
        guard let device else { return }
        let levels: AudioObjectPropertyListenerBlock = { _, _ in events(.volume) }
        let source: AudioObjectPropertyListenerBlock = { _, _ in events(.dataSource) }
        for var address in Self.deviceAddresses {
            AudioObjectAddPropertyListenerBlock(device, &address, queue, levels)
        }
        var sourceAddress = Self.dataSourceAddress
        AudioObjectAddPropertyListenerBlock(device, &sourceAddress, queue, source)
        deviceBlock = levels
        sourceBlock = source
        followed = device
    }

    private func detachAll() {
        detachDevice()
        if let block = systemBlock, let queue {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        systemBlock = nil
        events = nil
        queue = nil
    }

    /// A device that vanished answers the removal with an error and nothing
    /// else.
    private func detachDevice() {
        if let device = followed, let queue {
            if let block = deviceBlock {
                for var address in Self.deviceAddresses {
                    AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
                }
            }
            if let block = sourceBlock {
                var address = Self.dataSourceAddress
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            }
        }
        deviceBlock = nil
        sourceBlock = nil
        followed = nil
    }

    fileprivate func displaysChanged() {
        guard let target = displayLock.withLock({ displayEvents }) else { return }
        target.queue.async { target.events(.displays) }
    }

    deinit {
        // A safety net: the applier stops the watch with the tap, and this only
        // catches one released while still registered. Inline rather than
        // through `registrations`, because the last reference may be dropped
        // on that very queue; nothing else can reach this object any more.
        detachAll()
        if displaysRegistered {
            CGDisplayRemoveReconfigurationCallback(levelWatchDisplaysChanged, Unmanaged.passUnretained(self).toOpaque())
        }
    }
}

/// The display reconfiguration callback. It fires once before and once after
/// each change; only the second (no `beginConfigurationFlag`) is worth a look.
private func levelWatchDisplaysChanged(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    Unmanaged<SystemLevelWatch>.fromOpaque(userInfo).takeUnretainedValue().displaysChanged()
}

/// One reading, set from the writer's queue and read after it, for
/// `SystemLevelApplier.apply`.
private final class ReadingSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HUDReading?
    var value: HUDReading? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
