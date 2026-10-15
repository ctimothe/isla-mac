import CryptoKit
import Foundation
import XCTest
@testable import IslaKit

// The Lyrics Match Lab's plumbing: the env gate, the corpus readers, the
// record/replay transport, the recovery of which LRCLIB record a lookup chose,
// the per-script syllable heuristic, and the JSON writers.
//
// The 2026-10-11 Lyrics Accuracy Lab (`LyricAccuracyLabSupport.swift`) fetched
// records by id and asked what Isla does with a record it was already handed.
// This one asks the question that came first: does Isla *find* the right
// record for the song that is playing? It drives the shipped
// `OnlineLyrics.lookUp` and `OnlineLyrics.bestCandidate` over a corpus, through
// a transport that replays recorded HTTP answers, and writes numbers. The
// verdicts (right song, wrong song, a miss that was recoverable) are the
// Python classifier's, against an oracle that shares no code with Isla.
//
// Nothing here runs in `./scripts/check`. Every case calls
// `MatchLab.requireRoot()` first, which throws `XCTSkip` unless
// `ISLA_MATCH_LAB` names a directory, so the ordinary suite skips the lab in
// microseconds and never reads a file or opens a socket.
// `Scripts/lyric-match-lab.sh` sets it.
//
// The corpus is copyrighted lyric text. It lives only under the corpus root;
// everything this harness writes carries numbers, LRCLIB ids, titles and
// artist names, never a lyric line. Keep it that way when adding a measurement.
//
// Nothing here touches `UserDefaults.standard`, a real player, an audio device
// or Accessibility, and it launches nothing: the "app" under test is the
// library, called as a function.

struct MatchLabError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Corpus rows

/// One line of `resolved/variants.jsonl`: an identity as one player reports it.
struct MatchVariant {
    let trackID: String
    let slice: String
    let variant: String
    let playerID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    var identity: LocalTrackIdentity {
        LocalTrackIdentity(
            playerID: playerID, title: title, artist: artist, album: album,
            duration: duration, recordingID: nil
        )
    }

    init?(_ object: [String: Any]) {
        guard let trackID = object["track_id"] as? String,
              let variant = object["variant"] as? String else { return nil }
        self.trackID = trackID
        self.variant = variant
        // The slice is part of the id ("kpop-jpop-anime/014"), so a line
        // that omits the field still sorts into its slice.
        self.slice = (object["slice"] as? String)
            ?? String(trackID.split(separator: "/").first ?? "")
        self.playerID = (object["player_id"] as? String) ?? variant
        self.title = (object["title"] as? String) ?? ""
        self.artist = (object["artist"] as? String) ?? ""
        self.album = (object["album"] as? String) ?? ""
        // A missing or null duration is "unknown", which `request(for:)` and
        // the matcher both read as zero.
        self.duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// One LRCLIB object under `wordtimed/<slice>/<id>.json`.
struct MatchWordRecord {
    let id: Int
    let slice: String
    let trackID: String?
    let sameSong: Bool?
    let duration: TimeInterval
    let hasWordSync: Bool
    let instrumental: Bool
    let synced: String?
    let lyricsfile: String?
    /// The file's bytes, handed to Isla's own response decoder unchanged.
    let raw: Data
}

private struct MatchTextFields: Decodable {
    var syncedLyrics: String?
    var lyricsfile: String?
}

/// One row of an LRCLIB `get` or `search` answer, with the id Isla's own
/// `SearchRow` does not decode: the id is what the lab is after.
struct MatchRecord: Decodable {
    var id: Int?
    var trackName: String?
    var artistName: String?
    var duration: Double?
    var instrumental: Bool?
    var syncedLyrics: String?
}

/// A request the lookup made, as the results file lists it.
struct MatchRequestRef {
    let key: String
    let path: String
    let status: Int?
    let cached: Bool
}

/// One line of `results/isla-lookups.jsonl`, read back by the later sections.
struct MatchLookup {
    let trackID: String
    let variant: String
    let identity: LocalTrackIdentity
    let outcome: String
    let chosenID: Int?
    let chosenVia: String?
    let requests: [MatchRequestRef]

    var slice: String { String(trackID.split(separator: "/").first ?? "") }

    init?(_ object: [String: Any]) {
        guard let trackID = object["track_id"] as? String,
              let variant = object["variant"] as? String,
              let outcome = object["outcome"] as? String,
              let identity = object["identity"] as? [String: Any] else { return nil }
        self.trackID = trackID
        self.variant = variant
        self.outcome = outcome
        self.identity = LocalTrackIdentity(
            playerID: (identity["player_id"] as? String) ?? variant,
            title: (identity["title"] as? String) ?? "",
            artist: (identity["artist"] as? String) ?? "",
            album: (identity["album"] as? String) ?? "",
            duration: (identity["duration"] as? NSNumber)?.doubleValue ?? 0,
            recordingID: nil
        )
        self.chosenID = (object["chosen_id"] as? NSNumber)?.intValue
        self.chosenVia = object["chosen_via"] as? String
        self.requests = ((object["requests"] as? [[String: Any]]) ?? []).compactMap { request in
            guard let key = request["key"] as? String else { return nil }
            return MatchRequestRef(
                key: key,
                path: (request["path"] as? String) ?? "",
                status: (request["status"] as? NSNumber)?.intValue,
                cached: (request["cached"] as? Bool) ?? false
            )
        }
    }
}

// MARK: - The lab

enum MatchLab {
    static let rootKey = "ISLA_MATCH_LAB"
    static let recordKey = "ISLA_MATCH_RECORD"
    /// A ceiling on live requests in one process: a development run against a
    /// hand-made corpus must not be able to turn into a crawl by a typo.
    static let maxLiveKey = "ISLA_MATCH_MAX_LIVE"
    /// Seconds between two live LRCLIB requests for this run, when slower than
    /// the SPEC's gap (`ReplayTransport.gap(for:)`).
    static let lrclibGapKey = "ISLA_MATCH_LRCLIB_GAP"
    /// `1` trips a host on its first 429: no retry, and no live request goes
    /// to it for the rest of the run. On 2026-10-15 LRCLIB let three requests
    /// through after an hour's cool-down and refused the fourth, so the 30/60/120 s
    /// retries and the `tripAfter` requests were all refusals that extend the
    /// ban. A collector probing a banned limiter on a schedule sets this, and
    /// each probe then costs the limiter one refused request. The resolver's
    /// twin is `LAB_STOP_AT_429` (common.py).
    static let stopAt429Key = "ISLA_MATCH_STOP_AT_429"
    /// The directory under the root that holds the harness output, default
    /// `results`. A candidate change to Isla is scored beside the baseline by
    /// pointing this at another name (`ISLA_MATCH_OUT=candidate`): the same
    /// cache answers both, and neither overwrites the other. The classifier
    /// reads it with `--results`.
    static let outKey = "ISLA_MATCH_OUT"
    static let defaultOut = "results"
    /// The directory under the root the classifier writes its report to,
    /// default `reports`; the diagnosis case reads its input from there.
    static let reportsKey = "ISLA_MATCH_REPORTS"
    static let defaultReports = "reports"

    /// The lab's own version, so a results file says which harness wrote it.
    static let harnessVersion = "2026-10-15.1"

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Live requests on a cache miss are allowed only when asked for. Without
    /// it a miss is `uncached`, a fact about the cache and never about Isla.
    static var recording: Bool { environment[recordKey] == "1" }
    static var maxLiveRequests: Int? { environment[maxLiveKey].flatMap { Int($0) } }

    static func requireRoot() throws -> URL {
        guard let path = environment[rootKey], !path.isEmpty else {
            throw XCTSkip("set \(rootKey)=<dir> to run the Lyrics Match Lab (Scripts/lyric-match-lab.sh)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("\(rootKey) does not name a directory: \(path)")
        }
        for key in [outKey, reportsKey] {
            if let value = environment[key], !value.isEmpty, !isPlainDirectoryName(value) {
                throw MatchLabError("\(key)=\(value) is not a plain directory name under the root")
            }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A directory name under the root: no separators, not empty, not `..`.
    /// Anything else could write outside the corpus root.
    static func isPlainDirectoryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private static func directoryName(key: String, default defaultName: String, _ environment: [String: String]) -> String {
        guard let value = environment[key], !value.isEmpty else { return defaultName }
        return isPlainDirectoryName(value) ? value : defaultName
    }

    /// Where results are written and read: `ISLA_MATCH_OUT`, else `results`.
    /// `requireRoot` refuses a value that is not a plain name, so a bad one
    /// never reaches here during a run.
    static var outDirectory: String { directoryName(key: outKey, default: defaultOut, environment) }
    static var reportsDirectory: String { directoryName(key: reportsKey, default: defaultReports, environment) }

    static func resultsURL(_ root: URL, _ name: String, out: String? = nil) -> URL {
        root.appendingPathComponent(out ?? outDirectory, isDirectory: true).appendingPathComponent(name)
    }

    static func reportsURL(_ root: URL, _ name: String, reports: String? = nil) -> URL {
        root.appendingPathComponent(reports ?? reportsDirectory, isDirectory: true).appendingPathComponent(name)
    }

    // MARK: JSON in and out

    static func readJSONL(_ url: URL) throws -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else {
            throw MatchLabError("cannot read \(url.path)")
        }
        var rows: [[String: Any]] = []
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // A line a builder is still writing fails to parse and is skipped,
            // not fatal: the next run reads it whole.
            if let object = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any] {
                rows.append(object)
            }
        }
        return rows
    }

    static func readVariants(_ root: URL) throws -> [MatchVariant] {
        try readJSONL(root.appendingPathComponent("resolved/variants.jsonl")).compactMap(MatchVariant.init)
    }

    static func readLookups(_ root: URL) throws -> [MatchLookup] {
        try readJSONL(resultsURL(root, "isla-lookups.jsonl")).compactMap(MatchLookup.init)
    }

    /// `null` for a missing value. An `Optional` inside `[String: Any]` is not
    /// something `JSONSerialization` can write, and the crash it raises names
    /// no key.
    static func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

    /// JSON has no NaN or infinity; a percentile of nothing is null, not a crash.
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let double as Double:
            return double.isFinite ? (double * 1_000_000).rounded() / 1_000_000 : NSNull()
        case let dict as [String: Any]:
            return dict.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        default:
            return value
        }
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: sanitize(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    /// One compact object a line, keys sorted: two runs over the same cache
    /// write the same bytes, which is how the determinism check compares them.
    static func writeJSONL(_ rows: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var out = Data()
        for row in rows {
            out.append(try JSONSerialization.data(
                withJSONObject: sanitize(row), options: [.sortedKeys, .withoutEscapingSlashes]
            ))
            out.append(0x0A)
        }
        try out.write(to: url, options: .atomic)
    }

    static func report(section: String, summary: String) {
        print("MATCH-LAB \(section) — \(summary)")
    }

    // MARK: Cache

    struct CacheEntry {
        let url: String
        let status: Int
        let body: Data
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func cacheFile(_ root: URL, key: String, store: String = "isla") -> URL {
        root.appendingPathComponent("cache/\(store)", isDirectory: true).appendingPathComponent("\(key).json")
    }

    /// The cached answer for `key`: this harness's own store first, then the
    /// Python resolver's. Both key on the SHA-256 of the exact URL string, so
    /// a hit in the resolver's store is the very request Isla would send, and
    /// LRCLIB's answer does not depend on who asked — only the User-Agent
    /// differs. Reading it saves a live search wherever Isla asks exactly what
    /// the resolver already asked, which matters because LRCLIB's /api/search
    /// allows about ten requests a minute (2026-10-15). Writes still go only
    /// to `cache/isla`.
    static func cacheEntry(_ root: URL, key: String) -> CacheEntry? {
        for store in ["isla", "py"] {
            guard let data = try? Data(contentsOf: cacheFile(root, key: key, store: store)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = (object["status"] as? NSNumber)?.intValue,
                  let encoded = object["body_b64"] as? String,
                  let body = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
            else { continue }
            return CacheEntry(url: (object["url"] as? String) ?? "", status: status, body: body)
        }
        return nil
    }

    /// The cached answer for `url`: its exact string first, then the same
    /// request as the Python resolver spells it (`resolverForm`). An answer
    /// found the second way comes back `aliased`, so the caller can keep a
    /// copy under the key Isla's own request hashes to, and every later
    /// reader (this harness in replay, classify.py) finds it by that key.
    static func cacheEntry(_ root: URL, for url: URL) -> (entry: CacheEntry, aliased: Bool)? {
        if let entry = cacheEntry(root, key: sha256Hex(url.absoluteString)) { return (entry, false) }
        guard let alias = resolverForm(of: url), alias != url.absoluteString,
              let entry = cacheEntry(root, key: sha256Hex(alias)), entry.url == alias
        else { return nil }
        return (entry, true)
    }

    /// `url` as the Python resolver's `build_url` spells the same request: the
    /// same names and values in the same order, each percent-encoded as
    /// `urllib.parse.quote(safe="")` does, which leaves only `A-Z a-z 0-9 - . _ ~`
    /// bare. URLComponents also leaves `'()!,:;@/?$*` bare, so for
    /// "Don't Stop Me Now" the two strings differ, and keyed on the exact
    /// string the resolver's /api/get never answered Isla's identical first
    /// lookup — one LRCLIB request paid for twice while LRCLIB allows about
    /// ten a minute. A bare `+` is a space to the server (form decoding), so
    /// it turns into `%20` here: Isla's "Dan + Shay" is a different request
    /// from the resolver's "Dan %2B Shay" and must never be answered by it.
    static func resolverForm(of url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty else { return nil }
        let bare = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func spelled(_ text: Substring) -> String? {
            text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
                .addingPercentEncoding(withAllowedCharacters: bare)
        }
        var pairs: [String] = []
        for item in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = spelled(parts[0]), let value = spelled(parts.count > 1 ? parts[1] : "") else {
                return nil
            }
            pairs.append("\(name)=\(value)")
        }
        components.percentEncodedQuery = nil
        guard let base = components.url?.absoluteString else { return nil }
        return base + "?" + pairs.joined(separator: "&")
    }

    static func store(_ root: URL, key: String, url: String, status: Int, body: Data) throws {
        let file = cacheFile(root, key: key)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let object: [String: Any] = [
            "url": url,
            "status": status,
            "body_b64": body.base64EncodedString(),
            "fetched_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    // MARK: Word-timed records

    /// Every `wordtimed/<slice>/<id>.json`, slices in name order and ids
    /// numerically, so two runs list the same records in the same order.
    static func readWordRecords(_ root: URL) -> [MatchWordRecord] {
        let fm = FileManager.default
        let base = root.appendingPathComponent("wordtimed", isDirectory: true)
        var records: [MatchWordRecord] = []
        let slices = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted()
        for slice in slices where !slice.hasPrefix(".") && !slice.hasPrefix("_") {
            let directory = base.appendingPathComponent(slice, isDirectory: true)
            let files = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }
            for file in files {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                // The text through `JSONDecoder`, the decoder Isla's response
                // path uses: `JSONSerialization` was seen to drop a leading
                // U+FEFF that `JSONDecoder` keeps, and the reference reader
                // must see exactly the bytes Isla sees.
                let text = try? JSONDecoder().decode(MatchTextFields.self, from: data)
                records.append(MatchWordRecord(
                    id: (object["id"] as? NSNumber)?.intValue ?? Int(file.dropLast(5)) ?? -1,
                    slice: slice,
                    trackID: object["track_id"] as? String,
                    sameSong: object["same_song"] as? Bool,
                    duration: (object["duration"] as? NSNumber)?.doubleValue ?? 0,
                    hasWordSync: (object["hasWordSync"] as? Bool) ?? false,
                    instrumental: (object["instrumental"] as? Bool) ?? false,
                    synced: text?.syncedLyrics,
                    lyricsfile: text?.lyricsfile,
                    raw: data
                ))
            }
        }
        return records.sorted { ($0.slice, $0.id) < ($1.slice, $1.id) }
    }

    // MARK: Statistics

    static func stats(_ values: [Double]) -> [String: Any] { LabStats.summary(values) }

    static func share(_ part: Int, of whole: Int) -> Any {
        whole > 0 ? Double(part) / Double(whole) : NSNull()
    }

    // MARK: Candidates and id recovery

    /// A record a lookup (or a pooled matcher call) saw, and where.
    struct Candidate {
        /// Which request, in the order Isla made them.
        let exchange: Int
        /// Which row of that answer.
        let row: Int
        /// `get` for the exact query, `search` for a search row.
        let via: String
        let record: MatchRecord
    }

    static func isGet(_ path: String) -> Bool { path.hasPrefix("/api/get") }
    static func isSearch(_ path: String) -> Bool { path.hasPrefix("/api/search") }

    /// The records in one answer: the single object of `/api/get`, or the rows
    /// of `/api/search`. A body that does not decode holds none.
    static func records(path: String, status: Int?, body: Data?) -> [MatchRecord] {
        guard let status, (200..<300).contains(status), let body else { return [] }
        if isGet(path) {
            return (try? JSONDecoder().decode(MatchRecord.self, from: body)).map { [$0] } ?? []
        }
        if isSearch(path) {
            return (try? JSONDecoder().decode([MatchRecord].self, from: body)) ?? []
        }
        return []
    }

    static func candidates(
        _ exchanges: [(path: String, status: Int?, body: Data?)]
    ) -> [Candidate] {
        var out: [Candidate] = []
        for (index, exchange) in exchanges.enumerated() {
            let via = isGet(exchange.path) ? "get" : "search"
            let rows = records(path: exchange.path, status: exchange.status, body: exchange.body)
            for (row, record) in rows.enumerated() {
                out.append(Candidate(exchange: index, row: row, via: via, record: record))
            }
        }
        return out
    }

    /// A record in the shape of an `/api/get` answer, so Isla's own
    /// `timeline(from:status:duration:)` reads a search row exactly as it reads
    /// the exact query's.
    static func getShaped(_ record: MatchRecord) -> Data {
        struct Wrapped: Encodable {
            var syncedLyrics: String?
            var instrumental: Bool?
            var duration: Double?
        }
        // `JSONEncoder` keeps a string byte for byte, a leading U+FEFF included.
        return (try? JSONEncoder().encode(Wrapped(
            syncedLyrics: record.syncedLyrics, instrumental: record.instrumental, duration: record.duration
        ))) ?? Data()
    }

    static func searchRow(_ record: MatchRecord) -> OnlineLyrics.SearchRow {
        OnlineLyrics.SearchRow(
            trackName: record.trackName, artistName: record.artistName, duration: record.duration,
            instrumental: record.instrumental, syncedLyrics: record.syncedLyrics
        )
    }

    static func sameLines(_ a: [LyricsStore.Line], _ b: [LyricsStore.Line]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.at == $1.at && $0.text == $1.text }
    }

    /// The same lines AND the same `overrun`. `reachable` drops the lines past
    /// the track's end, so a record stamped for a longer cut and a record that
    /// ends where this one's reachable lines end can read identically; the
    /// first carries an overrun and is shown as timed for a longer version, the
    /// second does not. Matching on lines alone credited a fitting search row
    /// to an overrunning `/api/get` record (adversarial review F11).
    static func sameTimeline(_ a: LyricTimeline, _ b: LyricTimeline) -> Bool {
        guard sameLines(a.lines, b.lines) else { return false }
        switch (a.overrun, b.overrun) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 1e-6
        default: return false
        }
    }

    /// Which record is the one behind `target`, the timeline Isla returned.
    ///
    /// Each candidate is read through Isla's own path (`timeline(from:status:
    /// duration:)`, with a search row wrapped as a get-shaped object), and the
    /// ones whose lines equal the target's are the answer. Both sides were cut
    /// at the track's end by the same `reachable`, so the lines are compared
    /// whole: a record whose lines merely start the same way is another
    /// record. The `overrun` must be equal too (`sameTimeline`). A search row must also be one the matcher would accept on its
    /// own — `bestCandidate(in: [row])` is Isla's per-row test of title,
    /// artist and length — so a wrong-song copy of the same stamps can never be
    /// named as the choice.
    ///
    /// Several records can carry identical lines: LRCLIB copies one timeline
    /// onto many releases. Isla's tie-break is reproduced, not guessed: the
    /// exact query and an earlier search outrank a later one (`overruns` and
    /// the early return both keep what is held), and inside one search answer
    /// the closest listed length wins with the first row on a tie
    /// (`bestCandidate`'s strict `<`). The first by that order is the choice;
    /// every distinct id is listed as ambiguous.
    static func recover(
        target: LyricTimeline, identity: LocalTrackIdentity, candidates: [Candidate]
    ) -> (id: Int, via: String, ambiguous: [Int])? {
        var matching: [(candidate: Candidate, difference: Double)] = []
        for candidate in candidates {
            let record = candidate.record
            guard record.id != nil, record.instrumental != true else { continue }
            if candidate.via == "search" {
                guard let match = OnlineLyrics.bestCandidate(in: [searchRow(record)], for: identity).match,
                      sameTimeline(match.timeline, target) else { continue }
            }
            guard case .found(let timeline) = OnlineLyrics.timeline(
                from: getShaped(record), status: 200, duration: identity.duration
            ), sameTimeline(timeline, target) else { continue }
            let difference = candidate.via == "search" && identity.duration > 0
                ? abs((record.duration ?? 0) - identity.duration) : 0
            matching.append((candidate, difference))
        }
        matching.sort {
            ($0.candidate.exchange, $0.difference, $0.candidate.row)
                < ($1.candidate.exchange, $1.difference, $1.candidate.row)
        }
        guard let first = matching.first, let id = first.candidate.record.id else { return nil }
        var seen = Set<Int>()
        var ids: [Int] = []
        for entry in matching {
            if let candidateID = entry.candidate.record.id, seen.insert(candidateID).inserted {
                ids.append(candidateID)
            }
        }
        return (id, first.candidate.via, ids.count > 1 ? ids : [])
    }

    // MARK: Syllables

    /// A line's syllables, estimated per script.
    ///
    /// Latin, Cyrillic and Greek: groups of vowels in a word (a word with
    /// none, "hmm" or "shh", is one). Han and kana: one a character. Hangul:
    /// one a syllable block. Anything else (Arabic, Hebrew, Thai, Devanagari…):
    /// graphemes divided by 2.5, and the line is flagged low-confidence when
    /// those graphemes are at least half its letters.
    ///
    /// A heuristic and a stated one: it does not know that English drops a
    /// final "e", counts "y" as a vowel except at the start of a word before
    /// another vowel, and reads digits as nothing. The slice-to-slice shape is
    /// what the section reports; no single line's count is claimed exact.
    struct Syllables {
        var count: Double = 0
        var letters = 0
        var fallbackLetters = 0
        var lowConfidence: Bool { fallbackLetters > 0 && fallbackLetters * 2 >= letters }
    }

    private enum LetterClass { case latin, cyrillic, greek, han, kana, hangul, other }

    private static func classify(_ scalar: Unicode.Scalar) -> LetterClass {
        switch scalar.value {
        case 0x41...0x24F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x370...0x3FF, 0x1F00...0x1FFF:
            return .greek
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF, 0x3005, 0x3007:
            return .han
        case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
            return .kana
        case 0xAC00...0xD7A3:
            return .hangul
        default:
            return .other
        }
    }

    private static let cyrillicVowels = Set("аеёиоуыэюяіїєѐѝәөүұўӯӣӧӓ".unicodeScalars)
    private static let greekVowels = Set("αεηιουω".unicodeScalars)
    private static let latinVowels = Set("aeiouyæœøıə".unicodeScalars)
    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`"]

    static func syllables(in text: String) -> Syllables {
        var result = Syllables()
        // The letters of the word being read, as lowercased base letters, and
        // which script they belong to.
        var word: [Unicode.Scalar] = []
        var wordClass: LetterClass?

        func flush() {
            defer { word.removeAll(keepingCapacity: true); wordClass = nil }
            guard let kind = wordClass, !word.isEmpty else { return }
            var groups = 0
            var inVowel = false
            for (index, base) in word.enumerated() {
                var vowel: Bool
                switch kind {
                case .cyrillic: vowel = cyrillicVowels.contains(base)
                case .greek: vowel = greekVowels.contains(base)
                default: vowel = latinVowels.contains(base)
                }
                // "yes", "you": a "y" that opens a word before a vowel is a
                // consonant.
                if kind == .latin, base == "y", index == 0, index + 1 < word.count,
                   latinVowels.contains(word[index + 1]), word[index + 1] != "y" {
                    vowel = false
                }
                if vowel, !inVowel { groups += 1 }
                inVowel = vowel
            }
            result.count += Double(max(groups, 1))
        }

        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            if apostrophes.contains(scalar) {
                // "don't" is one word, not "don" and "t".
                continue
            }
            guard scalar.properties.isAlphabetic else {
                flush()
                continue
            }
            result.letters += 1
            let letterClass = classify(scalar)
            switch letterClass {
            case .han, .kana, .hangul:
                flush()
                result.count += 1
            case .other:
                flush()
                result.fallbackLetters += 1
                result.count += 1.0 / 2.5
            case .latin, .cyrillic, .greek:
                if let current = wordClass, current != letterClass { flush() }
                wordClass = letterClass
                var base = scalar
                if scalar.value >= 0xFF21, scalar.value <= 0xFF5A, let narrow = Unicode.Scalar(scalar.value - 0xFEE0) {
                    base = narrow
                }
                if letterClass != .cyrillic {
                    // A grapheme's base letter without its accent: "é" is an
                    // "e". Cyrillic is left alone because "й" decomposes to
                    // "и" and is a consonant.
                    let plain = base.isASCII
                        ? base
                        : String(character).decomposedStringWithCanonicalMapping.unicodeScalars.first ?? base
                    base = String(plain).lowercased().unicodeScalars.first ?? plain
                } else {
                    base = String(base).lowercased().unicodeScalars.first ?? base
                }
                word.append(base)
            }
        }
        flush()
        return result
    }
}

// MARK: - The replay transport

/// One request a lookup made, as the transport saw it.
struct MatchExchange {
    enum Kind { case answer, miss }
    let key: String
    /// The path with its query, percent-encoded as sent.
    let path: String
    let kind: Kind
    let status: Int?
    let cached: Bool
    let body: Data?
}

/// Answers Isla's LRCLIB requests from the lab's cache, and — only in record
/// mode — fetches a miss live, once, politely, and keeps the answer.
///
/// The key is the lowercase hex SHA-256 of the exact URL string as sent, the
/// scheme the Python resolver's cache uses, so the two can share a convention
/// without sharing a directory. A 2xx and a 404 are cached (a 404 is LRCLIB's
/// answer for "no such record"); a network failure and a 429/5xx that outlived
/// its retries never are, so the next record run asks again.
///
/// Without record mode a miss throws, which Isla reads as a failure to
/// retry — and the lookup is then reported as `uncached` rather than `failed`,
/// because the cache, not Isla, lacked the answer. A 429 or 5xx that outlived
/// its retries is a miss on the same terms: it is LRCLIB's load, not Isla's
/// lookup, so it is never handed to Isla as an answer to judge.
///
/// Live requests carry the request's own headers: they are Isla's requests,
/// with Isla's User-Agent, because the lab measures what Isla does.
final class ReplayTransport: @unchecked Sendable {
    struct Miss: Error {}

    /// Minimum seconds between two live requests to one pacing slot (SPEC,
    /// Politeness): a host, or an endpoint with a budget of its own. LRCLIB's
    /// search is one. On 2026-10-15 it answered 429 whenever requests came
    /// closer than about six seconds apart — about ten a minute — and a
    /// cooled-down run of /api/get at one second drew a 429 after five
    /// requests, so one limiter covers the whole host: every LRCLIB request
    /// keeps 7.5 s. The search slot stays, so a later change to the host's gap
    /// cannot speed searches up with it.
    static let minimumGap: [String: TimeInterval] = [
        "lrclib.net": 7.5, "lrclib.net/api/search": 7.5,
        "itunes.apple.com": 3.2, "api.deezer.com": 0.25,
    ]

    /// The gap a slot keeps in this run: the table's, or a slower one for
    /// LRCLIB from `ISLA_MATCH_LRCLIB_GAP`, which exists to probe a limiter
    /// that has just refused this address without editing the table. A value
    /// below the table's is ignored: the table is a floor (SPEC, Politeness).
    static func gap(for slot: String) -> TimeInterval? {
        guard let floor = minimumGap[slot] else { return nil }
        if slot.hasPrefix("lrclib.net"),
           let asked = MatchLab.environment[MatchLab.lrclibGapKey].flatMap(TimeInterval.init), asked > floor {
            return asked
        }
        return floor
    }
    /// Seconds to wait before retry 1, 2 and 3 of a 5xx, and of a 429. A 429
    /// waits far longer: LRCLIB's limiter counts the requests it refuses, so a
    /// quick retry only extends the ban it is waiting out.
    static let backoff: [TimeInterval] = [2, 8, 30]
    static let throttleBackoff: [TimeInterval] = [30, 60, 120]
    /// How far a run of 429s may stretch a slot's gap (each one doubles it,
    /// each success takes a tenth back), and how long a slot stays closed after
    /// a request ran out of retries on 429 — the ban outlasts its Retry-After.
    static let maxFactor = 8.0
    static let throttleHold: TimeInterval = 60
    /// After this many requests in a row ran out of retries on 429, a host
    /// gets no more live requests for the rest of the run: its limiter is in
    /// a long ban, and every refused request extends it. The lookups left are
    /// `uncached`, never cached, so the next run asks again (common.py's
    /// TRIP_AFTER is the same rule for the resolver).
    static let tripAfter = 3

    /// The statuses a live answer is kept for: every 2xx, 400 (deterministic
    /// for a URL) and 404 (LRCLIB's "no record"). The Python resolver caches
    /// exactly this set (`common.CACHEABLE_STATUSES` and 2xx); the two sides
    /// disagreed about 400, so a record run and its replay could differ.
    static func cachesStatus(_ status: Int) -> Bool {
        (200..<300).contains(status) || status == 400 || status == 404
    }

    /// A 403 is a gateway or a throttle refusing this client, not LRCLIB's
    /// word on the URL. It is never cached and never reaches Isla as an
    /// answer: it is logged and thrown as a miss, like a transport failure, so
    /// the lookup reads `uncached` and the next record run asks again. In the
    /// Python resolver it is a failed fetch.
    static func refusesStatus(_ status: Int) -> Bool { status == 403 }

    private let root: URL
    private let record: Bool
    private let maxLive: Int?
    private let stopAtFirst429: Bool
    private let send: @Sendable (URLRequest) async throws -> (Data, Int)
    private let lock = NSLock()
    private var exchanges: [MatchExchange] = []
    private var lastLive: [String: Date] = [:]
    private var factor: [String: Double] = [:]
    private var holdUntil: [String: Date] = [:]
    private var refusedInARow: [String: Int] = [:]
    private var throttles: [String: Int] = [:]
    private var tripped: Set<String> = []
    private var liveCount = 0

    /// `send` makes one live request and returns the body and HTTP status; it
    /// is `curl` unless a self-test stands in for the network.
    init(
        root: URL, record: Bool, maxLive: Int? = nil,
        stopAtFirst429: Bool = MatchLab.environment[MatchLab.stopAt429Key] == "1",
        send: (@Sendable (URLRequest) async throws -> (Data, Int))? = nil
    ) {
        self.root = root
        self.record = record
        self.maxLive = maxLive
        self.stopAtFirst429 = stopAtFirst429
        self.send = send ?? { try await ReplayTransport.curl($0) }
    }

    /// How many live HTTP requests this process has made, retries included.
    var liveRequests: Int { lock.withLock { liveCount } }

    func beginLookup() { lock.withLock { exchanges.removeAll(keepingCapacity: true) } }
    func takeExchanges() -> [MatchExchange] { lock.withLock { exchanges } }

    private func log(_ exchange: MatchExchange) { lock.withLock { exchanges.append(exchange) } }

    static func path(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    private static func response(for url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// The pacing slot for `url`: its endpoint when that has a gap of its own,
    /// otherwise its host.
    static func slot(for url: URL) -> String {
        let host = url.host ?? ""
        let endpoint = host + url.path
        return minimumGap[endpoint] == nil ? host : endpoint
    }

    /// Takes the next start time for `url` and returns how long to wait for
    /// it: the slot's own gap (stretched by any recent 429s), the host's gap
    /// from whatever went to that host last, and any hold, whichever is latest.
    private func reserveSlot(for url: URL) -> TimeInterval {
        lock.withLock {
            let now = Date()
            let host = url.host ?? ""
            let slot = Self.slot(for: url)
            let hostGap = Self.gap(for: host) ?? 0.6
            let gap = (Self.gap(for: slot) ?? hostGap) * (factor[slot] ?? 1)
            let start = max(
                now,
                (lastLive[slot] ?? .distantPast).addingTimeInterval(gap),
                (lastLive[host] ?? .distantPast).addingTimeInterval(hostGap),
                holdUntil[slot] ?? .distantPast
            )
            lastLive[slot] = start
            lastLive[host] = start
            return start.timeIntervalSince(now)
        }
    }

    /// Counts a 429 and says so in the log, as the resolver's `[throttle]`
    /// line does: the fetch loop retries quietly otherwise, and a run that is
    /// being refused looks merely slow.
    private func throttled(_ url: URL) {
        let slot = Self.slot(for: url)
        let count: Int = lock.withLock {
            factor[slot] = min((factor[slot] ?? 1) * 2, Self.maxFactor)
            throttles[slot, default: 0] += 1
            return throttles[slot, default: 0]
        }
        print("MATCH-LAB throttle \(slot) 429 #\(count)")
    }

    /// `ISLA_MATCH_STOP_AT_429`: the host's first 429 closes it for the run.
    private func tripNow(_ url: URL) {
        let host = url.host ?? ""
        let trippedNow: Bool = lock.withLock { tripped.insert(host).inserted }
        if trippedNow {
            print("MATCH-LAB trip \(host): stopped at the first 429 (\(MatchLab.stopAt429Key)); "
                + "no live request goes to it for the rest of this run")
        }
    }

    private func succeeded(_ url: URL) {
        lock.withLock {
            let slot = Self.slot(for: url)
            let next = (factor[slot] ?? 1) * 0.9
            factor[slot] = next < 1.05 ? 1 : next
        }
    }

    private func hold(_ url: URL) {
        lock.withLock { holdUntil[Self.slot(for: url)] = Date().addingTimeInterval(Self.throttleHold) }
    }

    func isTripped(_ url: URL) -> Bool { lock.withLock { tripped.contains(url.host ?? "") } }

    /// Counts requests that ran out of retries on 429, in a row per host, and
    /// trips the host at `tripAfter`; any answer resets the count.
    private func noteOutcome(_ url: URL, refused: Bool) {
        let host = url.host ?? ""
        let trippedNow: Bool = lock.withLock {
            guard refused else { refusedInARow[host] = 0; return false }
            refusedInARow[host, default: 0] += 1
            guard refusedInARow[host, default: 0] >= Self.tripAfter, !tripped.contains(host) else { return false }
            tripped.insert(host)
            return true
        }
        if trippedNow {
            print("MATCH-LAB trip \(host): \(Self.tripAfter) requests in a row ran out of retries on 429; "
                + "no live request goes to it for the rest of this run")
        }
    }

    /// One live request through `/usr/bin/curl -4`, returning the body and
    /// the HTTP status.
    ///
    /// Not URLSession, on purpose. On 2026-10-15 LRCLIB answered this Mac's
    /// IPv6 address with 429 while its IPv4 address got 200, and URLSession's
    /// Happy Eyeballs takes IPv6 whenever it connects, so every live request
    /// walked into the ban; URLSession offers no way to name the address
    /// family, and curl does. The body goes to a file rather than a pipe: a
    /// search page runs past a pipe's 64 KB buffer, and a child blocked on a
    /// full pipe never exits. The request's own headers travel with it, so
    /// it is still Isla's request with Isla's User-Agent. The 30 s ceiling is
    /// looser than Isla's 8 s timeout because the lab measures answers, not
    /// Isla's patience.
    private static func curl(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url else { throw URLError(.badURL) }
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("match-lab-\(UUID().uuidString).body")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        var arguments = ["-4", "-sS", "--compressed", "--max-time", "30", "-o", bodyFile.path, "-w", "%{http_code}"]
        for (field, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            arguments += ["-H", "\(field): \(value)"]
        }
        arguments.append(url.absoluteString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let status = Int(printed.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        // "000" and a non-zero exit is curl saying no HTTP answer came back.
        guard exitCode == 0, status > 0 else { throw URLError(.cannotConnectToHost) }
        return ((try? Data(contentsOf: bodyFile)) ?? Data(), status)
    }

    /// False once the live-request ceiling is reached; otherwise counts one.
    private func takeLiveBudget() -> Bool {
        lock.withLock {
            if let maxLive, liveCount >= maxLive { return false }
            liveCount += 1
            return true
        }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let key = MatchLab.sha256Hex(url.absoluteString)
        let path = Self.path(of: url)

        if let hit = MatchLab.cacheEntry(root, for: url) {
            let entry = hit.entry
            if hit.aliased {
                // Kept under Isla's own spelling, so the key this exchange
                // logs names a file that exists. No network is involved.
                try? MatchLab.store(root, key: key, url: url.absoluteString, status: entry.status, body: entry.body)
            }
            log(MatchExchange(key: key, path: path, kind: .answer, status: entry.status, cached: true, body: entry.body))
            return (entry.body, Self.response(for: url, status: entry.status))
        }
        guard record else {
            log(MatchExchange(key: key, path: path, kind: .miss, status: nil, cached: false, body: nil))
            throw Miss()
        }

        if isTripped(url) {
            log(MatchExchange(key: key, path: path, kind: .miss, status: nil, cached: false, body: nil))
            throw Miss()
        }
        var attempt = 0
        while true {
            guard takeLiveBudget() else {
                log(MatchExchange(key: key, path: path, kind: .miss, status: nil, cached: false, body: nil))
                throw Miss()
            }
            let wait = reserveSlot(for: url)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            let data: Data
            let status: Int
            do {
                (data, status) = try await send(request)
            } catch {
                // Never cached, and logged as a miss, not a failure: a curl
                // transport failure (no connection, a timeout) is a fact about
                // this run's network and not about Isla, so the lookup reads
                // `uncached` and the next record run asks again. Logged as a
                // failure it became `failed` and was never retried (F17).
                log(MatchExchange(key: key, path: path, kind: .miss, status: nil, cached: false, body: nil))
                throw error
            }
            let response = Self.response(for: url, status: status)
            if status == 429 { throttled(url) }
            if status == 429, stopAtFirst429 {
                hold(url)
                tripNow(url)
                log(MatchExchange(key: key, path: path, kind: .miss, status: status, cached: false, body: nil))
                throw Miss()
            }
            if status == 429 || (500...599).contains(status) {
                if attempt < Self.backoff.count {
                    let delays = status == 429 ? Self.throttleBackoff : Self.backoff
                    try await Task.sleep(for: .seconds(delays[attempt]))
                    attempt += 1
                    continue
                }
                if status == 429 {
                    hold(url)
                    noteOutcome(url, refused: true)
                }
                log(MatchExchange(key: key, path: path, kind: .miss, status: status, cached: false, body: nil))
                throw Miss()
            }
            if Self.refusesStatus(status) {
                log(MatchExchange(key: key, path: path, kind: .miss, status: status, cached: false, body: nil))
                throw Miss()
            }
            if Self.cachesStatus(status) {
                succeeded(url)
                noteOutcome(url, refused: false)
                try MatchLab.store(root, key: key, url: url.absoluteString, status: status, body: data)
            }
            log(MatchExchange(key: key, path: path, kind: .answer, status: status, cached: false, body: data))
            return (data, response)
        }
    }
}
