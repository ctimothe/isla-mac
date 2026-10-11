import Foundation

/// Metadata that travels with a listener-owned LRC document.
struct LocalLyricsMetadata: Codable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var version: String?
    var duration: TimeInterval?
}

/// One enhanced-LRC word marker. `end` remains optional because LRC records
/// word starts; the sweep derives an end from the next marker when needed.
struct LyricWord: Codable, Equatable, Sendable {
    var at: TimeInterval
    var text: String
    var end: TimeInterval?
}

/// A local LRC document, deliberately without any source, account, cache, or
/// network identity. It is the boundary between on-disk local files and lyric
/// presentation.
struct LocalLyricsDocument: Codable, Equatable, Sendable {
    /// Why a file was refused. `line` is the 1-based line of the source text,
    /// counting blank lines, so the place a listener is told to look is the
    /// line their editor shows.
    enum Error: Swift.Error, Equatable {
        case emptyTimeline
        case invalidTimestamp(line: Int)
        case invalidWordOrder(line: Int)
    }

    /// Moves whenever the same text would parse to a different document.
    /// Revision 2 reads the dialects revision 1 refused (unknown tags, section
    /// labels, '<3', stacked stamps, comma and colon fractions, a leading byte
    /// order mark) and merges equal stamps into one line, so an answer cached
    /// as unreadable under revision 1 is worth reading again. Revision 3
    /// keeps an empty stamp as the end of the line before it
    /// (`LyricsStore.Line.end`) instead of dropping it.
    static let parserRevision = 3

    /// The longest minutes field a stamp may carry. Nothing sung runs for
    /// 999 minutes; the bound exists so `1e300` or `inf` can never reach
    /// `serialize`, whose `Int(...)` traps on them (the editor's Save Copy
    /// crashed on a file with `[offset:inf]`).
    static let maximumMinutes = 999
    private static let maximumOffsetMilliseconds = TimeInterval(maximumMinutes * 60_000)
    private static let latestWritableTime = TimeInterval(maximumMinutes * 60) + 59.99

    var metadata: LocalLyricsMetadata
    var lines: [LyricsStore.Line]
    /// The LRC offset in seconds. It is applied while parsing and retained so
    /// exporting an edited document does not silently lose its timing intent.
    var offset: TimeInterval

    var duration: TimeInterval? { metadata.duration }

    var granularity: LyricTimeline.Granularity {
        lines.allSatisfy { !$0.words.isEmpty } ? .word : .line
    }

    func timeline(documentID: UUID?) -> LyricTimeline {
        LyricTimeline(
            lines: lines,
            granularity: granularity,
            documentID: documentID
        )
    }

    /// Collect, then sort, then validate.
    ///
    /// The parser used to validate as it read: every stamp had to be at or
    /// after the one before it, any `[x:y]` it did not know was a broken
    /// stamp, and any '<' started word timing. Each of those threw, and one
    /// throw rejects the whole file — a local file was listed as invalid, and
    /// an LRCLIB answer was cached as "this track has no lyrics" for 14 days.
    /// A compressed LRC (one chorus under several stamps) steps backwards by
    /// design, `[by:]` and `[re:]` are standard tags, and "I <3 you" is a
    /// lyric. Only a bracket that is plainly meant as a stamp and is not one
    /// still refuses the file, and it says which line.
    static func parse(_ raw: String) throws -> Self {
        var metadata = LocalLyricsMetadata()
        var offset: TimeInterval = 0
        var collected: [Entry] = []

        // Empty lines are kept so `number` counts the way an editor does. A
        // CRLF pair is a single `Character`, so it ends one line, not two.
        let sourceLines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, rawLine) in sourceLines.enumerated() {
            let number = index + 1
            let line = cleaned(rawLine)
            guard !line.isEmpty else { continue }

            if let tag = metadataTag(in: line) {
                switch tag.key {
                case "ti": metadata.title = tag.value
                case "ar": metadata.artist = tag.value
                case "al": metadata.album = tag.value
                case "ve": metadata.version = tag.value
                case "length":
                    guard let duration = parseTimestamp(tag.value) else {
                        throw Error.invalidTimestamp(line: number)
                    }
                    metadata.duration = duration
                case "offset":
                    // `TimeInterval(String)` reads "nan", "inf" and 1e300.
                    guard let milliseconds = TimeInterval(tag.value), milliseconds.isFinite,
                          abs(milliseconds) <= maximumOffsetMilliseconds else {
                        throw Error.invalidTimestamp(line: number)
                    }
                    offset = milliseconds / 1_000
                default:
                    // [by:], [re:], [au:], [#:], [id:], [tool:], and whatever
                    // the next editor invents: information about the file,
                    // never a reason to refuse it.
                    break
                }
                continue
            }

            guard let timed = try parseTimedLine(line, number: number) else { continue }
            for timestamp in timed.timestamps {
                collected.append(Entry(at: timestamp, order: collected.count, text: timed.text, words: timed.words))
            }
        }

        // File order breaks ties, so a bilingual pair keeps its original first.
        collected.sort { ($0.at, $0.order) < ($1.at, $1.order) }

        var lines: [LyricsStore.Line] = []
        for entry in collected {
            let at = max(0, entry.at - offset)
            // A stamp with no words is where the voice of the line before it
            // stopped. It was dropped until 2026-10-11, and every finished
            // line stayed lit to the next stamp — through every instrumental
            // and every outro (the lyric lab's L6: a median 28.9 s a track).
            // It never becomes a row. After the sort, the next sung line
            // cannot start before it, so the only test left is that it lies
            // strictly after the line it ends: one at that line's own moment
            // (or before any line at all) ends nothing. A second stamp in the
            // same gap leaves the first alone, the earliest the voice was
            // said to stop.
            if entry.text.isEmpty {
                if let last = lines.last, at > last.at, last.end == nil {
                    lines[lines.count - 1].end = at
                }
                continue
            }
            // Two word-less rows at one moment — an original and its
            // translation, the commonest bilingual LRC — are one line of two
            // rows. Kept apart, every search for that moment answered the
            // second, so the first was never shown, and the stage keyed both
            // rows by the same time. Merged after the offset, because a
            // positive offset can clamp several early stamps onto zero too.
            if let last = lines.last, last.at == at, last.words.isEmpty, entry.words.isEmpty {
                lines[lines.count - 1].text += "\n" + entry.text
            } else {
                lines.append(LyricsStore.Line(at: at, text: entry.text, words: entry.words))
            }
        }
        guard !lines.isEmpty else { throw Error.emptyTimeline }
        return Self(metadata: metadata, lines: lines, offset: offset)
    }

    func serialize() -> String {
        var output: [String] = []
        appendMetadata("ti", value: metadata.title, to: &output)
        appendMetadata("ar", value: metadata.artist, to: &output)
        appendMetadata("al", value: metadata.album, to: &output)
        appendMetadata("ve", value: metadata.version, to: &output)
        if let duration { output.append("[length:\(formatTimestamp(duration))]") }
        let offsetMilliseconds = writableOffsetMilliseconds
        if offsetMilliseconds != 0 { output.append("[offset:\(offsetMilliseconds)]") }

        for (index, line) in lines.enumerated() {
            let timestamp = formatTimestamp(line.at + offset)
            if line.words.isEmpty {
                // A merged two-row line goes back out as the rows it was read
                // from, each under the shared stamp, which `parse` merges again.
                for row in line.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    output.append("[\(timestamp)]\(row)")
                }
            } else {
                let words = line.words.map { word in
                    "<\(formatTimestamp(word.at + offset))>\(word.text)"
                }.joined(separator: " ")
                output.append("[\(timestamp)]\(words)")
            }
            if let end = Self.writableEnd(of: index, in: lines) {
                output.append("[\(formatTimestamp(end + offset))]")
            }
        }
        return output.joined(separator: "\n")
    }

    /// A line's end, when `parse` would read the bare stamp written for it
    /// back as this same line's end: strictly after the line's start and no
    /// later than the next line's. The editor moves lines without touching
    /// their ends, and an end written past the next start would come back as
    /// the end of that other line, an end nobody gave it.
    private static func writableEnd(of index: Int, in lines: [LyricsStore.Line]) -> TimeInterval? {
        guard let end = lines[index].end, end.isFinite, end > lines[index].at else { return nil }
        if index + 1 < lines.count, end > lines[index + 1].at { return nil }
        return end
    }

    private struct Entry {
        let at: TimeInterval
        let order: Int
        let text: String
        let words: [LyricWord]
    }

    private struct TimedLine {
        let timestamps: [TimeInterval]
        let text: String
        let words: [LyricWord]
    }

    /// A Windows editor starts the file with U+FEFF, and some concatenated
    /// files carry one on every part. `.whitespaces` keeps it, so the first
    /// stamp did not start with '[' and the first sung line was skipped.
    private static func cleaned(_ raw: Substring) -> String {
        var line = raw
        while line.unicodeScalars.first == "\u{FEFF}" {
            line = Substring(line.unicodeScalars.dropFirst())
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Nil for a line with no leading stamp (a section label, a credit, prose
    /// between verses) and for a stamp with nothing after it.
    private static func parseTimedLine(_ line: String, number: Int) throws -> TimedLine? {
        var remainder = line[...]
        var timestamps: [TimeInterval] = []

        while remainder.first == "[" {
            let close = remainder.firstIndex(of: "]")
            let inside = remainder[remainder.index(after: remainder.startIndex)..<(close ?? remainder.endIndex)]
            guard let close, let timestamp = parseTimestamp(inside) else {
                // `[Verse 1: Drake]` after a stamp is part of the lyric;
                // `[00:7x.00]` is a stamp somebody mistyped, and reading it
                // as text would put a line at the wrong moment silently.
                if looksLikeTimestamp(inside) { throw Error.invalidTimestamp(line: number) }
                break
            }
            timestamps.append(timestamp)
            remainder = remainder[remainder.index(after: close)...]
        }

        guard !timestamps.isEmpty else { return nil }
        let content = remainder.trimmingCharacters(in: .whitespaces)
        // A stamp with no words after it is a gap — the pause between verses,
        // which LRC writers mark exactly this way and which LRCLIB emits in
        // every second file. It used to throw `emptyTimeline`, and because that
        // error aborts the whole parse, one blank stanza break rejected an
        // otherwise perfect lyric: the file was reported invalid, and an online
        // answer was cached as "this track has no lyrics". It comes back with
        // empty text, and `parse` makes it the end of the line before it.
        guard !content.isEmpty else { return TimedLine(timestamps: timestamps, text: "", words: []) }
        let words = try parseWords(in: content, lineStart: timestamps[0], number: number)
        let text = words.isEmpty ? content : words.map(\.text).joined(separator: " ")
        return TimedLine(timestamps: timestamps, text: text, words: words)
    }

    private static func looksLikeTimestamp(_ inside: Substring) -> Bool {
        let trimmed = inside.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return false }
        return ("0"..."9").contains(first) && trimmed.contains(":")
    }

    private struct WordMarker {
        let start: String.Index
        let end: String.Index
        let at: TimeInterval
    }

    /// Word timing only when the content opens with a real `<mm:ss>` marker.
    /// Any '<' used to switch it on and then throw unless the content began
    /// with one, so "I <3 you" or "a -> b" rejected the file. Inside timed
    /// content, a '<' that does not close into a stamp is text as well.
    private static func parseWords(in content: String, lineStart: TimeInterval, number: Int) throws -> [LyricWord] {
        guard content.first == "<", var marker = wordMarker(opening: content.startIndex, in: content) else {
            return []
        }

        var words: [LyricWord] = []
        while true {
            var next: WordMarker?
            var search = marker.end
            while let open = content[search...].firstIndex(of: "<") {
                if let found = wordMarker(opening: open, in: content) {
                    next = found
                    break
                }
                search = content.index(after: open)
            }
            let word = content[marker.end..<(next?.start ?? content.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            guard marker.at >= lineStart else { throw Error.invalidTimestamp(line: number) }
            if let last = words.last, marker.at < last.at { throw Error.invalidWordOrder(line: number) }
            guard !word.isEmpty else { throw Error.invalidTimestamp(line: number) }
            words.append(LyricWord(at: marker.at, text: word, end: nil))
            guard let next else { break }
            marker = next
        }
        return words
    }

    private static func wordMarker(opening open: String.Index, in content: String) -> WordMarker? {
        let afterOpen = content.index(after: open)
        guard let close = content[afterOpen...].firstIndex(of: ">"),
              let at = parseTimestamp(content[afterOpen..<close]) else { return nil }
        return WordMarker(start: open, end: content.index(after: close), at: at)
    }

    /// A whole line of `[key:value]` whose key is a word (letters or '#'), not
    /// a number. The key comes back lowercased and the value trimmed.
    private static func metadataTag(in line: String) -> (key: String, value: String)? {
        guard line.first == "[", line.last == "]", let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[line.index(after: line.startIndex)..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "#" }) else { return nil }
        let value = line[line.index(after: colon)..<line.index(before: line.endIndex)]
        return (key.lowercased(), value.trimmingCharacters(in: .whitespaces))
    }

    /// `minutes ':' seconds`, then optionally '.', ',' or ':' and up to three
    /// fraction digits: `mm:ss`, `mm:ss.f`, `mm:ss.ff`, `mm:ss.fff`, the
    /// `mm:ss,ff` of European editors and the `mm:ss:ff` some Chinese editors
    /// write. Digits only — `TimeInterval(String)` accepted "inf" and 1e300 —
    /// and counted in integer milliseconds, so one moment written two ways
    /// (`12.3`, `12.30`, `12:30`) is one `TimeInterval`, which the merge of
    /// equal stamps depends on.
    private static func parseTimestamp<S: StringProtocol>(_ raw: S) -> TimeInterval? {
        let bytes = Array(raw.trimmingCharacters(in: .whitespaces).utf8)
        var cursor = 0
        func digits(upTo limit: Int) -> (value: Int, count: Int) {
            var value = 0, count = 0
            while cursor < bytes.count, count < limit, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[cursor]) {
                value = value * 10 + Int(bytes[cursor] - UInt8(ascii: "0"))
                cursor += 1
                count += 1
            }
            return (value, count)
        }

        let minutes = digits(upTo: 6)
        guard minutes.count > 0, minutes.value <= maximumMinutes,
              cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { return nil }
        cursor += 1
        let seconds = digits(upTo: 2)
        guard seconds.count > 0, seconds.value < 60 else { return nil }

        var milliseconds = minutes.value * 60_000 + seconds.value * 1_000
        if cursor < bytes.count {
            guard [UInt8(ascii: "."), UInt8(ascii: ","), UInt8(ascii: ":")].contains(bytes[cursor]) else {
                return nil
            }
            cursor += 1
            let fraction = digits(upTo: 3)
            milliseconds += fraction.value * [1_000, 100, 10, 1][fraction.count]
        }
        guard cursor == bytes.count else { return nil }
        return TimeInterval(milliseconds) / 1_000
    }

    private func appendMetadata(_ name: String, value: String?, to output: inout [String]) {
        guard let value, !value.isEmpty else { return }
        output.append("[\(name):\(value)]")
    }

    /// The offset as `serialize` writes it: whole milliseconds, within what
    /// `parse` accepts. A document built in code can hold anything, and
    /// `Int(...)` traps on a non-finite or out-of-range value.
    private var writableOffsetMilliseconds: Int {
        guard offset.isFinite else { return 0 }
        let limit = Self.maximumOffsetMilliseconds
        return Int(min(max((offset * 1_000).rounded(), -limit), limit))
    }

    /// Clamped to what `parse` reads back, before any `Int(...)`: a line at
    /// 1e17 or NaN trapped here, and the editor's Save Copy with it.
    private func formatTimestamp(_ time: TimeInterval) -> String {
        let latest = Self.latestWritableTime
        let clamped = time.isFinite ? min(max(0, time), latest) : (time > 0 ? latest : 0)
        let hundredths = Int((clamped * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6_000, (hundredths / 100) % 60, hundredths % 100)
    }
}
