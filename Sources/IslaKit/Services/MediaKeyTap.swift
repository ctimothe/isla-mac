import AppKit
import CoreGraphics

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

/// Modifiers that change a step: ⌥⇧ together give quarter steps, as macOS does
/// for the volume and both brightnesses.
struct MediaKeyModifiers: Equatable {
    var fine: Bool

    static let none = MediaKeyModifiers(fine: false)

    init(fine: Bool) { self.fine = fine }

    init(flags: CGEventFlags) {
        fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
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
    /// True when the tap is up. False when macOS refused to make one — no
    /// permission, or a session that does not allow it — in which case nothing
    /// is consumed and nothing else changes.
    @discardableResult func start() -> Bool
    func stop()
}

/// What a tap asks its owner for each decoded press: `true` when Isla applied
/// it and the event must be consumed, `false` to hand it on to the system.
typealias MediaKeyHandler = @MainActor (MediaKeyPress, MediaKeyModifiers) -> Bool

/// Makes a tap that reports to `handler`. Production passes
/// `EventMediaKeyTap.live`; tests pass a counting fake.
typealias MediaKeyTapFactory = @MainActor (
    _ handler: @escaping MediaKeyHandler, _ disabled: @escaping @MainActor @Sendable () -> Void
) -> MediaKeyTapping

/// The real tap: `.cgSessionEventTap`, head-inserted, `.defaultTap` (listen
/// *and modify*, which is what lets a callback consume an event) over
/// `NX_SYSDEFINED`.
///
/// The run-loop source goes on the **main** run loop, so the C callback runs on
/// the main thread and can reach the main actor with `MainActor.assumeIsolated`
/// rather than hopping a queue — a hop would make the answer to "may the system
/// have this key?" arrive after the system had already acted on it. The
/// callback stays minimal: it finds this object and calls `receive`, which
/// decodes and asks the handler.
@MainActor
final class EventMediaKeyTap: MediaKeyTapping {
    private let handler: MediaKeyHandler
    private let disabled: @MainActor @Sendable () -> Void
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// Switches the tap back on. A property so a test can watch it without a
    /// port.
    var reenable: @MainActor (CFMachPort?) -> Void = { port in
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    init(handler: @escaping MediaKeyHandler, disabled: @escaping @MainActor @Sendable () -> Void = {}) {
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

    var isRunning: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = 1 << CGEventMask(MediaKeyDecoder.systemDefinedType)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        port = created
        source = runLoopSource
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        // Invalidating the port is what releases the keys for good: a disabled
        // tap is still in the chain.
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    /// One event from the callback. `nil` consumes it.
    func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        switch MediaKeyTapDisposition.of(type) {
        case .reenable:
            reenable(port)
            disabled()
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

    deinit {
        // `stop()` is main-actor; a tap that is deallocated while running has
        // already lost its owner, so only the port needs ending.
        if let port { CFMachPortInvalidate(port) }
    }
}

/// A tap that never starts: what a test process gets from `EventMediaKeyTap.live`.
@MainActor
final class InertMediaKeyTap: MediaKeyTapping {
    var isRunning: Bool { false }
    func start() -> Bool { false }
    func stop() {}
}

/// The C callback. Nothing here but the hop to the main actor: the run-loop
/// source is on the main loop, so this already runs on the main thread.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventMediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { tap.receive(type: type, event: event) }
}
