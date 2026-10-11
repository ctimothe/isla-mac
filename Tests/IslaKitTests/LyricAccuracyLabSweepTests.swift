import Foundation
import XCTest
@testable import IslaKit

/// L5, L6 and L8 of the Lyrics Accuracy Lab: the sweep inside a line, what a
/// line does after its voice has stopped, and whether the three surfaces agree
/// on all of it. Skipped unless `ISLA_LYRIC_CORPUS` is set.
@MainActor
final class LyricAccuracyLabSweepTests: XCTestCase {

    // MARK: - L5 word sweep

    /// A timed word: where it starts, where its voice ends (the truth the
    /// sweep is judged against), and the `end` handed to Isla.
    private struct TimedWord {
        let text: String
        let start: TimeInterval
        let trueEnd: TimeInterval
        let islaEnd: TimeInterval?
    }

    private struct WordLine {
        let words: [TimedWord]
        let lineEnd: TimeInterval
        let category: String
    }

    func testL5WordSweep() throws {
        let tracks = try LyricLab.tracks()
        let accepted = try LyricLab.acceptedTracks()

        // Real word timing, where the catalogue had any.
        var real: [WordLine] = []
        var realLinesWithWordEnds = 0
        for track in tracks where track.lyricsfile != nil {
            let file = LyricsFile.parse(track.lyricsfile!)
            let sung = file.lines.filter { !$0.isEmpty && $0.startMs != nil }
            for (index, line) in sung.enumerated() where line.words.count >= 1 {
                let starts = line.words.compactMap(\.startMs)
                guard starts.count == line.words.count else { continue }
                let next = index + 1 < sung.count ? Double(sung[index + 1].startMs!) / 1000 : Double(line.endMs ?? starts.last! + 2000) / 1000
                var words: [TimedWord] = []
                for (k, word) in line.words.enumerated() {
                    let start = Double(word.startMs!) / 1000
                    let following = k + 1 < line.words.count ? Double(line.words[k + 1].startMs!) / 1000 : (line.endMs.map { Double($0) / 1000 } ?? next)
                    let end = word.endMs.map { Double($0) / 1000 } ?? following
                    if word.endMs != nil { realLinesWithWordEnds += 1 }
                    let text = word.text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    words.append(TimedWord(text: text, start: start, trueEnd: min(end, next), islaEnd: nil))
                }
                if !words.isEmpty { real.append(WordLine(words: words, lineEnd: next, category: track.category)) }
            }
        }

        // SYNTHETIC: Enhanced-LRC words derived from real line timings, the
        // line's slot shared out by estimated syllables, the voice taken to
        // fill 85% of the slot. The shape of real singing is not claimed.
        var syntheticNil: [WordLine] = []
        var syntheticEnded: [WordLine] = []
        for (track, lines) in accepted {
            for (index, line) in lines.enumerated() {
                let end = LyricSweep.end(of: index, in: lines)
                let tokens = Self.wordTokens(line.text)
                guard !tokens.isEmpty, end > line.at else { continue }
                let weights = tokens.map { Double(Self.syllables($0)) }
                let total = weights.reduce(0, +)
                let voiced = (end - line.at) * 0.85
                var cursor = line.at
                var withNil: [TimedWord] = [], withEnd: [TimedWord] = []
                for (token, weight) in zip(tokens, weights) {
                    let length = voiced * weight / total
                    // Each word voiced for 90% of its share, so word ends are
                    // real gaps the `end` field can describe.
                    let wordEnd = cursor + length * 0.9
                    withNil.append(TimedWord(text: token, start: cursor, trueEnd: wordEnd, islaEnd: nil))
                    withEnd.append(TimedWord(text: token, start: cursor, trueEnd: wordEnd, islaEnd: wordEnd))
                    cursor += length
                }
                syntheticNil.append(WordLine(words: withNil, lineEnd: end, category: track.category))
                syntheticEnded.append(WordLine(words: withEnd, lineEnd: end, category: track.category))
            }
        }

        let realResult = Self.judge(real)
        let nilResult = Self.judge(syntheticNil)
        let endedResult = Self.judge(syntheticEnded)
        let edge = Self.karaokeEdge(Array(syntheticEnded.prefix(4000)))

        // Equal lengths, different durations: the edge must cross the long
        // word slower, and stand at each word's half on each word's midpoint.
        let pair = [LyricWord(at: 0, text: "abcd", end: 0.2), LyricWord(at: 0.2, text: "efgh", end: 1.2)]
        let equalLength: [String: Double] = [
            "fractionAtShortMidpoint": LyricSweep.wordFraction(words: pair, at: 0.1, lineEnd: 1.2),
            "fractionAtLongMidpoint": LyricSweep.wordFraction(words: pair, at: 0.7, lineEnd: 1.2),
            "expectedShort": 0.25, "expectedLong": 0.75,
        ]
        let equalLengthOK = abs(equalLength["fractionAtShortMidpoint"]! - 0.25) < 1e-9
            && abs(equalLength["fractionAtLongMidpoint"]! - 0.75) < 1e-9
        // A word shorter than the 50 ms floor: its edge leaps at its end.
        let blink = [LyricWord(at: 0, text: "ab", end: 0.01), LyricWord(at: 0.01, text: "cd", end: 0.5)]
        let blinkBefore = LyricSweep.wordFraction(words: blink, at: 0.0099, lineEnd: 0.5)
        let blinkAfter = LyricSweep.wordFraction(words: blink, at: 0.0100, lineEnd: 0.5)

        let invariantFailures = [realResult, nilResult, endedResult].reduce(0) {
            $0 + ($1["monotonicViolations"] as! Int) + ($1["nonZeroBeforeStart"] as! Int)
                + ($1["reachedOneEarly"] as! Int) + ($1["reachedOneLate"] as! Int)
        }
        if invariantFailures > 0 || !equalLengthOK { LyricLab.finding("L5: \(invariantFailures) sweep invariant failures") }
        let verdict = invariantFailures > 0 || !equalLengthOK ? "fail" : "concern"
        LyricLab.write(section: "L5_word_sweep", [
            "reachableForLRCLIB": false,
            "whyNotReachable": "LyricsPresentation.usesWordTiming needs granularity .word, precision sync and the karaoke switch; an LRCLIB timeline is .line (OnlineLyrics.swift:15-17), so every LRCLIB line is drawn fully lit (fraction 1) for its whole slot",
            "real": realResult.merging([
                "label": "REAL word timing from lyricsfile",
                "tracksWithHasWordSync": tracks.filter(\.hasWordSync).count,
                "wordsWithEndMs": realLinesWithWordEnds,
            ]) { a, _ in a },
            "syntheticEndNil": nilResult.merging(["label": "SYNTHETIC, word end nil (what Isla's LRC parser produces)"]) { a, _ in a },
            "syntheticEndSet": endedResult.merging(["label": "SYNTHETIC, word end set to the voice's end"]) { a, _ in a },
            "jumpThreshold": "a frame-to-frame advance more than one character beyond what the true word timing advances in that frame: one glyph is the smallest step a reader sees as a jump rather than motion",
            "equalLengthDifferentDurations": equalLength.merging(["ok": equalLengthOK ? 1 : 0]) { a, _ in a },
            "subFloorWord": ["fractionJustBeforeEnd": blinkBefore, "fractionAtEnd": blinkAfter,
                             "note": "a word under 50 ms reaches only (duration/0.05) of its share, then leaps to full at its end"],
            "karaokeEdge": edge,
            "verdict": verdict,
            "summary": "real word lines \(realResult["lines"] ?? 0), synthetic \(nilResult["lines"] ?? 0); invariant failures \(invariantFailures); "
                + "end=nil max deviation \(fmt((nilResult["deviationChars"] as? [String: Any])?["max"])) chars vs end set \(fmt((endedResult["deviationChars"] as? [String: Any])?["max"])); "
                + "edge lag p50 \(fmt((edge["lagMs"] as? [String: Any])?["p50"])) ms, p95 \(fmt((edge["lagMs"] as? [String: Any])?["p95"])) ms at 120 Hz (PRODUCTION, per frame)",
        ])
    }

    /// Runs every invariant over a set of word lines.
    private static func judge(_ lines: [WordLine]) -> [String: Any] {
        let frame = 1.0 / 120
        var monotonic = 0, beforeStart = 0, early = 0, late = 0, cumulative = 0
        var deviations: [Double] = [], excessJumps: [Double] = [], jumpsOverOneChar = 0, linesOverOneChar = 0
        var perCategory: [String: [Double]] = [:]
        var wordsUnderFloor = 0, wordCount = 0
        for line in lines {
            wordCount += line.words.count
            wordsUnderFloor += line.words.filter { $0.trueEnd - $0.start < 0.05 }.count
            let words = line.words.map { LyricWord(at: $0.start, text: $0.text, end: $0.islaEnd) }
            let counts = words.map { Double($0.text.count) }
            let total = counts.reduce(0, +)
            guard total > 0 else { continue }
            func isla(_ t: Double) -> Double { LyricSweep.wordFraction(words: words, at: t, lineEnd: line.lineEnd) }
            func ideal(_ t: Double) -> Double {
                var sung = 0.0
                for (k, word) in line.words.enumerated() {
                    if t >= word.trueEnd { sung += counts[k]; continue }
                    if t > word.start { sung += counts[k] * min((t - word.start) / max(word.trueEnd - word.start, 1e-9), 1) }
                    break
                }
                return sung / total
            }
            // Isla's own end for each word: min(end ?? next start, next start).
            let effectiveEnds: [Double] = words.indices.map { k in
                let next = k + 1 < words.count ? words[k + 1].at : line.lineEnd
                return min(words[k].end ?? next, next)
            }
            var times: [Double] = []
            var t = line.words[0].start - 0.05
            while t <= line.lineEnd + 0.05 { times.append(t); t += frame }
            for (k, word) in words.enumerated() {
                times += [word.at - 0.001, word.at, word.at + 0.001,
                          effectiveEnds[k] - 0.001, effectiveEnds[k], effectiveEnds[k] + 0.001]
            }
            times.sort()
            var last = -1.0
            var firstOne: Double?
            var maxDeviation = 0.0
            for time in times {
                let value = isla(time)
                if value < last - 1e-12 { monotonic += 1 }
                last = value
                if time < words[0].at, value != 0 { beforeStart += 1 }
                if firstOne == nil, value >= 1 - 1e-12 { firstOne = time }
                maxDeviation = max(maxDeviation, abs(value - ideal(time)) * total)
            }
            let lastEnd = effectiveEnds.last!
            if let firstOne {
                if firstOne < lastEnd - 1e-9 { early += 1 }
                if firstOne > lastEnd + frame + 1e-9 { late += 1 }
            } else {
                late += 1
            }
            var running = 0.0
            for (k, end) in effectiveEnds.enumerated() {
                running += counts[k]
                if abs(isla(end) - running / total) > 1e-9 { cumulative += 1 }
            }
            // Frame-to-frame advance against the truth's.
            var previousTime = times.first!
            var frameTime = line.words[0].start
            while frameTime <= line.lineEnd {
                let next = frameTime + frame
                let excess = (isla(next) - isla(frameTime) - (ideal(next) - ideal(frameTime))) * total
                excessJumps.append(excess)
                if excess > 1 { jumpsOverOneChar += 1 }
                previousTime = frameTime
                frameTime = next
            }
            _ = previousTime
            deviations.append(maxDeviation)
            perCategory[line.category, default: []].append(maxDeviation)
            if maxDeviation > 1 { linesOverOneChar += 1 }
        }
        return [
            "lines": lines.count,
            "words": wordCount,
            "wordsVoicedUnder50ms": wordsUnderFloor,
            "monotonicViolations": monotonic,
            "nonZeroBeforeStart": beforeStart,
            "reachedOneEarly": early,
            "reachedOneLate": late,
            "cumulativeShareMismatchAtWordEnd": cumulative,
            "deviationChars": LabStats.summary(deviations),
            "linesDeviatingOverOneChar": linesOverOneChar,
            "perCategoryDeviationChars": perCategory.mapValues { LabStats.summary($0) },
            "frameExcessAdvanceChars120Hz": LabStats.summary(excessJumps),
            "framesJumpingOverOneChar": jumpsOverOneChar,
        ]
    }

    /// The edge the sung row draws, sampled from production at simulated
    /// display frames — not a model of it.
    ///
    /// Until LY-12 this was a MODEL of `KaraokeText`'s `.linear(duration:
    /// 0.25)` ramp re-aimed by every 0.1 s publish (additive 0.25 s ramps, one
    /// per publish): lag p50 175 ms, p95 196 ms. The edge is now placed by the
    /// clock on every frame, and restating that rule here to measure it would
    /// measure the restatement. So each frame calls the closure the surfaces
    /// hand `KaraokeText` — `LyricSweep.liveFraction` over
    /// `LyricSweep.frameClock`, which reads `MediaController.extrapolatedPosition`
    /// — on a real `MediaController` whose monotonic clock is set to the
    /// frame's instant. What that frame draws stays on screen until the next
    /// one replaces it, so it is judged at four moments through the frame
    /// against the true edge at each: the lag is how long ago the truth stood
    /// where the drawn edge stands. The lead is 0 here because placing the
    /// line against the voice is L7's question; this asks only whether the
    /// edge keeps up with the clock it reads.
    private static func karaokeEdge(_ lines: [WordLine]) -> [String: Any] {
        final class Clock { var now: TimeInterval = 0 }
        let clock = Clock()
        let media = MediaController()
        media.lyricsShown = { false }
        media.monotonicNow = { clock.now }
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Lab"
        snapshot.artist = "Lab"
        snapshot.album = "Lab"
        snapshot.duration = 1_000_000
        snapshot.elapsed = 0
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 1
        media.apply(snapshot)
        // Where the anchor landed, aged by the microseconds since `takenAt`:
        // track time t is monotonic time t - base.
        let base = media.extrapolatedPosition()
        guard let frameClock = LyricSweep.frameClock(media: media, lead: 0) else {
            return ["error": "the lab's MediaController is not playing, so no surface would hand a clock"]
        }
        var byRate: [String: Any] = [:]
        var aheadOfTruth = 0
        for rate in [LyricLeadModel.referenceFrameRate, 60] {
            let frame = 1.0 / rate
            var lags: [Double] = []
            for line in lines {
                let words = line.words.map { LyricWord(at: $0.start, text: $0.text, end: $0.islaEnd) }
                let start = line.words[0].start, end = line.lineEnd
                let row = LyricsStore.Line(at: start, text: words.map(\.text).joined(separator: " "), words: words)
                guard let sweep = LyricSweep.liveFraction(line: row, end: end, wordTiming: true, clock: frameClock) else { continue }
                func target(_ t: Double) -> Double { LyricSweep.wordFraction(words: words, at: t, lineEnd: end) }
                var frameTime = start
                while frameTime <= end {
                    clock.now = frameTime - base
                    let drawn = sweep()
                    for hold in [0.25, 0.5, 0.75, 0.999] {
                        let seen = frameTime + hold * frame
                        let truth = target(seen)
                        if drawn > truth + 1e-9 { aheadOfTruth += 1 }
                        // The drawn edge stands where the truth last stood
                        // `lag` ago. Last, not first: through the silence
                        // between two words the truth holds still, and timing
                        // from the start of that plateau charged a frame
                        // drawn just before the next word with the whole gap
                        // (the first run's 221 ms maximum, every one of them
                        // a gap).
                        guard truth > 0.02, truth < 0.98, drawn < truth else { continue }
                        var low = seen - 1.5, high = seen
                        for _ in 0..<30 {
                            let mid = (low + high) / 2
                            if target(mid) <= drawn { low = mid } else { high = mid }
                        }
                        lags.append(seen - low)
                    }
                    frameTime += frame
                }
            }
            byRate["\(Int(rate)) Hz"] = LabStats.summary(lags, scale: 1000)
        }
        return [
            "label": "PRODUCTION (LyricSweep.liveFraction over LyricSweep.frameClock on a MediaController, sampled through each simulated frame)",
            "linesSampled": lines.count,
            "lagMs": byRate["\(Int(LyricLeadModel.referenceFrameRate)) Hz"] ?? [String: Any](),
            "lagMsByFrameRate": byRate,
            "samplesAheadOfTruth": aheadOfTruth,
            "retiredModelLagMs": ["p50": 175, "p95": 196, "note": "the 0.25 s linear ramp over 0.1 s publishes, before LY-12"],
        ]
    }

    /// Words as a sweep would carry them: whitespace-separated, except that
    /// CJK, kana and hangul run one character to a word.
    static func wordTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        for piece in text.split(whereSeparator: \.isWhitespace) {
            var buffer = ""
            for character in piece {
                if character.unicodeScalars.contains(where: isCJK) {
                    if !buffer.isEmpty { tokens.append(buffer); buffer = "" }
                    tokens.append(String(character))
                } else {
                    buffer.append(character)
                }
            }
            if !buffer.isEmpty { tokens.append(buffer) }
        }
        return tokens
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    /// Vowel groups, Latin, Cyrillic and Greek; a CJK character is one; any
    /// other script one per three letters.
    static func syllables(_ word: String) -> Int {
        if word.unicodeScalars.contains(where: isCJK) { return 1 }
        let vowels = Set("aeiouyàáâãäåæèéêëìíîïòóôõöøùúûüýÿаеёиоуыэюяіїєαεηιουω")
        var groups = 0, inVowel = false, letters = 0
        for character in word.lowercased() {
            if character.isLetter { letters += 1 }
            let vowel = vowels.contains(character)
            if vowel, !inVowel { groups += 1 }
            inVowel = vowel
        }
        return groups > 0 ? groups : max(1, letters / 3)
    }

    // MARK: - L6 gap behaviour

    /// After a line's voice has stopped, how long the line stays current —
    /// against two truths: the empty stamps LRCLIB's own `syncedLyrics`
    /// writes at a line's end, and `lyricsfile`'s `end_ms` (which Isla never
    /// decodes, L-12).
    ///
    /// Until 2026-10-11 the parser dropped those stamps and every line held
    /// to the next one's stamp, and this case measured that by assuming it.
    /// It now measures production: a line is shown until
    /// `LyricSweep.effectiveEnd` (less the lead), and `LyricSweep.moment` is
    /// sampled on either side of that instant to prove it is the moment
    /// that draws the line dark, not this case's restatement of it.
    func testL6GapBehaviour() throws {
        let accepted = try LyricLab.acceptedTracks()
        let lead = LyricSweep.lead(precisionSync: false, userOffset: 0)

        struct Tally {
            var tracks = 0
            var tracksWithEndMs = 0
            var tracksWithInformativeEndMs = 0
            var staleSecondsPerTrack: [Double] = []
            var staleFraction: [Double] = []
            var outroStaleSeconds: [Double] = []
            var gapsOver8s = 0
            var outrosOver8s = 0
            var fullyLitSecondsInGapsOver8s: [Double] = []
            var residualAfterEmptyStampClock: [Double] = []
            var residualAfterEndMsClock: [Double] = []
            var stale_emptyStampTruth: [Double] = []
            var stale_endMsTruth: [Double] = []
        }
        var tallies: [String: Tally] = [:]
        var all = Tally()
        var matched = 0, unmatched = 0
        var sweepSpanFinishesEarly = 0, sweepSpanFinishesLate = 0, sweepSpanLines = 0
        var sitsFullSeconds: [Double] = []
        var fractionFullMidGap = 0, midGapChecks = 0
        var honouredEnds = 0, momentChecks = 0, momentDisagreements = 0
        var linesWithEnd = 0, endsUnderMinimumGap = 0, outrosWithoutEnd = 0

        for (track, lines) in accepted {
            let duration = track.duration > 0 ? track.duration : lines.last!.at + 6
            let reference = ReferenceLRC.parse(track.synced ?? "")
            let empties = reference.emptyEntries.map { Double(max(0, $0.ms - reference.offsetMs)) / 1000 }.sorted()
            let file = track.lyricsfile.map(LyricsFile.parse)
            let fileLines = (file?.lines ?? []).filter { !$0.isEmpty && $0.startMs != nil }
            var tally = tallies[track.category] ?? Tally()
            tally.tracks += 1
            all.tracks += 1
            if !fileLines.isEmpty { tally.tracksWithEndMs += 1; all.tracksWithEndMs += 1 }

            var cursor = 0
            var stale = 0.0, staleT1 = 0.0, staleT2 = 0.0, outro = 0.0
            var residualT1 = 0.0, residualT2 = 0.0
            var informative = false
            var litInLongGaps = 0.0
            for (i, line) in lines.enumerated() {
                // A line with no honoured end holds to the next stamp, and the
                // last line the track reaches to the track's end. A file timed
                // past the track's own length is cut at the length.
                let isLast = i + 1 == lines.count || lines[i + 1].at >= duration
                guard line.at < duration else { continue }
                let islaEnd = isLast ? duration : lines[i + 1].at
                guard islaEnd > line.at else { continue }
                let held = islaEnd - (isLast ? 0 : lead)
                if line.end != nil { linesWithEnd += 1 }
                let productionEnd = LyricSweep.effectiveEnd(of: i, in: lines)
                if line.end != nil, productionEnd == nil { endsUnderMinimumGap += 1 }
                if isLast, productionEnd == nil { outrosWithoutEnd += 1 }
                // The clock reads `position + lead`, so the line goes dark at
                // the position `end - lead`.
                let shownUntil = productionEnd.map { min($0 - lead, held) } ?? held
                if let productionEnd, productionEnd - lead < held {
                    honouredEnds += 1
                    // Production's own verdict either side of that instant.
                    for (offset, expected) in [(-0.01, Optional(i)), (0.01, nil)] where productionEnd + offset > line.at {
                        momentChecks += 1
                        let current = LyricSweep.moment(in: lines, at: productionEnd + offset).current
                        if current != expected { momentDisagreements += 1 }
                    }
                }

                // Truth 1: an empty stamp after this line and before the next.
                let t1 = empties.first { $0 > line.at && $0 < islaEnd }
                // Truth 2: this line's end_ms, matched by start within 150 ms.
                var t2: Double?
                while cursor < fileLines.count, Double(fileLines[cursor].startMs!) < line.at * 1000 - 150 { cursor += 1 }
                if cursor < fileLines.count, abs(Double(fileLines[cursor].startMs!) - line.at * 1000) <= 150 {
                    matched += 1
                    if let end = fileLines[cursor].endMs.map({ Double($0) / 1000 }), end < islaEnd {
                        t2 = end
                        if end < islaEnd - 0.1 { informative = true }
                    }
                    cursor += 1
                } else if !fileLines.isEmpty {
                    unmatched += 1
                }
                let truth = [t1, t2].compactMap { $0 }.min()
                if let t1 { staleT1 += max(0, shownUntil - t1) }
                if let t2 { staleT2 += max(0, shownUntil - t2) }
                guard let truth else { continue }
                let lineStale = max(0, shownUntil - truth)
                stale += lineStale
                if isLast {
                    outro += lineStale
                    if lineStale > 8 { tally.outrosOver8s += 1; all.outrosOver8s += 1 }
                } else if lineStale > 8 {
                    tally.gapsOver8s += 1
                    all.gapsOver8s += 1
                    // Line timing draws the row at fraction 1 throughout.
                    litInLongGaps += lineStale
                }
                // A gap-aware clock that ends lines at the empty stamps alone,
                // judged by end_ms; and one that uses end_ms, judged by the stamps.
                if let t2 { residualT1 += max(0, min(shownUntil, t1 ?? shownUntil) - t2) }
                if let t1 { residualT2 += max(0, min(shownUntil, t2 ?? shownUntil) - t1) }

                // The estimate path's sweep, for a line whose voice end is known.
                if let t2, !isLast {
                    sweepSpanLines += 1
                    let span = LyricsStore.sweepSpan(text: line.text, slot: islaEnd - line.at)
                    let voiced = t2 - line.at
                    if span < voiced - 0.1 { sweepSpanFinishesEarly += 1 }
                    if span > voiced + 0.1 { sweepSpanFinishesLate += 1 }
                    sitsFullSeconds.append(max(0, (islaEnd - line.at) - span))
                    if islaEnd - t2 > 1 {
                        midGapChecks += 1
                        let mid = (t2 + islaEnd) / 2
                        if LyricSweep.fraction(line: line, at: mid, end: islaEnd) >= 1 { fractionFullMidGap += 1 }
                    }
                }
            }
            if informative { tally.tracksWithInformativeEndMs += 1; all.tracksWithInformativeEndMs += 1 }
            for target in [0, 1] {
                func add(_ t: inout Tally) {
                    t.staleSecondsPerTrack.append(stale)
                    t.staleFraction.append(stale / duration)
                    t.outroStaleSeconds.append(outro)
                    t.fullyLitSecondsInGapsOver8s.append(litInLongGaps)
                    t.residualAfterEmptyStampClock.append(residualT1)
                    t.residualAfterEndMsClock.append(residualT2)
                    t.stale_emptyStampTruth.append(staleT1)
                    t.stale_endMsTruth.append(staleT2)
                }
                if target == 0 { add(&tally) } else { add(&all) }
            }
            tallies[track.category] = tally
        }

        func describe(_ t: Tally) -> [String: Any] {
            let total = t.staleSecondsPerTrack.reduce(0, +)
            let afterT1 = t.residualAfterEmptyStampClock.reduce(0, +)
            return [
                "tracks": t.tracks,
                "tracksWithLyricsfile": t.tracksWithEndMs,
                "tracksWithInformativeEndMs": t.tracksWithInformativeEndMs,
                "staleSecondsPerTrack": LabStats.summary(t.staleSecondsPerTrack),
                "staleShareOfTrackTime": LabStats.summary(t.staleFraction),
                "outroStaleSecondsPerTrack": LabStats.summary(t.outroStaleSeconds),
                "midSongGapsOver8s": t.gapsOver8s,
                "outrosOver8s": t.outrosOver8s,
                "fullyLitSecondsInGapsOver8sPerTrack": LabStats.summary(t.fullyLitSecondsInGapsOver8s),
                "staleVsEmptyStampTruthPerTrack": LabStats.summary(t.stale_emptyStampTruth),
                "staleVsEndMsTruthPerTrack": LabStats.summary(t.stale_endMsTruth),
                "totalStaleSeconds": total,
                "residualIfLinesEndAtEmptyStamps": afterT1,
                "residualIfLinesEndAtEndMs": t.residualAfterEndMsClock.reduce(0, +),
                "staleRemovedByEmptyStampClockShare": total > 0 ? 1 - afterT1 / total : Double.nan,
            ]
        }
        let overall = describe(all)
        let verdict = all.gapsOver8s > 0 ? "fail" : ((overall["totalStaleSeconds"] as? Double ?? 0) > 0 ? "concern" : "pass")
        if all.gapsOver8s > 0 { LyricLab.finding("L6: \(all.gapsOver8s) lines held current through more than 8 s of silence") }
        if momentDisagreements > 0 { LyricLab.finding("L6: LyricSweep.moment disagrees with effectiveEnd \(momentDisagreements) times") }
        LyricLab.write(section: "L6_gap_behaviour", [
            "lead": lead,
            "definition": "stale = time a line is still drawn current (until LyricSweep.effectiveEnd less the lead when it honours one, otherwise until the next stamp less the lead, and the last line until the track ends) after its voice ended; truth = the earlier of an empty LRC stamp and lyricsfile end_ms",
            "overall": overall,
            "productionEnds": [
                "minimumHonouredGap": LyricSweep.minimumHonouredGap,
                "linesWithEnd": linesWithEnd,
                "honouredEndsBeforeHold": honouredEnds,
                "endsUnderMinimumGap": endsUnderMinimumGap,
                "outrosWithoutEnd": outrosWithoutEnd,
                "momentChecks": momentChecks,
                "momentDisagreesWithEffectiveEnd": momentDisagreements,
            ],
            "perCategory": tallies.mapValues(describe),
            "lyricsfileLineMatch": ["matched": matched, "unmatched": unmatched, "toleranceMs": 150],
            "estimateSweepPath": [
                "note": "LyricSweep.fraction without word timing (LyricsStore.sweepSpan); unreachable from the views for LRCLIB, measured for completeness",
                "linesWithKnownEnd": sweepSpanLines,
                "finishesMoreThan100msBeforeVoiceEnds": sweepSpanFinishesEarly,
                "finishesMoreThan100msAfterVoiceEnds": sweepSpanFinishesLate,
                "sitsFullSecondsPerLine": LabStats.summary(sitsFullSeconds),
                "fullAtMidGap": fractionFullMidGap,
                "midGapChecks": midGapChecks,
            ],
            "verdict": verdict,
            "summary": "\(all.tracks) tracks: stale p50 \(fmt((overall["staleSecondsPerTrack"] as? [String: Any])?["p50"])) s/track, "
                + "share p50 \(fmt((overall["staleShareOfTrackTime"] as? [String: Any])?["p50"])), \(all.gapsOver8s) mid-song lines lit through >8 s of silence, \(all.outrosOver8s) outros; "
                + "ending lines at the empty stamps Isla already receives removes \(fmt(overall["staleRemovedByEmptyStampClockShare"])) of it",
        ])
    }

    // MARK: - L8 cross-surface agreement

    /// The island's stage, the caption and the lock card, handed the same
    /// moment, the same lines and the same settings: do they draw the same
    /// row as sung, with the same sweep?
    func testL8CrossSurfaceAgreement() throws {
        let accepted = try LyricLab.acceptedTracks()
        struct Config { let name: String; let precision: Bool; let userOffset: Double; let wordTiming: Bool }
        let configs = [
            Config(name: "standard", precision: false, userOffset: 0, wordTiming: false),
            Config(name: "precision", precision: true, userOffset: 0, wordTiming: false),
            // The owner's AirPods calibration: −0.247 s when the lead added the
            // correction, +0.247 s of delay since the 2026-10-11 sign migration.
            // Same effective lead, −0.047 s.
            Config(name: "owner +0.247", precision: false, userOffset: 0.247, wordTiming: false),
            Config(name: "word timing (SYNTHETIC words)", precision: true, userOffset: 0, wordTiming: true),
        ]
        var samples = 0
        var disagreements: [String: Int] = [:]
        var introSecondsCardLitStageNone: [Double] = []
        var otherDisagreementTracks = Set<Int>()

        for (track, plainLines) in accepted {
            // Word lines for the word-timing configuration, synthetic as in L5.
            let wordLines: [LyricsStore.Line] = plainLines.enumerated().map { index, line in
                let end = LyricSweep.end(of: index, in: plainLines)
                let tokens = Self.wordTokens(line.text)
                guard !tokens.isEmpty else { return line }
                let weights = tokens.map { Double(Self.syllables($0)) }
                let total = weights.reduce(0, +)
                var cursor = line.at
                var words: [LyricWord] = []
                for (token, weight) in zip(tokens, weights) {
                    words.append(LyricWord(at: cursor, text: token, end: nil))
                    cursor += (end - line.at) * 0.85 * weight / total
                }
                var copy = line
                copy.words = words
                return copy
            }
            var random = LabRandom(seed: UInt64(truncatingIfNeeded: track.id) &+ 99)
            let duration = max(track.duration, plainLines.last!.at + 2)
            for config in configs {
                let lines = config.wordTiming ? wordLines : plainLines
                let lead = LyricSweep.lead(precisionSync: config.precision, userOffset: config.userOffset)
                var positions: [Double] = (0..<300).map { _ in random.unit() * duration }
                for line in lines { positions += [line.at - lead - 0.0005, line.at - lead, line.at - lead + 0.0005] }
                positions += [0, max(0, lines[0].at - lead - 0.5)]
                for position in positions {
                    let inputs = LabSurfaces.Inputs(
                        position: position, precisionSync: config.precision,
                        userOffset: config.userOffset, trackOffset: 0, wordTiming: config.wordTiming
                    )
                    let stage = LabSurfaces.stage(lines, inputs)
                    let caption = LabSurfaces.caption(lines, inputs)
                    let card = LabSurfaces.lockCard(lines, inputs)
                    samples += 1
                    if stage == caption && caption == card { continue }
                    let beforeFirst = stage.current == nil
                    let key = "\(config.name): " + (beforeFirst
                        ? "before first line: stage \(stage.current.map(String.init) ?? "none")/\(stage.fraction), caption \(caption.current.map(String.init) ?? "none")/\(caption.fraction), card \(card.current.map(String.init) ?? "none")/\(card.fraction)"
                        : "index or fraction differs")
                    disagreements[key, default: 0] += 1
                    if !beforeFirst { otherDisagreementTracks.insert(track.id) }
                }
                if config.name == "standard" {
                    // Measured, not assumed: the intro counts only when the
                    // card, probed halfway through it, draws a sung line while
                    // the stage draws none. This used to append the intro's
                    // length unconditionally, which was true of the card
                    // before LY-04 and would have gone on reporting 12.9 s
                    // after it.
                    let intro = max(0, plainLines[0].at - lead)
                    let probe = LabSurfaces.Inputs(
                        position: intro / 2, precisionSync: config.precision,
                        userOffset: config.userOffset, trackOffset: 0, wordTiming: false
                    )
                    let cardLitStageNone = LabSurfaces.lockCard(plainLines, probe).current != nil
                        && LabSurfaces.stage(plainLines, probe).current == nil
                    introSecondsCardLitStageNone.append(cardLitStageNone ? intro : 0)
                }
            }
        }
        let total = disagreements.values.reduce(0, +)
        if total > 0 { LyricLab.finding("L8: \(total) cross-surface disagreements") }
        LyricLab.write(section: "L8_cross_surface_agreement", [
            "samples": samples,
            "disagreements": disagreements,
            "tracksWithDisagreementAfterFirstLine": otherDisagreementTracks.sorted(),
            "introSecondsWhereCardDrawsLineOneSungPerTrack": LabStats.summary(introSecondsCardLitStageNone),
            // Until LY-04 (2026-10-11) each view restated the clock inline and
            // this listed where; the card called its centre current and drew
            // line 1 sung through every intro. All three now resolve through
            // the statics below, which LabSurfaces calls directly.
            "surfaceResolvers": [
                "LyricsStage.resolve(lines:inputs:)",
                "MediaPane.captionResolution(lines:inputs:)",
                "LockScreenCard.resolve(lines:inputs:)",
                "each one LyricSweep.resolve: current from the one search, centre = current ?? 0, sweep from LyricSweep.drawnFraction",
            ],
            "verdict": total > 0 ? "fail" : "pass",
            "summary": "\(samples) samples × 3 surfaces: \(total) disagreements, \(otherDisagreementTracks.count) tracks disagreeing after the first line; "
                + "intro where the lock card draws line 1 as sung while the stage draws none: p50 \(fmt(LabStats.summary(introSecondsCardLitStageNone)["p50"])) s/track",
        ])
    }
}
