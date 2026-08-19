import Foundation

/// Keeps transport taps deterministic while the player is still reporting the
/// state from before the last command.
struct PlaybackIntent {
    private struct InFlight {
        let target: Bool
        let sentAt: Date
    }

    private static let confirmationTimeout: TimeInterval = 1.5

    private(set) var desired: Bool
    private var inFlight: InFlight?

    init(reported: Bool) {
        desired = reported
    }

    var hasInFlightCommand: Bool { inFlight != nil }

    /// Returns the state that must be sent now. While one command is in
    /// flight, further taps update the visible intent but are coalesced until
    /// the player confirms the first transition.
    mutating func toggle(at now: Date) -> Bool? {
        desired.toggle()
        guard inFlight == nil else { return nil }
        inFlight = InFlight(target: desired, sentAt: now)
        return desired
    }

    /// Accepts a player report and returns a queued target that is now safe to
    /// send. Reports contradicting an in-flight command are stale until the
    /// command is confirmed or times out.
    mutating func reconcile(reported: Bool, at now: Date) -> Bool? {
        guard let inFlight else {
            desired = reported
            return nil
        }

        if reported == inFlight.target {
            self.inFlight = nil
            guard desired != reported else { return nil }
            self.inFlight = InFlight(target: desired, sentAt: now)
            return desired
        }

        if now.timeIntervalSince(inFlight.sentAt) >= Self.confirmationTimeout {
            self.inFlight = nil
            desired = reported
        }
        return nil
    }
}
