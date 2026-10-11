import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// What the Prompter's stage draws, and where (spec 10.1, 10.2, 6.5, E-24,
/// E-25, E-27, E-32, E-33; the T7 design note's ladders). Everything that
/// decides a colour, an opacity or a position is a pure function, so it is
/// asserted here without a window; the view only places what these say.
@MainActor
final class PrompterStageRenderTests: XCTestCase {
    private let measurer = FixedWidthMeasurer()

    private func layout(
        _ text: String, column: Double = 100, dividers: Bool = false, measurer: FixedWidthMeasurer? = nil
    ) -> (PromptScript, PromptLayout) {
        let script = PromptScript(text)
        return (script, PromptFlowLayout.layout(
            script, measurer: measurer ?? self.measurer, columnWidth: column, dividers: dividers
        ))
    }

    /// The words of each line, as text, for readable assertions.
    private func lines(_ script: PromptScript, _ layout: PromptLayout) -> [String] {
        layout.lines.indices.map { layout.text(ofLine: $0, in: script) }
    }

    // MARK: - Contrast (design note: word ladder, cue ladder, tints)

    /// The one contrast model: white through `PrompterStageStyle.contrast` is
    /// exactly `Theme.contrast`, so the stage's numbers are the ramp's numbers.
    func testTheStageMeasuresContrastTheWayTheRampDoes() {
        for opacity in [0.4, 0.5, 0.55, 0.75, 1.0] {
            for grey in [0.0, 0.11, 0.24] {
                XCTAssertEqual(
                    PrompterStageStyle.contrast(of: .white, opacity: opacity, overGrey: grey),
                    Theme.contrast(textOpacity: opacity, overGrey: grey),
                    accuracy: 1e-9
                )
            }
        }
        // The figures the design note quotes, over black.
        XCTAssertEqual(Theme.contrast(textOpacity: 0.40, overGrey: 0), 3.7, accuracy: 0.05)
        XCTAssertEqual(Theme.contrast(textOpacity: 0.55, overGrey: 0), 6.27, accuracy: 0.05)
    }

    /// The design note's ladder for the default white highlight: unread and
    /// current at full, current underlined 2 pt, read 0.40, or 0.55 with
    /// Increase Contrast.
    func testTheWordLadderIsTheDesignNotes() {
        let plain = PrompterStageStyle(increaseContrast: false, reduceTransparency: false)
        XCTAssertEqual(plain.opacity(for: .unread), 1.0)
        XCTAssertEqual(plain.opacity(for: .current), 1.0)
        XCTAssertEqual(plain.opacity(for: .read), 0.40)
        XCTAssertEqual(PrompterStageStyle.underlineWidth, 2)
        XCTAssertTrue(plain.underlines(.current))
        XCTAssertFalse(plain.underlines(.unread))
        XCTAssertFalse(plain.underlines(.read))
        XCTAssertFalse(plain.underlines(.cue))

        let raised = PrompterStageStyle(increaseContrast: true, reduceTransparency: false)
        XCTAssertEqual(raised.opacity(for: .read), 0.55)
        XCTAssertGreaterThan(raised.opacity(for: .read), plain.opacity(for: .read))
        XCTAssertGreaterThan(plain.opacity(for: .current), plain.opacity(for: .read),
                             "the current word is never dimmer than the words behind it")
    }

    /// The cue ladder: one opacity per brightness, whatever the cue's state;
    /// Increase Contrast adds 0.15, capped at 1.
    func testTheCueLadderIsTheDesignNotes() {
        let expected: [(PrompterCueBrightness, Double, Double)] = [
            (.dim, 0.45, 0.60), (.low, 0.55, 0.70), (.medium, 0.70, 0.85), (.bright, 0.90, 1.0),
        ]
        for (brightness, plain, raised) in expected {
            XCTAssertEqual(
                PrompterStageStyle(increaseContrast: false, reduceTransparency: false, cueBrightness: brightness)
                    .opacity(for: .cue), plain, accuracy: 1e-9, "\(brightness)")
            XCTAssertEqual(
                PrompterStageStyle(increaseContrast: true, reduceTransparency: false, cueBrightness: brightness)
                    .opacity(for: .cue), raised, accuracy: 1e-9, "\(brightness) with Increase Contrast")
        }
    }

    /// No reading state is under its floor, at either contrast setting, for
    /// any highlight or cue colour, over black or over the brightest point of
    /// the glass the stage sits on (drawn, or solid under Reduce Transparency).
    /// The floor is 3:1: the stage's type starts at 18 pt, WCAG's large text.
    func testNoReadingStateIsUnderItsFloorOnAnyBackdrop() {
        for increaseContrast in [false, true] {
            for reduceTransparency in [false, true] {
                for tint in PrompterTint.allCases {
                    for brightness in PrompterCueBrightness.allCases {
                        let style = PrompterStageStyle(
                            increaseContrast: increaseContrast, reduceTransparency: reduceTransparency,
                            highlight: tint, cueTint: tint, cueBrightness: brightness
                        )
                        XCTAssertEqual(style.backdropGreys.first, 0, "black is always measured")
                        for grey in style.backdropGreys {
                            for state in [PrompterWordState.unread, .current, .read] {
                                let ratio = PrompterStageStyle.contrast(
                                    of: style.highlightColor, opacity: style.opacity(for: state), overGrey: grey)
                                XCTAssertGreaterThanOrEqual(
                                    ratio, PrompterStageStyle.minimumContrast,
                                    "\(tint) \(state) over \(grey), IC \(increaseContrast), RT \(reduceTransparency)")
                            }
                            let cue = PrompterStageStyle.contrast(
                                of: style.cueColor, opacity: style.opacity(for: .cue), overGrey: grey)
                            XCTAssertGreaterThanOrEqual(
                                cue, PrompterStageStyle.minimumContrast,
                                "\(tint) cue \(brightness) over \(grey), IC \(increaseContrast)")
                        }
                    }
                }
            }
        }
    }

    /// A tint that fails at full strength is lightened until it passes;
    /// white and the tints that already pass are left exactly as the spec
    /// gives them.
    func testTintsAreTheSpecsColoursLightenedOnlyWhereTheyFail() {
        XCTAssertEqual(PrompterTint.white.rgb, PromptRGB(red: 1, green: 1, blue: 1))
        XCTAssertEqual(PrompterTint.yellow.rgb, PromptRGB(red: 1.0, green: 0.84, blue: 0.04))
        XCTAssertEqual(PrompterTint.green.rgb, PromptRGB(red: 0.2, green: 0.84, blue: 0.29))
        XCTAssertEqual(PrompterTint.blue.rgb, PromptRGB(red: 0.31, green: 0.55, blue: 1.0))
        XCTAssertEqual(PrompterTint.pink.rgb, PromptRGB(red: 1.0, green: 0.38, blue: 0.57))
        XCTAssertEqual(PrompterTint.orange.rgb, PromptRGB(red: 1.0, green: 0.62, blue: 0.04))
        for tint in PrompterTint.allCases {
            let style = PrompterStageStyle(increaseContrast: false, reduceTransparency: false, highlight: tint)
            let passes = style.backdropGreys.allSatisfy {
                PrompterStageStyle.contrast(of: tint.rgb, opacity: 1, overGrey: $0) >= PrompterStageStyle.minimumContrast
            }
            if passes {
                XCTAssertEqual(style.highlightColor, tint.rgb, "\(tint) passes as given and is not touched")
            } else {
                XCTAssertNotEqual(style.highlightColor, tint.rgb, "\(tint) fails and must be lightened")
            }
        }
        // White read text stays at the ladder's 0.40: the floor only ever
        // raises a tint that needs it.
        XCTAssertGreaterThan(
            PrompterStageStyle(increaseContrast: false, reduceTransparency: false, highlight: .blue)
                .opacity(for: .read), 0.40, "blue at 0.40 is 1.8:1 over black and is raised")
        XCTAssertEqual(
            PrompterStageStyle(increaseContrast: false, reduceTransparency: false).opacity(for: .read), 0.40)
    }

    // MARK: - Word states (spec 10.1)

    func testTimerModesDrawEveryWordAlikeAndCuesAsCues() {
        let script = PromptScript("Hello there [smile] friends -- all")
        for progress in [0.0, 1.5, 4.2, 6.0] {
            let states = script.words.indices.map {
                PromptWordStates.state(of: $0, in: script, progress: progress, uniform: true)
            }
            XCTAssertEqual(states, [.unread, .unread, .cue, .unread, .unread, .unread], "progress \(progress)")
        }
        XCTAssertTrue(PrompterGuidanceMode.classic.drawsUniformly, "Classic is a timer mode")
    }

    /// Follow's states (release 3): read behind, current, unread ahead. A cue
    /// and a non-speech token are never current; the dash is drawn as text.
    func testTrackedStatesNeverMakeACueOrADashCurrent() {
        let script = PromptScript("one [pause] -- two three")
        // Progress on the cue: the current word is the next spoken one.
        XCTAssertEqual(PromptWordStates.currentWord(in: script, progress: 1), 3)
        XCTAssertEqual(PromptWordStates.currentWord(in: script, progress: 2.5), 3)
        let states = script.words.indices.map {
            PromptWordStates.state(of: $0, in: script, progress: 1, uniform: false)
        }
        XCTAssertEqual(states, [.read, .cue, .read, .current, .unread])
        // At the end nothing is current and everything spoken is read (E-30).
        let end = script.words.indices.map {
            PromptWordStates.state(of: $0, in: script, progress: Double(script.words.count), uniform: false)
        }
        XCTAssertEqual(end, [.read, .cue, .read, .read, .read])
        XCTAssertNil(PromptWordStates.currentWord(in: script, progress: 5))
        XCTAssertEqual(PromptWordStates.currentWord(in: script, progress: -3), 0, "clamped at the start")
    }

    // MARK: - Flow layout (spec 10.2)

    func testWordsFlowIntoLinesAtTheColumnWidth() {
        // 10 pt a letter, 5 pt a space: "aaaa bbbb" is 85 pt and fits 100;
        // "cccc" would take the line to 130.
        let (script, layout) = layout("aaaa bbbb cccc dd")
        XCTAssertEqual(lines(script, layout), ["aaaa bbbb", "cccc dd"])
        XCTAssertEqual(layout.lines.map(\.top), [0, 28], "line height 20 plus 8 pt spacing")
        XCTAssertEqual(layout.height, 48)
        XCTAssertTrue(layout.isComplete)
        let first = layout.items[layout.lines[0].items]
        XCTAssertEqual(first.map(\.x), [0, 45], "left-aligned, one space between words")
    }

    /// Line height is `ceil(ascender - descender + leading)`; spacing is 8 pt,
    /// or 2 pt for a face taller than 1.5 times its size (OpenDyslexic).
    func testLineHeightAndTheTallFaceRule() {
        let ordinary = PromptFontMetrics(pointSize: 26, ascender: 24.7, descender: -6.2, leading: 0)
        XCTAssertEqual(ordinary.lineHeight, 31)
        XCTAssertEqual(ordinary.lineSpacing, 8)
        let tall = PromptFontMetrics(pointSize: 26, ascender: 34, descender: -12, leading: 0)
        XCTAssertEqual(tall.lineHeight, 46)
        XCTAssertEqual(tall.lineSpacing, 2)
    }

    /// E-33: a word longer than the column with no spaces (a URL) breaks at
    /// the column and never overflows it.
    func testAWordWiderThanTheColumnBreaksInsideIt() {
        let (script, layout) = layout("go https://example.com/a/very/long/path ok", column: 100)
        for item in layout.items {
            XCTAssertLessThanOrEqual(item.x + item.width, 100 + 1e-9, "no item overflows the column")
            XCTAssertGreaterThanOrEqual(item.x, 0)
        }
        let url = 1
        let pieces = layout.items.filter { $0.word == url }
        XCTAssertGreaterThan(pieces.count, 1, "the URL is broken across lines")
        let rebuilt = pieces.map { piece -> String in
            let characters = Array(script.words[url].text)
            return String(characters[piece.fragment ?? 0..<characters.count])
        }.joined()
        XCTAssertEqual(rebuilt, script.words[url].text, "the pieces are the word, in order, nothing lost")
        XCTAssertEqual(layout.lineIndex(ofWord: url), 1, "the long word starts a line of its own")
    }

    /// E-25: CJK is one word per character and wraps per character, with no
    /// space drawn between characters that had none in the source.
    func testCJKWrapsPerCharacterWithoutSpaces() {
        let (script, layout) = layout("日本語のテキストです", column: 45)
        XCTAssertEqual(script.words.count, 10)
        XCTAssertEqual(layout.lines.count, 3, "four characters to a 45 pt line")
        let first = layout.items[layout.lines[0].items]
        XCTAssertEqual(first.map(\.x), [0, 10, 20, 30], "characters set side by side")
        // A space the author typed is still a space.
        let (_, spaced) = self.layout("日本 語", column: 200)
        XCTAssertEqual(spaced.items.map(\.x), [0, 10, 25])
    }

    /// E-24: a right-to-left page sets each line from the right edge, keeping
    /// logical order (the first word is the rightmost).
    func testRightToLeftLinesAreSetFromTheRightEdge() {
        let (script, layout) = layout("שלום עולם יפה מאוד", column: 100)
        XCTAssertEqual(script.direction, .rightToLeft)
        XCTAssertEqual(layout.direction, .rightToLeft)
        let first = layout.items[layout.lines[0].items]
        XCTAssertEqual(first.first?.word, 0)
        XCTAssertEqual(first.first.map { $0.x + $0.width }, 100, "the first word touches the right edge")
        XCTAssertLessThan(first[1].x, first[0].x, "the second word is to its left")
        // A leading cue does not decide the direction (E-24).
        let (cued, _) = self.layout("[smile] שלום", column: 100)
        XCTAssertEqual(cued.direction, .rightToLeft)
    }

    /// Spec 6.5: with dividers on, a blank line starts a new line 14 pt
    /// further down and draws three 3 pt dots at white 0.16; a single
    /// newline is a space; with dividers off the text flows.
    func testParagraphDividersOnlyAtBlankLines() {
        let text = "one two\nthree\n\nfour"
        let (script, on) = layout(text, column: 500, dividers: true)
        XCTAssertEqual(lines(script, on), ["one two three", "four"])
        XCTAssertEqual(on.lines.map(\.dividerAbove), [false, true])
        XCTAssertEqual(on.lines[1].top, 28 + PromptFontMetrics.dividerSpacing)
        let (_, off) = layout(text, column: 500, dividers: false)
        XCTAssertEqual(off.lines.count, 1, "with the setting off a paragraph flows on")
        XCTAssertEqual(PrompterStageStyle.dividerDotCount, 3)
        XCTAssertEqual(PrompterStageStyle.dividerDotDiameter, 3)
        XCTAssertEqual(PrompterStageStyle.dividerOpacity(increaseContrast: false), 0.16)
    }

    /// E-20/E-21: an empty page lays out to nothing; a page of cues alone is
    /// drawn (it is on screen while it completes).
    func testEmptyAndCueOnlyPages() {
        let (_, empty) = layout("   \n  ")
        XCTAssertTrue(empty.lines.isEmpty)
        XCTAssertEqual(empty.height, 0)
        XCTAssertTrue(empty.isComplete)
        let (cues, layout) = layout("[smile] [pause]")
        XCTAssertEqual(lines(cues, layout), ["[smile]", "[pause]"])
    }

    /// The column is the setting, never wider than the body less 24 pt a side
    /// (design note), and never negative on a body too small to hold it.
    func testTheColumnIsNeverWiderThanTheBodyLessMargins() {
        XCTAssertEqual(PrompterStageMetrics.columnWidth(setting: 360, bodyWidth: 560), 360)
        XCTAssertEqual(PrompterStageMetrics.columnWidth(setting: 560, bodyWidth: 560), 512)
        XCTAssertEqual(PrompterStageMetrics.columnWidth(setting: 560, bodyWidth: 480), 432)
        XCTAssertEqual(PrompterStageMetrics.columnWidth(setting: 280, bodyWidth: 20), 0)
        XCTAssertEqual(PrompterStageMetrics.controlRowHeight, 24)
        XCTAssertEqual(PrompterStageMetrics.sideMargin, 24)
    }

    // MARK: - Cache (spec 10.2, E-27)

    /// Keyed by the page's content hash plus font, size, column width and the
    /// divider setting: a same-length edit in the middle is a new layout.
    func testTheCacheIsKeyedByContentNotByShape() {
        let before = PromptScript("alpha bravo charlie delta")
        let after = PromptScript("alpha bravx charlie delta")
        let key = { (script: PromptScript, width: Double, dividers: Bool) in
            PromptStageLayoutKey(script: script, fontName: "Face", pointSize: 26, columnWidth: width, dividers: dividers)
        }
        XCTAssertNotEqual(key(before, 360, false), key(after, 360, false), "E-27: a middle word edited")
        XCTAssertNotEqual(key(before, 360, false), key(before, 361, false))
        XCTAssertNotEqual(key(before, 360, false), key(before, 360, true))
        XCTAssertEqual(key(before, 360, false), key(PromptScript("alpha bravo charlie delta"), 360, false))

        var cache = PromptLayoutCache(capacity: 2)
        let layout = PromptFlowLayout.layout(before, measurer: measurer, columnWidth: 360, dividers: false)
        cache.insert(layout, for: key(before, 360, false))
        XCTAssertNotNil(cache.layout(for: key(before, 360, false)))
        XCTAssertNil(cache.layout(for: key(after, 360, false)))
        cache.insert(layout, for: key(before, 300, false))
        cache.insert(layout, for: key(before, 280, false))
        XCTAssertNil(cache.layout(for: key(before, 360, false)), "bounded: the oldest is let go")
        XCTAssertEqual(cache.count, 2)
    }

    /// Never shared across views: each stage model has its own cache, so a
    /// layout made by one is not found by another.
    func testEachStageModelKeepsItsOwnCache() {
        let rig = StageRig()
        let one = rig.stage()
        let two = rig.stage()
        XCTAssertTrue(rig.session.start(pages: [PromptScript("a few words to read here")]))
        one.setViewport(CGSize(width: 560, height: 120))
        XCTAssertEqual(one.cachedLayoutCount, 1)
        XCTAssertEqual(two.cachedLayoutCount, 0, "the other model computed nothing and borrowed nothing")
        rig.session.stop()
    }

    // MARK: - Fonts (E-32)

    /// OpenDyslexic missing falls back to the rounded system face, silently,
    /// and says it did (for Settings' "not installed").
    func testAMissingDyslexiaFaceFallsBackToTheRoundedSystemFace() {
        let missing = PrompterFontResolver.resolve(family: .dyslexia, size: 26, lookup: { _, _ in nil })
        XCTAssertTrue(missing.isFallback)
        let rounded = PrompterFontResolver.systemFont(size: 26, design: .rounded)
        XCTAssertEqual(missing.font.fontName, rounded.fontName)
        XCTAssertEqual(missing.font.pointSize, 26)

        let present = NSFont.systemFont(ofSize: 26)
        let found = PrompterFontResolver.resolve(family: .dyslexia, size: 26, lookup: { name, _ in
            name == PrompterFontResolver.dyslexiaFontName ? present : nil
        })
        XCTAssertFalse(found.isFallback)

        for family in [PrompterFontFamily.sans, .serif, .mono] {
            let resolved = PrompterFontResolver.resolve(family: family, size: 22)
            XCTAssertFalse(resolved.isFallback, "\(family)")
            XCTAssertEqual(resolved.font.pointSize, 22)
        }
        XCTAssertNotEqual(
            PrompterFontResolver.resolve(family: .serif, size: 22).font.fontName,
            PrompterFontResolver.resolve(family: .sans, size: 22).font.fontName,
            "the cache key changes with the family"
        )
    }

    /// The real measurer agrees with itself off the main thread and gives
    /// the metrics the layout's line rule reads.
    func testTheCoreTextMeasurerMeasuresOffTheMainThread() async {
        let font = PrompterFontResolver.resolve(family: .sans, size: 26).font
        let measurer = CoreTextMeasurer(font: font, tracking: Theme.tracking(forSize: 26))
        let onMain = measurer.width(of: "Prompter")
        let offMain = await PrompterBackground.run { measurer.width(of: "Prompter") }
        XCTAssertGreaterThan(onMain, 40)
        XCTAssertEqual(onMain, offMain, accuracy: 1e-9)
        XCTAssertGreaterThan(measurer.metrics.lineHeight, 26)
        XCTAssertEqual(measurer.metrics.lineSpacing, 8)
    }
}

/// The start's cheap readability test is the tokenizer's own, on the cases
/// where they could part: Unicode spaces, the ideographic space, a zero-width
/// space (not whitespace, so a word), cues alone, a combining mark alone.
final class PrompterReadableTextTests: XCTestCase {
    @MainActor
    func testHasWordsAgreesWithTheTokenizer() {
        let cases = [
            "", " ", "\n\n\t", "\u{3000}", "\u{00A0}\u{2003}", "\u{200B}", "[smile]", "--",
            "\u{0301}", "a", " \n a \n", "日", "\u{FEFF}", "\u{2028}", "\r\n",
        ]
        for text in cases {
            XCTAssertEqual(
                PrompterParts.hasWords(text), !PromptScript(text).words.isEmpty,
                "disagree on \(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}
