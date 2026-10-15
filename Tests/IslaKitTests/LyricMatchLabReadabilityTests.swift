import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import IslaKit

/// M4: are the lines Isla chose readable where Isla draws them?
///
/// For each `canonical` lookup that found something, the chosen timeline is
/// rebuilt from the cache by `chosen_id` (the record's bytes through
/// `OnlineLyrics.timeline(from:)` with the lookup's own length, so the lines are
/// the ones that survived the cut at the track's end). Per slice it reports:
///
/// - **Line duration:** until the line's own end when the timeline has one
///   that Isla honours (`LyricSweep.effectiveEnd`: an LRC empty stamp at least
///   `minimumHonouredGap` before the next line), otherwise until the next
///   line's start. The last line runs to the track's end, capped at 10 s. The
///   section asks how long a line *could* be read, and the share it measures
///   is the short end. A line that ends before an instrumental break is no
///   longer credited with the break (adversarial review F15).
/// - **Credit lines are left out.** `LyricsStore.Line.isCredit` marks the
///   lines the app inferred as metadata ("Written by …"); the stage and the
///   band do not treat them as lyrics, so they are not measured. The count
///   left out is `credit_lines_excluded`.
/// - **Per lookup.** `per_lookup` holds the raw figures of every rebuilt
///   lookup, so the classifier can drop the lookups whose verdict is
///   wrong-song (the lyrics of another song are not evidence about the
///   right ones) and report the figures without them.
/// - **Graphemes without spaces per second**, and **syllables per second** from
///   `MatchLab.syllables` (a per-script heuristic, with the share of lines it
///   flagged low-confidence).
/// - **The share of lines under 0.6 s and under 1.0 s**, counted whatever their
///   rate (a zero-length line has no rate and is still too short).
/// - **Width against the real surfaces:** each line's rendered width in the
///   surface's font, tracking and available width, with the share that
///   overflows.
///
/// The surfaces and their numbers are *read from the shipped code*, not copied:
/// the sizes and weights from `Theme.TypeRole` and `LyricsStage.Metrics`, the
/// tracking from `Theme.tracking(forSize:)`, the widths from
/// `PlayerLayout.frames` at body widths 560 (the default) and 480 (the
/// minimum). The file and line each comes from is in `assumptions`.
///
/// Every surface draws one line (`lineLimit(1)`, `truncationMode(.tail)`), so
/// an overflowing line is *truncated*, never wrapped. The rows it would need if
/// it wrapped are reported anyway, as the size of the loss.
///
/// Widths come from `NSAttributedString.size()` in the system font with the
/// tracking as `.kern`. The same lines are also laid out by SwiftUI itself for
/// a sample, and the ratio is in `calibration`.
///
/// `testReadabilityByGenre` measures the held corpus the same way, by the
/// corpus's categories, for when too few lookups found a timeline.
@MainActor
final class LyricMatchLabReadabilityTests: XCTestCase {
    // MARK: - Surfaces

    struct Surface {
        let name: String
        let bodyWidth: CGFloat
        let available: CGFloat
        let size: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat

        var key: String { "\(name)@\(Int(bodyWidth))" }
        var fontKey: String { "\(size)pt/\(LyricMatchLabReadabilityTests.weightName(weight))/tracking \(tracking)" }
    }

    static let bodyWidths: [CGFloat] = [NotchMetrics.defaultBodyWidth, NotchMetrics.minimumBodyWidth]

    /// The three one-line surfaces that draw the sung line, for each body width.
    ///
    /// The sung line is what is measured: it is the bold one, and bold is the
    /// widest weight a surface sets a lyric in. A line that is not being sung is
    /// semibold in the column and narrower.
    static func surfaces() -> [Surface] {
        var out: [Surface] = []
        for bodyWidth in bodyWidths {
            // The player's lyric band: 13 pt bold in the text column, `bodyWidth − 220` wide.
            let player = PlayerLayout.frames(for: .player, bodyWidth: bodyWidth)
            let bandSize = Theme.TypeRole.subhead.size
            out.append(Surface(
                name: "band", bodyWidth: bodyWidth, available: player.sungLine?.width ?? 0,
                size: bandSize, weight: .bold, tracking: Theme.tracking(forSize: bandSize)
            ))
            // The lyric stage in its column, beside the cover: `bodyWidth − 282` wide.
            let column = PlayerLayout.frames(for: .column, bodyWidth: bodyWidth)
            let columnMetrics = LyricsStage.Metrics.column
            out.append(Surface(
                name: "column", bodyWidth: bodyWidth, available: column.lyricArea?.width ?? 0,
                size: columnMetrics.fontSize, weight: columnMetrics.weight,
                tracking: Theme.tracking(forSize: columnMetrics.fontSize)
            ))
            // The tall lyric page: the pane's whole width, `bodyWidth − 72`.
            let tall = PlayerLayout.frames(for: .tall, bodyWidth: bodyWidth)
            let tallMetrics = LyricsStage.Metrics.tall
            out.append(Surface(
                name: "tall", bodyWidth: bodyWidth, available: tall.lyricArea?.width ?? 0,
                size: tallMetrics.fontSize, weight: tallMetrics.weight,
                tracking: Theme.tracking(forSize: tallMetrics.fontSize)
            ))
        }
        return out
    }

    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    nonisolated static func weightName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "ultraLight"
        case .thin: return "thin"
        case .light: return "light"
        case .medium: return "medium"
        case .semibold: return "semibold"
        case .bold: return "bold"
        case .heavy: return "heavy"
        case .black: return "black"
        default: return "regular"
        }
    }

    static func attributed(_ text: String, size: CGFloat, weight: Font.Weight, tracking: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: nsWeight(weight)),
            .kern: tracking,
        ])
    }

    /// How many rows `text` needs when wrapped to `width`: the height AppKit
    /// lays it out in over one line's height.
    static func rowsIfWrapped(_ text: NSAttributedString, width: CGFloat, size: CGFloat, weight: Font.Weight) -> Int {
        let font = NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let bounds = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(1, Int((bounds.height / lineHeight).rounded()))
    }

    // MARK: - Accumulation

    private struct SurfaceTally {
        var widths: [Double] = []
        var ratios: [Double] = []
        var overflow = 0
        var rows: [Double] = []
    }

    private struct SliceTally {
        var tracks = 0
        var lines = 0
        var durations: [Double] = []
        var cps: [Double] = []
        var sps: [Double] = []
        var under06 = 0
        var under10 = 0
        var lowConfidence = 0
        var surfaces: [String: SurfaceTally] = [:]
        var creditLines = 0

        func json(_ surfaces: [Surface]) -> [String: Any] {
            var surfaceJSON: [String: Any] = [:]
            for surface in surfaces {
                let tally = self.surfaces[surface.key] ?? SurfaceTally()
                surfaceJSON[surface.key] = [
                    "available_pt": surface.available,
                    "overflow_lines": tally.overflow,
                    "overflow_share": MatchLab.share(tally.overflow, of: lines),
                    "behaviour_on_overflow": "truncates at the tail",
                    "width_pt": MatchLab.stats(tally.widths),
                    "width_over_available": MatchLab.stats(tally.ratios),
                    "rows_if_wrapped_for_overflowing_lines": MatchLab.stats(tally.rows),
                    // What a two-row stage would still cut: the report's fix for
                    // these surfaces is a second row, and percentiles of `rows`
                    // cannot say how many lines that leaves cut.
                    "lines_two_rows_cannot_hold": tally.rows.filter { $0 > 2 }.count,
                    "share_two_rows_cannot_hold": MatchLab.share(tally.rows.filter { $0 > 2 }.count, of: lines),
                ] as [String: Any]
            }
            return [
                "tracks": tracks,
                "lines": lines,
                "line_duration_s": MatchLab.stats(durations),
                "graphemes_per_second": MatchLab.stats(cps),
                "syllables_per_second": MatchLab.stats(sps),
                "share_under_0_6_s": MatchLab.share(under06, of: lines),
                "share_under_1_0_s": MatchLab.share(under10, of: lines),
                "syllable_low_confidence_share": MatchLab.share(lowConfidence, of: lines),
                "credit_lines_excluded": creditLines,
                "surfaces": surfaceJSON,
            ]
        }

        /// The raw numbers, for the classifier to merge without the lookups it
        /// excludes.
        func raw(trackID: String, slice: String) -> [String: Any] {
            var surfaceJSON: [String: Any] = [:]
            for (key, tally) in surfaces {
                surfaceJSON[key] = [
                    "ratios": tally.ratios, "widths": tally.widths, "rows": tally.rows, "overflow": tally.overflow,
                ] as [String: Any]
            }
            return [
                "track_id": trackID, "slice": slice, "lines": lines, "durations": durations,
                "cps": cps, "sps": sps, "low_confidence": lowConfidence, "credit_lines_excluded": creditLines,
                "surfaces": surfaceJSON,
            ]
        }
    }

    // MARK: - The run

    func testReadability() throws {
        let root = try MatchLab.requireRoot()
        let lookups = try MatchLab.readLookups(root).filter { $0.variant == "canonical" }
        let surfaces = Self.surfaces()
        let attributedFonts = Dictionary(grouping: surfaces, by: \.fontKey)

        var slices: [String: SliceTally] = [:]
        var all = SliceTally()
        var found = 0, rebuilt = 0, missingCache = 0
        var calibrationSample: [String] = []
        var perLookup: [[String: Any]] = []

        for lookup in lookups where lookup.outcome == "found" {
            found += 1
            guard let chosen = lookup.chosenID,
                  let timeline = Self.rebuild(lookup: lookup, chosenID: chosen, root: root),
                  !timeline.lines.isEmpty
            else { missingCache += 1; continue }
            rebuilt += 1
            let mine = Self.measure(
                timeline.lines, trackEnd: lookup.identity.duration, slice: lookup.slice, fonts: attributedFonts,
                slices: &slices, all: &all, calibration: &calibrationSample
            )
            perLookup.append(mine.raw(trackID: lookup.trackID, slice: lookup.slice))
        }

        let summary = "\(rebuilt) of \(found) found canonical lookups rebuilt (\(missingCache) not), \(all.lines) lines; "
            + "line duration p50 " + Self.fixed(all.durations, 0.5, "s") + ", under 0.6 s "
            + Self.percent(all.under06, all.lines) + ", under 1.0 s " + Self.percent(all.under10, all.lines)
            + "; overflow " + surfaces.map { surface in
                "\(surface.key) " + Self.percent(all.surfaces[surface.key]?.overflow ?? 0, all.lines)
            }.joined(separator: ", ")

        var sliceJSON: [String: Any] = [:]
        for (name, tally) in slices.sorted(by: { $0.key < $1.key }) { sliceJSON[name] = tally.json(surfaces) }

        let report: [String: Any] = [
            "harness": MatchLab.harnessVersion,
            "summary": summary,
            "canonical_lookups": lookups.count,
            "found": found,
            "rebuilt": rebuilt,
            "not_rebuilt_missing_cache_or_id": missingCache,
            "assumptions": Self.assumptions(surfaces),
            "calibration": Self.calibrate(sample: calibrationSample, surfaces: surfaces),
            "all": all.json(surfaces),
            "slices": sliceJSON,
            "per_lookup": perLookup,
        ]
        try MatchLab.writeJSON(report, to: MatchLab.resultsURL(root, "readability.json"))
        MatchLab.report(section: "readability", summary: summary)
    }

    // MARK: - The held corpus

    /// M4 on the held corpus, by its categories (SPEC, amended 2026-10-15).
    ///
    /// `testReadability` measures the timelines Isla chose for the sampled
    /// lookups, and LRCLIB stopped answering this address when 3 of the 88
    /// canonical lookups had found one: 211 lines from one slice, too few to
    /// say anything about a genre. This run measures every record in
    /// `ISLA_LYRIC_CORPUS` that Isla's own read of an answer accepts
    /// (`LyricLab.acceptedTracks`: `OnlineLyrics.timeline(from:status:duration:)`
    /// with the record's own length), grouped by the corpus's category
    /// directories — the genre slices of the 2026-10-11 corpus, or the pool's
    /// harvest slices.
    ///
    /// What differs from `testReadability`: nobody chose these records for a
    /// player's track, so a figure here says what the catalogue holds for a
    /// genre, not what a listener was shown, and a line's track end is the
    /// record's own length. The measurement is the same function. A record
    /// counts once per surface in `songs_with_a_truncated_line` when any of its
    /// lines overflows there. The calibration sample takes up to four lines from
    /// each category, so every script the corpus holds is in it, where
    /// `testReadability`'s first forty lines would all come from the first
    /// category.
    ///
    /// Writes the `M4` section of `ISLA_LYRIC_REPORT`: counts and widths only,
    /// never a line of text. Skipped unless `ISLA_LYRIC_CORPUS` is set.
    func testReadabilityByGenre() throws {
        let records = try LyricLab.tracks()
        let accepted = try LyricLab.acceptedTracks()
        let surfaces = Self.surfaces()
        let fonts = Dictionary(grouping: surfaces, by: \.fontKey)

        var categories: [String: SliceTally] = [:]
        var all = SliceTally()
        var samples: [String: [String]] = [:]
        var truncated: [String: [String: Int]] = [:]
        var truncatedAll: [String: Int] = [:]
        for (track, lines) in accepted {
            var sample: [String] = []
            let mine = Self.measure(
                lines, trackEnd: track.duration, slice: track.category, fonts: fonts,
                slices: &categories, all: &all, calibration: &sample
            )
            let room = 4 - samples[track.category, default: []].count
            if room > 0 { samples[track.category, default: []].append(contentsOf: sample.prefix(room)) }
            for surface in surfaces where (mine.surfaces[surface.key]?.overflow ?? 0) > 0 {
                truncated[track.category, default: [:]][surface.key, default: 0] += 1
                truncatedAll[surface.key, default: 0] += 1
            }
        }

        let summary = "\(accepted.count) of \(records.count) records accepted, \(all.lines) lines in "
            + "\(categories.count) categories; line duration p50 " + Self.fixed(all.durations, 0.5, "s")
            + ", under 0.6 s " + Self.percent(all.under06, all.lines)
            + ", under 1.0 s " + Self.percent(all.under10, all.lines)
            + "; overflow " + surfaces.map { surface in
                "\(surface.key) " + Self.percent(all.surfaces[surface.key]?.overflow ?? 0, all.lines)
            }.joined(separator: ", ")

        var categoryJSON: [String: Any] = [:]
        for (name, tally) in categories.sorted(by: { $0.key < $1.key }) {
            var json = tally.json(surfaces)
            json["songs_with_a_truncated_line"] = Self.songShares(truncated[name] ?? [:], of: tally.tracks, surfaces)
            json["lines_within_2_percent_of_the_edge"] = Self.nearTheEdge(tally, surfaces)
            categoryJSON[name] = json
        }
        var allJSON = all.json(surfaces)
        allJSON["songs_with_a_truncated_line"] = Self.songShares(truncatedAll, of: all.tracks, surfaces)
        allJSON["lines_within_2_percent_of_the_edge"] = Self.nearTheEdge(all, surfaces)

        // The column sets the sung line bold and every other line semibold
        // (`LyricsStage.Metrics.column`), so a line whose width falls between
        // the two fits while it waits and gains its ellipsis at the moment it
        // is sung. The tall page sets every line bold and cannot do this.
        let column = LyricsStage.Metrics.column
        var cutWhenSung: [String: Int] = [:]
        for (_, lines) in accepted {
            for line in lines where !line.isCredit {
                let text = LyricTranslation.rows(of: line.text).primary
                let tracking = Theme.tracking(forSize: column.fontSize)
                let sung = Self.attributed(text, size: column.fontSize, weight: column.weight, tracking: tracking).size().width
                let waiting = Self.attributed(text, size: column.fontSize, weight: column.contextWeight, tracking: tracking).size().width
                for surface in surfaces where surface.name == "column" && waiting <= surface.available && sung > surface.available {
                    cutWhenSung[surface.key, default: 0] += 1
                }
            }
        }
        var cutWhenSungJSON: [String: Any] = [:]
        for surface in surfaces where surface.name == "column" {
            let count = cutWhenSung[surface.key] ?? 0
            cutWhenSungJSON[surface.key] = ["lines": count, "share": MatchLab.share(count, of: all.lines)] as [String: Any]
        }
        allJSON["column_lines_cut_only_while_sung"] = cutWhenSungJSON

        LyricLab.write(section: "M4", [
            "summary": summary,
            "verdict": "measured",
            "records": records.count,
            "accepted": accepted.count,
            "assumptions": Self.assumptions(surfaces),
            "calibration": Self.calibrate(
                sample: samples.keys.sorted().flatMap { samples[$0] ?? [] }, surfaces: surfaces
            ),
            "all": allJSON,
            "categories": categoryJSON,
        ])
    }

    // MARK: - One timeline

    /// Measures one timeline into its slice's tally and the run's, and returns
    /// the timeline's own. Both runs go through here — the lookups Isla made
    /// and the held corpus — so a line is measured the same way in either.
    private static func measure(
        _ lines: [LyricsStore.Line], trackEnd: TimeInterval, slice: String, fonts: [String: [Surface]],
        slices: inout [String: SliceTally], all: inout SliceTally, calibration: inout [String]
    ) -> SliceTally {
        slices[slice, default: SliceTally()].tracks += 1
        all.tracks += 1
        var mine = SliceTally()
        mine.tracks = 1
        for (index, line) in lines.enumerated() {
            if line.isCredit {
                slices[slice, default: SliceTally()].creditLines += 1
                all.creditLines += 1
                mine.creditLines += 1
                continue
            }
            let duration = Self.duration(of: index, in: lines, trackEnd: trackEnd)
            // What the surfaces draw is the first row of a bilingual line.
            let text = LyricTranslation.rows(of: line.text).primary
            let graphemes = text.filter { !$0.isWhitespace }.count
            let syllables = MatchLab.syllables(in: text)

            func add(to tally: inout SliceTally) {
                tally.lines += 1
                tally.durations.append(duration)
                if duration < 0.6 { tally.under06 += 1 }
                if duration < 1.0 { tally.under10 += 1 }
                if duration > 0 {
                    tally.cps.append(Double(graphemes) / duration)
                    tally.sps.append(syllables.count / duration)
                }
                if syllables.lowConfidence { tally.lowConfidence += 1 }
            }
            add(to: &slices[slice, default: SliceTally()])
            add(to: &all)
            add(to: &mine)

            // One layout per distinct font, however many surfaces share it.
            for (_, group) in fonts {
                guard let first = group.first else { continue }
                let attributed = Self.attributed(text, size: first.size, weight: first.weight, tracking: first.tracking)
                let width = attributed.size().width
                for surface in group where surface.available > 0 {
                    let overflows = width > surface.available
                    let rows = overflows
                        ? Double(Self.rowsIfWrapped(attributed, width: surface.available, size: surface.size, weight: surface.weight))
                        : nil
                    func record(into tally: inout SliceTally) {
                        var entry = tally.surfaces[surface.key] ?? SurfaceTally()
                        entry.widths.append(Double(width))
                        entry.ratios.append(Double(width / surface.available))
                        if overflows { entry.overflow += 1 }
                        if let rows { entry.rows.append(rows) }
                        tally.surfaces[surface.key] = entry
                    }
                    record(into: &slices[slice, default: SliceTally()])
                    record(into: &all)
                    record(into: &mine)
                }
            }
            if calibration.count < 40, index % 11 == 0, !text.isEmpty { calibration.append(text) }
        }
        return mine
    }

    /// For each surface, how many songs have at least one line that overflows
    /// there, and their share of the songs measured.
    private static func songShares(_ counts: [String: Int], of songs: Int, _ surfaces: [Surface]) -> [String: Any] {
        var out: [String: Any] = [:]
        for surface in surfaces {
            let count = counts[surface.key] ?? 0
            out[surface.key] = ["songs": count, "share": MatchLab.share(count, of: songs)] as [String: Any]
        }
        return out
    }

    /// For each surface, the lines whose width is within 2 % of the space
    /// available, either side: the ones a different layout engine could
    /// decide the other way. `calibration` puts AppKit within about 1.5 % of
    /// SwiftUI, so this bounds how far an overflow share could move.
    private static func nearTheEdge(_ tally: SliceTally, _ surfaces: [Surface]) -> [String: Any] {
        var out: [String: Any] = [:]
        for surface in surfaces {
            let count = (tally.surfaces[surface.key]?.ratios ?? []).filter { abs($0 - 1) <= 0.02 }.count
            out[surface.key] = ["lines": count, "share": MatchLab.share(count, of: tally.lines)] as [String: Any]
        }
        return out
    }

    // MARK: - Helpers

    /// How long line `index` can be read: until its own end when the timeline
    /// has one that Isla honours (`LyricSweep.effectiveEnd`), otherwise until
    /// the next line starts; the last line runs to the track's end, capped at
    /// 10 s, and with no length it has only the cap.
    static func duration(of index: Int, in lines: [LyricsStore.Line], trackEnd: TimeInterval) -> TimeInterval {
        let line = lines[index]
        let next: TimeInterval = LyricSweep.effectiveEnd(of: index, in: lines)
            ?? (index + 1 < lines.count
                ? lines[index + 1].at
                : min(line.at + 10, trackEnd > 0 ? max(trackEnd, line.at) : line.at + 10))
        return next - line.at
    }

    /// The timeline Isla chose, rebuilt from the cached answers the lookup
    /// received: the record with `chosenID`, read the way Isla reads an answer,
    /// with the lookup's own length.
    static func rebuild(lookup: MatchLookup, chosenID: Int, root: URL) -> LyricTimeline? {
        for request in lookup.requests {
            guard let status = request.status, (200..<300).contains(status),
                  let entry = MatchLab.cacheEntry(root, key: request.key) else { continue }
            for record in MatchLab.records(path: request.path, status: entry.status, body: entry.body)
            where record.id == chosenID {
                if case .found(let timeline) = OnlineLyrics.timeline(
                    from: MatchLab.getShaped(record), status: 200, duration: lookup.identity.duration
                ) {
                    return timeline
                }
            }
        }
        return nil
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole > 0 ? String(format: "%.1f%%", 100 * Double(part) / Double(whole)) : "n/a"
    }

    private static func fixed(_ values: [Double], _ p: Double, _ unit: String) -> String {
        values.isEmpty ? "n/a" : String(format: "%.2f %@", LabStats.percentile(values, p), unit)
    }

    /// The same lines laid out by SwiftUI, for the fonts the surfaces use, as
    /// the ratio of AppKit's width to SwiftUI's. SwiftUI's `.system(size:)`
    /// leaves the font's own tracking table behind and AppKit's system font may
    /// not; this is how large the difference is on the sample.
    static func calibrate(sample: [String], surfaces: [Surface]) -> [String: Any] {
        guard !sample.isEmpty else { return ["n": 0] }
        var byFont: [String: Any] = [:]
        for (key, group) in Dictionary(grouping: surfaces, by: \.fontKey) {
            guard let surface = group.first else { continue }
            var ratios: [Double] = []
            var differences: [Double] = []
            for text in sample {
                let appKit = Double(attributed(text, size: surface.size, weight: surface.weight, tracking: surface.tracking).size().width)
                let host = NSHostingView(rootView: Text(text)
                    .font(.system(size: surface.size, weight: surface.weight))
                    .tracking(surface.tracking)
                    .lineLimit(1)
                    .fixedSize())
                let swiftUI = Double(host.fittingSize.width)
                guard swiftUI > 0 else { continue }
                ratios.append(appKit / swiftUI)
                differences.append(appKit - swiftUI)
            }
            byFont[key] = [
                "size": surface.size, "tracking": surface.tracking,
                "appkit_over_swiftui": MatchLab.stats(ratios),
                "appkit_minus_swiftui_pt": MatchLab.stats(differences),
            ] as [String: Any]
        }
        return ["n": sample.count, "by_font": byFont]
    }

    /// Where every number the section measures against comes from. The values
    /// are read from the code at run time (`surfaces()`); the citations are
    /// what a reader needs to check them, and the only part that goes stale
    /// when the code moves.
    static func assumptions(_ surfaces: [Surface]) -> [String: Any] {
        var measured: [String: Any] = [:]
        for surface in surfaces {
            measured[surface.key] = [
                "available_pt": surface.available, "font_pt": surface.size,
                "weight": weightName(surface.weight), "tracking_pt": surface.tracking,
            ] as [String: Any]
        }
        return [
            "measured_surfaces": measured,
            "body_widths_pt": ["default": NotchMetrics.defaultBodyWidth, "minimum": NotchMetrics.minimumBodyWidth],
            "closed_island_caption": "There is none in this build. The compact island is a cover and an equalizer "
                + "(Sources/IslaKit/Notch/CompactIslandLayout.swift:30-67), a new track's peek shows title and artist "
                + "(CompactIslandLayout.swift:73-92), and the ambient moments show a glyph and a name (:100-115); "
                + "none draws a lyric. The one-line sung-line caption is the lyric band of the open player, measured "
                + "here as `band`.",
            "band": [
                "font": "SF system 13 pt bold: Theme.TypeRole.subhead (Sources/IslaKit/UI/Theme.swift:474) "
                    + "with weight .bold (Sources/IslaKit/UI/MediaPane.swift:839)",
                "tracking": "Theme.tracking(forSize:) (Sources/IslaKit/UI/Theme.swift:420-428): 0 at 13 pt "
                    + "(Sources/IslaKit/UI/MediaPane.swift:843)",
                "width": "PlayerLayout.columnWidth = bodyWidth − 220 (Sources/IslaKit/UI/PlayerLayout.swift:136), "
                    + "the sungLine frame (:152); bodyWidth 560 and 480 per NotchMetrics (Sources/IslaKit/Notch/NotchMetrics.swift:10-12)",
                "overflow": "lineLimit defaults to 1 and truncationMode(.tail) (Sources/IslaKit/UI/KaraokeText.swift:121,167-168): truncates, never wraps",
                "text": "MediaPane.bandText: the first row of a bilingual line (Sources/IslaKit/UI/MediaPane.swift:290)",
            ] as [String: Any],
            "column": [
                "font": "13 pt, sung line .bold, others .semibold: LyricsStage.Metrics.column (Sources/IslaKit/UI/LyricsStage.swift:60-62)",
                "tracking": "Theme.tracking(forSize: 13) = 0, applied by LyricRow (Sources/IslaKit/UI/LyricRow.swift:351-352)",
                "width": "PlayerLayout column lyricArea: bodyWidth − columnLinesLeading(268) − paneTrailing(14) "
                    + "(Sources/IslaKit/UI/PlayerLayout.swift:510-513, :565); rows add no horizontal padding "
                    + "(Sources/IslaKit/UI/LyricsStage.swift:411)",
                "overflow": "lineLimit: 1 (Sources/IslaKit/UI/LyricsStage.swift:613), truncationMode(.tail) "
                    + "(Sources/IslaKit/UI/KaraokeText.swift:168): truncates, never wraps",
            ] as [String: Any],
            "tall": [
                "font": "17 pt bold throughout: LyricsStage.Metrics.tall (Sources/IslaKit/UI/LyricsStage.swift:63-65)",
                "tracking": "Theme.tracking(forSize: 17) = −0.2 (Sources/IslaKit/UI/Theme.swift:420-428)",
                "width": "PlayerLayout tall lyricArea: bodyWidth − paneLeading(58) − paneTrailing(14) "
                    + "(Sources/IslaKit/UI/PlayerLayout.swift:541-544)",
                "overflow": "same row, same lineLimit(1) and tail truncation as the column",
            ] as [String: Any],
            "lock_card": "not measured: the lock card is a fixed 460 pt window with its own rows "
                + "(Sources/IslaKit/UI/LockScreenCard.swift); the section asked for the island's surfaces.",
            "measurement": "NSAttributedString.size() in NSFont.systemFont(ofSize:weight:) with the tracking as .kern; "
                + "see `calibration` for the same lines laid out by SwiftUI.",
        ]
    }
}
