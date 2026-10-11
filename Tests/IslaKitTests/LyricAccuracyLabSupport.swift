import Foundation
import XCTest
@testable import IslaKit

// The Lyrics Accuracy Lab's plumbing: the corpus, an independent LRC reader,
// a reader for LRCLIB's `lyricsfile` YAML, statistics, and the JSON report.
//
// Nothing here runs in `./scripts/check`. Every lab case calls
// `LyricLab.requireCorpus()` first, which throws `XCTSkip` unless
// `ISLA_LYRIC_CORPUS` names a directory, so the ordinary suite skips the lab
// in microseconds and never reads a file. `Scripts/lyric-lab.sh` sets it.
//
// The corpus is copyrighted lyric text. The lab reads it to measure timing and
// writes only numbers: the report carries counts, percentiles and LRCLIB ids,
// never a line of text. Keep it that way when adding a measurement.

// MARK: - Corpus

/// One LRCLIB object from the corpus, as fetched.
struct LabTrack {
    let id: Int
    let category: String
    let duration: TimeInterval
    let hasWordSync: Bool
    let synced: String?
    let lyricsfile: String?
    /// The file's bytes, handed to Isla's own response decoder unchanged.
    let raw: Data
}

private struct LabTextFields: Decodable {
    var syncedLyrics: String?
    var lyricsfile: String?
}

@MainActor
enum LyricLab {
    static let corpusKey = "ISLA_LYRIC_CORPUS"
    static let reportKey = "ISLA_LYRIC_REPORT"
    static let strictKey = "ISLA_LYRIC_STRICT"
    static let defaultReport =
        "/private/tmp/claude-501/-Users-ctimothe-code-projects-production-dynamic-island/48ae4d81-9edf-4a35-a3fd-12960e5f9d5e/scratchpad/lyric-lab-report.json"

    /// The lab's own version, so a report says which harness produced it.
    static let harnessVersion = "2026-10-11.1"

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Findings fail the run only when asked. A measurement harness that
    /// stops at its first finding reports one finding; the default records
    /// every one in the JSON and leaves the verdicts to be read.
    static var strict: Bool { environment[strictKey] == "1" }

    static var reportURL: URL {
        URL(fileURLWithPath: environment[reportKey].flatMap { $0.isEmpty ? nil : $0 } ?? defaultReport)
    }

    static func requireCorpus() throws -> URL {
        guard let path = environment[corpusKey], !path.isEmpty else {
            throw XCTSkip("set \(corpusKey)=<dir> to run the Lyrics Accuracy Lab (Scripts/lyric-lab.sh)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("\(corpusKey) does not name a directory: \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    private static var cachedTracks: [LabTrack]?
    private static var cachedLoadNotes: [String: Any] = [:]

    /// Every `<category>/<id>.json` under the corpus, read once per process.
    /// Directories starting with `_` or `.` hold the builders' own scripts
    /// and logs and are skipped. A file a builder is still writing fails to
    /// decode and is counted, not fatal.
    static func tracks() throws -> [LabTrack] {
        if let cachedTracks { return cachedTracks }
        let root = try requireCorpus()
        let fm = FileManager.default
        var tracks: [LabTrack] = []
        var unreadable = 0
        let categories = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for category in categories.sorted() where !category.hasPrefix("_") && !category.hasPrefix(".") {
            let dir = root.appendingPathComponent(category)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
            for file in files {
                let url = dir.appendingPathComponent(file)
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { unreadable += 1; continue }
                let id = (object["id"] as? Int) ?? Int(file.dropLast(5)) ?? -1
                // The text fields through `JSONDecoder`, the decoder Isla's own
                // response path uses: `JSONSerialization` was seen to hand back
                // a string without the leading U+FEFF that `JSONDecoder` keeps,
                // and the reference must read exactly the bytes Isla reads.
                let text = try? JSONDecoder().decode(LabTextFields.self, from: data)
                tracks.append(LabTrack(
                    id: id,
                    category: category,
                    duration: (object["duration"] as? Double) ?? 0,
                    hasWordSync: (object["hasWordSync"] as? Bool) ?? false,
                    synced: text?.syncedLyrics,
                    lyricsfile: text?.lyricsfile,
                    raw: data
                ))
            }
        }
        var notes: [String: Any] = ["unreadableFiles": unreadable]
        let index = root.appendingPathComponent("_index.json")
        if let data = try? Data(contentsOf: index), let object = try? JSONSerialization.jsonObject(with: data) {
            notes["indexPresent"] = true
            if let array = object as? [Any] { notes["indexEntries"] = array.count }
            if let dict = object as? [String: Any] { notes["indexKeys"] = dict.keys.sorted().prefix(20).map { $0 } }
        } else {
            notes["indexPresent"] = false
        }
        cachedLoadNotes = notes
        cachedTracks = tracks
        return tracks
    }

    static var loadNotes: [String: Any] { cachedLoadNotes }

    // MARK: Isla's own parse

    struct IslaParse {
        let lines: [LyricsStore.Line]?
        let granularity: LyricTimeline.Granularity?
        /// `found`, `none` or `failed`, from `OnlineLyrics.timeline`.
        let outcome: String
        /// Why `LocalLyricsDocument.parse` refused, when it did.
        let error: String?
    }

    private static var parseCache: [Int: IslaParse] = [:]

    /// The production path for an LRCLIB answer: the response bytes through
    /// `OnlineLyrics.timeline(from:status:)`, which decodes `syncedLyrics` and
    /// hands it to `LocalLyricsDocument.parse`. The direct parse is repeated
    /// only to learn the error a refusal carried.
    static func islaParse(_ track: LabTrack) -> IslaParse {
        if let cached = parseCache[track.id] { return cached }
        // With the record's own length, as the app passes the track's: lines
        // stamped past it are dropped there, and the lab measures what shows.
        let outcome = OnlineLyrics.timeline(from: track.raw, status: 200, duration: track.duration)
        var refusal: String?
        if let synced = track.synced {
            do { _ = try LocalLyricsDocument.parse(synced) } catch { refusal = "\(error)" }
        }
        let parse: IslaParse
        switch outcome {
        case .found(let timeline):
            parse = IslaParse(lines: timeline.lines, granularity: timeline.granularity, outcome: "found", error: refusal)
        case .none:
            parse = IslaParse(lines: nil, granularity: nil, outcome: "none", error: refusal)
        case .failed:
            parse = IslaParse(lines: nil, granularity: nil, outcome: "failed", error: refusal)
        case .unreadable:
            parse = IslaParse(lines: nil, granularity: nil, outcome: "unreadable", error: refusal)
        }
        parseCache[track.id] = parse
        return parse
    }

    /// Tracks Isla accepted, with their lines — the input to every clock
    /// measurement after L1.
    static func acceptedTracks() throws -> [(track: LabTrack, lines: [LyricsStore.Line])] {
        try tracks().compactMap { track in
            guard let lines = islaParse(track).lines, !lines.isEmpty else { return nil }
            return (track, lines)
        }
    }

    // MARK: Report

    /// Merges one section into the report file. Each case owns its section, so
    /// the cases can run in any order, alone or together, and the file always
    /// holds the latest numbers for each.
    static func write(section: String, _ value: [String: Any]) {
        let url = reportURL
        var report: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            report = existing
        }
        report[section] = sanitize(value)
        var meta = (report["meta"] as? [String: Any]) ?? [:]
        meta["harnessVersion"] = harnessVersion
        meta["corpus"] = environment[corpusKey] ?? ""
        meta["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        meta["host"] = [
            "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let tracks = cachedTracks {
            meta["tracks"] = tracks.count
            var perCategory: [String: Int] = [:]
            for track in tracks { perCategory[track.category, default: 0] += 1 }
            meta["tracksPerCategory"] = perCategory
            meta["load"] = cachedLoadNotes
        }
        report["meta"] = meta
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            XCTFail("lyric lab: cannot write report to \(url.path): \(error)")
        }
        let verdict = (value["verdict"] as? String) ?? "-"
        print("LYRIC-LAB \(section) verdict=\(verdict) — \((value["summary"] as? String) ?? "")")
    }

    /// JSON has no NaN or infinity; a percentile of nothing is null, not a crash.
    private static func sanitize(_ value: Any) -> Any {
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

    /// A finding: always recorded by the caller in the report, and a test
    /// failure only under `ISLA_LYRIC_STRICT=1`.
    static func finding(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if strict { XCTFail(message, file: file, line: line) }
    }
}

// MARK: - Statistics

struct LabStats {
    /// Nearest-rank percentiles, the definition that never invents a value
    /// the data did not contain.
    static func summary(_ values: [Double], scale: Double = 1) -> [String: Any] {
        guard !values.isEmpty else { return ["n": 0] }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double {
            let index = max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)
            return sorted[min(index, sorted.count - 1)] * scale
        }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return [
            "n": sorted.count,
            "min": sorted[0] * scale,
            "p50": rank(0.50),
            "p95": rank(0.95),
            "p99": rank(0.99),
            "max": sorted[sorted.count - 1] * scale,
            "mean": mean * scale,
        ]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)
        return sorted[min(index, sorted.count - 1)]
    }
}

/// SplitMix64: a seeded generator, so every random position the lab draws is
/// the same on every rerun of the same corpus.
struct LabRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Reference LRC reader

/// An LRC reader written for the lab from the format, not from Isla's parser,
/// so the two can disagree. Timestamps are kept as integer milliseconds from
/// the digits themselves — never through a floating-point seconds value — so
/// "the same timestamp to the millisecond" has an exact meaning.
struct ReferenceLRC {
    struct Entry {
        let ms: Int
        let text: String
        let sourceLine: Int
        /// The text opened with an enhanced-LRC `<mm:ss>` word marker; `text`
        /// then holds the words with every marker taken out.
        var wordTimed = false
    }

    var entries: [Entry] = []
    var offsetMs: Int = 0
    var hasOffsetTag = false
    var hasBOM = false
    var hasCR = false
    var multiStampLines = 0
    var fractionDigits: [Int: Int] = [:]
    var colonFractionStamps = 0
    var metadataTags: [String: Int] = [:]
    var untimedTextLines = 0
    var angleBracketLines = 0
    var unparseableStampLines = 0

    /// The non-empty entries, offset applied, in time order (stable for equal
    /// times, which is file order). This is what a correct reader should show.
    var sungRows: [Entry] {
        entries.filter { !$0.text.isEmpty }
            .map { Entry(ms: max(0, $0.ms - offsetMs), text: $0.text, sourceLine: $0.sourceLine, wordTimed: $0.wordTimed) }
            .enumerated().sorted { ($0.element.ms, $0.offset) < ($1.element.ms, $1.offset) }
            .map(\.element)
    }

    /// `sungRows` with rows that share a moment read as one line of several
    /// rows, joined by "\n" in file order: two rows at one stamp are one
    /// thing sung (an original and its translation), and a reader that keeps
    /// them apart can never show the first. Word-timed rows stay their own
    /// lines, since their words cannot be interleaved.
    var sung: [Entry] {
        var merged: [Entry] = []
        for row in sungRows {
            if let last = merged.last, last.ms == row.ms, !last.wordTimed, !row.wordTimed {
                merged[merged.count - 1] = Entry(
                    ms: last.ms, text: last.text + "\n" + row.text, sourceLine: last.sourceLine
                )
            } else {
                merged.append(row)
            }
        }
        return merged
    }

    var emptyEntries: [Entry] { entries.filter { $0.text.isEmpty } }

    /// Whether the stamps, in file order, ever step backwards.
    var outOfOrder: Bool {
        var last = Int.min
        for entry in entries {
            if entry.ms < last { return true }
            last = entry.ms
        }
        return false
    }

    static func parse(_ raw: String) -> ReferenceLRC {
        var result = ReferenceLRC()
        // Counted in UTF-16 units: a string bridged from Foundation answers
        // these exactly, whatever grapheme the BOM was folded into.
        result.hasBOM = raw.utf16.first == 0xFEFF
        result.hasCR = raw.utf16.contains(0x0D)
        // Every newline convention: CRLF, CR and LF all end a line.
        let rawLines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (number, rawLine) in rawLines.enumerated() {
            var scalars = Substring(rawLine)
            while scalars.unicodeScalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
            let line = scalars.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // A metadata tag is a whole line of `[key:value]` whose key is a
            // word, not a number.
            if let tag = metadataTag(line) {
                result.metadataTags[tag.key, default: 0] += 1
                if tag.key == "offset" {
                    result.hasOffsetTag = true
                    result.offsetMs = Int(tag.value.trimmingCharacters(in: .whitespaces)) ?? 0
                }
                continue
            }

            var rest = Substring(line)
            var stamps: [Int] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inside = rest[rest.index(after: rest.startIndex)..<close]
                guard let stamp = timestamp(inside, into: &result) else { break }
                stamps.append(stamp)
                rest = rest[rest.index(after: close)...]
            }
            if stamps.isEmpty {
                if line.first == "[", line.contains(":") { result.unparseableStampLines += 1 }
                result.untimedTextLines += 1
                continue
            }
            if stamps.count > 1 { result.multiStampLines += 1 }
            let text = rest.trimmingCharacters(in: .whitespaces)
            if text.contains("<") || text.contains(">") { result.angleBracketLines += 1 }
            let words = wordTimedText(text)
            for stamp in stamps {
                result.entries.append(Entry(
                    ms: stamp, text: words ?? text, sourceLine: number, wordTimed: words != nil
                ))
            }
        }
        return result
    }

    /// A valid enhanced-LRC word marker, `<mm:ss>` with an optional '.', ','
    /// or ':' fraction of up to three digits.
    /// Written once and only read, which is why the unchecked isolation is safe.
    nonisolated(unsafe) private static let wordMarker = try! Regex(#"<\s*[0-9]+:[0-9]{1,2}(?:[.,:][0-9]{0,3})?\s*>"#)

    /// The words of a line that opens with a valid marker, every valid marker
    /// taken out and the pieces between them joined by one space; nil for a
    /// line that does not open with one, whose '<' (a "<3", an arrow) is text.
    private static func wordTimedText(_ text: String) -> String? {
        guard let first = text.firstMatch(of: wordMarker), first.range.lowerBound == text.startIndex else {
            return nil
        }
        return text.split(separator: wordMarker)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func metadataTag(_ line: String) -> (key: String, value: String)? {
        guard line.first == "[", line.last == "]", let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[line.index(after: line.startIndex)..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "#" }) else { return nil }
        let value = line[line.index(after: colon)..<line.index(before: line.endIndex)]
        return (key.lowercased(), String(value))
    }

    /// `mm:ss`, `mm:ss.f`, `mm:ss.ff`, `mm:ss.fff`, the `mm:ss,ff` of
    /// European editors and the `mm:ss:ff` variant some editors write, to
    /// integer milliseconds.
    private static func timestamp(_ raw: Substring, into result: inout ReferenceLRC) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        var secondsPart = Substring(parts[1])
        var fraction: Substring = ""
        if parts.count == 3 {
            fraction = parts[2]
            result.colonFractionStamps += 1
        } else if let dot = secondsPart.firstIndex(where: { $0 == "." || $0 == "," }) {
            fraction = secondsPart[secondsPart.index(after: dot)...]
            secondsPart = secondsPart[..<dot]
        }
        guard let seconds = Int(secondsPart), seconds >= 0, seconds < 60,
              fraction.allSatisfy(\.isNumber), fraction.count <= 3 else { return nil }
        result.fractionDigits[fraction.count, default: 0] += 1
        let fractionMs: Int
        switch fraction.count {
        case 0: fractionMs = 0
        case 1: fractionMs = Int(fraction)! * 100
        case 2: fractionMs = Int(fraction)! * 10
        default: fractionMs = Int(fraction)!
        }
        return minutes * 60_000 + seconds * 1_000 + fractionMs
    }
}

// MARK: - LRCLIB lyricsfile reader

/// LRCLIB's `lyricsfile` field: YAML with a `lines:` list of
/// `{text, start_ms, end_ms, words?}`. Only that shape is read — a general YAML
/// parser is not what the lab needs, and a field it cannot read is reported as
/// absent rather than guessed.
struct LyricsFile {
    struct Word {
        var startMs: Int?
        var endMs: Int?
        var text: String = ""
    }

    struct Line {
        var startMs: Int?
        var endMs: Int?
        var isEmpty = true
        var text: String = ""
        var words: [Word] = []
    }

    var lines: [Line] = []

    static func parse(_ raw: String) -> LyricsFile {
        var file = LyricsFile()
        var inLines = false
        var lineIndent: Int?
        var wordDashIndent: Int?
        var current: Line?
        var word: Word?

        func closeWord() {
            if let finished = word { current?.words.append(finished) }
            word = nil
            wordDashIndent = nil
        }
        func closeLine() {
            closeWord()
            if let finished = current { file.lines.append(finished) }
            current = nil
        }

        for rawLine in raw.components(separatedBy: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let content = rawLine.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            if !inLines {
                if indent == 0, content == "lines:" { inLines = true }
                continue
            }
            if indent == 0, !content.hasPrefix("-") {
                // The next top-level key (`plain:`) ends the list.
                closeLine()
                break
            }
            var body = content
            var isItem = false
            if content.hasPrefix("- ") || content == "-" {
                isItem = true
                body = String(content.dropFirst(content == "-" ? 1 : 2))
                if lineIndent == nil { lineIndent = indent }
                if indent == lineIndent {
                    closeLine()
                    current = Line()
                } else {
                    closeWord()
                    word = Word()
                    wordDashIndent = indent
                }
            }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[..<colon])
            let value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let belongsToWord = word != nil && (isItem ? indent == wordDashIndent : indent > (wordDashIndent ?? Int.max))
            if !belongsToWord, word != nil, !isItem { closeWord() }
            switch key {
            case "start_ms":
                if belongsToWord { word?.startMs = Int(value) } else { current?.startMs = Int(value) }
            case "end_ms":
                if belongsToWord { word?.endMs = Int(value) } else { current?.endMs = Int(value) }
            case "text":
                let text = scalar(value)
                if belongsToWord {
                    word?.text = text
                } else {
                    current?.text = text
                    current?.isEmpty = text.trimmingCharacters(in: .whitespaces).isEmpty
                }
            case "words":
                closeWord()
            default:
                break
            }
        }
        closeLine()
        return file
    }

    /// A one-line YAML scalar: quoted either way, or plain.
    private static func scalar(_ value: String) -> String {
        if value == "~" || value == "null" { return "" }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.hasPrefix("|") || value.hasPrefix(">") { return "<block>" }
        return value
    }
}

// MARK: - The surfaces, as the views compute them

/// What each lyric surface resolves for one moment — by calling the very
/// statics each view's body calls, never a restatement of them. This used to
/// copy the views' inline arithmetic, cited by line number, which is the drift
/// `LyricSweep` exists to prevent: a change to a view was a change the lab
/// could only find by reading. Now a surface that resolves differently fails
/// L8 on its own.
@MainActor
enum LabSurfaces {
    typealias Resolution = LyricResolution
    typealias Inputs = LyricInputs

    /// `LyricsStage.stage(lines:)` resolves through this.
    static func stage(_ lines: [LyricsStore.Line], _ inputs: Inputs) -> Resolution {
        LyricsStage.resolve(lines: lines, inputs: inputs)
    }

    /// `MediaPane.lyricsLine` resolves through this. It answers nil only for a
    /// song with no lines, where the caption draws its status instead; the lab
    /// never asks about one, and would report it as nothing drawn.
    static func caption(_ lines: [LyricsStore.Line], _ inputs: Inputs) -> Resolution {
        MediaPane.captionResolution(lines: lines, inputs: inputs)
            ?? Resolution(
                at: inputs.position, moment: LyricMoment(current: nil, centre: 0, upcoming: nil),
                fraction: 0
            )
    }

    /// `LockScreenCard.lyricsPane` resolves through this.
    static func lockCard(_ lines: [LyricsStore.Line], _ inputs: Inputs) -> Resolution {
        LockScreenCard.resolve(lines: lines, inputs: inputs)
    }
}
