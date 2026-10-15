import AppKit
import XCTest
@testable import IslaKit

/// What a copied string is (redesign spec §9.1): colour, link and code are
/// decided by pure functions, and "when unsure, a row is plain Text". The tables
/// below hold both halves — what each kind accepts and the near-misses that must
/// not be taken for it.
final class ClipboardKindTests: XCTestCase {
    // MARK: Colour

    func testEveryColourSyntaxTheSpecNamesIsAColour() {
        for value in [
            "#FF453A", "#ff453a", "#fff", "#FFF8", "#ff453a80", "  #FF453A\n",
            "rgb(48, 209, 88)", "RGB(48,209,88)", "rgba(0, 0, 0, 0.5)", "rgb(48 209 88)", "rgb(48 209 88 / 50%)",
            "rgb(10%, 20%, 30%)", "hsl(120, 100%, 50%)", "hsla(120, 100%, 50%, .5)", "hsl(120deg 100% 50% / 0.5)",
        ] {
            XCTAssertTrue(ClipboardDetection.isColour(value), "\(value) is a colour")
            XCTAssertEqual(ClipboardDetection.kind(ofText: value), .colour, value)
        }
    }

    func testNearMissesAreText() {
        for value in [
            "", "FF453A", "decade", "#12345", "#1234567", "#GGGGGG", "#", "# fff",
            "#fff #000", "color: #fff", "#fff;", "background: rgb(0,0,0)",
            "rgb(300, 0, 0)", "rgb(1, 2)", "rgb(1, 2, 3, 4, 5)", "rgb(10, 20, 30) and more", "rgb(var(--r), 0, 0)",
            "rgba(0, 0, 0, 1.5)", "rgb(101%, 0%, 0%)", "hsl(120, 100, 50)", "hsl(400, 100%, 50%)", "hsl(120, 101%, 50%)",
            "rgb 1 2 3", "rgb(1, 2, 3", "#fff\n#000", "red", "blue-ish",
        ] {
            XCTAssertFalse(ClipboardDetection.isColour(value), "\(value.debugDescription) is not a colour")
            XCTAssertNotEqual(ClipboardDetection.kind(ofText: value), .colour, value)
        }
    }

    func testTheSwatchDrawsWhatTheDetectorAccepted() {
        let red = ClipSwatch.rgba(for: "#FF453A")
        XCTAssertEqual(red?.r ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(red?.g ?? 0, 0x45 / 255, accuracy: 0.001)
        XCTAssertEqual(ClipSwatch.rgba(for: "#fff")?.b ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(ClipSwatch.rgba(for: "rgb(48, 209, 88)")?.g ?? 0, 209.0 / 255, accuracy: 0.001)
        XCTAssertEqual(ClipSwatch.rgba(for: "rgba(0,0,0,0.5)")?.a ?? 0, 0.5, accuracy: 0.001)
        // hsl(120, 100%, 50%) is pure green.
        let green = ClipSwatch.rgba(for: "hsl(120, 100%, 50%)")
        XCTAssertEqual(green?.r ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(green?.g ?? 0, 1, accuracy: 0.001)
        XCTAssertNil(ClipSwatch.rgba(for: "not a colour"))
    }

    // MARK: Link

    func testALinkIsOneURLAndNothingElse() throws {
        let long = try XCTUnwrap(ClipboardDetection.link("https://developer.apple.com/design/human-interface-guidelines"))
        XCTAssertEqual(long.host, "developer.apple.com")
        XCTAssertEqual(long.rest, "/design/human-interface-guidelines")

        let withPort = try XCTUnwrap(ClipboardDetection.link("http://localhost:3000/x?y=1#z"))
        XCTAssertEqual(withPort.host, "localhost:3000")
        XCTAssertEqual(withPort.rest, "/x?y=1#z")

        let bare = try XCTUnwrap(ClipboardDetection.link("  https://example.com \n"))
        XCTAssertEqual(bare, ClipLink(host: "example.com", rest: ""))
        XCTAssertNotNil(ClipboardDetection.link("HTTPS://Example.com/Path"))
        XCTAssertEqual(ClipboardDetection.kind(ofText: "https://github.com/ctimothe/isla-mac"), .link)
    }

    func testNearMissesAreNotLinks() {
        for value in [
            "", "www.apple.com", "apple.com", "see https://example.com", "https://a.com https://b.com",
            "https://a.com\nhttps://b.com", "https://", "https:///path", "https://exa mple.com",
            "ftp://example.com/a", "mailto:a@b.c", "file:///tmp/a", "Meet at https://example.com.",
        ] {
            XCTAssertNil(ClipboardDetection.link(value), "\(value.debugDescription) is not one URL")
            XCTAssertNotEqual(ClipboardDetection.kind(ofText: value), .link, value)
        }
    }

    // MARK: Code

    func testTwoOrMoreSignalsAndNoSentencePunctuationIsCode() {
        for value in [
            // The board's own sample: a keyword and a call.
            "let answer = try await translator.translate()",
            "func add(a: Int) -> Int {\n    return a + b\n}",
            "const x = () => 1;",
            "def f(x):\n    return x",
            "if (a) { b(); }",
            "let x = 1;",
            "x = y -> z;",
        ] {
            XCTAssertTrue(ClipboardDetection.isCode(value), "\(value.debugDescription) is code")
            XCTAssertEqual(ClipboardDetection.kind(ofText: value), .code, value)
        }
    }

    func testOneSignalOrASentenceIsText() {
        for value in [
            "let me know when you are ready",
            "Meet at the north entrance, 18:30 — bring the cable.",
            "I like { braces } a lot.",
            "Hello (world)",
            "return policy: call us (today)",
            "a.b(c)",
            "{}",
            "Use let x = 1; then run it.",
            "Привет! Как дела?",
            "x;",
            "",
        ] {
            XCTAssertFalse(ClipboardDetection.isCode(value), "\(value.debugDescription) is not code")
        }
        XCTAssertEqual(ClipboardDetection.kind(ofText: "Привет! Как дела?"), .text)
    }

    func testSentencePunctuationIsATerminalMarkNotADotInsideAName() {
        XCTAssertTrue(ClipboardDetection.hasSentencePunctuation("Done."))
        XCTAssertTrue(ClipboardDetection.hasSentencePunctuation("Really? Yes"))
        XCTAssertTrue(ClipboardDetection.hasSentencePunctuation("Wait!"))
        XCTAssertFalse(ClipboardDetection.hasSentencePunctuation("translator.translate()"))
        XCTAssertFalse(ClipboardDetection.hasSentencePunctuation("1.5 + 2.25"))
    }

    func testColourBeatsLinkBeatsCodeBeatsText() {
        // `rgb(1,2,3)` is also a call, and a colour first.
        XCTAssertEqual(ClipboardDetection.kind(ofText: "rgb(1,2,3)"), .colour)
        XCTAssertEqual(ClipboardDetection.kind(ofText: "https://a.com/f(x)"), .link)
        XCTAssertEqual(ClipboardDetection.kind(ofText: "just words"), .text)
    }

    // MARK: Kinds, filters and marks

    @MainActor
    func testAnEntryKnowsItsKindFromItsPayload() {
        func kind(_ payload: ClipItem.Payload) -> ClipKind { ClipItem(payload: payload, date: .distantPast).kind }
        XCTAssertEqual(kind(.text("a note")), .text)
        XCTAssertEqual(kind(.text("#FF453A")), .colour)
        XCTAssertEqual(kind(.text("https://example.com")), .link)
        XCTAssertEqual(kind(.text("let x = 1;")), .code)
        XCTAssertEqual(kind(.file(URL(fileURLWithPath: "/tmp/a.txt"))), .file)
        XCTAssertEqual(kind(.files([URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")])), .files)
        let link = ClipItem(payload: .text("https://example.com/x"), date: .distantPast)
        XCTAssertEqual(link.link, ClipLink(host: "example.com", rest: "/x"))
        XCTAssertNil(ClipItem(payload: .text("words"), date: .distantPast).link)
        XCTAssertFalse(link.isPinned)
    }

    func testEachKindAnswersToOneSegment() {
        XCTAssertEqual(ClipFilter.allCases, [.all, .text, .links, .images, .files])
        let expected: [ClipKind: ClipFilter] = [
            .text: .text, .colour: .text, .code: .text, .link: .links, .image: .images, .file: .files, .files: .files,
        ]
        for (kind, filter) in expected {
            XCTAssertEqual(kind.filter, filter, "\(kind)")
            for candidate in ClipFilter.allCases {
                XCTAssertEqual(candidate.includes(kind), candidate == .all || candidate == filter, "\(candidate) \(kind)")
            }
        }
    }

    func testTheFilterSymbolsAndNamesAreTheSpecs() {
        XCTAssertEqual(ClipFilter.allCases.map(\.symbol), ["square.grid.2x2", "text.alignleft", "link", "photo", "doc"])
        XCTAssertEqual(ClipFilter.allCases.map(\.title), ["All", "Text", "Links", "Images", "Files"])
        for filter in ClipFilter.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: filter.symbol, accessibilityDescription: nil), filter.symbol)
        }
    }

    func testOnlyTheStringKindsAreText() {
        XCTAssertEqual([ClipKind.text, .colour, .code, .link].map(\.isText), [true, true, true, true])
        XCTAssertEqual([ClipKind.image, .file, .files].map(\.isText), [false, false, false])
    }

    // MARK: Ages

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-15 12:00 UTC, a Thursday.
    private var now: Date { Date(timeIntervalSince1970: 1_792_065_600) }

    func testAgesAreTheShortWords() {
        func age(_ seconds: TimeInterval, narrow: Bool = false) -> String {
            ClipboardAge.text(of: now.addingTimeInterval(-seconds), now: now, narrow: narrow, calendar: utc)
        }
        XCTAssertEqual(age(5), "Now")
        XCTAssertEqual(age(59), "Now")
        XCTAssertEqual(age(4 * 60 + 10), "4 min")
        XCTAssertEqual(age(59 * 60), "59 min")
        XCTAssertEqual(age(3600 + 600), "1 hr")
        XCTAssertEqual(age(5 * 3600), "5 hr")
        // Yesterday evening is "Yesterday" however few hours ago it was.
        XCTAssertEqual(age(15 * 3600), "Yesterday")
        XCTAssertEqual(age(30 * 3600), "Yesterday")
    }

    func testOlderAgesAreAWeekdayThenADate() throws {
        try XCTSkipIf(appLanguage != "en", "weekday names follow the app's language")
        func age(days: Int, narrow: Bool = false) -> String {
            ClipboardAge.text(of: now.addingTimeInterval(-Double(days) * 86_400), now: now, narrow: narrow, calendar: utc)
        }
        XCTAssertEqual(age(days: 3), "Monday")
        XCTAssertEqual(age(days: 3, narrow: true), "Mon")
        // The date follows the locale's own order ("Oct 1" in en_US, "1 Oct" in
        // en_GB); what is held is that it is the day and the month and no
        // weekday, and that narrow changes nothing about it.
        for narrow in [false, true] {
            let date = age(days: 14, narrow: narrow)
            XCTAssertTrue(date.contains("Oct") && date.contains("1"), date)
            XCTAssertFalse(date.contains("day"), date)
        }
    }

    // MARK: Long single-line text (review 2026-10-15)

    /// Detection runs on the main thread from `ClipItem.init`. The call pattern
    /// restarted at every character of a long identifier run and scanned to its
    /// end each time — quadratic in the run. A generous bound, measured with the
    /// clock rather than XCTest metrics; the linear version takes microseconds.
    func testALongIdentifierRunClassifiesQuickly() {
        let run = String(repeating: "a", count: 20_000)
        let clock = ContinuousClock()
        let whole = clock.measure { XCTAssertEqual(ClipboardDetection.kind(ofText: run), .text) }
        XCTAssertLessThan(whole, .milliseconds(250), "the whole path, 20,000 characters")
        // The regex alone over the whole run, with the 2 KB sample out of the way.
        let signals = clock.measure { XCTAssertEqual(ClipboardDetection.signalCount(of: run), 0) }
        XCTAssertLessThan(signals, .milliseconds(250), "the call pattern is linear in an identifier run")
        let dotted = String(repeating: "ab.", count: 7_000)
        let chain = clock.measure { _ = ClipboardDetection.signalCount(of: dotted) }
        XCTAssertLessThan(chain, .milliseconds(250), "and in a dotted chain")
    }

    func testOnlyTheFirst2KBDecidesAndLongCodeIsStillCode() {
        XCTAssertEqual(ClipboardDetection.codeSampleLimit, 2048)
        let longCode = String(repeating: "let x = 1;\n", count: 3_000)
        XCTAssertGreaterThan(longCode.count, 20_000, "past the old 20,000 cut-off, which called it text")
        XCTAssertTrue(ClipboardDetection.isCode(longCode))
        // Prose in the head decides, whatever follows it.
        let proseThenCode = "Meet at the north entrance. " + longCode
        XCTAssertFalse(ClipboardDetection.isCode(proseThenCode))
        // The call pattern still finds a call after a dot, and ignores the middle of a word.
        XCTAssertGreaterThanOrEqual(ClipboardDetection.signalCount(of: "x = translator.translate()"), 1)
        XCTAssertEqual(ClipboardDetection.signalCount(of: "9lives(x)"), 0)
    }

    // MARK: Search

    func testSearchIsCaseAndAccentBlindAndFindsEveryMatch() {
        let text = "Café au lait, cafe noir, CAFÉ"
        let ranges = ClipboardSearch.ranges(of: "cafe", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Café", "cafe", "CAFÉ"])
        XCTAssertEqual(ClipboardSearch.ranges(of: "north", in: "Meet at the north entrance").count, 1)
        XCTAssertTrue(ClipboardSearch.ranges(of: "", in: "anything").isEmpty)
        XCTAssertTrue(ClipboardSearch.ranges(of: "   ", in: "anything").isEmpty)
        XCTAssertTrue(ClipboardSearch.ranges(of: "zzz", in: "anything").isEmpty)
        // Non-overlapping: "aa" in "aaaa" is two matches, not three.
        XCTAssertEqual(ClipboardSearch.ranges(of: "aa", in: "aaaa").count, 2)
    }

    @MainActor
    func testSearchLooksAtWhatEachKindHolds() {
        let text = ClipItem(payload: .text("Meet at the north entrance"), date: .distantPast)
        let file = ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/Q3 Report.pdf")), date: .distantPast)
        let files = ClipItem(
            payload: .files([URL(fileURLWithPath: "/tmp/alpha.key"), URL(fileURLWithPath: "/tmp/beta.key")]), date: .distantPast
        )
        XCTAssertTrue(ClipboardSearch.matches(text, query: "NORTH"))
        XCTAssertFalse(ClipboardSearch.matches(text, query: "south"))
        XCTAssertTrue(ClipboardSearch.matches(file, query: "report"))
        XCTAssertFalse(ClipboardSearch.matches(file, query: "/tmp"), "the folder is not what a row shows")
        XCTAssertTrue(ClipboardSearch.matches(files, query: "beta"))
        XCTAssertTrue(ClipboardSearch.matches(text, query: "  "), "nothing typed matches everything")
    }

    /// A row under the privacy cover is searched by its kind's name and never by
    /// its content (review 2026-10-15): the match list would otherwise show a
    /// screen-share which dots hide the word.
    @MainActor
    func testACoveredRowIsMatchedOnItsKindAndNeverOnItsContent() {
        let secret = ClipItem(payload: .text("hunter2 is my password"), date: .distantPast)
        let link = ClipItem(payload: .text("https://secret.example.com/path"), date: .distantPast)
        XCTAssertTrue(ClipboardSearch.matches(secret, query: "hunter2"))
        XCTAssertFalse(ClipboardSearch.matches(secret, query: "hunter2", hidden: true), "content is not compared")
        XCTAssertFalse(ClipboardSearch.matches(link, query: "secret", hidden: true))
        XCTAssertTrue(ClipboardSearch.matches(link, query: "link", hidden: true), "its kind's name is what the mark already says")
        XCTAssertTrue(ClipboardSearch.matches(secret, query: "TEXT", hidden: true))
        XCTAssertTrue(ClipboardSearch.matches(secret, query: "  ", hidden: true))
        // A revealed row (hidden: false) matches on content as before.
        XCTAssertTrue(ClipboardSearch.matches(link, query: "secret", hidden: false))
    }

    /// The text *past* what a row can show still finds the entry.
    @MainActor
    func testAMatchBeyondThePreviewStillFindsTheEntry() {
        let long = String(repeating: "x ", count: 400) + "needle"
        let item = ClipItem(payload: .text(long), date: .distantPast)
        XCTAssertFalse(item.preview.contains("needle"))
        XCTAssertTrue(ClipboardSearch.matches(item, query: "needle"))
    }

    @MainActor
    func testAMatchIsHighlightedAcrossAlinksHostAndPath() {
        let runs = [
            ClipHighlight.Run(text: "developer.apple.com", color: .white, font: .readingMedium),
            ClipHighlight.Run(text: "/design/human-interface-guidelines", color: .gray, font: .reading),
        ]
        XCTAssertEqual(ClipHighlight.matchedText(runs, query: "apple"), ["apple"])
        XCTAssertEqual(ClipHighlight.matchedText(runs, query: "com/des"), ["com/des"], "one match across two runs")
        XCTAssertEqual(ClipHighlight.matchedText(runs, query: ""), [])

        let attributed = ClipHighlight.attributed(runs, query: "apple")
        let lit = attributed.runs.filter { $0.backgroundColor == Theme.findHighlight }
        XCTAssertEqual(lit.count, 1)
        XCTAssertEqual(lit.first.map { String(attributed[$0.range].characters) }, "apple")
        XCTAssertEqual(lit.first?.foregroundColor, Theme.findHighlightText)
    }
}
