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

    /// The login item Settings shows: the app's own, or a test's stand-in.
    @MainActor static var serviceOverride: LoginItemService?
    @MainActor static var service: LoginItemService { serviceOverride ?? SMAppService.mainApp }

    /// What the last read or flip found.
    ///
    /// `status` is a round trip to the login-items daemon — 2.5 ms median and
    /// up to 9 ms on a busy Mac, with the caller waiting (2026-10-29) — and
    /// Settings asked it twice on the main thread every time it opened, in a
    /// `@State` initial value and again on appear: 5 to 18 ms of waiting at
    /// the start of a swap, against a 8.3 ms frame. A pane now begins from
    /// this, and `refresh` asks again off the main thread as it appears
    /// (`LaunchAtLoginReadTests`).
    @MainActor private static var remembered: State?
    /// Moves on every flip, so a read that set off before one is dropped.
    @MainActor private static var generation = 0

    /// The state to draw now: what was last found, or — once a launch, the
    /// first time Settings is drawn — a read made here.
    @MainActor static func lastKnown() -> State {
        if let remembered { return remembered }
        let fresh = read(service)
        remembered = fresh
        return fresh
    }

    /// Reads the status off the main thread and hands it to `deliver` on it,
    /// unless the switch was flipped meanwhile: that read began before the
    /// flip and would put the switch back where it was.
    @MainActor static func refresh(then deliver: @escaping @MainActor (State) -> Void) {
        let service = self.service
        let asked = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = read(service)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard asked == generation else { return }
                    remembered = fresh
                    deliver(fresh)
                }
            }
        }
    }

    /// The switch flipped: asks macOS and remembers where it left it. On the
    /// main thread, as the press that asked for it is.
    @MainActor static func apply(_ wants: Bool) -> State {
        generation += 1
        let state = set(wants, service: service)
        remembered = state
        return state
    }

    @MainActor static func forgetForTests() {
        remembered = nil
        generation += 1
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
