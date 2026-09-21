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
///
/// A hold that never ends is worse than none: the panel would never fold, and
/// its whole window would keep catching clicks. So a menu counts as open only
/// while the main run loop is actually tracking — AppKit runs a menu in
/// `.eventTracking` — and menus are counted by identity, so an opening whose
/// closing notice was lost cannot hold anything once tracking is over.
@MainActor
final class MenuTracking {
    static let shared = MenuTracking()

    private var open: Set<ObjectIdentifier> = []

    /// Menus that said they opened and have not said they closed.
    var hasOpenMenus: Bool { !open.isEmpty }

    /// Whether a menu is open *now*: counted open, and the run loop tracking.
    /// Read from the pointer sampler's tick, which runs in the common modes and
    /// so sees `.eventTracking` exactly while a menu has the run loop.
    var isOpen: Bool {
        hasOpenMenus && RunLoop.main.currentMode == .eventTracking
    }

    /// Called once the last open menu has closed.
    var onAllClosed: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.began(id) }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.ended(id) }
        })
    }

    func began(_ menu: ObjectIdentifier?) {
        guard let menu else { return }
        open.insert(menu)
    }

    /// A close for a menu never seen opening — one that opened before this
    /// started listening — changes nothing.
    func ended(_ menu: ObjectIdentifier?) {
        guard let menu, open.remove(menu) != nil else { return }
        if open.isEmpty { onAllClosed?() }
    }

    /// Forgets every open menu. Called when the panel folds: whatever was
    /// counted open belonged to a panel that is gone.
    func reset() {
        open.removeAll()
    }
}
