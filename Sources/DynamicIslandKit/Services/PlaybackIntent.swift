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
    /// Whether a tap arrived while a command was in flight and so was never
    /// sent. Distinct from `desired != reported`, which is also true of a
    /// single tap the player simply has not confirmed yet — that one has been
    /// sent and deserves no second attempt.
    private var hasQueuedTap = false
    /// Whether a queued tap has already been given its one retry.
    private var hasResent = false

    init(reported: Bool) {
        desired = reported
    }

    var hasInFlightCommand: Bool { inFlight != nil }

    /// Returns the state that must be sent now. While one command is in
    /// flight, further taps update the visible intent but are coalesced until
    /// the player confirms the first transition.
    mutating func toggle(at now: Date) -> Bool? {
        desired.toggle()
        guard inFlight == nil else {
            hasQueuedTap = true
            return nil
        }
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
            hasResent = false
            hasQueuedTap = false
            guard desired != reported else { return nil }
            self.inFlight = InFlight(target: desired, sentAt: now)
            return desired
        }

        if now.timeIntervalSince(inFlight.sentAt) >= Self.confirmationTimeout {
            self.inFlight = nil
            guard hasQueuedTap, !hasResent else {
                hasQueuedTap = false
                hasResent = false
                desired = reported
                return nil
            }
            hasQueuedTap = false
            // A tap was coalesced behind this command and the command was
            // never confirmed, so that tap has been sitting unsent while the
            // player carried on doing the opposite of what was last asked of
            // it. Adopting the reported state here silently threw the tap
            // away — press pause on a slow player and the music kept playing.
            // Sent once more instead; a second failure gives up, so a player
            // that never answers cannot be retried forever.
            hasResent = true
            self.inFlight = InFlight(target: desired, sentAt: now)
            return desired
        }
        return nil
    }
}
