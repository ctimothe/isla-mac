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
/// Not main-actor: since 2026-10-18 every call is made on the applier's own
/// serial queue (`SystemLevelApplier.queue`), or on the main thread while the
/// tap is being prepared, never on both at once. CoreAudio's property calls
/// are thread-safe; the main thread is exactly where a key press must not
/// wait for them.
protocol VolumeOutput: Sendable {
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
    init() {}

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
/// **Threads.** `canApply` runs on the tap's thread, `prepare`/`stop` on the
/// main actor, `apply` (through `submit`) and the listener events on `queue`.
/// Everything they share lives behind `lock`, which is held only to copy a
/// value in or out — never across a CoreAudio or DisplayServices call, so the
/// tap's thread can never wait on hardware through it. Writes and listener
/// refreshes are serialised by the queue itself, so a refresh cannot
/// interleave with a write and leave a stale level behind. That discipline is
/// why `@unchecked Sendable` is safe here.
///
/// **What is cached.** The default output's level, mute and device id, kept
/// current by CoreAudio listeners (so a volume step needs no read before its
/// write); the label of each device the pop-up has named; the built-in display
/// the brightness keys may move, refreshed by the display-reconfiguration
/// listener; and the last brightness and backlight level written or read,
/// trusted for `levelTrustedFor` seconds (nothing announces a change to
/// those, and auto-brightness moves them on its own).
final class SystemLevelApplier: MediaKeyApplying, @unchecked Sendable {
    /// How long a brightness or backlight level Isla wrote or read is used for
    /// the next step without reading it again. A held key repeats far inside
    /// this, so a hold costs one read at most; a press after a pause reads
    /// first — on the queue, never in front of the key — because the ambient
    /// light sensor may have moved the level since, and stepping from a stale
    /// one makes the screen jump.
    static let levelTrustedFor: TimeInterval = 1.5

    /// The hardware writes and the listener refreshes, in order, at the
    /// priority of the key press that caused them.
    let queue = DispatchQueue(label: "com.ctimothe.isla.levels", qos: .userInteractive)

    private let volume: VolumeOutput
    private let displays: DisplayBrightnessResolver
    /// Called at `prepare()` (main actor) and on `.displays` events (the
    /// queue). The real one is two CoreGraphics reads, which are thread-safe.
    private let topology: () -> DisplayTopology
    private let keyboards: KeyboardBrightnessResolver
    private let watch: LevelWatching
    private let describe: @Sendable (AudioDeviceID) -> DeviceLabel
    private let now: @Sendable () -> TimeInterval

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
    /// The default output as last read or written; nil when it has no volume
    /// Isla can set.
    private var volumeState: VolumeState?
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
        let state = volume.read()
        let label = state.map { describe($0.device) }
        let target = BuiltInDisplay.target(topology())
        lock.withLock {
            displayClient = display
            keyboardClient = keyboard
            volumeState = state
            displayTarget = target
            displayLevel = nil
            keyboardLevel = nil
            labels = [:]
            if let state, let label { labels[state.device] = label }
            prepared = true
            watching = true
        }
        watch.start(on: queue) { [weak self] event in self?.levelChanged(event) }
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
        queue.async { [self] in
            let signpostID = HUDSignpost.signposter.makeSignpostID()
            let interval = HUDSignpost.signposter.beginInterval("level write", id: signpostID)
            let reading = apply(key, fine: fine)
            HUDSignpost.signposter.endInterval("level write", interval)
            if let reading { deliver(reading) }
        }
    }

    /// The level after the key, or nil when it could not be applied — in which
    /// case nothing is shown. The body of `submit`, which runs it on `queue`;
    /// internal so the tests can step it synchronously.
    func apply(_ key: MediaKey, fine: Bool) -> HUDReading? {
        // A caller that never prepared (a test, not the app) still resolves
        // once, and only once.
        if !lock.withLock({ prepared }) { prepare() }
        switch key.kind {
        case .volume: return applyVolume(key, fine: fine)
        case .display: return applyDisplay(key, fine: fine)
        case .keyboard: return applyKeyboard(key, fine: fine)
        }
    }

    // MARK: The volume

    private func applyVolume(_ key: MediaKey, fine: Bool) -> HUDReading? {
        guard var from = lock.withLock({ volumeState }) else { return nil }
        var next = HUDStep.volume(after: key, level: from.level, muted: from.muted, fine: fine)
        var result = volume.write(level: next.level, muted: next.muted, from: from)
        if result == .deviceChanged {
            // The default output moved and its listener has not run yet (AirPods
            // connecting under the press). The key was already consumed, so it
            // is applied to the device that is current now, stepped from *that*
            // device's own level: a level worked out from one device must never
            // land on another — the bug `write(level:muted:from:)` exists for.
            // This is the one read a step can need, and it is on this queue.
            guard let fresh = adoptVolume(volume.read(), describing: true) else { return nil }
            from = fresh
            next = HUDStep.volume(after: key, level: from.level, muted: from.muted, fine: fine)
            result = volume.write(level: next.level, muted: next.muted, from: from)
        }
        guard result == .written else {
            // A refused write leaves the cache unsure of what the device holds.
            _ = adoptVolume(volume.read(), describing: false)
            return nil
        }
        let written = VolumeState(device: from.device, level: next.level, muted: next.muted)
        let known = lock.withLock { () -> DeviceLabel? in
            volumeState = written
            return labels[written.device]
        }
        let label = known ?? remember(describe(written.device), for: written.device)
        return HUDReading(
            kind: .volume, level: next.level, muted: next.muted, deviceSymbol: label.symbol,
            outputDevice: written.device, deviceName: label.name
        )
    }

    /// Stores a fresh read of the default output and moves the per-device
    /// listeners when the device changed. `describing` re-reads the label even
    /// for a device already known (the default-output listener: a device that
    /// came back may not be the one that left).
    @discardableResult
    private func adoptVolume(_ fresh: VolumeState?, describing: Bool) -> VolumeState? {
        let (moved, known, isWatching) = lock.withLock {
            let moved = volumeState?.device != fresh?.device
            volumeState = fresh
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

    /// A listener fired. On `queue` in the app, so it is ordered with the
    /// writes; one that was already queued when the tap stopped is ignored.
    private func levelChanged(_ event: LevelEvent) {
        guard lock.withLock({ watching }) else { return }
        switch event {
        case .defaultOutput:
            adoptVolume(volume.read(), describing: true)
        case .volume:
            adoptVolume(volume.read(), describing: false)
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
    /// the main control or on the two channels `SystemVolume` averages.
    private static var deviceAddresses: [AudioObjectPropertyAddress] {
        [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
            AudioObjectPropertyAddress(
                mSelector: $0, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementWildcard
            )
        }
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
