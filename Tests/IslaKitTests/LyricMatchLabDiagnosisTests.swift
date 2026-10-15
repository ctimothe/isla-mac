import Foundation
import XCTest
@testable import IslaKit

/// Why did Isla's matcher accept or refuse a record? Asked of the records the
/// classifier singled out, by running Isla's own predicates on each.
///
/// Input: `<root>/reports/diagnose-input.jsonl`, written by the Python
/// classifier, one line per lookup worth explaining:
///
///     {track_id, variant, verdict, identity{player_id,title,artist,album,duration},
///      request_keys:[…], fit_ids:[…], chosen_id, cluster_ids:[…]}
///
/// - For `miss-rejected`, `miss-unqueried` and `miss-tolerance` every record in
///   `fit_ids` is examined: a record that fitted, and was not shown.
/// - For `wrong-song`, `uncertain`, `correct-longer-cut` and `alt-script` the
///   `chosen_id` record is examined: a record that was shown.
///
/// **No network, ever.** This file never builds a `URLSession` and never
/// constructs a `ReplayTransport`; it reads `cache/isla` and `cache/py` files
/// and nothing else. A record is looked up in the `cache/isla` bodies named by
/// the line's `request_keys` first, then in an index of every LRCLIB body in
/// `cache/py` (URLs under `https://lrclib.net/`; iTunes and Deezer bodies are
/// skipped), built once.
///
/// The predicates are the ones `OnlineLyrics.bestCandidate` evaluates, called
/// as it calls them: `comparable(baseTitle(…))` for the title,
/// `comparable(primaryArtist(…))` contained in the row's comparable artist,
/// `durationTolerance` for the length, then Isla's parser. `accepted` is
/// `bestCandidate(in: [row], …)` itself, so the explanation can be checked
/// against the real decision: `consistent` is false for any row where the first
/// failing check and `accepted` disagree, which would mean this file's reading
/// of the order has drifted from the matcher's.
///
/// `first_failing` follows `bestCandidate`'s order: `instrumental`, `empty` (no
/// synced lyrics), `title`, `artist`, `duration`, `unreadable` (the parser
/// refused the words), then `unreachable` (every line is past the track's end).
/// `overrun` is reported beside it and never as a failure: it ranks rows
/// against each other and rejects none.
///
/// Titles and artists, and their comparable forms, are metadata and are
/// written; no lyric text is.
final class LyricMatchLabDiagnosisTests: XCTestCase {
    static let fitVerdicts: Set<String> = ["miss-rejected", "miss-unqueried", "miss-tolerance"]
    static let chosenVerdicts: Set<String> = ["wrong-song", "uncertain", "correct-longer-cut", "alt-script"]

    /// A record found, and in which cache.
    struct Located {
        let record: MatchRecord
        let source: String
    }

    /// Every LRCLIB record in `cache/py`, by id, read once. The first file in
    /// name order wins an id, so two runs index the same way.
    static func indexPy(_ root: URL) -> [Int: MatchRecord] {
        let fm = FileManager.default
        let directory = root.appendingPathComponent("cache/py", isDirectory: true)
        var index: [Int: MatchRecord] = [:]
        for file in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() where file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlString = object["url"] as? String, urlString.hasPrefix("https://lrclib.net/"),
                  let url = URL(string: urlString),
                  let status = (object["status"] as? NSNumber)?.intValue,
                  let encoded = object["body_b64"] as? String,
                  let body = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
            else { continue }
            for record in MatchLab.records(path: ReplayTransport.path(of: url), status: status, body: body) {
                if let id = record.id, index[id] == nil { index[id] = record }
            }
        }
        return index
    }

    /// The `cache/isla` answers for `keys`: each one's request path and the
    /// records it holds. A key whose file is gone is skipped.
    static func islaExchanges(_ root: URL, keys: [String]) -> [(path: String, records: [MatchRecord])] {
        keys.compactMap { key in
            guard let entry = MatchLab.cacheEntry(root, key: key), let url = URL(string: entry.url) else { return nil }
            let path = ReplayTransport.path(of: url)
            return (path, MatchLab.records(path: path, status: entry.status, body: entry.body))
        }
    }

    /// Isla's checks on one record against one identity.
    static func evaluate(record: MatchRecord, identity: LocalTrackIdentity) -> [String: Any] {
        let wantTitle = OnlineLyrics.comparable(OnlineLyrics.baseTitle(identity.title))
        let wantArtist = OnlineLyrics.comparable(OnlineLyrics.primaryArtist(identity.artist))
        let rowTitle = record.trackName.map { OnlineLyrics.comparable(OnlineLyrics.baseTitle($0)) }
        let rowArtist = record.artistName.map(OnlineLyrics.comparable)

        let identityUsable = !wantTitle.isEmpty && !wantArtist.isEmpty
        let instrumental = record.instrumental == true
        let synced = record.syncedLyrics ?? ""
        let hasSynced = !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let titleEqual = rowTitle == wantTitle
        let artistContains = rowArtist?.contains(wantArtist) ?? false

        // `bestCandidate` skips this check when the identity's length is
        // unknown, and a row with no length cannot pass it when it is known.
        var withinTolerance: Bool?
        var durationDifference: Double?
        if identity.duration > 0 {
            if let length = record.duration {
                durationDifference = abs(length - identity.duration)
                withinTolerance = abs(length - identity.duration) <= OnlineLyrics.durationTolerance
            } else {
                withinTolerance = false
            }
        }

        // The parser's verdict as a lookup reads it, and — from the document
        // itself — whether its words fit the track and how far they run past it
        // (measured before `reachable` drops the lines past the end, exactly
        // where `bestCandidate` measures).
        var parse = "empty"
        var fits: Bool?
        var overrun: Double?
        if hasSynced {
            switch OnlineLyrics.timeline(from: MatchLab.getShaped(record), status: 200, duration: identity.duration) {
            case .found: parse = "found"
            case .none: parse = "none"
            case .unreadable: parse = "unreadable"
            case .failed: parse = "failed"
            }
            if let document = try? LocalLyricsDocument.parse(synced) {
                let timeline = document.timeline(documentID: nil)
                fits = OnlineLyrics.fits(timeline, duration: identity.duration)
                overrun = OnlineLyrics.overrun(of: timeline, duration: identity.duration)
            }
        }

        let candidate = OnlineLyrics.bestCandidate(in: [MatchLab.searchRow(record)], for: identity)
        let accepted = candidate.match != nil

        var firstFailing: String?
        if !identityUsable { firstFailing = "identity" }
        else if instrumental { firstFailing = "instrumental" }
        else if !hasSynced { firstFailing = "empty" }
        else if !titleEqual { firstFailing = "title" }
        else if !artistContains { firstFailing = "artist" }
        else if withinTolerance == false { firstFailing = "duration" }
        else if parse == "unreadable" { firstFailing = "unreadable" }
        else if !accepted { firstFailing = "unreachable" }

        return [
            "want_title": wantTitle,
            "row_title_comparable": MatchLab.orNull(rowTitle),
            "want_artist": wantArtist,
            "row_artist_comparable": MatchLab.orNull(rowArtist),
            "title_equal": titleEqual,
            "artist_contains": artistContains,
            "within_tolerance": MatchLab.orNull(withinTolerance),
            "duration_difference": MatchLab.orNull(durationDifference),
            "instrumental": instrumental,
            "has_synced": hasSynced,
            "parse": parse,
            "fits": MatchLab.orNull(fits),
            "overrun": MatchLab.orNull(overrun),
            "accepted": accepted,
            "saw_unreadable": candidate.sawUnreadable,
            "first_failing": MatchLab.orNull(firstFailing),
            "consistent": (firstFailing == nil) == accepted,
        ]
    }

    func testDiagnosis() throws {
        let root = try MatchLab.requireRoot()
        let input = try MatchLab.readJSONL(root.appendingPathComponent("reports/diagnose-input.jsonl"))
        let pyIndex = Self.indexPy(root)

        var rows: [[String: Any]] = []
        var tally: [String: [String: Int]] = [:]
        var notFound = 0, inconsistent = 0

        for line in input {
            guard let trackID = line["track_id"] as? String, let variant = line["variant"] as? String,
                  let verdict = line["verdict"] as? String,
                  let identityObject = line["identity"] as? [String: Any] else { continue }
            let identity = LocalTrackIdentity(
                playerID: (identityObject["player_id"] as? String) ?? variant,
                title: (identityObject["title"] as? String) ?? "",
                artist: (identityObject["artist"] as? String) ?? "",
                album: (identityObject["album"] as? String) ?? "",
                duration: (identityObject["duration"] as? NSNumber)?.doubleValue ?? 0,
                recordingID: nil
            )

            let role: String
            let ids: [Int]
            if Self.fitVerdicts.contains(verdict) {
                role = "fit"
                ids = ((line["fit_ids"] as? [NSNumber]) ?? []).map(\.intValue)
            } else if Self.chosenVerdicts.contains(verdict) {
                role = "chosen"
                ids = (line["chosen_id"] as? NSNumber).map { [$0.intValue] } ?? []
            } else {
                continue
            }

            let keys = (line["request_keys"] as? [String]) ?? []
            let exchanges = Self.islaExchanges(root, keys: keys)
            // The exact requests, for the miss whose cause may be a query that
            // was never made: path and query as Isla sent them.
            let requested = exchanges.map(\.path)

            for id in ids {
                var located: Located?
                search: for exchange in exchanges {
                    for record in exchange.records where record.id == id {
                        located = Located(record: record, source: "isla")
                        break search
                    }
                }
                if located == nil, let record = pyIndex[id] { located = Located(record: record, source: "py") }

                var row: [String: Any] = [
                    "track_id": trackID, "variant": variant, "verdict": verdict, "role": role,
                    "record_id": id,
                    "identity_title": identity.title, "identity_artist": identity.artist,
                    "identity_duration": identity.duration,
                ]
                if let located {
                    row["found"] = true
                    row["source"] = located.source
                    row["row_title"] = MatchLab.orNull(located.record.trackName)
                    row["row_artist"] = MatchLab.orNull(located.record.artistName)
                    row["row_duration"] = MatchLab.orNull(located.record.duration)
                    for (key, value) in Self.evaluate(record: located.record, identity: identity) { row[key] = value }
                    if (row["consistent"] as? Bool) == false { inconsistent += 1 }
                } else {
                    notFound += 1
                    row["found"] = false
                    row["first_failing"] = NSNull()
                }
                if verdict == "miss-unqueried" { row["requested_urls"] = requested }
                let failing = (row["first_failing"] as? String) ?? (located == nil ? "record-not-found" : "none")
                tally[verdict, default: [:]][failing, default: 0] += 1
                rows.append(row)
            }
        }

        try MatchLab.writeJSONL(rows, to: MatchLab.resultsURL(root, "diagnosis.jsonl"))
        let detail = tally.sorted { $0.key < $1.key }.map { verdict, counts in
            verdict + "{" + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "}"
        }.joined(separator: " ")
        // The prefix the coordinator named; the script greps for it.
        print("LYRIC-MATCH diagnosis \(rows.count) rows from \(input.count) lines, "
            + "\(notFound) record(s) not in any cache, \(inconsistent) inconsistent: \(detail)")
    }
}
