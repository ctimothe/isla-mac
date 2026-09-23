import AppIntents
import AppKit

/// What Isla offers the rest of the system.
///
/// The app has no Dock icon, no menu-bar item and no window, which makes it
/// unusually dependent on the routes macOS provides rather than the ones an app
/// draws for itself. Shortcuts is the deepest of those: it puts the panel's own
/// verbs — open the words, tell me what is playing, move the lyrics in time —
/// into Spotlight, the Shortcuts app, a Stream Deck, a Focus automation, or a
/// shortcut bound to a key.
///
/// It costs nothing to claim. `AppIntents` needs no entitlement, asks for no
/// permission, and makes no network request; the metadata Shortcuts reads is
/// generated at bundle time from these very declarations — see
/// `Scripts/bundle.sh`. The one thing it does need is to be present in the
/// bundle *before* it is signed, which is why the step sits where it does.
///
/// Every intent here reaches the running app through `NSApp.delegate`, the same
/// route `SettingsPane` already uses. An intent invoked while the app is not
/// running launches it first — macOS has to have the process to run `perform()`
/// in — so the controller may be a moment behind; each intent says so plainly
/// rather than failing silently.

/// The one thing every intent needs: the live panel.
@MainActor
private func liveController() throws -> NotchController {
    guard let controller = (NSApp.delegate as? AppDelegate)?.controller else {
        throw IslaIntentError.notReady
    }
    return controller
}

@MainActor
private func liveModel() throws -> NotchViewModel {
    guard let model = try liveController().intentModel else { throw IslaIntentError.notReady }
    return model
}

enum IslaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case nothingPlaying

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "Isla is still starting up. Try again in a moment."
        case .nothingPlaying: return "Nothing is playing."
        }
    }
}

// MARK: - Opening

/// Straight to the words, from Spotlight or a key.
struct ShowLyricsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Lyrics"
    static var description = IntentDescription(
        "Opens Isla's panel with the lyrics page for whatever is playing."
    )
    /// False on purpose. The app is an accessory with no window and a policy
    /// that is set once and never changed; "opening" it means the panel
    /// unfolds at the notch, which is exactly what the intent does itself.
    /// Letting the system activate it instead would bring forward an app that
    /// has nothing to bring.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try liveController().toggleLyrics()
        return .result()
    }
}

/// The panel itself, the same as ⌃⌥⌘I.
struct ShowPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Isla"
    static var description = IntentDescription("Opens Isla's panel at the notch.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try liveController().toggle()
        return .result()
    }
}

// MARK: - Reading

/// The line being sung, as text.
///
/// The intent this whole surface exists for. A lyric on screen is worth one
/// glance; a lyric as a value is worth whatever the person builds with it —
/// a key that copies it, a Focus automation that posts it, a second display
/// that shows it.
struct CurrentLyricIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Lyric"
    static var description = IntentDescription(
        "Returns the lyric line playing right now, if Isla has words for the track."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try liveModel()
        guard case .synced(let lines) = model.lyrics.state, !lines.isEmpty else {
            return .result(value: "")
        }
        let at = LyricSweep.position(
            model.media.position,
            precisionSync: model.media.precisionSync,
            userOffset: model.lyrics.userOffset,
            trackOffset: model.lyrics.trackOffset
        )
        // `swept` false means the voice has not reached the first line yet, and
        // a line nobody has sung is not the line playing right now.
        guard let shown = LyricSweep.displayed(lines: lines, at: at), shown.swept else {
            return .result(value: "")
        }
        return .result(value: shown.line.text)
    }
}

/// What is playing, in the form a shortcut can use.
struct CurrentTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Track"
    static var description = IntentDescription("Returns the track and artist Isla is showing.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let track = try liveModel().media.track else { throw IslaIntentError.nothingPlaying }
        return .result(value: Self.describe(track))
    }

    /// Artist first is the order a person says it in, and the dash is the one
    /// the media pane already joins with. Static and pure so a test can hold it.
    static func describe(_ track: MediaController.Track) -> String {
        track.artist.isEmpty ? track.title : "\(track.artist) — \(track.title)"
    }
}

// MARK: - Timing

/// The correction a pair of AirPods asks for, as an automation.
///
/// Bluetooth audio arrives at the ear later than the Mac says it does, which
/// puts every lyric on screen early by a fixed amount. That is exactly the
/// shape of a thing Shortcuts is good at: when these headphones connect, set
/// the delay; when they disconnect, set it back. The slider in Settings is the
/// same value, so whichever one is used last wins and both agree afterwards.
struct SetLyricDelayIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Lyric Delay"
    static var description = IntentDescription(
        "Shifts every lyric in time. Negative shows lyrics earlier; positive, later."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Seconds", default: 0, inclusiveRange: (-3, 3))
    var seconds: Double

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        let model = try liveModel()
        model.lyrics.userOffset = seconds
        // The store clamps; the value returned is what was actually set, not
        // what was asked for, so a shortcut can see the difference.
        return .result(value: model.lyrics.userOffset)
    }
}

// MARK: - Transport

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Toggles playback of whatever Isla is showing.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try liveModel().media.togglePlayPause()
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Skips to the next track.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try liveModel().media.next()
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Goes back to the previous track.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try liveModel().media.previous()
        return .result()
    }
}

// MARK: - Phrases

/// What Spotlight and Siri will accept out loud, without the user building a
/// shortcut first.
///
/// Every phrase has to carry `\(.applicationName)` — the system requires the
/// app's name in the sentence so two apps cannot claim the same words. Kept
/// short: a phrase nobody would say is a phrase nobody will use.
struct IslaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowLyricsIntent(),
            phrases: [
                "Show lyrics in \(.applicationName)",
                "Open \(.applicationName) lyrics",
            ],
            shortTitle: "Show Lyrics",
            systemImageName: "quote.bubble"
        )
        AppShortcut(
            intent: CurrentLyricIntent(),
            phrases: [
                "What line is this in \(.applicationName)",
                "Current lyric in \(.applicationName)",
            ],
            shortTitle: "Current Lyric",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: CurrentTrackIntent(),
            phrases: [
                "What is playing in \(.applicationName)",
                "Current track in \(.applicationName)",
            ],
            shortTitle: "Current Track",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: ShowPanelIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Show Isla",
            systemImageName: "macbook"
        )
    }
}
