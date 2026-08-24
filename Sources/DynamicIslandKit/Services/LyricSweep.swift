import Foundation

/// Where the voice stands in a lyric, and which line that is — in one place, for
/// every surface that draws one.
///
/// There were four clocks. The caption and the lock card each carried a private
/// copy of the same six lines of sweep arithmetic, byte for byte; the stage
/// borrowed the lock card's. Worse, the three disagreed about *when* now is: the
/// stage added the listener's own sync correction, the caption used the same two
/// lead constants without it, and the lock card hardcoded `+ 0.25` and consulted
/// neither the precision flag nor the correction. So nudging Sync moved one
/// surface, and the other two kept pointing at the line before.
///
/// Surfaces that disagree about the current word are not a matter of taste. They
/// are separate clocks, and the only fix for separate clocks is one clock.
@MainActor
enum LyricSweep {
    /// Three real delays stack between the singer and the screen: the position
    /// ticks four times a second, so a line lands up to 250ms after its
    /// timestamp; the crossfade spends another 160ms arriving; and the
    /// pipeline's own readings run slightly behind the audio. Leading by roughly
    /// their sum is what karaoke has always done — the line appears as the voice
    /// does, not noticeably after it.
    static let standardLead: TimeInterval = 0.45
    /// With the position corrected against the player's own clock the pipeline's
    /// share of the lag is gone; what remains is display cost.
    static let precisionLead: TimeInterval = 0.25

    static func lead(precisionSync: Bool, userOffset: TimeInterval) -> TimeInterval {
        (precisionSync ? precisionLead : standardLead) + userOffset
    }

    /// The moment the lyric should be read against: the clock, plus the lead.
    static func position(
        _ position: TimeInterval, precisionSync: Bool, userOffset: TimeInterval
    ) -> TimeInterval {
        position + lead(precisionSync: precisionSync, userOffset: userOffset)
    }

    /// The line to show right now, which is not always the line being sung.
    ///
    /// A paused track's position is frozen — the ticker stops with playback, and
    /// the readings that keep arriving are rejected as describing a moment
    /// already past — so a track paused before its first timestamp has no line
    /// covering it, and every surface used to draw nothing at all. The opening
    /// line, unswept, is the honest answer: the words are there, the voice has
    /// not reached them.
    ///
    /// `swept` is what carries that distinction. A filled sweep across a line
    /// nobody has sung claims the voice is there, which is the same lie a swept
    /// producer credit tells.
    static func displayed(
        lines: [LyricsStore.Line], at: TimeInterval
    ) -> (line: LyricsStore.Line, end: TimeInterval, swept: Bool)? {
        guard let first = lines.first else { return nil }
        let current = LyricsStore.current(in: lines, at: at)
        guard let line = current.line else {
            // The end matters even here: it is what the sweep will span once the
            // voice arrives, and the caller reads it before that happens.
            return (first, lines.count > 1 ? lines[1].at : first.at + 6, false)
        }
        return (line, current.next?.at ?? line.at + 6, true)
    }

    /// Real word timing when a source had it; the singing-speed estimate only for
    /// lines that never got any.
    static func fraction(line: LyricsStore.Line, at: TimeInterval, end: TimeInterval) -> Double {
        guard line.words.isEmpty else {
            return WordSyncedLyrics.wordFraction(words: line.words, at: at, lineEnd: end)
        }
        let span = LyricsStore.sweepSpan(text: line.text, slot: end - line.at)
        return min(max((at - line.at) / span, 0), 1)
    }
}
