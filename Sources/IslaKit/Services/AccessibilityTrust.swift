import ApplicationServices
import Foundation

/// Whether the person has granted Isla the Accessibility permission — the one
/// thing a session event tap needs to see the media keys (redesign 2026-10-15,
/// spec §12; the parity design's "one opt-in Accessibility use").
///
/// A seam, so a test never reaches `AXIsProcessTrustedWithOptions`: the real
/// call with the prompt option puts a system dialog on the owner's screen.
@MainActor
protocol AccessibilityTrust {
    func isTrusted() -> Bool
    /// Asks macOS to show its permission prompt. Called once, from the moment
    /// the person turns the setting on — never from a poll, never at launch.
    func requestPrompt()
}

struct SystemAccessibilityTrust: AccessibilityTrust {
    /// Where "Open Privacy & Security…" goes.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    func isTrusted() -> Bool {
        // The plain call, which never prompts: it is what the 2 s poll and
        // every key press ask.
        AXIsProcessTrusted()
    }

    func requestPrompt() {
        // Never from a test process: the suite runs on the owner's Mac, and
        // this call is a system dialog.
        guard !PlayerBridge.isRunningTests else { return }
        // The option's value is the constant `kAXTrustedCheckOptionPrompt`,
        // spelled out because the imported global is a mutable `Unmanaged`
        // that strict concurrency refuses to read from here.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// The system's announcement that the Accessibility trust list changed (a grant,
/// a removal, a switch flipped in System Settings). A seam, so a test posts a
/// fake of its own: the real notification is the whole machine's, and a test
/// must never post it into the owner's other apps.
///
/// It exists because the permission is granted in another app and nothing else
/// tells Isla. Waiting for the two-second poll alone made turning Volume and
/// Brightness on feel broken: the owner granted the permission, the keys kept
/// showing the Mac's own pop-up for up to two more seconds, and a tap made in the
/// moment right after the grant could fail (tccd lags the notification), so the
/// first press after "it worked" still went to macOS.
@MainActor
protocol AccessibilityGrantNotifying {
    /// Calls `handler` on the main actor each time the trust list changes, until
    /// the returned closure is called.
    func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> () -> Void
}

struct SystemAccessibilityGrantNotifier: AccessibilityGrantNotifying {
    /// What the system posts to the distributed centre when the list changes.
    static let name = Notification.Name("com.apple.accessibility.api")

    func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: Self.name, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return { DistributedNotificationCenter.default().removeObserver(token) }
    }
}
