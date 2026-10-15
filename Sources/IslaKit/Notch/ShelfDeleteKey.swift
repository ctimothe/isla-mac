import AppKit
import Carbon.HIToolbox

/// The Shelf's Delete and ⌘⌫, held system-wide for exactly as long as
/// `NotchViewModel.claimsDelete` says and not one moment longer (spec §8.2).
///
/// Two Carbon hot keys, because there are two keys: plain Delete, which is
/// what a Shelf selection is removed with, and ⌘⌫, Finder's own spelling of
/// "get rid of this". Neither needs a permission and neither sees any other key
/// that is typed, which is why the pinned panel's Escape (`NotchController
/// .updateEscapeHotKey`) is made the same way.
///
/// This object is the *only* place that registers or gives them up, and it is
/// built so the worst thing it could do — leave Delete registered, eating the
/// person's Delete in every app — has one shape and one guard:
/// - `update(wanted:)` is the whole API, **idempotent in both directions**:
///   asking again for what is already so does nothing, so a burst of
///   notifications cannot register twice (the second registration would be
///   orphaned, unreachable, and live until the process ended);
/// - the registrations are held as one group, so "registered" is a single
///   fact and a partial failure cannot leave half of a pair behind unnoticed;
/// - `teardown()` is `update(wanted: false)` and is called by every road out —
///   the panel closing, the lock, the tab changing, a rebuild, quit.
///
/// The registrar is a seam. A real `GlobalHotKey` reserves the combination for
/// the login session, so a test that made one would take the developer's Delete
/// key away until the test runner exited; tests hand in a fake that records.
@MainActor
final class ShelfDeleteKeyHolder {
    typealias Registrar = @MainActor (HotKeyBinding, @escaping () -> Void) -> HotKeyRegistration?

    /// What is registered: Delete, and ⌘⌫.
    static let bindings: [HotKeyBinding] = [
        HotKeyBinding(keyCode: UInt32(kVK_Delete), modifiers: 0),
        HotKeyBinding(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey)),
    ]

    static let realRegistrar: Registrar = { binding, action in
        GlobalHotKey(keyCode: binding.keyCode, modifiers: binding.modifiers, action: action)
    }

    private let registrar: Registrar
    private let onPress: () -> Void
    private var registrations: [HotKeyRegistration] = []

    /// - Parameter onPress: what a press does. The owner re-asks the claim
    ///   before acting (the press can be queued behind the event that ended it).
    init(registrar: Registrar? = nil, onPress: @escaping () -> Void) {
        self.registrar = registrar ?? Self.realRegistrar
        self.onPress = onPress
    }

    /// Whether the keys are held right now.
    var isRegistered: Bool { !registrations.isEmpty }

    /// Holds the keys or lets them go.
    func update(wanted: Bool) {
        if wanted {
            guard registrations.isEmpty else { return }
            for binding in Self.bindings {
                if let registration = registrar(binding, { [weak self] in self?.onPress() }) {
                    registrations.append(registration)
                } else {
                    // A combination macOS refuses leaves the Shelf as it was
                    // before the keys existed: the button and the menu still
                    // remove. Said in the log rather than pretended away.
                    Log.app.error("macOS refused the transient Shelf key \(binding.displayString, privacy: .public)")
                }
            }
        } else {
            registrations.forEach { $0.unregister() }
            registrations.removeAll()
        }
    }

    func teardown() { update(wanted: false) }
}

extension NotchPanel {
    /// Whether a key press is the Shelf's remove key — Delete, or ⌘⌫ — for a
    /// panel that happens to be key. A press with ⌥, ⌃ or ⇧ is not: ⌥⌫ deletes a
    /// word in a text field and nobody means it to empty a shelf.
    static func isRemoveKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard Int(keyCode) == kVK_Delete else { return false }
        let relevant = flags.intersection([.command, .control, .option, .shift])
        return relevant.isEmpty || relevant == .command
    }
}

// MARK: - Where the pointer counts as "on the Shelf"

extension ShelfLayout {
    /// The Shelf pane in screen coordinates, from the open body's rect in the
    /// same: everything right of the rail, below the header and above the
    /// body's padding — the grid, the bar and the wells, and not the header
    /// row, so a pointer heading for Expand has already let go of Delete.
    static func pointerZone(bodyScreenRect body: CGRect, headerHeight: CGFloat) -> CGRect {
        CGRect(
            x: body.minX + PlayerLayout.paneLeading,
            y: body.minY + NotchGeometry.bodyBottomPadding,
            width: max(0, body.width - PlayerLayout.paneLeading - PlayerLayout.paneTrailing),
            height: max(0, body.height - headerHeight - NotchGeometry.bodyBottomPadding)
        )
    }
}
