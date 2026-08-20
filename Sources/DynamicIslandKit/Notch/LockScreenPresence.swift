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
/// Presentation takes the public route: while locked the panel is raised past
/// `CGShieldingWindowLevel()` and marked `canBecomeVisibleWithoutLogin` — the
/// documented permission bit for drawing over loginwindow, the one whose
/// absence macOS logs as "trying to draw over login window without
/// permission" — then fronted again. Honesty about the precedent: both of
/// those apps went further, into the private SkyLight SPI (`SLSSpaceCreate`,
/// `SLSSpaceSetAbsoluteLevel(400)`, `SLSSpaceAddWindowsAndRemoveFromSpaces`),
/// because the modern lock screen is not a window to out-level but a whole
/// space at absolute level 300, drawn over every window of the spaces below
/// it whatever their level. If the physical lock test shows the public route
/// losing to that, the SPI is the known fallback, and this type is the one
/// place it would land.
@MainActor
final class LockScreenPresence {
    static let lockNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// Where the panel sits while the shield is up. Pure, so the arithmetic
    /// is testable without a window: one past the shield, and never below
    /// where the panel normally lives — a shield reported at some absurd low
    /// value must not become an instruction to sink the panel.
    static func lockedLevel(base: Int, shield: Int) -> Int {
        max(base, shield + 1)
    }

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

    /// Raises the panel past the shield, or puts it back exactly where
    /// `NotchPanel` normally keeps it. Fronting is re-asserted both ways: at
    /// lock because the panel has just been handed a new level in a new
    /// ordering, at unlock for the same reason a space change re-fronts it —
    /// the transition can leave it behind.
    func apply(to panel: NSPanel?, locked: Bool) {
        guard let panel else { return }
        if locked {
            panel.canBecomeVisibleWithoutLogin = true
            panel.level = NSWindow.Level(rawValue: Self.lockedLevel(
                base: NotchPanel.normalLevel.rawValue,
                shield: Int(CGShieldingWindowLevel())
            ))
        } else {
            panel.level = NotchPanel.normalLevel
            panel.canBecomeVisibleWithoutLogin = false
        }
        panel.orderFrontRegardless()
    }
}
