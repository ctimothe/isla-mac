import AppKit

/// Keeps the collapsed pill on screen while the Mac is locked, the way the
/// iPhone's island keeps playing on its lock screen. Display only: what shows
/// over the shield is exactly the compact pill — artwork and equalizer,
/// playing or paused — and nothing about it can be opened or clicked there.
///
/// Locking is watched, not asked about. loginwindow has posted
/// "com.apple.screenIsLocked" and "com.apple.screenIsUnlocked" on the
/// distributed center for years — no entitlement, no permission prompt — and
/// the open-source notch apps (boring.notch, mew-notch) both ship on exactly
/// this pair, so it is as close to a public contract as an undocumented
/// notification gets.
///
/// Presentation goes through a SkyLight space of the app's own — see
/// `apply(to:locked:)` for why the public route, a panel raised past
/// `CGShieldingWindowLevel()`, lost the physical test. The documented
/// permission bit for drawing over loginwindow, `canBecomeVisibleWithoutLogin`,
/// is still set for the length of a lock.
@MainActor
final class LockScreenPresence {
    static let lockNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockNotification = Notification.Name("com.apple.screenIsUnlocked")

    private(set) var isLocked = false
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?
    private var observers: [Any] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Self.lockNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleLock() }
        })
        observers.append(center.addObserver(
            forName: Self.unlockNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUnlock() }
        })
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    /// Internal rather than private: the transition — fire once per edge,
    /// swallow repeats — is the half of this type a test can hold still.
    func handleLock() {
        guard !isLocked else { return }
        isLocked = true
        onLock?()
    }

    func handleUnlock() {
        guard isLocked else { return }
        isLocked = false
        onUnlock?()
    }

    /// Moves the panel into a SkyLight space above the shield, or returns it
    /// to the ordinary world.
    ///
    /// The public route was tried first and lost, exactly as the precedent
    /// warned: raised past `CGShieldingWindowLevel()` with
    /// `canBecomeVisibleWithoutLogin`, the pill still never appeared on a
    /// physically locked Mac. The modern lock screen is not a window to
    /// out-level — it is a whole compositor space at absolute level 300,
    /// drawn over every window of the spaces beneath it whatever their level.
    /// The only way over it is a space of one's own, one level higher, which
    /// is what boring.notch and mew-notch both ship: `SLSSpaceCreate`, set to
    /// absolute level 400, and the panel's window moved into it for the
    /// duration of the lock. Private SPI, knowingly adopted on the user's
    /// explicit call after the public route failed the physical test.
    ///
    /// Coming back matters as much as going up: the window is removed from
    /// the custom space and re-ordered, which rebinds it to the active space;
    /// the space itself is hidden and destroyed so nothing leaks across
    /// lock cycles.
    /// Takes a window that is going away out of the space, without ordering
    /// anything. A panel rebuilt during a lock (a display plugged in with the
    /// shield up) is thrown away while still lifted. Left in the space, it
    /// would keep the space alive after the unlock, now that the space lives
    /// until its last window leaves.
    func release(_ panel: NSPanel?) {
        guard let panel else { return }
        SkyLight.shared?.lower(windowNumber: panel.windowNumber)
    }

    func apply(to panel: NSPanel?, locked: Bool) {
        guard let panel else { return }
        if locked {
            panel.canBecomeVisibleWithoutLogin = true
            SkyLight.shared?.lift(windowNumber: panel.windowNumber)
        } else {
            SkyLight.shared?.lower(windowNumber: panel.windowNumber)
            panel.level = NotchPanel.normalLevel
            panel.canBecomeVisibleWithoutLogin = false
        }
        panel.orderFrontRegardless()
    }
}

/// The four SkyLight calls, resolved at runtime.
///
/// dlopen/dlsym rather than linking: the framework is private, its symbols
/// carry no headers, and resolving by name means a macOS release that
/// removes one degrades to the public behavior (pill hidden while locked)
/// instead of failing to launch.
@MainActor
final class SkyLight {
    /// The lock screen's own space sits at absolute level 300
    /// (kCGSSpaceAbsoluteLevelScreenLock); 400 is the notification-center-
    /// at-lock level the shipping notch apps use — above the shield, below
    /// nothing that matters.
    private static let aboveShield: Int32 = 400

    static let shared = SkyLight()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias HideSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias SpaceAddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias RemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void

    /// The calls, as plain Swift functions of the space and window ids, so a
    /// test can stand in for SkyLight and watch what is asked of it.
    struct Calls {
        var create: () -> UInt64
        var destroy: (UInt64) -> Void
        var setLevel: (UInt64, Int32) -> Void
        var show: (UInt64) -> Void
        var hide: (UInt64) -> Void
        var add: (UInt64, Int) -> Void
        var remove: (UInt64, Int) -> Void
    }

    private let calls: Calls
    private var space: UInt64 = 0
    /// Every window currently in the space. The notch panel and the lock card
    /// share one space, and the space used to be destroyed by whichever window
    /// was lowered first. On unlock that is the card, so the panel's own
    /// `lower` then found no space and never removed the panel from the one
    /// just destroyed; only the re-order after it put the panel back. Now the
    /// space goes when its last window leaves.
    private(set) var windows: Set<Int> = []

    private convenience init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW
        ) else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: type)
        }

        guard
            let main = symbol("SLSMainConnectionID", as: MainConnectionID.self),
            let create = symbol("SLSSpaceCreate", as: SpaceCreate.self),
            let destroy = symbol("SLSSpaceDestroy", as: SpaceDestroy.self),
            let level = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
            let show = symbol("SLSShowSpaces", as: ShowSpaces.self),
            let hide = symbol("SLSHideSpaces", as: HideSpaces.self),
            let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindows.self),
            let remove = symbol("SLSRemoveWindowsFromSpaces", as: RemoveWindowsFromSpaces.self)
        else { return nil }

        let connection = main()
        self.init(calls: Calls(
            create: { create(connection, 1, 0) },
            destroy: { destroy(connection, $0) },
            setLevel: { level(connection, $0, $1) },
            show: { show(connection, [$0] as CFArray) },
            hide: { hide(connection, [$0] as CFArray) },
            add: { add(connection, $0, [$1] as CFArray, 7) },
            remove: { remove(connection, [$1] as CFArray, [$0] as CFArray) }
        ))
    }

    init(calls: Calls) {
        self.calls = calls
    }

    func lift(windowNumber: Int) {
        if space == 0 {
            space = calls.create()
            guard space != 0 else { return }
            calls.setLevel(space, Self.aboveShield)
        }
        calls.show(space)
        calls.add(space, windowNumber)
        windows.insert(windowNumber)
    }

    func lower(windowNumber: Int) {
        guard space != 0, windows.contains(windowNumber) else { return }
        calls.remove(space, windowNumber)
        windows.remove(windowNumber)
        guard windows.isEmpty else { return }
        calls.hide(space)
        calls.destroy(space)
        space = 0
    }
}
