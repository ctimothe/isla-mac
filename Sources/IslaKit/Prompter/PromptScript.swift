import Foundation

// Foundation only, on purpose: the script model is computed off the main
// thread for large pages and tested without a window server. Importing AppKit
// or SwiftUI here would pull main-actor isolation into every caller.

/// Which way a page reads. Decided by `PromptScript`, applied by the stage
/// (alignment and layout direction) and by the editor (`baseWritingDirection`).
enum PromptDirection: Sendable, Equatable {
    case leftToRight
    case rightToLeft
}

/// One word of a tokenized page.
struct PromptWord: Sendable, Equatable, Identifiable {
    /// Index in `PromptScript.words`; stable for one page text.
    let id: Int
    let text: String
    /// `Character` offsets into the *collapsed* text.
    let range: Range<Int>
    /// UTF-16 offsets into the *original* page text, the unit `NSTextView`
    /// speaks. Kept per word so an editor selection never has to be re-derived
    /// from `Character` counts (Textream mixed the two and drifted after an
    /// emoji).
    let utf16Range: Range<Int>
    /// Overlaps a `[...]` span. Editor styling and speech skipping both read
    /// this one flag, so they cannot disagree about `[]`.
    let isCue: Bool
    /// Has no letter or digit (`--`, `...`, a bullet, an emoji). Skipped by
    /// matching and advanced over by progress, but drawn as normal text.
    let isNonSpeech: Bool
    /// Preceded by a blank line (never by a single newline).
    let startsParagraph: Bool

    var isSkipped: Bool { isCue || isNonSpeech }
    var nsRange: NSRange { NSRange(location: utf16Range.lowerBound, length: utf16Range.count) }
}

/// Everything a layout cache needs besides the page text. The caller supplies
/// font, size and width; the script only supplies its own content hash.
/// Textream keyed its cache by word count plus first and last word, so editing
/// a middle word kept a stale layout, and the cache was shared by every view.
struct PromptLayoutKey: Hashable, Sendable {
    let contentHash: UInt64
    let fontName: String
    let pointSize: Double
    let columnWidth: Double
}

/// The immutable tokenized form of one page (spec section 6). Pure value, no
/// I/O. All progress offsets index the collapsed text, which is the words
/// joined by one space.
struct PromptScript: Sendable, Equatable {
    /// The page text exactly as the author typed it.
    let source: String
    let words: [PromptWord]
    /// Words joined by single spaces.
    let collapsedText: String
    /// Total `Character` count of the collapsed text.
    let collapsedCount: Int
    /// Each `[` through the next `]`, as collapsed `Character` offsets,
    /// brackets included.
    let cues: [Range<Int>]
    let direction: PromptDirection
    /// Hash of `source` (not of the collapsed text, see `contentHash(of:)`).
    let contentHash: UInt64

    /// Words a matcher or a progress bar can actually wait for.
    var speakableWordCount: Int { words.lazy.filter { !$0.isSkipped }.count }

    init(_ source: String) {
        self.source = source
        contentHash = Self.contentHash(of: source)

        let tokens = Self.tokenize(source)

        // The collapsed text as a Character sequence of our own making (words
        // joined by one space). Offsets are positions in this sequence, so
        // they cannot drift because a re-segmentation merged a space with a
        // following combining mark.
        var chars: [Character] = []
        var words: [PromptWord] = []
        words.reserveCapacity(tokens.count)
        var collapsedWords: [(range: Range<Int>, token: Token)] = []
        collapsedWords.reserveCapacity(tokens.count)
        for token in tokens {
            if !chars.isEmpty { chars.append(" ") }
            let start = chars.count
            chars.append(contentsOf: token.characters)
            collapsedWords.append((start..<chars.count, token))
        }

        // Cues: `[` to the NEXT `]`, not nested. No closer means no later
        // opener can have one either, so the scan stops; that keeps a page of
        // 100,000 stray brackets linear instead of quadratic.
        var cues: [Range<Int>] = []
        var i = 0
        scan: while i < chars.count {
            if chars[i] == "[" {
                var j = i + 1
                while j < chars.count, chars[j] != "]" { j += 1 }
                if j >= chars.count { break scan }
                cues.append(i..<(j + 1))
                i = j + 1
            } else {
                i += 1
            }
        }

        // Words overlapping a cue are cue words; both lists ascend, so one
        // forward pass is enough.
        var cuePointer = 0
        for (index, entry) in collapsedWords.enumerated() {
            while cuePointer < cues.count, cues[cuePointer].upperBound <= entry.range.lowerBound {
                cuePointer += 1
            }
            let isCue = cuePointer < cues.count && cues[cuePointer].lowerBound < entry.range.upperBound
            let speakable = entry.token.characters.contains { $0.isLetter || $0.isNumber }
            words.append(PromptWord(
                id: index,
                text: String(entry.token.characters),
                range: entry.range,
                utf16Range: entry.token.utf16Start..<entry.token.utf16End,
                isCue: isCue,
                isNonSpeech: !speakable,
                startsParagraph: entry.token.startsParagraph
            ))
        }

        self.words = words
        self.collapsedText = String(chars)
        self.collapsedCount = chars.count
        self.cues = cues
        self.direction = Self.direction(of: chars, skipping: cues)
    }

    // MARK: - Tokenizing

    private struct Token {
        var characters: [Character]
        var utf16Start: Int
        var utf16End: Int
        var startsParagraph: Bool
    }

    /// Spec 6.1 steps 1 and 2, plus the paragraph rule of 6.5, in one pass over
    /// the original text so every word keeps its UTF-16 position in it.
    private static func tokenize(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var run: Token?
        var utf16 = 0
        var newlinesSinceContent = 0

        func closeRun() {
            if let r = run { tokens.append(r); run = nil }
        }
        // A word that opens after whitespace holding two or more line ends has
        // a whitespace-only line between it and the previous word: a blank
        // line. A single newline is just a space (Textream drew a divider on
        // every hard newline). Leading blank lines have no previous word.
        func opensParagraph() -> Bool { newlinesSinceContent >= 2 && !tokens.isEmpty }

        for ch in source {
            let width = ch.utf16.count
            defer { utf16 += width }
            if ch.isWhitespace {
                // Whitespace wins over the CJK list, so U+3000 separates words.
                closeRun()
                if ch.isNewline { newlinesSinceContent += 1 }
                continue
            }
            if isCJK(ch) {
                closeRun()
                tokens.append(Token(
                    characters: [ch], utf16Start: utf16, utf16End: utf16 + width,
                    startsParagraph: opensParagraph()
                ))
            } else if run != nil {
                run!.characters.append(ch)
                run!.utf16End = utf16 + width
            } else {
                run = Token(
                    characters: [ch], utf16Start: utf16, utf16End: utf16 + width,
                    startsParagraph: opensParagraph()
                )
            }
            newlinesSinceContent = 0
        }
        closeRun()
        return tokens
    }

    /// 4E00-9FFF, 3400-4DBF, 20000-2A6DF, F900-FAFF, 3040-309F, 30A0-30FF,
    /// AC00-D7AF, and 3000-303F so CJK punctuation is a word of its own
    /// instead of fusing to the previous character.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x309F, 0x30A0...0x30FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2A6DF:
            return true
        default:
            return false
        }
    }

    /// A grapheme is CJK when its base scalar is: `a` plus a combining
    /// Hiragana mark (3099 sits in the Hiragana block) stays a Latin word.
    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.first.map(isCJK) ?? false
    }

    // MARK: - Direction

    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EEFF:
            return true
        default:
            return false
        }
    }

    /// First strong letter outside cues. Digits, marks and punctuation inside
    /// the RTL blocks are not strong, so `1 שלום` is RTL because of the Hebrew,
    /// not because of the numeral. No strong letter is LTR.
    private static func direction(of chars: [Character], skipping cues: [Range<Int>]) -> PromptDirection {
        var cueIndex = 0
        for (offset, ch) in chars.enumerated() {
            while cueIndex < cues.count, cues[cueIndex].upperBound <= offset { cueIndex += 1 }
            if cueIndex < cues.count, cues[cueIndex].contains(offset) { continue }
            guard let scalar = ch.unicodeScalars.first else { continue }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                return isRightToLeft(scalar) ? .rightToLeft : .leftToRight
            default:
                continue
            }
        }
        return .leftToRight
    }

    // MARK: - Content hash

    /// FNV-1a, 64 bit, over the UTF-8 bytes of the original text. Not
    /// `Hasher`: its seed changes every launch, and a stored resume point has
    /// to survive a relaunch. It hashes the original text, not the collapsed
    /// text, because the offsets-to-`NSRange` mapping depends on the
    /// whitespace; any edit, even one that leaves the words alone, invalidates
    /// a stored offset (the conservative reading of spec 6.4).
    static func contentHash(of text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Offsets (spec 6.4: the only place that converts)

    /// Index of the word that holds a collapsed offset. The separator after a
    /// word belongs to that word, and the end offset clamps to the last word.
    func wordIndex(containingCollapsedOffset offset: Int) -> Int? {
        guard !words.isEmpty, offset >= 0, offset <= collapsedCount else { return nil }
        return lastWordIndex(where: { $0.range.lowerBound <= offset })
    }

    private enum Affinity { case start, end }

    /// UTF-16 offset in the original text for a collapsed `Character` offset.
    /// An offset on the separator between two words has no single answer; as a
    /// range start it means the next word, as a range end the previous one.
    func utf16Offset(forCollapsedOffset offset: Int) -> Int? {
        utf16Offset(forCollapsedOffset: offset, affinity: .start)
    }

    private func utf16Offset(forCollapsedOffset offset: Int, affinity: Affinity) -> Int? {
        guard offset >= 0, offset <= collapsedCount else { return nil }
        guard let w = wordIndex(containingCollapsedOffset: offset) else { return 0 }
        let word = words[w]
        if offset < word.range.upperBound {
            var units = word.utf16Range.lowerBound
            for ch in word.text.prefix(offset - word.range.lowerBound) { units += ch.utf16.count }
            return units
        }
        // On the separator after `word`, or at the very end.
        if w + 1 < words.count, affinity == .start { return words[w + 1].utf16Range.lowerBound }
        return word.utf16Range.upperBound
    }

    /// The `NSRange` in the original text for a collapsed `Character` range,
    /// or nil when it leaves the collapsed text.
    func nsRange(forCollapsedRange range: Range<Int>) -> NSRange? {
        guard let start = utf16Offset(forCollapsedOffset: range.lowerBound, affinity: .start) else { return nil }
        if range.isEmpty { return NSRange(location: start, length: 0) }
        guard let end = utf16Offset(forCollapsedOffset: range.upperBound, affinity: .end) else { return nil }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The collapsed `Character` offset for a UTF-16 offset in the original
    /// text. An offset inside a surrogate pair or a combining sequence floors
    /// to the start of that `Character`; whitespace points at the next word;
    /// past the end clamps to the end; negative is nil.
    func collapsedOffset(forUTF16 offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        guard !words.isEmpty else { return 0 }
        guard let w = lastWordIndex(where: { $0.utf16Range.lowerBound <= offset }) else { return 0 }
        let word = words[w]
        if offset < word.utf16Range.upperBound {
            var consumed = 0
            var count = 0
            let into = offset - word.utf16Range.lowerBound
            for ch in word.text {
                let width = ch.utf16.count
                if consumed + width > into { break }
                consumed += width
                count += 1
            }
            return word.range.lowerBound + count
        }
        if offset == word.utf16Range.upperBound { return word.range.upperBound }
        return w + 1 < words.count ? words[w + 1].range.lowerBound : collapsedCount
    }

    /// Binary search: the last word for which `predicate` holds, given that it
    /// holds for a prefix of the (ascending) word list.
    private func lastWordIndex(where predicate: (PromptWord) -> Bool) -> Int? {
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(words[mid]) { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}
