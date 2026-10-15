import AppKit
import CoreText
import Foundation
import XCTest
@testable import IslaKit

/// M3b: when a word is sung, is the highlight on that word?
///
/// The sweep has two halves that were each measured alone before. The
/// fraction (`LyricSweep.wordFraction`) shares a line out by *characters*:
/// at the start of word i it is the characters of the words before i over the
/// characters of every word. The renderer (`KaraokeRenderer.draw`) turns that
/// fraction into a lit *width*, from the left edge, over the laid-out line.
/// The two meet at a word only where character share equals width share, and
/// only where the line reads left to right. The 2026-10-11 lab's L5 judged
/// the fraction against an ideal that also counted characters, so neither
/// mismatch could show.
///
/// For every word-timed line Isla builds from the corpus's word-timed records
/// (`OnlineLyrics.timeline(from:)`, the online path), each word's reading
/// start is placed where CoreText puts the caret at that word's first
/// character (`CTLineGetOffsetForStringIndex`, visual coordinates, so a
/// right-to-left word's reading start is its right edge), in the font,
/// weight and tracking of each surface (read from the shipped code through
/// `LyricMatchLabReadabilityTests.surfaces()`). The edge reaches the word when
/// `wordFraction × width` first covers that caret; the error is that moment
/// minus the word's stamp. Positive is late. The lead moves every edge and
/// every stamp alike, so it is left out.
///
/// The three surfaces measured, `band`, `column` and `tall`, each draw the sung
/// line on one row and cut it at the tail: the band is a `KaraokeText` with the
/// default `lineLimit` of 1 (`MediaPane.swift`), and the column and the tall
/// page share one row builder that passes `lineLimit: 1` to `LyricRow`
/// (`LyricsStage.swift:613`), which hands it to `KaraokeText`. The lock card,
/// whose current line may take more rows (`LockScreenCard.swift:909`), is not
/// among them. A word whose reading start lies past the surface's visible
/// width (`Surface.available`) is therefore never drawn, so it cannot be "on
/// the word": it is left out of the error statistics and counted per surface
/// as `beyond_visible`. On a line that overflows, `.truncationMode(.tail)`
/// replaces the end of the visible row with "…", so the room for words is
/// `available` less the ellipsis, measured in the surface's own font the way
/// the words are (`visibleLimit`; third review, m9). A line that fits draws no
/// ellipsis and keeps all of `available`.
///
/// `width` is CoreText's typographic width of the whole line, trailing
/// whitespace included, and that is what `KaraokeRenderer` multiplies the
/// fraction by: `fullWidth`, the line measured on one unconstrained row, and
/// the sum of the laid-out runs' `typographicBounds.width` (it takes the larger
/// and caps the lit width at what is drawn, `KaraokeRenderer.litWidth`). Both
/// were checked against CoreText on 2026-10-15: SwiftUI's run bounds equal
/// `CTLineGetTypographicBounds` to the last digit for a string with trailing
/// spaces, and its fitted width is that value rounded up to a whole point. So
/// nothing is subtracted for trailing whitespace: the renderer counts it too.
/// (The parser trims a line's ends anyway, `LocalLyricsDocument`.) The
/// whole-point rounding, under one point on a line of a hundred or more, is
/// the model's only approximation of the width.
///
/// The model of the renderer is one lit span growing from the line's left
/// edge. That is exact for a line of one direction: the renderer lights runs
/// in order, each from its own left edge, and a left-to-right line's runs run
/// left to right, while a right-to-left line is one run lit from the left. A
/// line that mixes directions is lit run by run in an order this does not
/// model, so its numbers are approximate; such lines are counted apart.
///
/// The results hold counts, ids and milliseconds, never a word.
@MainActor
final class LyricMatchLabSweepTests: XCTestCase {
    /// The dominant script of `text` by letters, and whether a second script
    /// holds at least a quarter of them.
    static func script(of text: String) -> (name: String, mixed: Bool) {
        var counts: [String: Int] = [:]
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            let name: String
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: name = "latin"
            case 0x0370...0x03FF: name = "greek"
            case 0x0400...0x052F: name = "cyrillic"
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: name = "hebrew"
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: name = "arabic"
            case 0x0900...0x0DFF: name = "indic"
            case 0x0E00...0x0E7F: name = "thai"
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: name = "hangul"
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: name = "cjk"
            default: name = "other"
            }
            counts[name, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        guard let first = ranked.first else { return ("none", false) }
        let total = counts.values.reduce(0, +)
        let mixed = ranked.count > 1 && Double(ranked[1].value) >= 0.25 * Double(total)
        return (first.key, mixed)
    }

    /// The UTF-16 offset of each word's first character in `text`, found in
    /// order; nil when a word's text is not in the line (the line is skipped
    /// and counted rather than guessed at).
    static func wordOffsets(_ words: [LyricWord], in text: String) -> [Int]? {
        var cursor = text.startIndex
        var offsets: [Int] = []
        for word in words {
            let needle = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, let found = text.range(of: needle, range: cursor..<text.endIndex) else { return nil }
            offsets.append(text.utf16.distance(from: text.utf16.startIndex, to: found.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex))
            cursor = found.upperBound
        }
        return offsets
    }

    /// The typographic width of "…" in a surface's font, weight and tracking:
    /// what tail truncation spends on the ellipsis it draws.
    static func ellipsisWidth(of surface: LyricMatchLabReadabilityTests.Surface) -> CGFloat {
        let attributed = LyricMatchLabReadabilityTests.attributed(
            "\u{2026}", size: surface.size, weight: surface.weight, tracking: surface.tracking
        )
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
    }

    /// The x beyond which no word is drawn: all of `available` for a line that
    /// fits, and `available` less the ellipsis for one that is cut at its tail.
    static func visibleLimit(available: CGFloat, lineWidth: CGFloat, ellipsis: CGFloat) -> CGFloat {
        lineWidth > available ? available - ellipsis : available
    }

    /// The first moment the lit width covers `caret`: `wordFraction` never
    /// falls as the clock runs, so a bisection finds it.
    static func edgeTime(words: [LyricWord], lineStart: TimeInterval, lineEnd: TimeInterval,
                         width: CGFloat, caret: CGFloat) -> TimeInterval {
        let target = Double(caret) - 0.5
        func lit(_ t: TimeInterval) -> Double { LyricSweep.wordFraction(words: words, at: t, lineEnd: lineEnd) * Double(width) }
        var low = min(lineStart, words.first?.at ?? lineStart) - 1
        var high = lineEnd
        if lit(low) >= target { return low }
        for _ in 0..<50 {
            let mid = (low + high) / 2
            if lit(mid) >= target { high = mid } else { low = mid }
        }
        return high
    }

    private struct Tally {
        var signed: [Double] = []
        var lines = 0
        /// Words whose reading start lies beyond the surface's visible width:
        /// the line is cut at its tail there, the word is never drawn, so it
        /// cannot be "on the word" and is left out of the statistics.
        var beyondVisible = 0
    }

    func testSweepEdgeMeetsEachWord() throws {
        let root = try MatchLab.requireRoot()
        let records = MatchLab.readWordRecords(root)
        let surfaces = LyricMatchLabReadabilityTests.surfaces().filter { $0.bodyWidth == NotchMetrics.defaultBodyWidth }
        let ellipsis = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.name, Self.ellipsisWidth(of: $0)) })

        var wordTimedRecords = 0, lines = 0, unmapped = 0, words = 0
        var under120Hz = 0, under60Hz = 0, under100ms = 0
        var rtlLines = 0
        var rtlRecords = Set<Int>()
        var tallies: [String: [String: Tally]] = [:]   // surface -> script -> tally
        var worst: [[String: Any]] = []

        for record in records {
            guard case .found(let timeline) = OnlineLyrics.timeline(from: record.raw, status: 200, duration: record.duration),
                  timeline.granularity == .word else { continue }
            wordTimedRecords += 1
            for (index, line) in timeline.lines.enumerated() where line.words.count >= 2 && !line.isCredit {
                guard let offsets = Self.wordOffsets(line.words, in: line.text) else { unmapped += 1; continue }
                lines += 1
                words += line.words.count
                let lineEnd = LyricSweep.end(of: index, in: timeline.lines)
                for (k, word) in line.words.enumerated() {
                    let next = k + 1 < line.words.count ? line.words[k + 1].at : lineEnd
                    let span = min(word.end ?? next, next) - word.at
                    if span < 1.0 / 120 { under120Hz += 1 }
                    if span < 1.0 / 60 { under60Hz += 1 }
                    if span < 0.1 { under100ms += 1 }
                }
                let (script, mixed) = Self.script(of: line.text)
                let group = mixed ? "\(script)+mixed" : script
                if script == "arabic" || script == "hebrew" { rtlLines += 1; rtlRecords.insert(record.id) }

                for surface in surfaces {
                    let attributed = LyricMatchLabReadabilityTests.attributed(
                        line.text, size: surface.size, weight: surface.weight, tracking: surface.tracking
                    )
                    let ctLine = CTLineCreateWithAttributedString(attributed)
                    let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                    guard width > 0 else { continue }
                    var tally = tallies[surface.name, default: [:]][group, default: Tally()]
                    tally.lines += 1
                    for (k, word) in line.words.enumerated() {
                        let caret = CTLineGetOffsetForStringIndex(ctLine, offsets[k], nil)
                        // A word whose reading start is the line's left edge is
                        // lit from its first frame by construction: no measurement.
                        guard caret >= 0.5 else { continue }
                        // Every surface measured here is one row cut at its tail
                        // (see the class comment). A word that starts past the
                        // visible width is never drawn, and counting it would put
                        // an edge that cannot be seen into the error statistics.
                        if surface.available > 0,
                           caret >= Self.visibleLimit(available: surface.available, lineWidth: width,
                                                      ellipsis: ellipsis[surface.name] ?? 0) {
                            tally.beyondVisible += 1
                            continue
                        }
                        let reached = Self.edgeTime(words: line.words, lineStart: line.at, lineEnd: lineEnd,
                                                    width: width, caret: caret)
                        let error = reached - word.at
                        tally.signed.append(error)
                        if surface.name == "band", abs(error) >= 0.25 {
                            worst.append(["id": record.id, "slice": record.slice, "line": index, "word": k,
                                          "script": group, "error_ms": Int((error * 1000).rounded())])
                        }
                    }
                    tallies[surface.name, default: [:]][group] = tally
                }
            }
        }

        var perSurface: [String: Any] = [:]
        for (surface, scripts) in tallies {
            var out: [String: Any] = [:]
            for (script, tally) in scripts {
                let absolute = tally.signed.map(abs)
                out[script] = [
                    "lines": tally.lines,
                    "words_measured": tally.signed.count,
                    "beyond_visible": tally.beyondVisible,
                    "signed_s": MatchLab.stats(tally.signed),
                    "abs_s": MatchLab.stats(absolute),
                    "late_over_100ms": MatchLab.share(tally.signed.filter { $0 > 0.1 }.count, of: tally.signed.count),
                    "early_over_100ms": MatchLab.share(tally.signed.filter { $0 < -0.1 }.count, of: tally.signed.count),
                    "off_over_250ms": MatchLab.share(absolute.filter { $0 > 0.25 }.count, of: tally.signed.count),
                ] as [String: Any]
            }
            perSurface[surface] = out
        }
        var beyondVisible: [String: Int] = [:]
        for (surface, scripts) in tallies { beyondVisible[surface] = scripts.values.reduce(0) { $0 + $1.beyondVisible } }
        worst.sort { abs(($0["error_ms"] as? Int) ?? 0) > abs(($1["error_ms"] as? Int) ?? 0) }

        let result: [String: Any] = [
            "section": "M3b sweep edge",
            "records": records.count,
            "word_timed_records": wordTimedRecords,
            "lines": lines,
            "unmapped_lines": unmapped,
            "words": words,
            "short_words": ["under_one_frame_120hz": under120Hz, "under_one_frame_60hz": under60Hz,
                            "under_100ms": under100ms],
            "rtl": ["lines": rtlLines, "records": rtlRecords.count,
                    "note": "KaraokeRenderer lights [origin.x, origin.x + lit] of each run, from the left, whatever the run's direction"],
            "surfaces": perSurface,
            "beyond_visible": beyondVisible,
            "surface_available_pt": Dictionary(uniqueKeysWithValues: surfaces.map { ($0.name, Double($0.available)) }),
            "ellipsis_pt": Dictionary(uniqueKeysWithValues: ellipsis.map { ($0.key, Double($0.value)) }),
            "worst_band": Array(worst.prefix(25)),
            "method": "error = first t with wordFraction(t) x width >= caret(word start) - 0.5 pt, minus the word's stamp; "
                + "caret from CTLineGetOffsetForStringIndex in the surface's system font, weight and tracking",
        ]
        try MatchLab.writeJSON(result, to: MatchLab.resultsURL(root, "sweep-edge.json"))
        let band = (tallies["band"] ?? [:]).values.flatMap(\.signed)
        let off = band.filter { abs($0) > 0.1 }.count
        MatchLab.report(
            section: "sweep-edge",
            summary: "\(wordTimedRecords) word-timed records, \(lines) lines, \(words) words; band: "
                + "\(off)/\(band.count) words lit more than 100 ms off their stamp, "
                + "\(beyondVisible["band", default: 0]) more beyond the visible width; RTL lines \(rtlLines)"
        )
    }
}
