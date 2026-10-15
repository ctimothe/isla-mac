import Foundation

/// What a clipboard entry is, for the row that draws it and the filter that
/// finds it (redesign spec §9.1).
///
/// Colour, code and link are subtypes of what used to be one `text` row: the
/// entry still holds a string, and the kind only says how the row dresses it.
/// They are decided once, at capture, by the pure functions in
/// `ClipboardDetection`, so a row never runs a regular expression while it is
/// drawn and a test can hold every near-miss in a table.
enum ClipKind: Equatable {
    case text, colour, code, link, image, file, files

    /// The filter segment this kind answers to. Colour and code are Text: the
    /// spec's table files them under the Text segment, because "I copied some
    /// text" is how a person remembers a hex value or a snippet.
    var filter: ClipFilter {
        switch self {
        case .text, .colour, .code: return .text
        case .link: return .links
        case .image: return .images
        case .file, .files: return .files
        }
    }

    /// Whether the entry is a string a person can read, search and translate.
    /// A link is text too: it is what Translate and Copy as Plain Text would
    /// take, and the spec's "text kinds" is everything that holds a string.
    var isText: Bool {
        switch self {
        case .text, .colour, .code, .link: return true
        case .image, .file, .files: return false
        }
    }

    /// How much of a row's content slot the covered dots fill (spec §9.4: "a
    /// width proportional to the kind"). The board's numbers: a colour value is
    /// short, a sentence is long, and the proportions are what let the covered
    /// list read as a list of different things without saying what they are.
    var coverFraction: Double {
        switch self {
        case .text: return 0.9
        case .code: return 0.8
        case .link: return 0.75
        case .colour: return 0.3
        case .image: return 0.55
        case .files: return 0.6
        case .file: return 0.45
        }
    }
}

/// The header's segmented "Kind" filter (spec §9.3): All, Text, Links, Images,
/// Files — in that order, which is the order the segments are drawn in.
enum ClipFilter: CaseIterable, Equatable {
    case all, text, links, images, files

    var title: String {
        switch self {
        case .all: return localized("All")
        case .text: return localized("Text")
        case .links: return localized("Links")
        case .images: return localized("Images")
        case .files: return localized("Files")
        }
    }

    /// What the list says when entries exist but none is of this kind: "No Text",
    /// "No Links", "No Images", "No Files". Nil for All, which is empty only when
    /// the history is, and says "Nothing copied yet" (review 2026-10-15: the
    /// pane said that for a Links filter over a history full of text, which
    /// reads as lost data).
    var emptyTitle: String? {
        switch self {
        case .all: return nil
        case .text: return localized("No Text")
        case .links: return localized("No Links")
        case .images: return localized("No Images")
        case .files: return localized("No Files")
        }
    }

    /// Below 540 the segments become symbols and these names become their
    /// tooltips (spec §9.3, `Stress-Clip-RU-480`).
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "doc"
        }
    }

    func includes(_ kind: ClipKind) -> Bool {
        self == .all || kind.filter == self
    }
}

/// A link split the way its row reads it (spec §9.1): the host in white
/// (weight 500), the path and what follows it in secondary.
struct ClipLink: Equatable {
    let host: String
    /// Path, query and fragment, as typed; empty for a bare origin.
    let rest: String
}

/// The pure half of capture: what a string is. Every function answers "is the
/// whole string this?" and nothing looser — a row that says Colour or Link for
/// something that merely contains one would be a row that lies, and "when
/// unsure, plain Text" (spec §9.1) is the rule every near-miss below falls on.
enum ClipboardDetection {
    static func kind(ofText string: String) -> ClipKind {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isColour(trimmed) { return .colour }
        if link(trimmed) != nil { return .link }
        if isCode(string) { return .code }
        return .text
    }

    // MARK: Colour

    /// A hex, `rgb()`, `rgba()`, `hsl()` or `hsla()` value and nothing else.
    ///
    /// Hex needs its `#`: six letters from a to f are a word as often as a
    /// colour ("decade", "facade"), and a bare `FF453A` is copied from a
    /// design tool with the `#` far more often than a word is copied alone.
    /// Components are range-checked, so `rgb(300, 0, 0)` — which no browser
    /// renders as that colour — stays text. A trailing `;` is a CSS
    /// declaration, not a value, and is text too.
    static func isColour(_ string: String) -> Bool {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64, !value.contains("\n") else { return false }
        if matches(hex, value) { return true }
        if let parts = components(of: value, function: ["rgb", "rgba"]) {
            return rgbComponentsAreValid(parts)
        }
        if let parts = components(of: value, function: ["hsl", "hsla"]) {
            return hslComponentsAreValid(parts)
        }
        return false
    }

    private static let hex = try! NSRegularExpression(
        pattern: "^#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"
    )

    /// The comma-, space- or slash-separated arguments of `name(...)`, or nil
    /// when the string is anything else — a second value after the bracket, a
    /// missing bracket, another function's name.
    private static func components(of value: String, function names: [String]) -> [String]? {
        let lower = value.lowercased()
        guard let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        guard names.contains(String(lower[..<open])) else { return nil }
        let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
        // No nested brackets: `rgb(var(--x))` is a template, not a colour.
        guard !inner.contains("("), !inner.contains(")") else { return nil }
        let parts = inner
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
            .map(String.init)
        return parts
    }

    private static let number = try! NSRegularExpression(pattern: "^(?:\\d+(?:\\.\\d+)?|\\.\\d+)(%?)$")

    /// A number with an optional percent sign, or nil when it is neither.
    private static func parse(_ part: String) -> (value: Double, isPercent: Bool)? {
        let range = NSRange(part.startIndex..., in: part)
        guard let match = number.firstMatch(in: part, range: range) else { return nil }
        let isPercent = match.range(at: 1).length > 0
        guard let value = Double(isPercent ? String(part.dropLast()) : part) else { return nil }
        return (value, isPercent)
    }

    private static func rgbComponentsAreValid(_ parts: [String]) -> Bool {
        guard parts.count == 3 || parts.count == 4 else { return false }
        for part in parts.prefix(3) {
            guard let (value, isPercent) = parse(part) else { return false }
            if value > (isPercent ? 100 : 255) { return false }
        }
        return parts.count == 3 || alphaIsValid(parts[3])
    }

    private static func hslComponentsAreValid(_ parts: [String]) -> Bool {
        guard parts.count == 3 || parts.count == 4 else { return false }
        // Hue: a plain number of degrees, or one with a unit — the only unit
        // people copy is "deg".
        var hue = parts[0]
        if hue.hasSuffix("deg") { hue = String(hue.dropLast(3)) }
        guard let (hueValue, hueIsPercent) = parse(hue), !hueIsPercent, hueValue <= 360 else { return false }
        for part in parts[1...2] {
            guard let (value, isPercent) = parse(part), isPercent, value <= 100 else { return false }
        }
        return parts.count == 3 || alphaIsValid(parts[3])
    }

    private static func alphaIsValid(_ part: String) -> Bool {
        guard let (value, isPercent) = parse(part) else { return false }
        return value <= (isPercent ? 100 : 1)
    }

    private static func matches(_ expression: NSRegularExpression, _ string: String) -> Bool {
        expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    // MARK: Link

    /// The host and the rest of a string that is one `http` or `https` URL and
    /// nothing else.
    ///
    /// A scheme is required — "www.apple.com" is how a person types an
    /// address, and also how they type most other things — and so is a host,
    /// so "https://" and "https:///path" are text. No whitespace anywhere:
    /// "see https://example.com" and two URLs on two lines are sentences and
    /// lists, not links, and a row that read them as one would open the first
    /// and drop the rest.
    static func link(_ string: String) -> ClipLink? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 2048, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let lower = value.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let components = URLComponents(string: value), let host = components.host, !host.isEmpty else { return nil }
        var shownHost = host
        if let port = components.port { shownHost += ":\(port)" }
        // The rest as typed, not as `URLComponents` re-encodes it: a row that
        // shows "%E2%80%A6" for what was copied as "…" is not the copy.
        let afterScheme = value.drop(while: { $0 != ":" }).dropFirst(3)
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let rest = String(afterScheme[authorityEnd...])
        return ClipLink(host: shownHost, rest: rest)
    }

    // MARK: Code

    /// Two or more code signals and no sentence punctuation (spec §9.1).
    ///
    /// The signals are the spec's five, counted once each: a line that ends in
    /// `;`, a `{` or `}`, an arrow (`=>` or `->`), a line that starts
    /// indented, and a declaration keyword opening a line (`func`, `let`,
    /// `const`, `def` and their kin). One signal is not enough — a sentence
    /// that starts "let me know" has the keyword — and prose is what the
    /// second rule is for: a full stop, question or exclamation mark followed
    /// by a space or the end of the string means somebody wrote a sentence.
    ///
    /// **One signal beyond the spec's list**: a call written the way code
    /// writes it, `name(…)` or `object.name(…)` with no space before the
    /// bracket. The board's own sample, `let answer = try await
    /// translator.translate()`, has the keyword and nothing else of the five,
    /// and the board draws it as code; the call is the second signal it
    /// carries. It cannot make prose code on its own, because two signals are
    /// still needed.
    ///
    /// **Decided on the first 2 KB** (`codeSampleLimit`). This runs on the main
    /// thread from `ClipItem.init`, and a long single-line copy — a minified
    /// bundle, a base64 blob, a 20,000-character run with no spaces — made the
    /// call pattern below quadratic (review 2026-10-15). The head of a text is
    /// as good a witness to its shape as the whole of it, and a row shows one
    /// line of it anyway.
    static let codeSampleLimit = 2048

    static func isCode(_ string: String) -> Bool {
        let head = String(string.prefix(codeSampleLimit))
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return false }
        guard !hasSentencePunctuation(text) else { return false }
        return signalCount(of: head) >= 2
    }

    /// `.`, `?`, `!` or `…` followed by whitespace or the end. Not `a.b` and
    /// not `1.5`: a dot inside an identifier or a number is code's own.
    static func hasSentencePunctuation(_ text: String) -> Bool {
        let characters = Array(text)
        for (index, character) in characters.enumerated() where ".?!…".contains(character) {
            let next = index + 1
            if next >= characters.count || characters[next].isWhitespace { return true }
        }
        return false
    }

    static func signalCount(of string: String) -> Int {
        let lines = string.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
        var signals = 0
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(";") }) { signals += 1 }
        if string.contains("{") || string.contains("}") { signals += 1 }
        if string.contains("=>") || string.contains("->") { signals += 1 }
        if lines.contains(where: { $0.hasPrefix("\t") || $0.hasPrefix("  ") }) { signals += 1 }
        if lines.contains(where: startsWithKeyword) { signals += 1 }
        if matches(call, string) { signals += 1 }
        return signals
    }

    /// Words that open a declaration in the languages people copy from. Plain
    /// English words among them (`let`, `return`) are why a keyword alone is
    /// never enough.
    private static let keywords: Set<String> = [
        "func", "let", "var", "const", "def", "class", "struct", "enum", "import",
        "fn", "function", "return", "interface", "public", "private", "static",
    ]

    private static func startsWithKeyword(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return false }
        return keywords.contains(String(trimmed[..<space]))
    }

    /// `name(…)` or `object.name(…)`. The lookbehind makes the engine try only
    /// where an identifier *starts*: without it every position inside a long run
    /// of identifier characters was a fresh start that scanned to the end of the
    /// run before failing to find a bracket, which is quadratic in the run
    /// (review 2026-10-15).
    private static let call = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_.])[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*\\([^()\\n]*\\)"
    )
}

// MARK: - Search (spec §9.3)

/// What the header's search field does with a query: which entries match and
/// where, as values a test can read.
enum ClipboardSearch {
    /// Case and accent blind, like Spotlight and every find field on the Mac:
    /// "cafe" finds "Café", and "NORTH" finds "north". Compared on the string's
    /// own characters, so a match is a range the row can highlight.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every non-overlapping range of `query` in `text`, in order. An empty or
    /// whitespace-only query matches nothing: the field open with nothing typed
    /// shows the whole list, not an empty one.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: needle, options: options, range: cursor..<text.endIndex) {
            found.append(range)
            cursor = range.upperBound
        }
        return found
    }

    /// - Parameter hidden: the row is under the privacy cover. Its content is
    ///   never compared; only the name of its kind is, which the row's mark
    ///   already says aloud.
    static func matches(_ item: ClipItem, query: String, hidden: Bool = false) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if hidden { return item.kind.filter.title.range(of: needle, options: options) != nil }
        return item.searchText.range(of: needle, options: options) != nil
    }
}

// MARK: - Age (spec §9.2)

/// How long ago, in the short words a 28 pt row has room for: "Now", "4 min",
/// "1 hr", "Yesterday", "Monday", then a date. The Shelf's relative formatter
/// spells the same idea in sentences ("5 min. ago"); a row that also carries
/// two buttons, and a body that can be 480 wide, needs the bare noun.
enum ClipboardAge {
    /// - Parameter narrow: below 540 (spec §9.3): the weekday and the date
    ///   shorten ("Mon", "12 Oct"), the rest are short already.
    static func text(of date: Date, now: Date = Date(), narrow: Bool = false, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return localized("Now") }
        if elapsed < 3600 { return localized("%d min", Int(elapsed / 60)) }
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return localized("%d hr", Int(elapsed / 3600)) }
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        if date >= startOfYesterday { return localized("Yesterday") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 7
        let locale = Locale(identifier: appLanguage)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        if days < 7 {
            formatter.setLocalizedDateFormatFromTemplate(narrow ? "EEE" : "EEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return formatter.string(from: date)
    }
}
