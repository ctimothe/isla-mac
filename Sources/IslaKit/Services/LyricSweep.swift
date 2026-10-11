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
    /// What the lead is made of: every term between a line's timestamp and
    /// the listener's eye and ear, named. See `LyricLeadModel`.
    ///
    /// Mutable because one of its inputs is live: the route's reported output
    /// latency, which `LyricsCoordinator` writes when the default output
    /// moves (and which the sum does not apply yet — see
    /// `LyricLeadModel.appliesOutputLatency`). Tests that change it put it
    /// back.
    ///
    /// Any write that changes `lead` must be followed by re-registering the
    /// lyric boundaries, because the armed wake was computed with the old
    /// lead; `LyricsCoordinator.outputLatencyChanged` does.
    static var model = LyricLeadModel.calibrated

    /// How far ahead of the clock a line is shown, before the listener's
    /// corrections: the model's sum.
    ///
    /// It was a bare 0.20 s constant, and before that 0.25 (while the ticker's
    /// quarter-second grid had to be covered) and 0.45 (before the probe
    /// measured anything). The lyric lab's L7 showed why no constant could
    /// settle it: the optimum is about 0.27 s on built-in speakers and 0.10 s
    /// on a 200 ms Bluetooth route, and the owner's ear sits about 0.35 s
    /// away from both. So the number is now the sum of terms that can each be
    /// re-measured, calibrated to give the same 0.20 s on the route it was
    /// tuned on. The probe stays the arbiter: re-run `Scripts/measure-sync.sh`
    /// after any change to a term.
    static var standardLead: TimeInterval { model.lead }
    /// Precision sync corrects against the player's own clock, and the probe
    /// still measured the same lag through cross-process sampling and
    /// rendering — so the same terms apply. Kept as its own name so the two
    /// paths can be re-measured apart: a precision-only anchor lag is a
    /// second model, not an edit to this one.
    static var precisionLead: TimeInterval { model.lead }

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
    ///
    /// The same holds after a line's honoured end: the line coming is shown,
    /// unswept, and in the outro the last line is. Read through `moment`, so
    /// the Shortcuts action that asks for "the line playing right now" agrees
    /// with every surface about when a line has stopped playing.
    ///
    /// `readAhead` is the caption's reading lead (`readingMoment`). The one
    /// caller that asks for the line *sung* — the Shortcuts action — passes
    /// `.off`, and so never reads a line ahead of the voice.
    static func displayed(
        lines: [LyricsStore.Line], at: TimeInterval, readAhead: LyricReadAhead = .off
    ) -> (line: LyricsStore.Line, end: TimeInterval, swept: Bool)? {
        guard !lines.isEmpty else { return nil }
        let moment = readingMoment(in: lines, at: at, readAhead: readAhead)
        // The end matters even when nothing is sung: it is what the sweep will
        // span once the voice arrives, and the caller reads it before that.
        let shown = moment.current ?? moment.centre
        return (lines[shown], end(of: shown, in: lines), moment.current != nil)
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
    /// Through a gap after a line's end it is the line coming, as `moment`
    /// says — this is that moment's centre, not a second rule.
    static func centreIndex(in lines: [LyricsStore.Line], at: TimeInterval) -> Int {
        moment(in: lines, at: at).centre
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
    ///
    /// After a line's honoured end (`effectiveEnd`) nothing is current until
    /// the next line starts — the same statement the intro makes — and the
    /// surfaces centre on the line the voice reaches next. A finished line
    /// used to stay lit to the next stamp, through every instrumental: the
    /// lab measured a median 28.9 s a track, and 447 mid-song lines lit
    /// through more than 8 s of silence. In the outro there is no next line,
    /// so the centre stays on the last one, drawn unsung.
    ///
    /// When the silence is long enough to be an interlude (`interlude(before:in:)`)
    /// the moment names it and how far through it the clock is, so a surface
    /// can centre on the interlude's own slot instead of on a dim line.
    static func moment(in lines: [LyricsStore.Line], at: TimeInterval) -> LyricMoment {
        guard let found = index(in: lines, at: at) else {
            guard !lines.isEmpty else { return LyricMoment(current: nil, centre: 0, upcoming: nil) }
            let intro = interlude(before: 0, in: lines)
            return LyricMoment(
                current: nil, centre: 0, upcoming: 0,
                interlude: intro, progress: intro.map { interludeProgress($0, at: at) } ?? 0
            )
        }
        let upcoming = found + 1 < lines.count ? found + 1 : nil
        if let end = effectiveEnd(of: found, in: lines), at >= end {
            let gap = upcoming.flatMap { interlude(before: $0, in: lines) }
            return LyricMoment(
                current: nil, centre: upcoming ?? found, upcoming: upcoming,
                interlude: gap, progress: gap.map { interludeProgress($0, at: at) } ?? 0
            )
        }
        return LyricMoment(current: found, centre: found, upcoming: upcoming)
    }

    // MARK: - Reading lead

    /// The longest a line may be asked to give away to the next one, as a
    /// share of its own length. A short line is on screen for a beat at best;
    /// handing over half of it would leave the singer no time to sing the
    /// line they are leaving.
    static let maximumReadAheadShare = 0.45

    /// When the one-line caption turns to line `next` ahead of the voice, in
    /// the same lyric-moment time as `moment(in:at:)`, or nil when it does
    /// not.
    ///
    /// A person singing along reads a line before they sing it: with the
    /// caption turning exactly as the voice arrives, the eye is still
    /// finding the words when the mouth should be on them. So for a
    /// transition with no honoured end — continuous singing — the caption
    /// turns early: `readAhead` says by how much (a fixed 0.3 s or 0.5 s, or
    /// Auto, which asks `LyricReadAhead.seconds(forNextLine:)` and so gives a
    /// long line more time to be read than a short one). That is capped at 45
    /// percent of the line it leaves and never earlier than the start of that
    /// line's final word, so the last word is still on screen when it is
    /// sung. The cap is why a single transition can come out below Auto's
    /// 0.30 s floor: a line only half a second long cannot give away 0.30 s
    /// of itself without taking the line being sung off the screen, and
    /// protecting that line wins over the floor. A transition with an
    /// honoured end already shows `next` from the end (`moment`), so there is
    /// nothing to bring forward.
    ///
    /// The one place that decides it: `readingMoment` reads it for the line
    /// to draw and `LyricsCoordinator.registerBoundaries` for the wake that
    /// turns the caption on time, so a drawn turn and an armed wake cannot
    /// answer two different rules — including the per-line early time Auto
    /// computes, which differs from one transition to the next.
    static func readAheadStart(
        before next: Int, in lines: [LyricsStore.Line], readAhead: LyricReadAhead
    ) -> TimeInterval? {
        let previous = next - 1
        guard readAhead != .off, lines.indices.contains(previous),
              lines.indices.contains(next),
              effectiveEnd(of: previous, in: lines) == nil else { return nil }
        let wanted = readAhead.seconds(forNextLine: lines[next].text)
        let length = lines[next].at - lines[previous].at
        guard wanted > 0, wanted.isFinite, length > 0 else { return nil }
        let early = min(wanted, maximumReadAheadShare * length)
        var start = lines[next].at - early
        if let finalWord = lines[previous].words.last { start = max(start, finalWord.at) }
        return start < lines[next].at ? start : nil
    }

    /// The moment the one-line caption draws: `moment(in:at:)`, except that in
    /// the last stretch of a line sung straight into the next
    /// (`readAheadStart`) the next line is already the one shown, unswept —
    /// nothing is current, as in an intro. A pure function of the position
    /// like the rest, so a seek, a pause and a scrub give the same answer
    /// they would have played through. With `readAhead` Off it is `moment`.
    static func readingMoment(
        in lines: [LyricsStore.Line], at: TimeInterval, readAhead: LyricReadAhead
    ) -> LyricMoment {
        let base = moment(in: lines, at: at)
        guard readAhead != .off, let current = base.current,
              let start = readAheadStart(before: current + 1, in: lines, readAhead: readAhead),
              at >= start else { return base }
        return LyricMoment(current: nil, centre: current + 1, upcoming: current + 1)
    }

    // MARK: - Slots

    /// The shortest silence that gets a slot of its own.
    ///
    /// After LY-05 a line goes dark at its end, and a twenty-second solo
    /// showed nothing but the next line, dim, waiting at the reading centre —
    /// which reads as the lyrics having lost the song. Five seconds is where
    /// the wait stops being a breath between phrases (`minimumHonouredGap`
    /// covers those) and starts being a passage somebody plays: long enough
    /// for a marker to be read and to visibly fill, and short enough that a
    /// bridge of two bars still gets one.
    static let minimumInterlude: TimeInterval = 5

    /// The interlude that ends where line `index` starts, if the silence
    /// before it is `minimumInterlude` or longer: from zero for the opening
    /// line (the intro), from the line before's honoured end otherwise.
    ///
    /// Only an end the source gave counts, through `effectiveEnd`, the one
    /// rule LY-05 put every surface on. Two stamps twenty seconds apart with
    /// no end between them are one long line as far as anyone knows, and
    /// guessing a solo there would draw a marker over a voice still singing.
    /// The outro has no line to fill toward, so it gets no slot: the last
    /// line stays where it is, unsung.
    ///
    /// `slots(for:)` and `moment` both ask here, so the slot a stage scrolls
    /// to and the interlude a moment says is playing are one decision.
    static func interlude(before index: Int, in lines: [LyricsStore.Line]) -> LyricSlot? {
        guard lines.indices.contains(index) else { return nil }
        let to = lines[index].at
        let from: TimeInterval
        if index == 0 {
            from = 0
        } else if let end = effectiveEnd(of: index - 1, in: lines) {
            from = end
        } else {
            return nil
        }
        guard to - from >= minimumInterlude else { return nil }
        return .interlude(from: from, to: to, before: index)
    }

    /// How far through an interlude the clock is, 0 to 1. A clock read before
    /// the interlude's start — a large listener delay on the song's first
    /// frame puts the lyric moment below zero — is its start, not a negative
    /// fill; a non-interlude slot is 0.
    static func interludeProgress(_ slot: LyricSlot, at: TimeInterval) -> Double {
        guard case .interlude(let from, let to, _) = slot, to > from else { return 0 }
        return min(max((at - from) / (to - from), 0), 1)
    }

    /// Every row a lyric surface lays out, in order: each line, and before a
    /// line the interlude leading to it when there is one.
    ///
    /// A row of its own rather than a mark drawn over a line. The stage's
    /// scroll is exact because every row is one fixed slot and the clock maps
    /// to a row by arithmetic; an interlude that is a slot keeps that, and an
    /// overlay at the reading centre would sit on the text of the line the
    /// voice just left.
    static func slots(for lines: [LyricsStore.Line]) -> [LyricSlot] {
        var slots: [LyricSlot] = []
        slots.reserveCapacity(lines.count + 4)
        for index in lines.indices {
            if let gap = interlude(before: index, in: lines) { slots.append(gap) }
            slots.append(.line(index))
        }
        return slots
    }

    /// Where `slot` sits among `slots`; 0 for a slot that is not there, which
    /// only a lyric replaced between two reads can produce.
    ///
    /// A linear search, on purpose: a song is a few dozen rows, the moment
    /// already did the binary search that matters, and a second index kept
    /// beside `slots` would be one more thing to fall out of step with it.
    static func slotIndex(of slot: LyricSlot, in slots: [LyricSlot]) -> Int {
        slots.firstIndex(of: slot) ?? 0
    }

    /// The row the depth falloff is measured from: the sung line, or the
    /// interlude while one plays. Nil when neither is lit — a breath too
    /// short to be an interlude, or an outro.
    static func litSlotIndex(_ moment: LyricMoment, in slots: [LyricSlot]) -> Int? {
        guard let lit = moment.litSlot else { return nil }
        return slots.firstIndex(of: lit)
    }

    /// An interlude's fill read against `clock` on every display frame, or
    /// nil when it has no reason to move between publishes — not an
    /// interlude, or a song that is not playing. The same arithmetic as the
    /// moment's `progress`, called rather than restated.
    static func liveProgress(
        _ slot: LyricSlot, clock: (@MainActor () -> TimeInterval)?
    ) -> (@MainActor () -> Double)? {
        guard let clock, case .interlude = slot else { return nil }
        return { interludeProgress(slot, at: clock()) }
    }

    /// How many rows a slot stands from the lit one, for the depth falloff.
    ///
    /// Counted in rows, not lines. Counted in lines, the line on the far side
    /// of a solo was drawn as the sung line's neighbour while the marker
    /// between them sat at the floor — depth that skipped a row. With nothing
    /// lit every row sits at the far floor, which is what
    /// `LyricMoment.distance(of:)` already says for lines.
    static func distance(ofSlot index: Int, lit: Int?) -> Int {
        lit.map { abs(index - $0) } ?? 2
    }

    /// The sweep a row is drawn with: none unless the voice is in it, none for
    /// a credit, and otherwise the word sweep when word timing is on and the
    /// line has words, or the whole line lit when either is missing. `LyricRow`
    /// and the caption both draw through this, so the number a surface
    /// reports is the number it draws.
    ///
    /// A word-timed song can hold lines without words — the editor drops a
    /// line's words when its text is edited, and a document is word-timed
    /// when any line is (J-014). Those lines light whole. Swept by the
    /// singing-speed estimate (`fraction`'s fallback), they would draw word
    /// timing nobody wrote, beside lines whose timing is real.
    static func drawnFraction(
        line: LyricsStore.Line, isCurrent: Bool, at: TimeInterval, end: TimeInterval,
        wordTiming: Bool
    ) -> Double {
        guard isCurrent, !line.isCredit else { return 0 }
        guard wordTiming, !line.words.isEmpty else { return 1 }
        return wordFraction(words: line.words, at: at, lineEnd: end)
    }

    /// The moment a sweep reads on each display frame: the running clock, lead
    /// added, or nil while the song is not moving.
    ///
    /// The running clock, not `MediaController.position`. That one is
    /// published on the 0.1 s tick, so an edge read from it steps ten times a
    /// second — and the quarter-second ramp that used to smooth the steps
    /// over left the edge 175 ms behind the voice at the median (F-011). Read
    /// through `extrapolatedPosition`, the one copy of the clock's arithmetic,
    /// so the edge and the bar can never be on two clocks. Nil when paused: a
    /// still song has nothing to show between frames, and a frame callback
    /// for it would be spent on nothing.
    static func frameClock(
        media: MediaController, lead: TimeInterval
    ) -> (@MainActor () -> TimeInterval)? {
        guard media.isPlaying else { return nil }
        return { media.extrapolatedPosition() + lead }
    }

    /// The sweep of a line being sung, read against `clock` whenever it is
    /// asked — every display frame, from `KaraokeText` — or nil when the
    /// sweep has no reason to move between publishes.
    ///
    /// Only a word-timed line moves: line timing and a word-less line draw 1
    /// (`drawnFraction`), a credit draws 0, and a sweep that cannot change
    /// costs no frame callback. The arithmetic is `drawnFraction`'s, called
    /// rather than restated, so the edge a frame draws is the edge the lab
    /// reports.
    static func liveFraction(
        line: LyricsStore.Line, end: TimeInterval, wordTiming: Bool,
        clock: (@MainActor () -> TimeInterval)?
    ) -> (@MainActor () -> Double)? {
        guard let clock, wordTiming, !line.isCredit, !line.words.isEmpty else { return nil }
        return { drawnFraction(line: line, isCurrent: true, at: clock(), end: end, wordTiming: true) }
    }

    /// What every lyric surface draws for one reading of the clock. The stage,
    /// the caption and the lock card each name a static that comes here — and
    /// the lyric lab calls those same statics, so it measures the code that
    /// draws rather than a restatement of it that can drift.
    ///
    /// `readAhead` is passed by the caption alone (`MediaPane.captionResolution`):
    /// the stage and the lock card show several lines at once and have no use
    /// for a reading lead, and the Lyric Delay preview calibrates against the
    /// voice. It is an argument rather than a field of `LyricInputs` so a
    /// surface cannot pick it up by accident.
    static func resolve(
        lines: [LyricsStore.Line], inputs: LyricInputs, readAhead: LyricReadAhead = .off
    ) -> LyricResolution {
        let at = position(
            inputs.position, precisionSync: inputs.precisionSync,
            userOffset: inputs.userOffset, trackOffset: inputs.trackOffset
        )
        let moment = readingMoment(in: lines, at: at, readAhead: readAhead)
        let fraction = moment.current.map {
            drawnFraction(
                line: lines[$0], isCurrent: true, at: at, end: end(of: $0, in: lines),
                wordTiming: inputs.wordTiming
            )
        } ?? 0
        return LyricResolution(at: at, moment: moment, fraction: fraction)
    }

    /// The shortest silence a line goes dark for. Some LRCLIB files put the
    /// empty stamp a breath before the next line; honoured, the line would
    /// blink off and on again between two phrases of one verse, which reads
    /// as a glitch rather than as the voice stopping.
    static let minimumHonouredGap: TimeInterval = 1.5

    /// When the line's voice stops, if the source said so and the silence
    /// after it is worth showing: the line's own `end`, kept only when it
    /// lies after the line's start and at least `minimumHonouredGap` before
    /// the next line. The last line has no next line, so its end (the outro
    /// stamp) is always honoured.
    ///
    /// The one place that decides it. `moment`, `end(of:in:)` and the
    /// clock's boundary wakes (`LyricsCoordinator.registerBoundaries`) all
    /// ask here, so a surface that went dark and a wake that fired for it
    /// can never be answering two different rules.
    static func effectiveEnd(of index: Int, in lines: [LyricsStore.Line]) -> TimeInterval? {
        guard lines.indices.contains(index), let end = lines[index].end,
              end.isFinite, end > lines[index].at else { return nil }
        if index + 1 < lines.count, lines[index + 1].at - end < minimumHonouredGap { return nil }
        return end
    }

    /// When a line stops being sung: where its voice ends when the source
    /// said so, otherwise the next line's start, or a spoken length borrowed
    /// for the last one. The honoured end matters to a word-timed line: its
    /// last word used to stretch across the whole instrumental after it.
    static func end(of index: Int, in lines: [LyricsStore.Line]) -> TimeInterval {
        guard lines.indices.contains(index) else { return 0 }
        if let end = effectiveEnd(of: index, in: lines) { return end }
        if index + 1 < lines.count { return lines[index + 1].at }
        return lines[index].at + 6
    }

    /// Real word timing when a source had it; the singing-speed estimate only for
    /// lines that never got any. No surface draws the estimate any more —
    /// `drawnFraction` lights a word-less line whole — so it is here for the
    /// lyric lab, which measures what the estimate would have drawn.
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
                // The word's true span. It was floored at 50 ms, so a 10 ms
                // word had reached a fifth of itself when its successor began
                // and the edge leapt the rest in one frame (the lab's L5:
                // 0.099 to 0.5 across 0.1 ms). It cannot be zero here: the
                // clock is strictly between the word's start and its end.
                let span = wordEnd - word.at
                sung += counts[index] * min((position - word.at) / span, 1)
                break
            } else {
                break
            }
        }
        return min(max(sung / total, 0), 1)
    }
}

/// The lyric lead as the sum of what it compensates, term by term.
///
/// lead = anchorLag + timerWake + frameHalf + compositor + onsetRise
///        + anticipation − outputLatency − unmeasuredPlayerDelay
///
/// Each positive term is time the line spends getting from its timestamp to
/// the eye, so the line has to be shown that much earlier; each negative one
/// is time the voice spends getting to the ear, so the line can wait for it.
/// The terms and their sources are the lyric lab's (L7, 2026-10-11). The
/// listener's corrections come off the sum afterwards, in `LyricSweep.lead`.
///
/// Calibrated, not chosen: `unmeasuredPlayerDelay` is set so the built-in
/// route at 120 Hz sums to the 0.20 s every stored correction was tuned
/// against, so introducing the model moved no one's lyrics.
struct LyricLeadModel: Equatable, Sendable {
    /// How far the clock's anchor sits behind the player's real position at
    /// a boundary wake: the 2026-09-21 Spotify probe's published-position lag
    /// of 0.188 s, less the 0.05 s mean staleness of the 0.1 s tick grid that
    /// a boundary wake does not suffer (it publishes a fresh extrapolation).
    var anchorLag: TimeInterval
    /// How late the boundary wake runs: the strict dispatch timer's idle
    /// median (LY-07, about 0.07 ms), rounded up.
    var timerWake: TimeInterval
    /// The island screen's refresh rate. A changed line waits on average half
    /// a frame for the next vsync and then one frame in the compositor.
    ///
    /// Held at `referenceFrameRate` for now rather than read from the island
    /// screen's `maximumFramesPerSecond`: a 60 Hz panel (a notched MacBook
    /// Air) would gain 12.5 ms of lead the day it went live, moving a stored
    /// correction tuned there, which is the same silent move that keeps
    /// `outputLatency` unapplied. It goes live with that term.
    var frameRate: Double
    /// How long the onset crossfade takes to be half there — the moment the
    /// eye takes the line as lit. `LyricRow` lights a line on
    /// `Theme.lyricScroll`, which reaches 50% about 104 ms after it starts
    /// (L-09). Shown that much earlier, the crossfade's midpoint lands on the
    /// voice and the motion itself is unchanged.
    var onsetRise: TimeInterval
    /// How far ahead of the voice the line should land: the centre of ITU-R
    /// BT.1359-1's detectability window (−125/+45 ms), which the lab uses as
    /// the target. A line lit a beat early reads as anticipation; one lit late
    /// reads as lagging, and people forgive the first far more.
    var anticipation: TimeInterval
    /// What CoreAudio reports the default output device adds (device latency,
    /// safety offset, one IO buffer, stream latency), written live by
    /// `LyricsCoordinator` from `OutputLatencyMonitor`. Measured and logged,
    /// but applied only once `appliesOutputLatency` says so.
    var outputLatency: TimeInterval
    /// The term nobody has measured yet: whatever lies between the player's
    /// reported position and the voice reaching the ear that the other terms
    /// do not cover — player-side buffering, catalogue stamps set early. It
    /// is a placeholder, about 67 ms, chosen only so the built-in route keeps
    /// the shipped 0.20 s. The acoustic loopback probe, or the owner's S-LEAD
    /// session (docs/audits/2026-10-11-live-validation-script.md), must
    /// replace it with a number; until then it is the honest name for the
    /// part of the 0.20 s nobody can account for.
    var unmeasuredPlayerDelay: TimeInterval

    /// Whether the live `outputLatency` is part of the sum. Not yet.
    ///
    /// Applied, it would show lines later on a Bluetooth route by its reported
    /// latency less the built-in route's — the direction the owner's AirPods
    /// correction points. But every stored correction was tuned by ear on
    /// whatever route was playing at the time, and none recorded which: the
    /// owner's +0.247 s, set for AirPods, would move by about 173 ms on the
    /// built-in speakers the moment the term went live, and no migration can
    /// fix that without knowing the route it was tuned on. And if a player's
    /// reported position already compensates for its output (plausible for
    /// Apple Music through AVFoundation, unknown for Spotify), the term counts
    /// that latency twice for that player. The owner's S-LEAD session — per
    /// player, per route, with CoreAudio's number from the DI_MEDIA trail
    /// beside the by-ear correction — decides both; until then the term is
    /// held at `referenceOutputLatency` and the lead is today's on every
    /// route.
    static let appliesOutputLatency = false
    /// The built-in output's reported latency on the Mac the lab ran on
    /// (27.3 ms): the route the shipped 0.20 s is calibrated against, and
    /// the value the term holds while the live one is not applied.
    static let referenceOutputLatency: TimeInterval = 0.0273
    /// The refresh rate the calibration assumes: every notched MacBook Pro's
    /// panel at ProMotion's ceiling.
    static let referenceFrameRate: Double = 120

    /// The lead every stored correction was tuned against, on the reference
    /// route and display.
    static let calibrationLead: TimeInterval = 0.200

    /// The model the app ships with.
    static var calibrated: LyricLeadModel {
        var model = LyricLeadModel(
            anchorLag: 0.138,
            timerWake: 0.0001,
            frameRate: referenceFrameRate,
            onsetRise: Theme.springRiseTime(
                response: Theme.lyricScrollResponse, damping: Theme.lyricScrollDamping, level: 0.5
            ),
            anticipation: 0.040,
            outputLatency: referenceOutputLatency,
            unmeasuredPlayerDelay: 0
        )
        // The placeholder is whatever made the reference route total exactly
        // `calibrationLead` on the day the model replaced the constant — so
        // about 67.2 ms. It is computed against the spring as it was then
        // (response 0.42, damping 0.86), not against `Theme`'s live values:
        // if the lyric spring is retuned, `onsetRise` moves and the lead
        // moves with it, which is the point of naming the term, rather than
        // this remainder quietly swallowing the change. A rounded literal
        // was tried and missed 0.200 by 0.04 ms, which the lab's
        // owner-calibration check (L7, 1e-9) rightly refused.
        var reference = model
        reference.onsetRise = Theme.springRiseTime(response: 0.42, damping: 0.86, level: 0.5)
        model.unmeasuredPlayerDelay = reference.lead - calibrationLead
        return model
    }

    /// A screen that does not say how fast it refreshes counts as 60 Hz: the
    /// slower guess, so a frame is never assumed shorter than it is.
    private var effectiveFrameRate: Double { frameRate > 0 ? frameRate : 60 }
    /// The mean wait for the next vsync once a line has changed.
    var frameHalf: TimeInterval { 0.5 / effectiveFrameRate }
    /// One frame in the window server's compositor before scan-out
    /// (assumed by the lab; a display-frame probe would measure it).
    var compositor: TimeInterval { 1 / effectiveFrameRate }
    /// The output latency the sum uses: the live one only once it is applied.
    var appliedOutputLatency: TimeInterval {
        Self.appliesOutputLatency ? outputLatency : Self.referenceOutputLatency
    }

    var lead: TimeInterval {
        anchorLag + timerWake + frameHalf + compositor + onsetRise + anticipation
            - appliedOutputLatency - unmeasuredPlayerDelay
    }

    /// One line for the DI_MEDIA trail, every term in milliseconds, so a
    /// live session can read what CoreAudio reported on each route beside
    /// the lead it produced.
    var trail: String {
        func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f", seconds * 1000) }
        return "lyric lead \(ms(lead)) ms = anchorLag \(ms(anchorLag)) + timerWake \(ms(timerWake))"
            + " + frameHalf \(ms(frameHalf)) + compositor \(ms(compositor)) (\(Int(effectiveFrameRate)) Hz)"
            + " + onsetRise \(ms(onsetRise)) + anticipation \(ms(anticipation))"
            + " - outputLatency \(ms(appliedOutputLatency)) (reported \(ms(outputLatency)),"
            + " \(Self.appliesOutputLatency ? "applied" : "not applied"))"
            + " - unmeasuredPlayerDelay \(ms(unmeasuredPlayerDelay))"
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
    /// The interlude playing now — `LyricSweep.interlude(before:in:)` — or
    /// nil while a line is sung, in a breath too short for one, and in the
    /// outro. Always an `.interlude` slot when present.
    var interlude: LyricSlot? = nil
    /// How far through `interlude` the clock is, 0 to 1; 0 without one.
    var progress: Double = 0

    /// The row a surface centres on: the interlude while one plays, the
    /// centre line otherwise. The caption keeps reading `centre` — it has one
    /// line of room, and through a solo that line is the one coming, unswept.
    var centreSlot: LyricSlot { interlude ?? .line(centre) }

    /// The row that is lit: the sung line, or the interlude while one plays.
    var litSlot: LyricSlot? { current.map { .line($0) } ?? interlude }

    /// How far a row stands from the voice, for the depth falloff. With no
    /// line sung every row sits at the far floor: measured from the centre
    /// instead, the opening line came out as the dimmest thing on the card
    /// beside a brighter neighbour, depth inside out.
    func distance(of index: Int) -> Int {
        current.map { abs(index - $0) } ?? 2
    }
}

/// One row of a lyric surface: a line, or the silence before one.
///
/// Slot indices are not line indices. Anything that counts rows — the stage's
/// scroll anchor, the card's window and its jump test, the depth falloff —
/// counts slots; anything that reads a line's words or times reads `.line`'s
/// index into the lines. An interlude is identified by the line it leads to,
/// and carries its own span so a row can be drawn without the lines at hand.
enum LyricSlot: Hashable, Sendable {
    case line(Int)
    case interlude(from: TimeInterval, to: TimeInterval, before: Int)
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

/// How early the island's one-line lyric turns to the next line: "Show next
/// line early" in Settings. Display only; the highlight's timing is not
/// among the things it changes.
///
/// Auto is the default (ly/READ-02). A fixed half second was exactly right on
/// a slow ballad of long lines and a little much on everything else, and the
/// owner would not go below 0.30 s anywhere, so Auto reads the line it is
/// about to show: the longer the line, the longer a person needs to take it
/// in. The two fixed choices remain for a listener who wants the same beat
/// on every line.
enum LyricReadAhead: CaseIterable, Identifiable, Sendable {
    case off
    case auto
    case threeTenths
    case half

    var id: String {
        switch self {
        case .off: return "off"
        case .auto: return "auto"
        case .threeTenths: return "0.3"
        case .half: return "0.5"
        }
    }

    /// The fixed early time of a fixed choice; nil for Auto, which has none
    /// until it is shown a line.
    var fixedSeconds: TimeInterval? {
        switch self {
        case .off: return 0
        case .auto: return nil
        case .threeTenths: return 0.3
        case .half: return 0.5
        }
    }

    /// Auto's floor and ceiling, and the time each visible character adds:
    /// 0.30 s for a few words, 0.50 s from fifty characters, 0.42 s for
    /// thirty. The floor is the owner's ("definitely not lower than 0.30"),
    /// the ceiling the 0.5 s that was perfect on long lines.
    static let automaticFloor: TimeInterval = 0.30
    static let automaticCeiling: TimeInterval = 0.50
    static let automaticPerCharacter: TimeInterval = 0.004

    /// Auto's early time for a line of `count` visible characters, before
    /// `LyricSweep.readAheadStart` applies its caps.
    static func automaticSeconds(forCharacters count: Int) -> TimeInterval {
        min(max(automaticFloor + automaticPerCharacter * Double(max(count, 0)), automaticFloor), automaticCeiling)
    }

    /// How early the caption turns to a line with this text. `Character`s,
    /// not UTF-16 units, so an emoji or an accented letter is one thing to
    /// read, and trimmed, since padding is not read at all.
    func seconds(forNextLine text: String) -> TimeInterval {
        if let fixed = fixedSeconds { return fixed }
        return Self.automaticSeconds(forCharacters: text.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    /// What is kept in defaults, or nil for Auto: an absent key *is* Auto, so
    /// the default needs no write and a build that never heard of Auto reads
    /// a positive number as one of its own fixed values.
    var storedValue: Double? { self == .auto ? nil : fixedSeconds }

    /// The choice a stored value means. Absent (nil) is Auto; 0 or below is
    /// Off; a positive number snaps to the nearer of 0.3 and 0.5, which is
    /// how READ-01's 0.25 s becomes 0.3 s and its 0.75 s becomes 0.5 s. A
    /// value that is not a finite number is the default rather than a wake
    /// armed at an absurd time.
    init(storedValue: Double?) {
        guard let value = storedValue, value.isFinite else { self = .auto; return }
        if value <= 0 { self = .off; return }
        self = abs(value - 0.3) < abs(value - 0.5) ? .threeTenths : .half
    }

    var title: String {
        switch self {
        case .off: return localized("Off")
        case .auto: return localized("Auto")
        case .threeTenths: return localized("0.3 s")
        case .half: return localized("0.5 s")
        }
    }
}
