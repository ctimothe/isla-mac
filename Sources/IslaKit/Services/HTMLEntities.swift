import Foundation

/// The one HTML entity decoder for every lyric source boundary.
///
/// The lyric sources ship escaped text in different places: Kugou stores lyric
/// text HTML-escaped inside KRC, QQ's search answers escape song and singer
/// names, and LRCLIB's user-contributed files carry escapes some of the time.
/// Each parser used to handle that — or not — on its own, and the KRC path
/// never decoded at all, so `I&apos;ve been waiting` reached the screen raw.
/// One type, one order: decode here and the boundary decides only *when*.
///
/// Decode-if-present: some KRC payloads carry no entities, and unknown names
/// (`&bogus;`) match nothing and ride through unchanged. A decoder that
/// guesses is a decoder that mangles.
enum HTMLEntities {
    /// Numeric entities: decimal `&#39;` (leading zeros included) and hex
    /// `&#x27;`. Only a lowercase `x` opens hex — no lyric source ships
    /// `&#X27;`, and widening the match would start decoding things the
    /// sources never meant as entities.
    private static let numeric = try! NSRegularExpression(
        pattern: #"&#(?:\d+|x[0-9a-fA-F]+);"#
    )

    static func decode(_ text: String) -> String {
        // Numeric first. `&amp;#39;` must read `&#39;` after one pass, which
        // holds only while `&amp;` is still intact — decoding the ampersand
        // first would hand this pass a fresh `&#39;` to eat, and one level of
        // escaping would become two levels decoded.
        var decoded = ""
        var cursor = text.startIndex
        let full = NSRange(text.startIndex..., in: text)
        for match in numeric.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            decoded += text[cursor..<range.lowerBound]
            decoded += scalarDecoded(text[range])
            cursor = range.upperBound
        }
        decoded += text[cursor...]

        // Named entities, ampersand strictly last — the order is the whole
        // contract. `&amp;apos;` means the text `&apos;`, and only an
        // ampersand-last pass leaves it there: the TTML copy that decoded
        // `&amp;` first collapsed it to `'`, twice as far as the source meant.
        return decoded
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The scalar a numeric entity names, or the entity untouched when the
    /// scalar model cannot name it: overflow past U+10FFFF, surrogates, and
    /// zero are all either undecodable or characters no lyric line should
    /// grow.
    private static func scalarDecoded(_ entity: Substring) -> String {
        let digits = entity.dropFirst(2).dropLast() // between `&#` and `;`
        let value = digits.first == "x"
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits)
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else {
            return String(entity)
        }
        return String(Character(scalar))
    }
}
