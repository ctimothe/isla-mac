import Foundation
import XCTest
@testable import IslaKit

/// L1 and L2 of the Lyrics Accuracy Lab: does Isla read every timestamp the
/// file holds, to the millisecond, and does its search name the right line
/// for every moment of every track. Skipped unless `ISLA_LYRIC_CORPUS` is set.
@MainActor
final class LyricAccuracyLabParseTests: XCTestCase {

    // MARK: - L1 parse fidelity

    /// Isla's real LRCLIB path against an independent reader of the raw
    /// `syncedLyrics`: same lines, same timestamps to the millisecond, same
    /// text — and every way the two can differ, counted by class.
    func testL1ParseFidelity() throws {
        let tracks = try LyricLab.tracks()
        var classes: [String: [String: Int]] = [:]
        func count(_ name: String, lines: Int = 1, track: Bool = true) {
            var entry = classes[name] ?? ["tracks": 0, "lines": 0]
            if track { entry["tracks", default: 0] += 1 }
            entry["lines", default: 0] += lines
            classes[name] = entry
        }
        var outcomes: [String: Int] = [:]
        var refusals: [String: Int] = [:]
        var refusedIDs: [String: [Int]] = [:]
        var compared = 0, linesCompared = 0
        var stampErrorsMs: [Double] = []
        var countMismatch = 0, stampMismatch = 0, textMismatch = 0
        var mismatchTracks: [Int: [String: Int]] = [:]
        var missingInIsla = 0, extraInIsla = 0
        var noSynced = 0
        var perCategoryRejected: [String: Int] = [:]

        for track in tracks {
            guard let synced = track.synced, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                noSynced += 1
                continue
            }
            let reference = ReferenceLRC.parse(synced)
            let isla = LyricLab.islaParse(track)
            outcomes[isla.outcome, default: 0] += 1

            // The classes, counted from the reference regardless of outcome.
            if reference.hasBOM { count("bom") }
            if reference.hasCR { count("crlf_or_cr") }
            if reference.hasOffsetTag { count("offset_tag") }
            if reference.multiStampLines > 0 { count("multiple_timestamps_on_one_line", lines: reference.multiStampLines) }
            if let three = reference.fractionDigits[3], three > 0 { count("three_digit_milliseconds", lines: three) }
            if let one = reference.fractionDigits[1], one > 0 { count("one_digit_fraction", lines: one) }
            if let none = reference.fractionDigits[0], none > 0 { count("no_fraction", lines: none) }
            if reference.colonFractionStamps > 0 { count("colon_fraction_mm_ss_ff", lines: reference.colonFractionStamps) }
            let empties = reference.emptyEntries.count
            if empties > 0 { count("empty_lines_dropped", lines: empties) }
            if reference.outOfOrder { count("out_of_order_stamps") }
            let sung = reference.sung
            // Counted on the rows, before equal stamps merge into one line,
            // so the class still says how many files carry them.
            let rows = reference.sungRows
            var duplicates = 0
            for index in rows.indices.dropFirst() where rows[index].ms == rows[index - 1].ms { duplicates += 1 }
            if duplicates > 0 { count("duplicate_stamps", lines: duplicates) }
            let beyond = track.duration > 0 ? sung.filter { Double($0.ms) / 1000 > track.duration }.count : 0
            if beyond > 0 { count("lines_beyond_track_duration", lines: beyond) }
            if reference.untimedTextLines > 0 { count("untimed_text_lines", lines: reference.untimedTextLines) }
            if reference.angleBracketLines > 0 { count("angle_brackets_in_text", lines: reference.angleBracketLines) }
            let unknownTags = reference.metadataTags.filter { !["ti", "ar", "al", "ve", "length", "offset"].contains($0.key) }
            if !unknownTags.isEmpty { count("metadata_tags_isla_does_not_know", lines: unknownTags.values.reduce(0, +)) }

            guard let lines = isla.lines else {
                // A file the reference reads words from and Isla refuses is the
                // whole song lost, not a line.
                if !sung.isEmpty {
                    let reason = isla.error ?? isla.outcome
                    refusals[reason, default: 0] += 1
                    refusedIDs[reason, default: []].append(track.id)
                    perCategoryRejected[track.category, default: 0] += 1
                    LyricLab.finding("L1 track \(track.id): Isla refused (\(reason)); reference read \(sung.count) lines")
                }
                continue
            }
            compared += 1
            if lines.count != sung.count {
                countMismatch += 1
                mismatchTracks[track.id] = [
                    "isla": lines.count, "reference": sung.count,
                    "untimedTextLines": reference.untimedTextLines,
                    "unparseableStampLines": reference.unparseableStampLines,
                    "metadataTags": reference.metadataTags.values.reduce(0, +),
                    "firstDivergingLine": zip(lines, sung).enumerated().first {
                        abs($0.element.0.at * 1000 - Double($0.element.1.ms)) > 0.5
                    }?.offset ?? -1,
                ]
                LyricLab.finding("L1 track \(track.id): Isla \(lines.count) lines, reference \(sung.count)")
            }
            // Aligned by time, so one lost line counts once rather than
            // shifting every line after it out of step.
            var i = 0, r = 0
            while i < lines.count || r < sung.count {
                if i < lines.count, r < sung.count {
                    let error = abs(lines[i].at * 1000 - Double(sung[r].ms))
                    if error <= 0.5 {
                        linesCompared += 1
                        stampErrorsMs.append(error)
                        if lines[i].text != sung[r].text {
                            textMismatch += 1
                            LyricLab.finding("L1 track \(track.id) line \(sung[r].sourceLine): text differs")
                        }
                        i += 1; r += 1
                        continue
                    }
                    stampMismatch += 1
                    if Double(sung[r].ms) < lines[i].at * 1000 {
                        missingInIsla += 1
                        LyricLab.finding("L1 track \(track.id) line \(sung[r].sourceLine): missing from Isla's timeline")
                        r += 1
                    } else {
                        extraInIsla += 1
                        i += 1
                    }
                } else if r < sung.count {
                    stampMismatch += 1; missingInIsla += 1; r += 1
                } else {
                    stampMismatch += 1; extraInIsla += 1; i += 1
                }
            }
        }

        let rejected = refusals.values.reduce(0, +)
        let verdict: String
        if rejected > 0 || countMismatch > 0 || stampMismatch > 0 || textMismatch > 0 {
            verdict = "fail"
        } else if (classes["empty_lines_dropped"]?["lines"] ?? 0) > 0
                    || (classes["lines_beyond_track_duration"]?["lines"] ?? 0) > 0 {
            verdict = "concern"
        } else {
            verdict = "pass"
        }
        let summary = "\(tracks.count) tracks; Isla accepted \(compared), refused \(rejected) the reference reads; "
            + "\(linesCompared) lines matched to the ms with \(textMismatch) text mismatches; "
            + "\(missingInIsla) sung lines missing from Isla (\(countMismatch) tracks), \(extraInIsla) extra; "
            + "\(classes["empty_lines_dropped"]?["lines"] ?? 0) empty gap stamps dropped by design"
        LyricLab.write(section: "L1_parse_fidelity", [
            "tracks": tracks.count,
            "tracksWithoutSyncedLyrics": noSynced,
            "islaOutcomes": outcomes,
            "tracksCompared": compared,
            "linesCompared": linesCompared,
            "lineCountMismatches": countMismatch,
            "unalignedStamps": stampMismatch,
            "sungLinesMissingFromIsla": missingInIsla,
            "linesOnlyInIsla": extraInIsla,
            "textMismatches": textMismatch,
            "lineCountMismatchTracks": Dictionary(uniqueKeysWithValues: mismatchTracks.map { (String($0.key), $0.value) }),
            "timestampAbsErrorMs": LabStats.summary(stampErrorsMs),
            "refusedByIsla": refusals,
            "refusedIDs": refusedIDs,
            "refusedPerCategory": perCategoryRejected,
            "discrepancyClasses": classes,
            "verdict": verdict,
            "summary": summary,
        ])
    }

    // MARK: - L2 index exactness

    /// Every boundary to the millisecond, 2000 random seeks against a linear
    /// scan, a 1 ms sweep of each whole track, and the three entry points that
    /// answer "which line" held against each other.
    func testL2IndexExactness() throws {
        let accepted = try LyricLab.acceptedTracks()
        var boundaryChecks = 0, boundaryOracleMisses = 0
        var boundaryNotThisLine = 0, boundaryBeforeNotPrevious = 0
        var shadowedLines = 0, shadowedTracks: [Int] = []
        var randomChecks = 0, randomMisses = 0
        var sweepEvaluations = 0, monotonicViolations = 0, sweepOracleMisses = 0
        var entryPointDisagreements: [String: Int] = [
            "index_vs_LyricsStore.current": 0,
            "moment.current_vs_index": 0,
            "moment.dark_without_an_end": 0,
            "moment_vs_displayed.line": 0,
            "displayed.swept_vs_moment.current": 0,
            "displayed.end_vs_LyricSweep.end": 0,
        ]

        func oracle(_ lines: [LyricsStore.Line], _ at: TimeInterval) -> Int? {
            var found: Int?
            for (index, line) in lines.enumerated() where line.at <= at { found = index }
            return found
        }

        for (track, lines) in accepted {
            // Boundaries.
            var shadowedHere = 0
            for (i, line) in lines.enumerated() {
                let t = line.at
                boundaryChecks += 1
                let at = LyricSweep.index(in: lines, at: t)
                let before = LyricSweep.index(in: lines, at: t - 0.001)
                if at != oracle(lines, t) || before != oracle(lines, t - 0.001) { boundaryOracleMisses += 1 }
                if at != i {
                    // Only a later line with the same stamp can take a
                    // boundary from its own line; that line is never shown.
                    boundaryNotThisLine += 1
                    if i + 1 < lines.count, lines[i + 1].at == t { shadowedHere += 1 }
                }
                let expectedBefore: Int? = i == 0 ? nil : i - 1
                if before != expectedBefore, !(i > 0 && lines[i - 1].at > t - 0.001) {
                    boundaryBeforeNotPrevious += 1
                }
            }
            if shadowedHere > 0 { shadowedLines += shadowedHere; shadowedTracks.append(track.id) }

            // Random seeks, and the three entry points against each other.
            var random = LabRandom(seed: UInt64(truncatingIfNeeded: track.id))
            let end = max(track.duration, lines.last!.at) + 5
            for _ in 0..<2000 {
                let at = -2 + random.unit() * (end + 2)
                randomChecks += 1
                let index = LyricSweep.index(in: lines, at: at)
                if index != oracle(lines, at) { randomMisses += 1 }
                let current = LyricsStore.current(in: lines, at: at)
                if current.line != index.map({ lines[$0] }) { entryPointDisagreements["index_vs_LyricsStore.current", default: 0] += 1 }
                // Since line ends (LY-05) the moment may call nothing current
                // while `index` still names the line before: only after that
                // line's honoured end. Anything else is a disagreement.
                let moment = LyricSweep.moment(in: lines, at: at)
                if let current = moment.current, current != index {
                    entryPointDisagreements["moment.current_vs_index", default: 0] += 1
                }
                if moment.current == nil, let index,
                   !(LyricSweep.effectiveEnd(of: index, in: lines).map { at >= $0 } ?? false) {
                    entryPointDisagreements["moment.dark_without_an_end", default: 0] += 1
                }
                if let shown = LyricSweep.displayed(lines: lines, at: at) {
                    let row = moment.current ?? moment.centre
                    if shown.line != lines[row] { entryPointDisagreements["moment_vs_displayed.line", default: 0] += 1 }
                    if shown.swept != (moment.current != nil) { entryPointDisagreements["displayed.swept_vs_moment.current", default: 0] += 1 }
                    if shown.end != LyricSweep.end(of: row, in: lines) { entryPointDisagreements["displayed.end_vs_LyricSweep.end", default: 0] += 1 }
                }
            }

            // A 1 ms sweep of the whole track: never backwards, and always the
            // line a walking pointer names.
            var pointer = -1
            var previous: Int = -1
            let steps = Int(((end + 1) * 1000).rounded(.up))
            for step in 0...steps {
                let at = -1 + Double(step) / 1000
                while pointer + 1 < lines.count, lines[pointer + 1].at <= at { pointer += 1 }
                let index = LyricSweep.index(in: lines, at: at) ?? -1
                sweepEvaluations += 1
                if index < previous { monotonicViolations += 1 }
                if index != pointer { sweepOracleMisses += 1 }
                previous = index
            }
        }

        let disagreements = entryPointDisagreements.values.reduce(0, +)
        let hardFailures = boundaryOracleMisses + randomMisses + monotonicViolations + sweepOracleMisses + disagreements
        if hardFailures > 0 { LyricLab.finding("L2: \(hardFailures) index disagreements") }
        let verdict = hardFailures > 0 ? "fail" : (shadowedLines > 0 ? "concern" : "pass")
        LyricLab.write(section: "L2_index_exactness", [
            "tracks": accepted.count,
            "boundaryChecks": boundaryChecks,
            "boundaryOracleMisses": boundaryOracleMisses,
            "boundaryIndexNotThisLine": boundaryNotThisLine,
            "boundaryMinus1msNotPreviousLine": boundaryBeforeNotPrevious,
            "shadowedLinesDuplicateStamp": shadowedLines,
            "shadowedTrackIDs": shadowedTracks,
            "randomSeekChecks": randomChecks,
            "randomSeekOracleMisses": randomMisses,
            "sweep1msEvaluations": sweepEvaluations,
            "sweepMonotonicViolations": monotonicViolations,
            "sweepOracleMisses": sweepOracleMisses,
            "entryPointDisagreements": entryPointDisagreements,
            "verdict": verdict,
            "summary": "\(boundaryChecks) boundaries, \(randomChecks) random seeks, \(sweepEvaluations) 1 ms steps: "
                + "\(hardFailures) disagreements; \(shadowedLines) lines never reachable (duplicate stamp)",
        ])
    }
}
