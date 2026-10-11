import Foundation
import XCTest
@testable import IslaKit

/// L10 of the Lyrics Accuracy Lab: how many LRCLIB timelines are stamped past
/// the end of their own record, i.e. timed for a longer version of the song
/// than the one they are filed under (ly/VERSION-01). Skipped unless
/// `ISLA_LYRIC_CORPUS` is set.
@MainActor
final class LyricAccuracyLabVersionTests: XCTestCase {

    /// Method: for every corpus object with timed words and a known length,
    /// Isla's own parse (`LocalLyricsDocument.parse`) and Isla's own measure
    /// (`OnlineLyrics.overrun(of:duration:)`) — the figure the stage flags on —
    /// against the record's own `duration`. A track is "timed for a longer
    /// version" above `OnlineLyrics.durationTolerance`, the same threshold
    /// the app uses.
    ///
    /// Assumed: the record's own length is the length of the recording it is
    /// filed under. That is the weakest link — LRCLIB lengths are uploader
    /// metadata, which is exactly why the app compares stamps — so this counts
    /// records that contradict themselves, a floor on the mismatches the app
    /// meets, not an estimate of how many tracks are wrong against a player's
    /// real length.
    ///
    /// Reports counts, percentiles and LRCLIB ids only; never lyric text.
    func testL10TimedForALongerVersion() throws {
        let tracks = try LyricLab.tracks()
        var withWords = 0, withLength = 0, unreadable = 0
        var flagged: [(id: Int, category: String, overrun: Double, linesPast: Int)] = []
        var overruns: [Double] = []
        var perCategory: [String: [String: Int]] = [:]

        for track in tracks {
            guard let synced = track.synced, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            withWords += 1
            guard let document = try? LocalLyricsDocument.parse(synced) else { unreadable += 1; continue }
            guard track.duration > 0 else { continue }
            let timeline = document.timeline(documentID: nil)
            guard let overrun = OnlineLyrics.overrun(of: timeline, duration: track.duration) else { continue }
            withLength += 1
            overruns.append(overrun)
            perCategory[track.category, default: ["tracks": 0, "flagged": 0]]["tracks", default: 0] += 1
            if overrun > OnlineLyrics.durationTolerance {
                let past = timeline.lines.filter { $0.at > track.duration }.count
                flagged.append((track.id, track.category, overrun, past))
                perCategory[track.category, default: [:]]["flagged", default: 0] += 1
            }
        }

        let flaggedOverruns = flagged.map(\.overrun)
        func bucket(_ low: Double, _ high: Double) -> Int {
            flaggedOverruns.filter { $0 > low && $0 <= high }.count
        }
        let share = withLength > 0 ? Double(flagged.count) / Double(withLength) : 0
        let verdict = flagged.isEmpty ? "pass" : "concern"
        let summary = "\(flagged.count) of \(withLength) tracks with a length are stamped more than "
            + "\(Int(OnlineLyrics.durationTolerance)) s past their own end (\(String(format: "%.1f", share * 100)) %); "
            + "median overrun \((flaggedOverruns.isEmpty ? 0 : LabStats.percentile(flaggedOverruns, 0.5)).rounded()) s"
        if !flagged.isEmpty { LyricLab.finding("L10: \(summary)") }
        LyricLab.write(section: "L10_timed_for_a_longer_version", [
            "tracks": tracks.count,
            "tracksWithTimedWords": withWords,
            "tracksWithTimedWordsAndALength": withLength,
            "unreadableByIsla": unreadable,
            "toleranceSeconds": OnlineLyrics.durationTolerance,
            "flaggedTracks": flagged.count,
            "flaggedShare": share,
            "flaggedLinesPastTheEnd": flagged.map(\.linesPast).reduce(0, +),
            "flaggedOverrunSeconds": LabStats.summary(flaggedOverruns),
            "flaggedOverrunBuckets": [
                "over_3_to_10_s": bucket(OnlineLyrics.durationTolerance, 10),
                "over_10_to_30_s": bucket(10, 30),
                "over_30_to_60_s": bucket(30, 60),
                "over_60_s": flaggedOverruns.filter { $0 > 60 }.count,
            ],
            "allTracksOverrunSeconds": LabStats.summary(overruns),
            "perCategory": perCategory,
            "flaggedIDs": flagged.sorted { $0.overrun > $1.overrun }.map { $0.id },
            "verdict": verdict,
            "summary": summary,
        ])
    }
}
