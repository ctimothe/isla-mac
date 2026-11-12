import Foundation

/// Keeps transport taps deterministic while the player is still reporting the
/// state from before the last command.
struct PlaybackIntent {
    private struct InFlight {
        let target: Bool
        let sentAt: Date
    }

    /// How long a command may go unconfirmed before the reported state is
    /// believed over it. Settable so a test need not wait it out, the way
    /// `MediaController.trackChangeGrace` is; written by tests alone, on the
    /// main thread, which is also the only place it is read.
    nonisolated(unsafe) static var confirmationTimeout: TimeInterval = 1.5

    private(set) var desired: Bool
    /// What the player last said. `settleUnconfirmed` judges a command against
    /// it on a route where nothing says it again.
    private var lastReported: Bool
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
        lastReported = reported
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
        lastReported = reported
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

    /// Ends a command no report came for, on a route where none may ever.
    ///
    /// Every timeout above is judged when a report arrives, and the helper
    /// sends one every few seconds whatever happens. A song held under a
    /// film is another matter: MediaRemote describes only the film, so the
    /// song is reported when its player announces a change, if it is a
    /// player that announces at all. A command that changed nothing is
    /// announced by nobody — refused consent, a player that did not answer,
    /// a pause sent to a player already paused — and a held Tidal is never
    /// reported, whatever it did. The command then stayed in flight for
    /// good, and every later tap was coalesced behind it and never sent:
    /// the icon went on flipping over a player that had stopped listening.
    ///
    /// `took` is the caller's best knowledge. True where the command was
    /// delivered and nobody can say otherwise: it counts as confirmed. False
    /// where the player could have been heard and was not: the command is
    /// judged against what the player last said, exactly as its next report
    /// would have judged it, so a queued tap gets its one resend and the
    /// icon otherwise goes back to the last thing known. Returns a queued
    /// target that must be sent now, like `reconcile`.
    mutating func settleUnconfirmed(at now: Date, took: Bool) -> Bool? {
        guard let inFlight else { return nil }
        return reconcile(reported: took ? inFlight.target : lastReported, at: now)
    }
}
