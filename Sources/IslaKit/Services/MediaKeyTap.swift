import AppKit
import CoreGraphics
import OSLog

/// The seven keys the pop-up replaces (redesign 2026-10-15, spec §12).
///
/// The raw values are the `NX_KEYTYPE_*` codes the system puts in an
/// `NX_SYSDEFINED` event's `data1`; they are the whole contract with the
/// keyboard, so each one is held by a test (`MediaKeyDecoderTests`).
enum MediaKey: Int, CaseIterable, Equatable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case keyboardBrightnessUp = 21
    case keyboardBrightnessDown = 22
}

/// One press or release of a media key, decoded.
struct MediaKeyPress: Equatable {
    var key: MediaKey
    /// `NX_KEYSTATE_DOWN` (0xA). A release is 0xB.
    var isDown: Bool
    /// The system's own auto-repeat of a held key.
    var isRepeat: Bool
}

/// What the held modifiers mean for a media key: a quarter step, or "not mine".
///
/// - ⌥⇧ together give quarter steps, as macOS does for the volume and both
///   brightnesses. Those two are the only modifier states Isla consumes besides
///   none at all.
/// - Every other combination of ⌘ ⌃ ⌥ ⇧ belongs to the system, and the event is
///   passed through untouched: ⇧ with a volume key is the silent change (no
///   feedback sound), ⌥ with a volume or brightness key opens Sound or Displays
///   settings, and ⌘/⌃ chords are somebody's shortcut. The tap used to swallow
///   all of them and apply a plain step, so those shortcuts stopped working the
///   moment the setting was on.
/// - fn, caps lock and the numeric-pad bit are ignored on purpose: the built-in
///   keyboard stamps fn on its media keys, and a rule that counted it would
///   pass every press through.
struct MediaKeyModifiers: Equatable {
    var fine: Bool
    /// The system handles this combination; Isla must neither apply nor
    /// consume it.
    var leavesToTheSystem: Bool

    static let none = MediaKeyModifiers(fine: false)

    init(fine: Bool, leavesToTheSystem: Bool = false) {
        self.fine = fine
        self.leavesToTheSystem = leavesToTheSystem
    }

    /// Pure, so every one of the sixteen combinations is a test.
    init(flags: CGEventFlags) {
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)
        fine = option && shift
        leavesToTheSystem = command || control || (option != shift)
    }
}

/// `NX_SYSDEFINED` data → a key press, and nothing else. Pure, so every key,
/// both states, the repeat bit and everything that must be left alone are
/// tests rather than a hope about what the keyboard sends.
enum MediaKeyDecoder {
    /// `NX_SYSDEFINED`, the CGEvent type media keys arrive as.
    static let systemDefinedType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: the subtype the media and brightness
    /// keys share. Every other subtype (power button, eject, …) is not ours.
    static let auxControlSubtype = 8

    private static let keyDownState = 0xA
    private static let keyUpState = 0xB

    /// - Returns: nil for anything that is not a recognised key in a state the
    ///   system defines — and nil means *pass the event through untouched*.
    static func decode(subtype: Int, data1: Int) -> MediaKeyPress? {
        guard subtype == auxControlSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8
        guard let key = MediaKey(rawValue: keyCode) else { return nil }
        switch keyState {
        case keyDownState: return MediaKeyPress(key: key, isDown: true, isRepeat: data1 & 0x1 != 0)
        case keyUpState: return MediaKeyPress(key: key, isDown: false, isRepeat: false)
        default: return nil
        }
    }
}

/// What the tap does with an event type, before it looks inside. Pure, so
/// the re-enable rule is a test.
enum MediaKeyTapDisposition: Equatable {
    /// `kCGEventTapDisabledByTimeout` or `…ByUserInput`: macOS switched the tap
    /// off (a callback too slow once, or Secure Input, or a revoked
    /// permission). Switch it back on — and let the owner re-check trust, since
    /// a revoked permission is also one of the ways here.
    case reenable
    /// A system-defined event: look inside.
    case inspect
    case ignore

    static func of(_ type: CGEventType) -> MediaKeyTapDisposition {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput: return .reenable
        default: return type.rawValue == MediaKeyDecoder.systemDefinedType ? .inspect : .ignore
        }
    }
}

/// The part of an event tap the rest of the app depends on: something that can
/// be started, stopped, and asked whether it is up. A seam, so the tests count
/// how many taps were made and when they were torn down without ever creating a
/// real `CGEventTap` (which needs the Accessibility permission and would sit
/// in front of the owner's real volume keys).
@MainActor
protocol MediaKeyTapping: AnyObject {
    var isRunning: Bool { get }
    /// Whether macOS still has the tap switched on. A revoked and re-granted
    /// Accessibility permission can leave a tap that exists and hears nothing
    /// (and never sends a disabled notice), so the owner asks before it trusts
    /// one it made earlier.
    var isTapEnabled: Bool { get }
    /// True when the tap is up. False when macOS refused to make one — no
    /// permission, or a session that does not allow it — in which case nothing
    /// is consumed and nothing else changes.
    @discardableResult func start() -> Bool
    func stop()
}

/// What a tap asks its owner for each decoded press: `true` when Isla takes
/// the key and the event must be consumed, `false` to hand it on to the
/// system.
///
/// Called on the tap's own thread, inside the callback, so it must answer from
/// cached state and return at once (`MediaKeyGate`); it is `@Sendable` and not
/// main-actor for exactly that reason.
typealias MediaKeyHandler = @Sendable (MediaKeyPress, MediaKeyModifiers) -> Bool

/// Makes a tap that reports to `handler`, and calls `disabled` — on the tap's
/// thread, before the tap is switched back on — when macOS switched it off.
/// Production passes `EventMediaKeyTap.live`; tests pass a counting fake.
typealias MediaKeyTapFactory = @MainActor (
    _ handler: @escaping MediaKeyHandler, _ disabled: @escaping @Sendable () -> Void
) -> MediaKeyTapping

/// The signposts an Instruments run reads the key path's latency from:
/// "media key" around the tap's callback, "level write" around the hardware
/// write. They cost nothing while nobody is recording.
enum HUDSignpost {
    static let signposter = OSSignposter(subsystem: Log.subsystem, category: "hud")
}

/// The real tap: `.cgSessionEventTap`, head-inserted, `.defaultTap` (listen
/// *and modify*, which is what lets a callback consume an event) over
/// `NX_SYSDEFINED`.
///
/// **Its run-loop source lives on a thread of its own**, at user-interactive
/// quality of service, never on the main run loop. It used to sit on the main
/// loop so the callback could reach the main actor directly — but then every
/// volume press waited for whatever the main thread was drawing, and while the
/// Mac was loaded the wait passed macOS's timeout: the tap was disabled, and
/// the presses until it was re-enabled went to the system's own pop-up. The
/// callback now answers from cached state (`MediaKeyGate`) and the hardware
/// write happens later on the applier's queue, so nothing in front of a key
/// waits on the main thread or on CoreAudio.
///
/// The object itself stays main-actor (it is started and stopped from there);
/// everything the tap's thread touches lives in `MediaKeyTapContext`.
@MainActor
final class EventMediaKeyTap: MediaKeyTapping {
    /// How long `stop()` waits for the tap's thread to leave its run loop. The
    /// callback never blocks, so this is only ever a bound, not a delay.
    static let threadExitTimeout: TimeInterval = 1.0

    private let handler: MediaKeyHandler
    private let disabled: @Sendable () -> Void
    private var context: MediaKeyTapContext?

    init(handler: @escaping MediaKeyHandler, disabled: @escaping @Sendable () -> Void = {}) {
        self.handler = handler
        self.disabled = disabled
    }

    /// The factory production uses. Under test it makes a tap that never
    /// starts: the suite runs on the owner's Mac, often with the setting on,
    /// and a real tap there would sit in front of their volume keys.
    static let live: MediaKeyTapFactory = { handler, disabled in
        if PlayerBridge.isRunningTests { return InertMediaKeyTap() }
        return EventMediaKeyTap(handler: handler, disabled: disabled)
    }

    var isRunning: Bool { context != nil }

    var isTapEnabled: Bool {
        guard let port = context?.port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    @discardableResult
    func start() -> Bool {
        guard context == nil else { return true }
        let made = MediaKeyTapContext(handler: handler, disabled: disabled)
        let mask: CGEventMask = 1 << CGEventMask(MediaKeyDecoder.systemDefinedType)
        // Unretained: the callback only ever runs on the tap's thread, inside
        // its run loop, and that thread's closure holds the context strongly
        // until the loop has ended.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(made).toOpaque()
        ) else { return false }
        made.attach(port: port, source: CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0))
        let thread = Thread { made.run() }
        thread.name = "com.ctimothe.isla.media-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Microseconds: the thread only adds the source to its loop.
        made.loopReady.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        context = made
        return true
    }

    func stop() {
        guard let context else { return }
        self.context = nil
        context.shutdown()
        // No thread outlives `stop()`: wait for it to leave its run loop.
        if context.loopEnded.wait(timeout: .now() + Self.threadExitTimeout) == .timedOut {
            Log.app.error("media key tap thread did not end within \(Self.threadExitTimeout, privacy: .public) s")
        }
    }

    deinit {
        // `stop()` is main-actor; a tap that is deallocated while running has
        // already lost its owner, so the port is ended and the thread told to
        // leave without being waited for.
        context?.shutdown()
    }
}

/// What the tap's thread shares with the main actor: the handler, the port,
/// and the thread's run loop. The handler and `disabled` are immutable and
/// `@Sendable`; the port, source, run loop and stopping flag are written once
/// at start and once at shutdown, always under `lock`. The CF calls made on
/// them from another thread (`CGEvent.tapEnable`, `CFRunLoopStop`,
/// `CFRunLoopRemoveSource`, `CFMachPortInvalidate`) are documented
/// thread-safe. That is why `@unchecked Sendable` is safe.
final class MediaKeyTapContext: @unchecked Sendable {
    let handler: MediaKeyHandler
    let disabled: @Sendable () -> Void
    /// Switches the tap back on. A seam so a test can watch it without a port.
    let reenable: @Sendable (CFMachPort?) -> Void
    let loopReady = DispatchSemaphore(value: 0)
    let loopEnded = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    // Guarded by `lock`.
    private var portStorage: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var stopping = false

    init(
        handler: @escaping MediaKeyHandler, disabled: @escaping @Sendable () -> Void = {},
        reenable: (@Sendable (CFMachPort?) -> Void)? = nil
    ) {
        self.handler = handler
        self.disabled = disabled
        self.reenable = reenable ?? { port in
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        }
    }

    var port: CFMachPort? { lock.withLock { portStorage } }

    func attach(port: CFMachPort, source: CFRunLoopSource?) {
        lock.withLock {
            portStorage = port
            self.source = source
        }
    }

    /// The tap's thread: add the source to this thread's loop and run it until
    /// `shutdown()`.
    func run() {
        let loop = CFRunLoopGetCurrent()
        lock.withLock {
            runLoop = loop
            if let source { CFRunLoopAddSource(loop, source, .commonModes) }
        }
        loopReady.signal()
        while !lock.withLock({ stopping }) {
            // Returns when `shutdown()` stops the loop, or at once when the
            // source has been removed (`.finished`) — never a spin, because
            // removal only happens after `stopping` is set.
            let result = CFRunLoopRunInMode(.defaultMode, 3600, false)
            if result == .finished { break }
        }
        loopEnded.signal()
    }

    /// Releases the keys for good and tells the thread to leave. Safe from any
    /// thread, and idempotent.
    func shutdown() {
        let (port, source, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?) in
            stopping = true
            let parts = (portStorage, self.source, runLoop)
            self.source = nil
            return parts
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source, let loop { CFRunLoopRemoveSource(loop, source, .commonModes) }
        // Invalidating the port is what takes the tap out of the chain: a
        // disabled tap is still in it.
        if let port { CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
    }

    /// One event from the callback, on the tap's thread. `nil` consumes it.
    func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        switch MediaKeyTapDisposition.of(type) {
        case .reenable:
            // Holds first, then the tap back on: nothing may reach the handler
            // in between with a hold left over from before the gap.
            disabled()
            if !lock.withLock({ stopping }) { reenable(port) }
            return passThrough
        case .ignore:
            return passThrough
        case .inspect:
            guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
                  let press = MediaKeyDecoder.decode(subtype: Int(ns.subtype.rawValue), data1: ns.data1)
            else { return passThrough }
            let consumed = handler(press, MediaKeyModifiers(flags: event.flags))
            return consumed ? nil : passThrough
        }
    }
}

/// A tap that never starts: what a test process gets from `EventMediaKeyTap.live`.
@MainActor
final class InertMediaKeyTap: MediaKeyTapping {
    var isRunning: Bool { false }
    var isTapEnabled: Bool { false }
    func start() -> Bool { false }
    func stop() {}
}

/// The C callback, on the tap's thread. Nothing here but the signpost and the
/// hand-off to the context.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<MediaKeyTapContext>.fromOpaque(refcon).takeUnretainedValue()
    let signposter = HUDSignpost.signposter
    let interval = signposter.beginInterval("media key", id: signposter.makeSignpostID())
    defer { signposter.endInterval("media key", interval) }
    return context.receive(type: type, event: event)
}
