import AppKit
import CoreServices

/// Where macOS stands on Isla scripting one player.
enum AutomationConsent: Equatable {
    /// macOS lets the events through.
    case allowed
    /// The user refused, in the prompt or in System Settings. Asking again
    /// only earns another -1743, so nothing in the background asks.
    case denied
    /// Never asked. The first event raises the system prompt.
    case notAsked
    /// Not known yet: nothing has been asked, and the read-only check has not
    /// answered or could not (the player is not running).
    case unknown
}

/// What Isla knows about its Automation consent for Music and Spotify.
///
/// It exists so the background can tell "allowed" from "would prompt". Isla
/// launches at login with Spotify playing and the panel closed, and the
/// "Isla wants to control Spotify" dialog used to appear right then, with
/// nothing on screen to say what Isla was or why it asked: the heart's
/// track-id lookup, the fallback's state read and the search under a film
/// all sent their first Apple Event whenever they liked. An ad-hoc build
/// resets the grant on every update, so the unprompted dialog came back
/// after each one. `MediaController.mayScript` reads this: an allowed player
/// is scripted as before, and one that would prompt is asked only once the
/// panel is open on it.
///
/// Two sources, and neither of them ever prompts:
/// - `refresh()`, at launch and on every panel open, asks macOS with
///   `AEDeterminePermissionToAutomateTarget` and `askUserIfNeeded: false`.
///   That call blocks while it runs, so it runs on a utility queue, never on
///   the main thread.
/// - `learn(_:outcome:)`, from every script `PlayerBridge` runs: an answer
///   of any kind means the event got through, and -1743 means it was refused.
///
/// Nothing is stored. TCC resets on every ad-hoc build, and a remembered
/// "already asked" would be wrong after the very update that makes it matter.
@MainActor
final class AutomationAccess: ObservableObject {
    static let shared = AutomationAccess()

    /// Per player. Absent means `.unknown`. Published so a surface can show
    /// the state and so the media clock can act the moment it changes.
    @Published private(set) var consents: [PlayerApp: AutomationConsent] = [:]

    init() {}

    func status(_ app: PlayerApp) -> AutomationConsent {
        consents[app] ?? .unknown
    }

    /// Takes an Apple Event's outcome as the latest word on consent. An
    /// outcome that says nothing about consent — the player quit, a timeout —
    /// leaves what was known.
    func learn(_ app: PlayerApp, outcome: OSStatus) {
        let consent = Self.consent(for: outcome)
        guard consent != .unknown, consents[app] != consent else { return }
        consents[app] = consent
    }

    /// Asks macOS, without prompting, where each running player stands.
    /// Skipped inside a test process, which must never reach a real player.
    func refresh() {
        guard !PlayerBridge.isRunningTests else { return }
        for app in PlayerApp.allCases where app.isRunning {
            let bundleID = app.bundleID
            Self.queue.async {
                let outcome = Self.determine(bundleID: bundleID)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.learn(app, outcome: outcome) }
                }
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.ctimothe.isla.automation-access", qos: .utility)

    /// errAEEventNotPermitted: the user refused, in the prompt or in
    /// System Settings.
    static let refused: OSStatus = -1743
    /// errAEEventWouldRequireUserConsent: only the read-only check answers
    /// this. It is "never asked", not a refusal — read as one, the first panel
    /// open would never raise the prompt at all.
    static let wouldPrompt: OSStatus = -1744
    /// errAENoSuchObject: the script asked for a current track the player does
    /// not have. The player answered, so the event got through.
    private static let noSuchObject: OSStatus = -1728

    /// What one outcome says about consent. Only answers that could have come
    /// from the player itself count as "allowed"; procNotFound, a timeout or a
    /// script that did not compile say nothing either way.
    nonisolated static func consent(for outcome: OSStatus) -> AutomationConsent {
        switch outcome {
        case OSStatus(noErr), noSuchObject: return .allowed
        case refused: return .denied
        case wouldPrompt: return .notAsked
        default: return .unknown
        }
    }

    /// The read-only check. Blocks; never on the main thread.
    nonisolated private static func determine(bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
    }
}
