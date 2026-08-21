import Foundation
import Compression

/// Parsers for the two word-synced lyric formats worth having.
///
/// TTML is the community standard: the amll-ttml-db project collects
/// hand-reviewed, CC0-licensed word-by-word lyrics keyed by Spotify track id.
/// KRC is Kugou's format — encrypted with a long-known static key, carrying
/// per-word offsets and durations. Between them and LRCLIB's line-level LRC,
/// every track gets the best timing that exists for it.
enum WordSyncedLyrics {
    struct Word: Equatable {
        /// Seconds from the start of the track.
        let at: TimeInterval
        let text: String
        /// When the word stops being sung, where the source knew. Nil falls
        /// back to the next word's start — which is exactly what both formats
        /// used to be flattened to, and why the sweep kept moving through
        /// pauses: a line with a breath in the middle carried real end times
        /// that were parsed and then thrown away.
        var end: TimeInterval? = nil

        init(at: TimeInterval, text: String, end: TimeInterval? = nil) {
            self.at = at
            self.text = text
            self.end = end
        }
    }

    struct Line: Equatable {
        let at: TimeInterval
        let text: String
        /// Present only when the source carried genuine word timing.
        let words: [Word]
    }

    // MARK: - TTML (amll-ttml-db)

    /// Minimal TTML reader for the amll profile: `<p begin=…>` lines holding
    /// `<span begin=…>` syllables. A full TTML engine would be wasted here —
    /// the database's files are machine-generated into exactly this shape.
    static func parseTTML(_ data: Data) -> [Line] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var lines: [Line] = []

        for p in matches(of: #"<p\b[^>]*begin="([^"]+)"[^>]*>(.*?)</p>"#, in: xml) {
            guard let lineStart = clock(p.1) else { continue }
            let inner = p.2
            var words: [Word] = []
            var text = ""
            var cursor = inner.startIndex

            // Walked with a cursor rather than mapped over the spans alone:
            // the whitespace between two spans belongs to the line's text, and
            // to the word before it — dropping it fused every pair of words.
            for span in rangedMatches(of: #"<span\b[^>]*begin="([^"]+)"(?:[^>]*?end="([^"]+)")?[^>]*>(.*?)</span>"#, in: inner) {
                let gap = decodeEntities(strippingTags(String(inner[cursor..<span.range.lowerBound])))
                if !gap.isEmpty {
                    text += gap
                    if !words.isEmpty {
                        let last = words.removeLast()
                        words.append(Word(at: last.at, text: last.text + gap, end: last.end))
                    }
                }
                cursor = span.range.upperBound
                guard let at = clock(span.group1) else { continue }
                let end = span.group2.isEmpty ? nil : clock(span.group2)
                let word = decodeEntities(strippingTags(span.group3))
                guard !word.trimmingCharacters(in: .whitespaces).isEmpty else {
                    text += word
                    continue
                }
                words.append(Word(at: at, text: word, end: end))
                text += word
            }
            if words.isEmpty {
                text = decodeEntities(strippingTags(inner))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(Line(at: lineStart, text: trimmed, words: words))
        }
        return lines.sorted { $0.at < $1.at }
    }

    /// TTML clock values: "12.34s", "1:23.45", "0:01:23.450".
    static func clock(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("s"), let seconds = TimeInterval(value.dropLast()) { return seconds }
        let parts = value.split(separator: ":").map(String.init)
        let numbers = parts.compactMap(TimeInterval.init)
        guard numbers.count == parts.count, !numbers.isEmpty else { return nil }
        return numbers.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, TimeInterval($1.offset)) }
    }

    // MARK: - KRC (Kugou)

    /// The XOR key Kugou has shipped unchanged for a decade; the payload under
    /// it is a zlib stream after a 4-byte "krc1" magic.
    private static let krcKey: [UInt8] = [
        0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
        0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69,
    ]

    static func decryptKRC(_ data: Data) -> String? {
        guard data.count > 4, data.prefix(4) == Data("krc1".utf8) else { return nil }
        var payload = [UInt8](data.dropFirst(4))
        for index in payload.indices {
            payload[index] ^= krcKey[index % krcKey.count]
        }
        // Compression's ZLIB codec is the raw deflate stream, so the two-byte
        // zlib header has to go before it will inflate.
        guard payload.count > 2 else { return nil }
        let deflate = [UInt8](payload.dropFirst(2))
        let capacity = max(deflate.count * 8, 1 << 16)
        var output = [UInt8](repeating: 0, count: capacity)
        let written = deflate.withUnsafeBufferPointer { source in
            compression_decode_buffer(
                &output, capacity,
                source.baseAddress!, source.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return String(bytes: output[0..<written], encoding: .utf8)
    }

    /// KRC body: `[lineStartMs,lineDurationMs]<offsetMs,durationMs,0>word<…>word…`
    /// Word offsets are relative to their line's start.
    static func parseKRCBody(_ body: String) -> [Line] {
        var lines: [Line] = []
        for raw in body.split(separator: "\n") {
            let line = String(raw)
            guard let header = matches(of: #"^\[(\d+),(\d+)\]"#, in: line).first,
                  let startMs = TimeInterval(header.1) else { continue }
            let lineStart = startMs / 1000

            var words: [Word] = []
            var text = ""
            for token in matches(of: #"<(\d+),(\d+),\d+>([^<]*)"#, in: line) {
                guard let offsetMs = TimeInterval(token.1) else { continue }
                let word = token.3
                guard !word.isEmpty else { continue }
                let at = lineStart + offsetMs / 1000
                // The format carries each word's duration; it used to be
                // matched by this very regex and never read.
                let end = TimeInterval(token.2).map { at + $0 / 1000 }
                words.append(Word(at: at, text: word, end: end))
                text += word
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(Line(at: lineStart, text: trimmed, words: words))
        }
        return lines.sorted { $0.at < $1.at }
    }

    // MARK: - Word-accurate sweep

    /// Where the reading edge stands inside a word-synced line, 0...1, in
    /// character space — so the mask lands on the exact word being sung and
    /// moves through it at that word's own pace.
    static func wordFraction(words: [Word], at position: TimeInterval, lineEnd: TimeInterval) -> Double {
        guard !words.isEmpty else { return 0 }
        let counts = words.map { Double($0.text.count) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return 0 }

        var sung: Double = 0
        for (index, word) in words.enumerated() {
            let nextStart = index + 1 < words.count ? words[index + 1].at : lineEnd
            // The word's own end where the source knew it, clamped to the next
            // start so malformed data cannot run words backwards. Without this
            // the sweep spread every word across the gap to the next one —
            // through breaths, rests, and instrumental breaks mid-line — which
            // is exactly what read as "wrong timeline" on long lines.
            let wordEnd = min(word.end ?? nextStart, nextStart)
            if position >= wordEnd {
                sung += counts[index]
                // Holding through the pause: the next iteration's `at` check
                // stops the sweep until that word actually begins.
            } else if position > word.at {
                let span = max(wordEnd - word.at, 0.05)
                sung += counts[index] * min((position - word.at) / span, 1)
                break
            } else {
                break
            }
        }
        return min(max(sung / total, 0), 1)
    }

    // MARK: - Small helpers

    private static func matches(of pattern: String, in text: String) -> [(String, String, String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            func group(_ index: Int) -> String {
                guard index < match.numberOfRanges,
                      let r = Range(match.range(at: index), in: text) else { return "" }
                return String(text[r])
            }
            return (group(0), group(1), group(2), group(3))
        }
    }

    private struct RangedMatch {
        let range: Range<String.Index>
        let group1: String
        let group2: String
        let group3: String
    }

    private static func rangedMatches(of pattern: String, in text: String) -> [RangedMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            guard let whole = Range(match.range, in: text) else { return nil }
            func group(_ index: Int) -> String {
                guard index < match.numberOfRanges,
                      let r = Range(match.range(at: index), in: text) else { return "" }
                return String(text[r])
            }
            return RangedMatch(range: whole, group1: group(1), group2: group(2), group3: group(3))
        }
    }

    private static func strippingTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
