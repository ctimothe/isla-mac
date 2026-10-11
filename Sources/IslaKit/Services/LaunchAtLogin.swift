import Foundation
import ServiceManagement

/// The part of `SMAppService` that Launch at Login uses, so a test can stand
/// in for the real login item instead of registering the app it runs in.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// What the Launch at Login switch shows, read from what macOS decided.
///
/// The switch used to log any error and re-read `status == .enabled`. On a
/// fresh account macOS answers a registration with `.requiresApproval` — the
/// item is listed in Login Items and waits for the user to allow it — and
/// that read as off, so the switch snapped back with no words; any other
/// failure was just as silent (F-027). The status is the truth and the error
/// only explains it, so the mapping looks at the status first.
enum LaunchAtLogin {
    enum State: Equatable {
        case on
        case off
        /// Registered, waiting for the user to allow it in Login Items.
        case needsApproval
        /// Not registered, with macOS's own reason.
        case failed(String)

        /// Pending approval is on: the registration stands, and turning the
        /// switch off is how the user withdraws it.
        var isOn: Bool {
            switch self {
            case .on, .needsApproval: return true
            case .off, .failed: return false
            }
        }

        /// Only the pending case has somewhere to send the user. A failure
        /// is not something Login Items can fix.
        var offersLoginItems: Bool { self == .needsApproval }
    }

    /// `.enabled` with an error is still on: a register that complains the
    /// item is already registered changed nothing, and showing off would
    /// lie about what happens at the next login. An unregister that fails
    /// leaves the item enabled, so the switch staying on is also the truth;
    /// the log keeps the reason.
    static func state(status: SMAppService.Status, error: Error?) -> State {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: break
        @unknown default: break
        }
        if let error { return .failed(error.localizedDescription) }
        return .off
    }

    static func read(_ service: LoginItemService = SMAppService.mainApp) -> State {
        state(status: service.status, error: nil)
    }

    /// Asks for `wants` and reports where macOS left it.
    static func set(_ wants: Bool, service: LoginItemService = SMAppService.mainApp) -> State {
        var failure: Error?
        do {
            if wants {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failure = error
            Log.app.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        // Only a failed turn-on is news. A turn-off that throws either left
        // the item enabled, which the switch shows by staying on, or left it
        // unregistered, which is what was asked; "Launch at Login failed"
        // under a switch that did go off would be the wrong story.
        return state(status: service.status, error: wants ? failure : nil)
    }

    /// The line under the switch, when there is something to say.
    static func note(_ state: State) -> String? {
        switch state {
        case .on, .off: return nil
        case .needsApproval: return localized("Needs your approval in Login Items.")
        case let .failed(reason): return localized("Launch at Login failed: %@", reason)
        }
    }
}
