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
