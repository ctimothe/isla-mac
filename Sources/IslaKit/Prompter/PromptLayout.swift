import Foundation

// Foundation only, like `PromptScript`: the flow layout runs off the main
// thread for a big page (E-26), and every test of it runs without a font. The
// one thing it needs from a typeface comes in through `PromptTextMeasuring`,
// which the stage fills from CoreText and a test fills from arithmetic.

// MARK: - Measuring

/// What the layout needs to know about a face to stack its lines (spec 10.2).
struct PromptFontMetrics: Sendable, Equatable {
    let pointSize: Double
    let ascender: Double
    /// Negative below the baseline, as AppKit and CoreText report it.
    let descender: Double
    let leading: Double

    /// Spec 10.2's line spacing, and its exception: a face whose line is taller
    /// than one and a half times its size (OpenDyslexic, which carries very tall
    /// ascenders) already has its air inside the line, and 8 pt more spread a
    /// four-line stage over three.
    static let lineSpacing: Double = 8
    static let tallLineSpacing: Double = 2
    /// Extra room above a line that opens a paragraph, with dividers on (6.5).
    static let dividerSpacing: Double = 14

    /// `ceil(ascender - descender + leading)` (10.2). Whole points, so lines
    /// sit on the pixel grid and a page of a thousand lines does not drift.
    var lineHeight: Double { (ascender - descender + leading).rounded(.up) }
    var lineSpacing: Double { lineHeight > 1.5 * pointSize ? Self.tallLineSpacing : Self.lineSpacing }
    /// From one line's top to the next one's, without a divider.
    var pitch: Double { lineHeight + lineSpacing }
}

/// Widths of text in one face. Must be safe to call from any thread: the
/// layout of a large page runs on a background task.
protocol PromptTextMeasuring: Sendable {
    var metrics: PromptFontMetrics { get }
    /// Names the face for the layout cache's key, so two faces never share a
    /// layout (E-32: the fallback face is a different key from the real one).
    var fontName: String { get }
    func width(of text: String) -> Double
}

extension PromptTextMeasuring {
    var fontName: String { "measured" }
}

// MARK: - Layout

/// One run of a word on one line. A word is one item, unless it is wider than
/// the column on its own (a URL, E-33) and has to be broken into pieces.
struct PromptLineItem: Sendable, Equatable {
    /// Index into `PromptScript.words`.
    let word: Int
    /// The `Character` range of the word's text this piece draws; nil for the
    /// whole word.
    let fragment: Range<Int>?
    /// From the column's left edge, whatever the direction: a right-to-left
    /// line has its first word at the right.
    let x: Double
    let width: Double
}

struct PromptLine: Sendable, Equatable {
    /// Into `PromptLayout.items`.
    let items: Range<Int>
    let top: Double
    /// Opens a paragraph with dividers on: the dots sit in the extra room
    /// above it.
    let dividerAbove: Bool
}

/// The positioned words of one page in one face at one column width.
///
/// Flat arrays rather than a line of word structs each: a 100,000-word page is
/// about 12,000 lines, and the stage asks for a dozen of them per frame by
/// binary search over `lines`.
struct PromptLayout: Sendable {
    let metrics: PromptFontMetrics
    let columnWidth: Double
    let direction: PromptDirection
    let items: [PromptLineItem]
    let lines: [PromptLine]
    /// The line holding each word's first piece, for every word laid out.
    let lineOfWord: [Int]
    /// False for the first screenful the stage draws while the rest of a big
    /// page is laid out elsewhere: `lineOfWord` then stops short of the page.
    let isComplete: Bool

    var height: Double { lines.last.map { $0.top + metrics.lineHeight } ?? 0 }

    func lineBottom(_ line: Int) -> Double { lines[line].top + metrics.lineHeight }
    func lineCenter(_ line: Int) -> Double { lines[line].top + metrics.lineHeight / 2 }

    /// The line a word starts on. A word past the end of a partial layout is
    /// on its last line, which is where the stage is looking until the rest
    /// arrives; nil only when nothing is laid out.
    func lineIndex(ofWord word: Int) -> Int? {
        guard !lines.isEmpty, !lineOfWord.isEmpty else { return nil }
        return lineOfWord[min(max(word, 0), lineOfWord.count - 1)]
    }

    /// The lines that cross `lower..<upper`, in content coordinates. Binary
    /// search, so the per-frame cost does not grow with the page (E-26).
    func lines(intersecting lower: Double, _ upper: Double) -> Range<Int> {
        guard !lines.isEmpty, upper > lower else { return 0..<0 }
        let lineHeight = metrics.lineHeight
        // First line whose bottom is below `lower`.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].top + lineHeight <= lower { low = mid + 1 } else { high = mid }
        }
        let first = low
        // First line whose top is at or below `upper`.
        high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].top < upper { low = mid + 1 } else { high = mid }
        }
        return first..<max(first, low)
    }

    /// The line whose slot (its top to the next line's top) holds `y`, or the
    /// nearest end. Used to find what sits under the reading guide.
    func line(atContentY y: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].top <= y { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    /// The text a line draws, its pieces joined as they are set. For the
    /// accessibility value and for tests; never on a per-frame path.
    func text(ofLine line: Int, in script: PromptScript) -> String {
        guard lines.indices.contains(line) else { return "" }
        var parts: [String] = []
        var previousWord: Int?
        for item in items[lines[line].items] {
            let word = script.words[item.word]
            let piece: String
            if let fragment = item.fragment {
                piece = String(Array(word.text)[fragment])
            } else {
                piece = word.text
            }
            if let previousWord, !PromptFlowLayout.isJoined(previousWord, item.word, in: script) {
                parts.append(" ")
            }
            parts.append(piece)
            previousWord = item.word
        }
        return parts.joined()
    }
}

// MARK: - Key and cache

/// The layout cache's key: `PromptLayoutKey` (the page's content hash, the
/// face, its size, the column) plus the one setting that moves lines without
/// changing the face, the paragraph dividers.
///
/// Spec 10.2: never the word count, never the first and last word. The
/// upstream key was exactly those, so a same-length edit in the middle of a
/// page kept the old layout and the highlight drifted off the words (E-27).
struct PromptStageLayoutKey: Hashable, Sendable {
    let base: PromptLayoutKey
    let dividers: Bool

    init(script: PromptScript, fontName: String, pointSize: Double, columnWidth: Double, dividers: Bool) {
        base = PromptLayoutKey(
            contentHash: script.contentHash, fontName: fontName, pointSize: pointSize, columnWidth: columnWidth
        )
        self.dividers = dividers
    }
}

/// A few recent layouts, most recent first. Bounded, because one entry for a
/// 100,000-word page is a few megabytes, and the stage only ever goes back to
/// the width or face it just left. Owned by one stage model and never shared:
/// two views with one cache is how the upstream app drew one view's layout in
/// another.
struct PromptLayoutCache {
    let capacity: Int
    private var entries: [(key: PromptStageLayoutKey, layout: PromptLayout)] = []

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    mutating func layout(for key: PromptStageLayoutKey) -> PromptLayout? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
        return entry.layout
    }

    mutating func insert(_ layout: PromptLayout, for key: PromptStageLayoutKey) {
        entries.removeAll { $0.key == key }
        entries.insert((key, layout), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

// MARK: - The flow layout

/// Spec 10.2: a line breaks when the running width plus the next word would
/// pass the column. Pure; `measurer` is the only outside thing it touches.
enum PromptFlowLayout {
    /// Two words with nothing between them in the source: the characters of a
    /// CJK run, which the tokenizer splits one to a word (6.1). They are set
    /// side by side, as the author typed them; a space the author did type is
    /// still a space.
    static func isJoined(_ previous: Int, _ next: Int, in script: PromptScript) -> Bool {
        script.words[previous].utf16Range.upperBound == script.words[next].utf16Range.lowerBound
    }

    /// - Parameter stopBelow: stop once a line would start below this content
    ///   y. The stage uses it for the first screenful of a big page; the result
    ///   is then marked incomplete. Lines already laid out are exactly the
    ///   lines a full layout has, since a line depends only on what is before
    ///   it.
    static func layout(
        _ script: PromptScript,
        measurer: some PromptTextMeasuring,
        columnWidth: Double,
        dividers: Bool,
        stopBelow: Double? = nil
    ) -> PromptLayout {
        let metrics = measurer.metrics
        let column = max(columnWidth.isFinite ? columnWidth : 0, 1)
        let rtl = script.direction == .rightToLeft

        var items: [PromptLineItem] = []
        var lines: [PromptLine] = []
        var lineOfWord: [Int] = []
        items.reserveCapacity(script.words.count)
        lineOfWord.reserveCapacity(script.words.count)

        // One measurement per distinct word: prose repeats itself, and the
        // measurer is the expensive part of a big page.
        var widths: [String: Double] = [:]
        func width(_ text: String) -> Double {
            if let known = widths[text] { return known }
            let measured = max(0, measurer.width(of: text))
            widths[text] = measured
            return measured
        }
        let space = width(" ")

        var lineStart = 0
        var lineTop = 0.0
        var lineDivider = false
        var x = 0.0
        var stopped = false

        /// Ends the open line, if it has anything on it, and opens the next.
        func closeLine(extra: Double = 0) {
            guard items.count > lineStart else { return }
            if rtl {
                for index in lineStart..<items.count {
                    let item = items[index]
                    items[index] = PromptLineItem(
                        word: item.word, fragment: item.fragment,
                        x: column - item.x - item.width, width: item.width
                    )
                }
            }
            lines.append(PromptLine(items: lineStart..<items.count, top: lineTop, dividerAbove: lineDivider))
            lineStart = items.count
            lineTop += metrics.pitch + extra
            lineDivider = false
            x = 0
            if let stopBelow, lineTop > stopBelow { stopped = true }
        }

        for (index, word) in script.words.enumerated() {
            if word.startsParagraph, dividers, index > 0 {
                closeLine(extra: PromptFontMetrics.dividerSpacing)
                lineDivider = true
            }
            if stopped { break }
            let wordWidth = width(word.text)
            let gap = index > 0 && items.count > lineStart && !isJoined(index - 1, index, in: script) ? space : 0

            if wordWidth > column {
                // E-33: wider than the column on its own. Start it on a fresh
                // line and break it into pieces that each fit; the last piece
                // leaves the line open for what follows.
                closeLine()
                if stopped { break }
                lineOfWord.append(lines.count)
                let characters = Array(word.text)
                var pieceStart = 0
                var pieceWidth = 0.0
                for (offset, character) in characters.enumerated() {
                    let characterWidth = width(String(character))
                    if offset > pieceStart, pieceWidth + characterWidth > column {
                        items.append(PromptLineItem(
                            word: index, fragment: pieceStart..<offset, x: 0, width: pieceWidth))
                        closeLine()
                        pieceStart = offset
                        pieceWidth = 0
                    }
                    pieceWidth += characterWidth
                }
                items.append(PromptLineItem(
                    word: index, fragment: pieceStart..<characters.count, x: 0, width: pieceWidth))
                x = pieceWidth
                continue
            }

            if items.count > lineStart, x + gap + wordWidth > column {
                closeLine()
                if stopped { break }
                lineOfWord.append(lines.count)
                items.append(PromptLineItem(word: index, fragment: nil, x: 0, width: wordWidth))
                x = wordWidth
            } else {
                lineOfWord.append(lines.count)
                items.append(PromptLineItem(word: index, fragment: nil, x: x + gap, width: wordWidth))
                x += gap + wordWidth
            }
        }
        if !stopped { closeLine() }

        return PromptLayout(
            metrics: metrics,
            columnWidth: column,
            direction: script.direction,
            items: items,
            lines: lines,
            lineOfWord: lineOfWord,
            isComplete: lineOfWord.count == script.words.count
        )
    }
}

// MARK: - Off the main thread

/// Where a big page is tokenized and laid out (E-26). A detached task, so the
/// work never inherits the main actor from the caller that asked for it.
enum PrompterBackground {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }
}
