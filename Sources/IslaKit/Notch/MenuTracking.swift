import AppKit

/// Whether one of the app's menus is open.
///
/// A menu is a window of its own, and a long one hangs past the panel's
/// bottom edge — the Translate tab's language lists do, sixteen rows deep. The
/// pointer rule reads the cursor leaving the panel as the person leaving it, so
/// moving down such a list used to fold the panel away mid-choice, taking the
/// menu's owner with it. While a menu tracks, the panel is held exactly the way
/// a drag holds it (`PointerWatcher.isDragging`), and when the last one closes
/// the pointer gets a moment to come back from wherever the chosen row was.
@MainActor
final class MenuTracking {
    static let shared = MenuTracking()

    private(set) var openMenus = 0
    var isOpen: Bool { openMenus > 0 }

    /// Called once the last open menu has closed.
    var onAllClosed: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.began() }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        })
    }

    func began() {
        openMenus += 1
    }

    /// Never below zero: an end with no begin — a menu that opened before this
    /// started listening — must not leave the count owing one forever.
    func ended() {
        guard openMenus > 0 else { return }
        openMenus -= 1
        if openMenus == 0 { onAllClosed?() }
    }
}
