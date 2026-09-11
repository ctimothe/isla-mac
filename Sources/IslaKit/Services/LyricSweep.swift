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

    static func lead(
        precisionSync: Bool, userOffset: TimeInterval,
        sourceBias: TimeInterval = 0, trackOffset: TimeInterval = 0
    ) -> TimeInterval {
        // Three layers, summed at read and clamped nowhere here: the global
        // correction clamps at ±3s and the track layer at ±1.5s where each is
        // written, in LyricsStore. Clamping the sum instead would let one
        // layer steal another's range — a global +3 with a track −0.5 must
        // still read +2.5, not a clamped +1.5.
        (precisionSync ? precisionLead : standardLead) + userOffset + sourceBias + trackOffset
    }

    /// The moment the lyric should be read against: the clock, plus the lead.
    static func position(
        _ position: TimeInterval, precisionSync: Bool, userOffset: TimeInterval,
        sourceBias: TimeInterval = 0, trackOffset: TimeInterval = 0
    ) -> TimeInterval {
        position + lead(
            precisionSync: precisionSync, userOffset: userOffset,
            sourceBias: sourceBias, trackOffset: trackOffset
        )
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

    /// The index of the line covering `at`, or nil before the song's first
    /// timestamp.
    ///
    /// One binary search. There were three — `LyricsStore.current`, this, and a
    /// private copy inside the lyrics stage — and the copies had drifted apart
    /// on the case that matters most: before the first line the stage answered
    /// nil and highlighted nothing, while the card answered the opening line.
    /// Two surfaces showing the same song disagreeing about which line is
    /// current is the whole reason this type exists.
    static func index(in lines: [LyricsStore.Line], at: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].at <= at { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found >= 0 ? found : nil
    }

    /// The index to centre a view on: the line being sung, or the first one
    /// when the voice has not reached it yet. Never nil for a song that has
    /// words, which is what keeps a paused track from showing an empty page.
    static func centreIndex(in lines: [LyricsStore.Line], at: TimeInterval) -> Int {
        index(in: lines, at: at) ?? 0
    }

    /// When a line stops being sung: the next line's start, or a spoken length
    /// borrowed for the last one.
    static func end(of index: Int, in lines: [LyricsStore.Line]) -> TimeInterval {
        guard lines.indices.contains(index) else { return 0 }
        if index + 1 < lines.count { return lines[index + 1].at }
        return lines[index].at + 6
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
