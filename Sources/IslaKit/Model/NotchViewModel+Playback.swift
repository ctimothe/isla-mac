import AppKit
import Combine
import UniformTypeIdentifiers

/// What a change of playback does to the island. Stored properties live in NotchViewModel.swift.
extension NotchViewModel {
    /// Asks the island to confirm an act, and says it once to VoiceOver when
    /// the act's own path has not already (`announcesAtTheAct`). Spoken here,
    /// at the act, and never when the pill draws: whether the pill is drawn
    /// depends on the panel and the second it may wait, and the person on
    /// VoiceOver is owed the answer either way — as the volume pop-up's level
    /// is spoken over an open panel that draws nothing.
    func confirm(_ kind: IslandConfirmation.Kind) {
        let confirmation = IslandConfirmation(kind)
        if confirmation.announcesAtTheAct { Announcer.shared.announce(confirmation.accessibilityLabel) }
        onConfirmation?(confirmation)
    }

    /// What the compact island says it is: "Playing: title, artist".
    ///
    /// The pill's accessibility label and the peek's announcement are the
    /// same sentence, kept here so the two cannot drift. Empty with no track,
    /// which the announcer refuses to speak.
    var compactAccessibilityLabel: String {
        guard let track = media.track else { return "" }
        let state = compactMediaActivity == .playing ? localized("Playing") : localized("Paused")
        return "\(state): \(track.title), \(track.artist)"
    }

    var compactMediaActivity: CompactMediaActivity {
        CompactMediaActivity(
            hasTrack: media.track != nil,
            isPlaying: media.isPlaying,
            pauseHasSettled: pauseHasSettled
        )
    }

    /// Decides whether a paused track shows its pill, and for how long.
    ///
    /// The linger exists so a quick resume never flickers the pill away, which
    /// makes it about a pause somebody just made. It used to run for every
    /// paused track the island merely learned about as well: a song adopted
    /// after a relaunch, or re-described while a film owned Now Playing, woke
    /// the island for five seconds with nothing to announce — filmed on
    /// 2026-09-21, the paused song's pill appearing over the notch each time
    /// the owner pressed play on a film. Those rest at once now. A linger
    /// already running is left alone, so re-describing the same pause cannot
    /// cut it short or restart it.
    ///
    /// A different song arriving paused rests too. It used to get a glance,
    /// but with the linger now only a skip's breath long a glance would be a
    /// flicker, and the owner asked for a paused island to stay out of the way.
    func playbackChanged(isPlaying: Bool, hasTrack: Bool) {
        let sawPlaying = lastSawPlaying
        lastSawPlaying = isPlaying && hasTrack
        guard hasTrack, !isPlaying else {
            pauseSettleTask?.cancel()
            pauseSettleTask = nil
            if pauseHasSettled { pauseHasSettled = false }
            DebugTrail.note("island: playing=\(isPlaying ? 1 : 0) track=\(hasTrack ? 1 : 0)")
            return
        }
        if sawPlaying {
            pauseSettleTask?.cancel()
            pauseSettleTask = nil
            // Paused while a film plays: the pill has nothing to linger for,
            // the same as a film starting during the linger.
            if media.otherMediaIsPlaying {
                if !pauseHasSettled { pauseHasSettled = true }
                DebugTrail.note("island: paused while other media plays -> rests at once")
                return
            }
            if pauseHasSettled { pauseHasSettled = false }
            DebugTrail.note("island: paused while showing -> lingers \(NotchMetrics.pausedLinger)s")
            pauseSettleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NotchMetrics.pausedLinger))
                guard !Task.isCancelled, let self else { return }
                self.pauseSettleTask = nil
                self.pauseHasSettled = true
                DebugTrail.note("island: pause settled -> rests in the notch")
            }
        } else if pauseSettleTask == nil, !pauseHasSettled {
            pauseHasSettled = true
            DebugTrail.note("island: a paused track nobody was seen pausing -> rests at once")
        }
    }

    /// A source Music Only keeps off the island started playing. A pause still
    /// lingering has nothing left to say once a film is playing, so its pill
    /// folds into the notch now rather than hanging over the film for the rest
    /// of its five seconds. A playing song is left alone.
    func otherMediaStartedPlaying() {
        guard pauseSettleTask != nil else { return }
        pauseSettleTask?.cancel()
        pauseSettleTask = nil
        pauseHasSettled = true
        DebugTrail.note("island: other media started playing -> the paused pill folds")
    }
}
