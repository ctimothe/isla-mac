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
    enum Error: Swift.Error, Equatable {
        case emptyTimeline
        case invalidTimestamp
        case invalidWordOrder
    }

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
            documentID: documentID,
            attribution: "Local LRC",
            source: "local",
            matchConfidence: 1,
            cacheExpiry: .distantFuture
        )
    }

    static func parse(_ raw: String) throws -> Self {
        var metadata = LocalLyricsMetadata()
        var offset: TimeInterval = 0
        var pending: [(at: TimeInterval, text: String, words: [LyricWord])] = []
        var lastTimestamp: TimeInterval?

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let tag = metadataTag(in: line, named: "ti") {
                metadata.title = tag
                continue
            }
            if let tag = metadataTag(in: line, named: "ar") {
                metadata.artist = tag
                continue
            }
            if let tag = metadataTag(in: line, named: "al") {
                metadata.album = tag
                continue
            }
            if let tag = metadataTag(in: line, named: "ve") {
                metadata.version = tag
                continue
            }
            if let tag = metadataTag(in: line, named: "length") {
                guard let duration = parseTimestamp(tag) else { throw Error.invalidTimestamp }
                metadata.duration = duration
                continue
            }
            if let tag = metadataTag(in: line, named: "offset") {
                guard let milliseconds = TimeInterval(tag.trimmingCharacters(in: .whitespaces)) else {
                    throw Error.invalidTimestamp
                }
                offset = milliseconds / 1_000
                continue
            }

            let parsed = try parseTimedLine(line)
            guard !parsed.timestamps.isEmpty else { continue }
            for timestamp in parsed.timestamps {
                if let lastTimestamp, timestamp < lastTimestamp { throw Error.invalidTimestamp }
                lastTimestamp = timestamp
                pending.append((timestamp, parsed.text, parsed.words))
            }
        }

        let lines = pending.map { item in
            LyricsStore.Line(
                at: max(0, item.at - offset), text: item.text, words: item.words
            )
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
        if offset != 0 { output.append("[offset:\(Int((offset * 1_000).rounded()))]") }

        for line in lines {
            let timestamp = formatTimestamp(line.at + offset)
            if line.words.isEmpty {
                output.append("[\(timestamp)]\(line.text)")
            } else {
                let words = line.words.map { word in
                    "<\(formatTimestamp(word.at + offset))>\(word.text)"
                }.joined(separator: " ")
                output.append("[\(timestamp)]\(words)")
            }
        }
        return output.joined(separator: "\n")
    }

    private struct TimedLine {
        let timestamps: [TimeInterval]
        let text: String
        let words: [LyricWord]
    }

    private static func parseTimedLine(_ line: String) throws -> TimedLine {
        var remainder = line[...]
        var timestamps: [TimeInterval] = []

        while remainder.first == "[" {
            guard let close = remainder.firstIndex(of: "]") else { throw Error.invalidTimestamp }
            let rawTimestamp = String(remainder[remainder.index(after: remainder.startIndex)..<close])
            guard let timestamp = parseTimestamp(rawTimestamp) else {
                if rawTimestamp.contains(":") { throw Error.invalidTimestamp }
                break
            }
            timestamps.append(timestamp)
            remainder = remainder[remainder.index(after: close)...]
        }

        guard !timestamps.isEmpty else { return TimedLine(timestamps: [], text: "", words: []) }
        let content = String(remainder).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { throw Error.emptyTimeline }
        let words = try parseWords(in: content, lineStart: timestamps[0])
        let text = words.isEmpty ? content : words.map(\.text).joined(separator: " ")
        return TimedLine(timestamps: timestamps, text: text, words: words)
    }

    private static func parseWords(in content: String, lineStart: TimeInterval) throws -> [LyricWord] {
        guard content.contains("<") || content.contains(">") else { return [] }

        var remainder = content[...]
        var words: [LyricWord] = []
        var lastStart: TimeInterval?

        while !remainder.isEmpty {
            guard remainder.first == "<", let close = remainder.firstIndex(of: ">") else {
                throw Error.invalidTimestamp
            }
            let rawTimestamp = String(remainder[remainder.index(after: remainder.startIndex)..<close])
            guard let timestamp = parseTimestamp(rawTimestamp), timestamp >= lineStart else {
                throw Error.invalidTimestamp
            }
            if let lastStart, timestamp < lastStart { throw Error.invalidWordOrder }
            remainder = remainder[remainder.index(after: close)...]
            let next = remainder.firstIndex(of: "<") ?? remainder.endIndex
            let word = String(remainder[..<next]).trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { throw Error.invalidTimestamp }
            words.append(LyricWord(at: timestamp, text: word, end: nil))
            lastStart = timestamp
            remainder = remainder[next...]
        }
        return words
    }

    private static func metadataTag(in line: String, named name: String) -> String? {
        let prefix = "[\(name):"
        guard line.hasPrefix(prefix), line.hasSuffix("]") else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        return String(line[start..<line.index(before: line.endIndex)]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let minutes = TimeInterval(parts[0]),
              let seconds = TimeInterval(parts[1]),
              minutes >= 0, seconds >= 0, seconds < 60 else {
            return nil
        }
        return minutes * 60 + seconds
    }

    private func appendMetadata(_ name: String, value: String?, to output: inout [String]) {
        guard let value, !value.isEmpty else { return }
        output.append("[\(name):\(value)]")
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let hundredths = Int((max(0, time) * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6_000, (hundredths / 100) % 60, hundredths % 100)
    }
}
