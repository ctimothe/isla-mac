import Foundation
import XCTest
@testable import IslaKit

/// M3 (fidelity): does Isla turn a word-timed LRCLIB record into a `.word`
/// timeline with the right word starts?
///
/// Every record under `wordtimed/` goes through four questions, none of which
/// needs the network:
///
/// - **(a) The online path.** The record's bytes through
///   `OnlineLyrics.timeline(from:status:duration:)`, the function every
///   lookup reads an answer with. What granularity does a listener get?
/// - **(b) The local-document parser**, for records whose `syncedLyrics` is
///   an enhanced LRC: `LocalLyricsDocument.parse`. Does it give `.word`, does
///   it refuse (and why), how many words match the lab's independent reader,
///   and how far off is each word's start?
/// - **(c) `lyricsfile`.** Does any Isla API read it at all? Answered by
///   scanning `Sources/` rather than by assertion, so the finding goes stale
///   loudly: if a later release starts reading the field, the count changes.
/// - **(d) Agreement.** Where one record carries both an enhanced LRC and a
///   `lyricsfile` with words, do the two agree?
///
/// The independent reader is `ReferenceLRC` (line stamps, offset, text) plus
/// `referenceWords` below, which extracts each word's start from the raw line
/// with a regular expression and integer arithmetic. `ReferenceLRC` keeps no
/// per-word times (it joins a word-timed line to its text), so word starts need
/// a reader of their own; it shares nothing with `LocalLyricsDocument`.
///
/// The results hold counts, ids and millisecond errors, never a word.
@MainActor
final class LyricMatchLabWordTests: XCTestCase {
    // MARK: - The independent word reader

    struct ReferenceWord {
        let ms: Int
        let text: String
    }

    private static let markerPattern = try! NSRegularExpression(
        pattern: #"<\s*([0-9]+):([0-9]{1,2})(?:[.,:]([0-9]{0,3}))?\s*>"#
    )
    private static let stampPrefix = try! NSRegularExpression(
        pattern: #"^(?:\s*\[\s*[0-9]+:[0-9]{1,2}(?:[.,:][0-9]{0,3})?\s*\])+"#
    )

    /// `mm:ss`, `mm:ss.f`, `mm:ss.ff`, `mm:ss.fff` to integer milliseconds,
    /// from the digits themselves and never through a floating-point seconds
    /// value, so "the same start to the millisecond" has an exact meaning.
    private static func milliseconds(minutes: String, seconds: String, fraction: String) -> Int {
        let fractionMs: Int
        switch fraction.count {
        case 0: fractionMs = 0
        case 1: fractionMs = (Int(fraction) ?? 0) * 100
        case 2: fractionMs = (Int(fraction) ?? 0) * 10
        default: fractionMs = Int(fraction) ?? 0
        }
        return (Int(minutes) ?? 0) * 60_000 + (Int(seconds) ?? 0) * 1_000 + fractionMs
    }

    /// The words of one raw LRC line that opens with `<mm:ss.xx>` markers, in
    /// order, each with the start its marker names, the offset applied. A
    /// marker followed by nothing (an end marker) names no word and is skipped.
    static func referenceWords(inRawLine raw: String, offsetMs: Int) -> [ReferenceWord] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        var content = line as NSString
        if let prefix = stampPrefix.firstMatch(in: line, range: NSRange(location: 0, length: content.length)) {
            content = content.substring(from: prefix.range.upperBound) as NSString
        }
        let full = NSRange(location: 0, length: content.length)
        let markers = markerPattern.matches(in: content as String, range: full)
        var words: [ReferenceWord] = []
        for (index, marker) in markers.enumerated() {
            let from = marker.range.upperBound
            let to = index + 1 < markers.count ? markers[index + 1].range.lowerBound : content.length
            let text = content.substring(with: NSRange(location: from, length: max(0, to - from)))
            guard !text.isEmpty else { continue }
            func group(_ n: Int) -> String {
                let range = marker.range(at: n)
                return range.location == NSNotFound ? "" : content.substring(with: range)
            }
            let ms = milliseconds(minutes: group(1), seconds: group(2), fraction: group(3))
            words.append(ReferenceWord(ms: max(0, ms - offsetMs), text: text))
        }
        return words
    }

    /// The word-timed rows of an LRC as the reference reads them: the line
    /// stamp (offset applied) and the words with their starts.
    static func referenceRows(of synced: String) -> [(ms: Int, words: [ReferenceWord])] {
        let reference = ReferenceLRC.parse(synced)
        // `sourceLine` counts the lines the way the reference split them; the
        // same split recovers the raw text of a row.
        let rawLines = synced.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return reference.sungRows.filter(\.wordTimed).compactMap { row in
            guard row.sourceLine < rawLines.count else { return nil }
            let words = referenceWords(inRawLine: rawLines[row.sourceLine], offsetMs: reference.offsetMs)
            return words.isEmpty ? nil : (row.ms, words)
        }
    }

    // MARK: - Finding (c): does Isla read `lyricsfile`?

    /// `Sources/`, found from this file's own path so the scan follows the
    /// checkout the test was built from.
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    /// `file:line` of the first line of `file` (under `Sources/`) containing `marker`.
    static func sourceLocation(file: String, marker: String) -> String? {
        let url = sourcesRoot.appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains(marker) {
            return "Sources/\(file):\(index + 1)"
        }
        return nil
    }

    /// The files under `Sources/` that name the field, and where the two
    /// decoders an LRCLIB answer goes through are declared.
    ///
    /// The match is on the field's spelling as a whole word, `lyricsfile` or
    /// `lyricsFile` (or the snake-case `lyrics_file`). A plain substring match
    /// reported `chooseLocalLyricsFile`, a menu action about importing an LRC
    /// file, as a reader of the field; it is not one.
    static func sourceScan() -> [String: Any] {
        let fm = FileManager.default
        let needles: [(name: String, pattern: NSRegularExpression)] = [
            ("lyricsfile", try! NSRegularExpression(pattern: #"\blyrics_?[Ff]ile\b"#)),
            ("hasWordSync", try! NSRegularExpression(pattern: #"\bhasWordSync\b"#)),
            ("start_ms", try! NSRegularExpression(pattern: #"\bstart_ms\b"#)),
        ]
        var hits: [String: Set<String>] = [:]
        var scanned = 0
        if let enumerator = fm.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                let range = NSRange(text.startIndex..., in: text)
                for needle in needles where needle.pattern.firstMatch(in: text, range: range) != nil {
                    hits[needle.name, default: []].insert(url.lastPathComponent)
                }
            }
        }
        let serviceFile = "IslaKit/Services/OnlineLyrics.swift"
        return [
            "swift_files_scanned": scanned,
            "files_mentioning": needles.reduce(into: [String: Any]()) { $0[$1.name] = (hits[$1.name] ?? []).sorted() },
            // The two types an LRCLIB answer is decoded into. Only what these
            // list is ever read from a response.
            "response_decodes": Mirror(reflecting: OnlineLyrics.Response()).children.compactMap(\.label),
            "response_declared_at": MatchLab.orNull(sourceLocation(file: serviceFile, marker: "struct Response: Decodable")),
            "search_row_decodes": Mirror(reflecting: OnlineLyrics.SearchRow()).children.compactMap(\.label),
            "search_row_declared_at": MatchLab.orNull(sourceLocation(file: serviceFile, marker: "struct SearchRow: Decodable")),
            "finding": "No Isla API reads lyricsfile. OnlineLyrics.Response and OnlineLyrics.SearchRow decode "
                + "syncedLyrics, instrumental, duration (and trackName, artistName for a search row) only; "
                + "the source tree holds no reference to the field, to hasWordSync or to start_ms. "
                + "A record whose words are only in lyricsfile is read as line-timed.",
        ]
    }

    // MARK: - The run

    private struct Agreement {
        var recordsWithBoth = 0
        var linesPaired = 0
        var linesOnlyInLyricsfile = 0
        var linesOnlyInLRC = 0
        var wordsCompared = 0
        var wordsSameText = 0
        var wordCountDiffers = 0
        var startDiffMs: [Double] = []
    }

    func testWordFidelity() throws {
        let root = try MatchLab.requireRoot()
        let records = MatchLab.readWordRecords(root)

        var onlineOutcomes: [String: Int] = [:]
        var onlineGranularity: [String: Int] = [:]
        var perSlice: [String: [String: Int]] = [:]
        var localEnhanced = 0
        var localGranularity: [String: Int] = [:]
        var refusals: [String: Int] = [:]
        var refusedIDs: [Int] = []
        var wordsReference = 0, wordsIsla = 0, wordsMatched = 0, wordsTextDiffers = 0, wordCountMismatchLines = 0
        var linesReference = 0, linesPaired = 0, linesOnlyIsla = 0, linesOnlyReference = 0
        var wordErrorsMs: [Double] = []
        var lineErrorsMs: [Double] = []
        var lyricsfileWordRecords = 0
        var lyricsfileWordsLost = 0
        var agreement = Agreement()
        var details: [[String: Any]] = []
        var cacheProbe: [String: Any]?

        for record in records {
            var detail: [String: Any] = [
                "id": record.id, "slice": record.slice,
                "track_id": MatchLab.orNull(record.trackID), "same_song": MatchLab.orNull(record.sameSong),
                "has_word_sync": record.hasWordSync, "instrumental": record.instrumental,
            ]

            // (a) The online path.
            let online = OnlineLyrics.timeline(from: record.raw, status: 200, duration: record.duration)
            var onlineName = "none"
            var onlineGran: String?
            var onlineTimeline: LyricTimeline?
            switch online {
            case .found(let timeline):
                onlineName = "found"; onlineGran = timeline.granularity.rawValue; onlineTimeline = timeline
            case .none: onlineName = "none"
            case .failed: onlineName = "failed"
            case .unreadable: onlineName = "unreadable"
            }
            onlineOutcomes[onlineName, default: 0] += 1
            if let onlineGran { onlineGranularity[onlineGran, default: 0] += 1 }
            perSlice[record.slice, default: [:]]["records", default: 0] += 1
            perSlice[record.slice, default: [:]]["online_" + (onlineGran ?? onlineName), default: 0] += 1
            detail["online"] = [
                "outcome": onlineName, "granularity": MatchLab.orNull(onlineGran),
                "lines": MatchLab.orNull(onlineTimeline?.lines.count),
                "lines_with_words": MatchLab.orNull(onlineTimeline?.lines.filter { !$0.words.isEmpty }.count),
            ] as [String: Any]

            // (b) The local-document parser on an enhanced LRC.
            let referenceRows = record.synced.map(Self.referenceRows(of:)) ?? []
            detail["synced_word_lines"] = referenceRows.count
            if !referenceRows.isEmpty, let synced = record.synced {
                localEnhanced += 1
                do {
                    let document = try LocalLyricsDocument.parse(synced)
                    localGranularity[document.granularity.rawValue, default: 0] += 1
                    let result = Self.compare(document: document, reference: referenceRows)
                    linesReference += referenceRows.count
                    linesPaired += result.paired
                    linesOnlyIsla += result.onlyIsla
                    linesOnlyReference += result.onlyReference
                    wordsReference += result.wordsReference
                    wordsIsla += result.wordsIsla
                    wordsMatched += result.matched
                    wordsTextDiffers += result.textDiffers
                    wordCountMismatchLines += result.countMismatch
                    wordErrorsMs += result.wordErrors
                    lineErrorsMs += result.lineErrors
                    detail["local"] = result.json
                } catch {
                    let reason: String
                    switch error as? LocalLyricsDocument.Error {
                    case .emptyTimeline?: reason = "emptyTimeline"
                    case .invalidTimestamp?: reason = "invalidTimestamp"
                    case .invalidWordOrder?: reason = "invalidWordOrder"
                    case nil: reason = "other"
                    }
                    refusals[reason, default: 0] += 1
                    refusedIDs.append(record.id)
                    linesReference += referenceRows.count
                    linesOnlyReference += referenceRows.count
                    detail["local"] = ["refused": reason, "line": MatchLab.orNull(Self.refusedLine(error))] as [String: Any]
                }
            }

            // (c)/(d) lyricsfile.
            let lyricsfile = record.lyricsfile.map(LyricsFile.parse)
            let lyricsfileRows = lyricsfile?.lines.filter { !$0.words.isEmpty } ?? []
            detail["lyricsfile_word_lines"] = lyricsfileRows.count
            if !lyricsfileRows.isEmpty {
                lyricsfileWordRecords += 1
                if onlineGran != "word" { lyricsfileWordsLost += 1 }
                if !referenceRows.isEmpty {
                    agreement.recordsWithBoth += 1
                    detail["agreement"] = Self.agree(lyricsfile: lyricsfileRows, reference: referenceRows, into: &agreement)
                }
            }

            // The cache probe: a fresh word-timed answer, then the same answer
            // as a second play gets it back from `OnlineLyricsCache`.
            if cacheProbe == nil, let timeline = onlineTimeline, timeline.granularity == .word {
                let cache = OnlineLyricsCache(directory: nil, capacity: 8)
                let identity = LocalTrackIdentity(
                    playerID: "lab", title: "t", artist: "a", album: "", duration: record.duration, recordingID: nil
                )
                cache.remember(.found(timeline), for: identity)
                var replayed: String?
                var wordsKept: Bool?
                if case .some(.some(let again)) = cache.cached(identity) {
                    replayed = again.granularity.rawValue
                    wordsKept = again.lines.contains { !$0.words.isEmpty }
                }
                cacheProbe = [
                    "record_id": record.id, "fresh_granularity": timeline.granularity.rawValue,
                    "cached_granularity": MatchLab.orNull(replayed), "cached_lines_keep_words": MatchLab.orNull(wordsKept),
                    "finding": "OnlineLyricsCache.cached builds its LyricTimeline with granularity .line "
                        + "(\(Self.sourceLocation(file: "IslaKit/Services/OnlineLyrics.swift", marker: "granularity: .line, documentID: nil, overrun: entry.overrun") ?? "OnlineLyrics.swift")), so a word-timed "
                        + "answer shown fresh is line-timed on its second play, although the cached lines still carry their words.",
                ]
            }
            details.append(detail)
        }

        let wordErrorsAbs = wordErrorsMs.map(abs)
        let lineErrorsAbs = lineErrorsMs.map(abs)
        let within10 = wordErrorsAbs.filter { $0 <= 10 }.count
        let agreementAbs = agreement.startDiffMs.map(abs)
        let signedMean = wordErrorsMs.isEmpty ? Double.nan : wordErrorsMs.reduce(0, +) / Double(wordErrorsMs.count)

        let summary = "\(records.count) word-timed records; online path: "
            + onlineGranularity.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            + " of \(onlineOutcomes["found"] ?? 0) found; enhanced LRC \(localEnhanced): "
            + "word=\(localGranularity["word"] ?? 0) refused=\(refusals.values.reduce(0, +)); "
            + "words matched \(wordsMatched)/\(wordsReference), start error p95 "
            + (wordErrorsAbs.isEmpty ? "n/a" : String(format: "%.0f ms", LabStats.percentile(wordErrorsAbs, 0.95)))
            + "; lyricsfile-word records \(lyricsfileWordRecords) (Isla line-only: \(lyricsfileWordsLost)); "
            + "records with both formats \(agreement.recordsWithBoth)"

        let report: [String: Any] = [
            "harness": MatchLab.harnessVersion,
            "summary": summary,
            "records": records.count,
            "records_by_slice": perSlice,
            "online_path": [
                "outcomes": onlineOutcomes, "granularity": onlineGranularity,
                "note": "OnlineLyrics.timeline(from:) parses syncedLyrics with LocalLyricsDocument.parse and "
                    + "keeps its granularity, so an enhanced LRC in an LRCLIB answer is .word online as well as locally.",
            ] as [String: Any],
            "local_document": [
                "enhanced_lrc_records": localEnhanced,
                "granularity": localGranularity,
                "refused": refusals,
                "refused_ids": refusedIDs,
                "reference_word_lines": linesReference,
                "lines_paired": linesPaired,
                "lines_only_in_isla": linesOnlyIsla,
                "lines_only_in_reference": linesOnlyReference,
                "lines_with_word_count_mismatch": wordCountMismatchLines,
                "words_reference": wordsReference,
                "words_isla": wordsIsla,
                "words_matched": wordsMatched,
                "words_text_differs": wordsTextDiffers,
                "word_start_error_ms_abs": MatchLab.stats(wordErrorsAbs),
                "word_start_error_ms_signed_mean": signedMean,
                "words_within_10_ms_share": MatchLab.share(within10, of: wordErrorsAbs.count),
                "line_start_error_ms_abs": MatchLab.stats(lineErrorsAbs),
            ] as [String: Any],
            "lyricsfile": [
                "records_with_word_lines": lyricsfileWordRecords,
                "records_isla_reads_line_only": lyricsfileWordsLost,
                "source_scan": Self.sourceScan(),
            ] as [String: Any],
            "agreement": [
                "records_with_both_formats": agreement.recordsWithBoth,
                "lines_paired": agreement.linesPaired,
                "lines_only_in_lyricsfile": agreement.linesOnlyInLyricsfile,
                "lines_only_in_enhanced_lrc": agreement.linesOnlyInLRC,
                "words_compared": agreement.wordsCompared,
                "words_same_text": agreement.wordsSameText,
                "lines_with_word_count_difference": agreement.wordCountDiffers,
                "word_start_diff_ms_abs": MatchLab.stats(agreementAbs),
            ] as [String: Any],
            "cache_probe": MatchLab.orNull(cacheProbe),
            "per_record": details,
        ]
        try MatchLab.writeJSON(report, to: MatchLab.resultsURL(root, "word-fidelity.json"))
        MatchLab.report(section: "word-fidelity", summary: summary)
    }

    // MARK: - Comparisons

    private static func refusedLine(_ error: Error) -> Int? {
        switch error as? LocalLyricsDocument.Error {
        case .invalidTimestamp(let line)?, .invalidWordOrder(let line)?: return line
        default: return nil
        }
    }

    /// What comparing one document with the reference found.
    struct LocalComparison {
        var granularity = ""
        var referenceLines = 0
        var paired = 0
        var onlyIsla = 0
        var onlyReference = 0
        var wordsReference = 0
        var wordsIsla = 0
        var matched = 0
        var textDiffers = 0
        var countMismatch = 0
        var wordErrors: [Double] = []
        var lineErrors: [Double] = []

        var json: [String: Any] {
            [
                "granularity": granularity,
                "reference_lines": referenceLines, "lines_paired": paired,
                "lines_only_in_isla": onlyIsla, "lines_only_in_reference": onlyReference,
                "words_reference": wordsReference, "words_isla": wordsIsla,
                "words_matched": matched, "words_text_differs": textDiffers,
                "word_start_error_ms_abs": MatchLab.stats(wordErrors.map { Swift.abs($0) }),
            ]
        }
    }

    /// Pairs Isla's word-timed lines with the reference's by start (within
    /// 20 ms, the centisecond the LRC stamp is rounded to) and compares the
    /// words of each pair index by index: the same trimmed text is a match,
    /// and its start error is Isla's minus the reference's, in milliseconds.
    private static func compare(
        document: LocalLyricsDocument, reference: [(ms: Int, words: [ReferenceWord])]
    ) -> LocalComparison {
        var result = LocalComparison()
        result.granularity = document.granularity.rawValue
        result.referenceLines = reference.count
        var consumed = Set<Int>()
        for line in document.lines where !line.words.isEmpty {
            let startMs = Int((line.at * 1000).rounded())
            guard let index = reference.indices.first(where: { !consumed.contains($0) && abs(reference[$0].ms - startMs) <= 20 })
            else { result.onlyIsla += 1; continue }
            consumed.insert(index)
            result.paired += 1
            result.lineErrors.append(line.at * 1000 - Double(reference[index].ms))
            let ref = reference[index].words
            result.wordsReference += ref.count
            result.wordsIsla += line.words.count
            if ref.count != line.words.count { result.countMismatch += 1 }
            for (isla, expected) in zip(line.words, ref) {
                if isla.text.trimmingCharacters(in: .whitespaces) == expected.text.trimmingCharacters(in: .whitespaces) {
                    result.matched += 1
                    result.wordErrors.append(isla.at * 1000 - Double(expected.ms))
                } else {
                    result.textDiffers += 1
                }
            }
        }
        result.onlyReference = reference.count - consumed.count
        return result
    }

    /// (d): the `lyricsfile` words against the enhanced LRC's, line by line.
    /// Lines are paired by the nearest start within 250 ms — the two formats
    /// round a line's start differently — and words index by index.
    private static func agree(
        lyricsfile: [LyricsFile.Line], reference: [(ms: Int, words: [ReferenceWord])], into total: inout Agreement
    ) -> [String: Any] {
        var consumed = Set<Int>()
        var paired = 0, onlyFile = 0, compared = 0, same = 0, countDiffers = 0
        var diffs: [Double] = []
        for line in lyricsfile {
            guard let start = line.startMs else { onlyFile += 1; continue }
            let candidates = reference.indices.filter { !consumed.contains($0) && abs(reference[$0].ms - start) <= 250 }
            guard let index = candidates.min(by: { abs(reference[$0].ms - start) < abs(reference[$1].ms - start) }) else {
                onlyFile += 1
                continue
            }
            consumed.insert(index)
            paired += 1
            let ref = reference[index].words
            if ref.count != line.words.count { countDiffers += 1 }
            for (file, lrc) in zip(line.words, ref) {
                compared += 1
                if file.text.trimmingCharacters(in: .whitespaces) == lrc.text.trimmingCharacters(in: .whitespaces) {
                    same += 1
                    if let ms = file.startMs { diffs.append(Double(ms - lrc.ms)) }
                }
            }
        }
        let onlyLRC = reference.count - consumed.count
        total.linesPaired += paired
        total.linesOnlyInLyricsfile += onlyFile
        total.linesOnlyInLRC += onlyLRC
        total.wordsCompared += compared
        total.wordsSameText += same
        total.wordCountDiffers += countDiffers
        total.startDiffMs += diffs
        return [
            "lines_paired": paired, "lines_only_in_lyricsfile": onlyFile, "lines_only_in_enhanced_lrc": onlyLRC,
            "words_compared": compared, "words_same_text": same, "lines_with_word_count_difference": countDiffers,
            "word_start_diff_ms_abs": MatchLab.stats(diffs.map { Swift.abs($0) }),
        ]
    }
}
