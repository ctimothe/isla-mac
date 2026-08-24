import AppKit
import SwiftUI

/// The app's window, and the Dock icon that comes and goes with it.
///
/// Dynamic Island is an accessory: it lives at the notch and has no business in
/// the Dock while it is only doing that. But a window with no Dock icon is a
/// window you cannot get back to once something covers it, and there is no
/// icon to click and no app to switch to. So the policy follows the window —
/// `.regular` while it is open, `.accessory` the moment it closes — and the
/// Dock icon and the menu bar arrive and leave with the thing they belong to.
///
/// `LSUIElement` in the bundle sets only the *initial* policy; changing it at
/// runtime is supported and is what this does.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    /// What the window can ask the rest of the app to do. Injected rather than
    /// reached for, so the window can be built and tested without a controller,
    /// a panel, or a notch.
    struct Actions {
        var togglePanel: () -> Void = {}
        var privacy: () -> PrivacyMode? = { nil }
    }

    var actions = Actions()

    private var window: NSWindow?

    /// Pure, so the rule can be tested without a window on screen.
    static func policy(windowOpen: Bool) -> NSApplication.ActivationPolicy {
        windowOpen ? .regular : .accessory
    }

    var isPresented: Bool { window?.isVisible ?? false }

    func present() {
        let window = window ?? makeWindow()
        self.window = window
        // Before ordering front: becoming `.regular` is what gives the app a
        // Dock icon and a menu bar to be activated into.
        NSApp.setActivationPolicy(Self.policy(windowOpen: true))
        window.makeKeyAndOrderFront(nil)
        // The macOS 14 form. `activate(ignoringOtherApps:)` is deprecated, and
        // this app has spent its whole life avoiding activation — this is the
        // one moment it is correct.
        NSApp.activate()
    }

    func dismiss() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ProductIdentity.displayName
        window.contentMinSize = NSSize(width: 720, height: 480)
        // The window is closed and reopened rather than rebuilt, so it must
        // survive its own close. Released on close it would be a dangling
        // pointer the second time the status item was clicked.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: MainWindowView(
                togglePanel: { [weak self] in self?.actions.togglePanel() },
                privacy: actions.privacy()
            )
        )
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to an accessory. Leaving the app `.regular` with nothing on
        // screen strands a Dock icon for an app that has no window to show.
        NSApp.setActivationPolicy(Self.policy(windowOpen: false))
    }

    #if DEBUG
    /// Test seam: identity only, so a test can prove the window is reused
    /// rather than rebuilt on every press of the status item.
    var windowForTesting: NSWindow? { window }

    func presentForTesting() {
        let window = window ?? makeWindow()
        self.window = window
    }
    #endif
}
