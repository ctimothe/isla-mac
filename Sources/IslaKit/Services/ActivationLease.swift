import AppKit

/// Borrowing activation for a window the user has to work in, and giving it
/// back when that window closes.
///
/// Isla never activates on its own: the panel is non-activating so the app
/// being typed in keeps the keyboard. A window Isla opens for the user —
/// Quick Look, the AirDrop sheet, About — is the exception, because an app
/// that is not active gets its windows behind the one in front: About was
/// ordered front without activation and could open behind whatever app the
/// user was in (F-048). So the window's owner activates Isla for it, and
/// hands activation back to the app that had it once the window closes. Left
/// active, Isla held the keyboard with no window to type in, and the
/// document the user had been writing in stopped answering until it was
/// clicked.
///
/// Lifted out of `ShelfSharing`, which solved this first for Quick Look and
/// AirDrop; the behaviour is unchanged. The frontmost app and the two
/// activations are closures so a test can drive a lease without activating
/// anything real.
@MainActor
final class ActivationLease {
    private let ownPID: pid_t
    private let frontmostPID: () -> pid_t?
    private let activateSelf: () -> Void
    private let activate: (pid_t) -> Void
    private var returnTo: pid_t?

    init(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        activateSelf: @escaping () -> Void = { NSApp.activate() },
        activate: @escaping (pid_t) -> Void = { NSRunningApplication(processIdentifier: $0)?.activate() }
    ) {
        self.ownPID = ownPID
        self.frontmostPID = frontmostPID
        self.activateSelf = activateSelf
        self.activate = activate
    }

    /// Remembers the app in front, unless that is Isla itself, and activates
    /// Isla. A lease begun while Isla is already in front keeps whatever it
    /// remembered before, as `ShelfSharing` always did: a second Quick Look
    /// over the first must not forget where the keyboard came from.
    func begin() {
        let front = frontmostPID()
        if front != ownPID { returnTo = front }
        activateSelf()
    }

    /// Hands activation back to the remembered app, once, and only if Isla is
    /// still the one in front. A user who clicked into a third app meanwhile
    /// has already chosen where the keyboard goes.
    func end() {
        guard let app = returnTo else { return }
        returnTo = nil
        guard frontmostPID() == ownPID else { return }
        activate(app)
    }
}
