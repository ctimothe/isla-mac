import AppKit

/// The one voice Isla has for assistive technology.
///
/// Everything the island says to a sighted person it says by appearing: a peek
/// for a new track, a charger or headphones moment, a new title on the lock
/// card, a shake when the locked island refuses to open. Each of those is gone
/// in about two seconds, and none of them used to reach VoiceOver at all — a
/// blind user plugged in a charger, skipped a song over the shield or clicked
/// the locked pill, and heard nothing (F-013). This posts the same moments as
/// `announcementRequested`, which VoiceOver speaks without moving its cursor.
///
/// One helper rather than a post in each view, because the rule that matters
/// is shared: the same sentence twice inside a second is one event arriving by
/// two routes, not two events. The locked refusal is the case that needs it —
/// a click on the pill and the AX action, or ⌃⌥⌘I pressed twice, would
/// otherwise be heard twice back to back. A *different* sentence is news and
/// always passes, and the same one a second later is a second event and is
/// spoken again.
///
/// It does not ask whether VoiceOver is running. Other assistive clients —
/// Switch Control, braille displays, third-party readers — consume the same
/// announcements, and the post is cheap enough that skipping it saves nothing.
@MainActor
final class Announcer {
    static let shared = Announcer()

    /// How long the same sentence is held back after it was last spoken.
    static let repeatWindow: TimeInterval = 1.0

    /// Where an announcement goes. The real one posts to the accessibility
    /// system; tests put a recorder here.
    ///
    /// Never posts from a test process. The suite runs on the owner's own Mac,
    /// often with VoiceOver on, and a test nudging a locked island would speak
    /// "Unlock your Mac" into whatever they were doing.
    var sink: (String) -> Void = { text in
        guard !PlayerBridge.isRunningTests, let app = NSApp else { return }
        // Against the application, not the panel: the app is `.accessory` and
        // its panel never becomes key, so there is no focused window to speak
        // for. High priority, because each of these moments is gone from the
        // screen in about two seconds and queued speech would describe
        // something that has already left.
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// A monotonic clock, so a wall-clock change cannot unmute or mute a
    /// sentence. Injected by tests.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var last: (text: String, at: TimeInterval)?

    func announce(_ text: String) {
        // An empty label — a peek for a track with no title yet — would be
        // VoiceOver interrupting itself to say nothing.
        guard !text.isEmpty else { return }
        let time = now()
        if let last, last.text == text, time - last.at < Self.repeatWindow { return }
        // Only what was spoken moves the window. A refused duplicate leaves it
        // where it was, so a stream of repeats cannot keep a real second
        // event silent forever.
        last = (text, time)
        sink(text)
    }

    /// Drops the memory of the last sentence, so a test starts from silence.
    func forget() {
        last = nil
    }
}
