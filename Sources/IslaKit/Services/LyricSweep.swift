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
    /// How far ahead of the clock a line is shown.
    ///
    /// Two terms, both measured or conventional, and one that used to be here
    /// and is not any more. The live Spotify probe (`Scripts/measure-sync.sh`,
    /// 2026-09-13) found the clock about 0.10s behind the audio in steady
    /// play; that is the first term. The second is the anticipation every
    /// karaoke surface carries on purpose — the system's own lyrics light a
    /// line a beat before the voice reaches it, so the eye is already there —
    /// and 0.10s is the small end of that. The term that is gone is the
    /// ticker's quarter-second grid: `MediaController` now wakes on the frame
    /// a line is due, so the lead no longer has to over-shoot to cover a
    /// change that might land 250ms late. It was 0.25 when it did, and 0.45
    /// before the probe measured anything, and both read as ahead of the
    /// singing on the tracks the sources had timed well.
    ///
    /// The probe stays the arbiter: re-run it after any change here and read
    /// the word-edge column before believing the number.
    static let standardLead: TimeInterval = 0.20
    /// Precision sync corrects against the player's own clock, and the probe
    /// still measured the same 0.10s behind through cross-process sampling
    /// and rendering — so the same two terms apply. Kept as its own constant
    /// so the two paths can be re-measured apart.
    static let precisionLead: TimeInterval = 0.20

    static func lead(
        precisionSync: Bool, userOffset: TimeInterval, trackOffset: TimeInterval = 0
    ) -> TimeInterval {
        // Three layers, summed at read and clamped nowhere here: the global
        // correction clamps at ±3s and the track layer at ±1.5s where each is
        // written, in LyricsStore. Clamping the sum instead would let one
        // layer steal another's range — a global +3 with a track −0.5 must
        // still read +2.5, not a clamped +1.5.
        //
        // Both corrections are *delays*, so they come off the lead. They were
        // added until 2026-10-11, which ran every control backwards: "Lyric
        // Delay" +0.5 lit lines half a second early, the stage's "Lyrics
        // Earlier" made them later, and the AirPods listener the setting
        // exists for followed the note under the slider and doubled the
        // error. Stored values were negated once on the way (LyricsStore's
        // sign migration), so no listener's timing moved with the fix.
        (precisionSync ? precisionLead : standardLead) - userOffset - trackOffset
    }

    /// The moment the lyric should be read against: the clock, plus the lead
    /// (which a positive delay shrinks).
    static func position(
        _ position: TimeInterval, precisionSync: Bool, userOffset: TimeInterval,
        trackOffset: TimeInterval = 0
    ) -> TimeInterval {
        position + lead(
            precisionSync: precisionSync, userOffset: userOffset, trackOffset: trackOffset
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

    /// The whole moment, from the one search: the line being sung, the line a
    /// surface centres on, and the line the voice reaches next.
    ///
    /// `current` and `centre` are kept apart on purpose. The lock card used to
    /// ask only for the centre and then call it current, and `LyricRow` fills
    /// a current line-timed row to 1 — so through every intro the card drew
    /// line 1 as sung while the stage drew nothing and the caption drew line 1
    /// unswept. The lyric lab counted 52,013 such disagreements over 540
    /// tracks, a median 12.9 s of every song. Centring on a line and claiming
    /// the voice is in it are two different statements.
    static func moment(in lines: [LyricsStore.Line], at: TimeInterval) -> LyricMoment {
        let current = index(in: lines, at: at)
        let upcoming: Int?
        if let current {
            upcoming = current + 1 < lines.count ? current + 1 : nil
        } else {
            upcoming = lines.isEmpty ? nil : 0
        }
        return LyricMoment(current: current, centre: current ?? 0, upcoming: upcoming)
    }

    /// The sweep a row is drawn with: none unless the voice is in it, none for
    /// a credit, and otherwise the word sweep when word timing is on or the
    /// whole line lit when it is not. `LyricRow` and the caption both draw
    /// through this, so the number a surface reports is the number it draws.
    static func drawnFraction(
        line: LyricsStore.Line, isCurrent: Bool, at: TimeInterval, end: TimeInterval,
        wordTiming: Bool
    ) -> Double {
        guard isCurrent, !line.isCredit else { return 0 }
        return wordTiming ? fraction(line: line, at: at, end: end) : 1
    }

    /// What every lyric surface draws for one reading of the clock. The stage,
    /// the caption and the lock card each name a static that comes here — and
    /// the lyric lab calls those same statics, so it measures the code that
    /// draws rather than a restatement of it that can drift.
    static func resolve(lines: [LyricsStore.Line], inputs: LyricInputs) -> LyricResolution {
        let at = position(
            inputs.position, precisionSync: inputs.precisionSync,
            userOffset: inputs.userOffset, trackOffset: inputs.trackOffset
        )
        let moment = moment(in: lines, at: at)
        let fraction = moment.current.map {
            drawnFraction(
                line: lines[$0], isCurrent: true, at: at, end: end(of: $0, in: lines),
                wordTiming: inputs.wordTiming
            )
        } ?? 0
        return LyricResolution(at: at, moment: moment, fraction: fraction)
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
            return wordFraction(words: line.words, at: at, lineEnd: end)
        }
        let span = LyricsStore.sweepSpan(text: line.text, slot: end - line.at)
        return min(max((at - line.at) / span, 0), 1)
    }

    static func wordFraction(words: [LyricWord], at position: TimeInterval, lineEnd: TimeInterval) -> Double {
        guard !words.isEmpty else { return 0 }
        let counts = words.map { Double($0.text.count) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return 0 }

        var sung: Double = 0
        for (index, word) in words.enumerated() {
            let nextStart = index + 1 < words.count ? words[index + 1].at : lineEnd
            let wordEnd = min(word.end ?? nextStart, nextStart)
            if position >= wordEnd {
                sung += counts[index]
            } else if position > word.at {
                let span = max(wordEnd - word.at, 0.05)
                sung += counts[index] * min((position - word.at) / span, 1)
                break
            } else {
                break
            }
        }
        return min(max(sung / total, 0), 1)
    }
}

/// Where the voice stands in a lyric, by row index. See `LyricSweep.moment`.
struct LyricMoment: Equatable, Sendable {
    /// The line being sung, or nil before the first timestamp.
    let current: Int?
    /// The line a surface centres on: the current one, or the opening line
    /// while the voice has not reached it. Never nil, so a paused intro still
    /// shows words.
    let centre: Int
    /// The line the voice reaches next: the opening line during the intro,
    /// the one after the current line otherwise, nil after the last.
    let upcoming: Int?

    /// How far a row stands from the voice, for the depth falloff. With no
    /// line sung every row sits at the far floor: measured from the centre
    /// instead, the opening line came out as the dimmest thing on the card
    /// beside a brighter neighbour, depth inside out.
    func distance(of index: Int) -> Int {
        current.map { abs(index - $0) } ?? 2
    }
}

/// What a lyric surface reads the clock with.
struct LyricInputs: Equatable, Sendable {
    let position: TimeInterval
    let precisionSync: Bool
    let userOffset: TimeInterval
    let trackOffset: TimeInterval
    /// `LyricsPresentation.usesWordTiming`, already decided.
    let wordTiming: Bool
}

/// What one surface draws at one moment: compared across surfaces by the lab,
/// so two of them disagreeing is a failing number rather than a filmed bug.
struct LyricResolution: Equatable, Sendable {
    /// The moment the lyric is read against, lead applied.
    let at: TimeInterval
    let moment: LyricMoment
    /// The sweep the current row is drawn with; 0 when no row is current.
    let fraction: Double

    var current: Int? { moment.current }
    var centre: Int { moment.centre }
}
