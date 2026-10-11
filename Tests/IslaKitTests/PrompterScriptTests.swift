import Foundation
import XCTest
@testable import IslaKit

/// `PromptScript` is a pure value type, so none of this touches UserDefaults,
/// the microphone or the filesystem. Spec section 6; edge cases E-21 to E-31.
final class PrompterScriptTests: XCTestCase {
    private func texts(_ s: PromptScript) -> [String] { s.words.map(\.text) }
    private func cueFlags(_ s: PromptScript) -> [Bool] { s.words.map(\.isCue) }

    // MARK: - Collapse

    func testWhitespaceCollapsesToSingleSpaces() {
        let s = PromptScript("Hello   world\nfoo\r\nbar\t baz\r\u{2028}qux")
        XCTAssertEqual(texts(s), ["Hello", "world", "foo", "bar", "baz", "qux"])
        XCTAssertEqual(s.collapsedText, "Hello world foo bar baz qux")
    }

    func testWordIdsAndCollapsedRangesIndexTheCollapsedText() {
        let s = PromptScript("  Hello   world  ")
        XCTAssertEqual(s.words.map(\.id), [0, 1])
        XCTAssertEqual(s.words[0].range, 0..<5)
        XCTAssertEqual(s.words[1].range, 6..<11)
        XCTAssertEqual(s.collapsedCount, 11)
        for w in s.words {
            let chars = Array(s.collapsedText)
            XCTAssertEqual(String(chars[w.range]), w.text)
        }
    }

    func testEmptyAndWhitespaceOnlyScriptsHaveNoWords() {
        for text in ["", "   ", "\n\n\t \r\n"] {
            let s = PromptScript(text)
            XCTAssertTrue(s.words.isEmpty, "\(text.debugDescription)")
            XCTAssertEqual(s.collapsedText, "")
            XCTAssertEqual(s.collapsedCount, 0)
            XCTAssertEqual(s.direction, .leftToRight)
        }
    }

    // MARK: - CJK

    func testCJKSplitsToOneWordPerCharacterAndLatinRunsStayTogether() {
        XCTAssertEqual(texts(PromptScript("你好世界")), ["你", "好", "世", "界"])
        XCTAssertEqual(texts(PromptScript("Hello你好world")), ["Hello", "你", "好", "world"])
        XCTAssertEqual(texts(PromptScript("こんにちは")), ["こ", "ん", "に", "ち", "は"])
        XCTAssertEqual(texts(PromptScript("カタカナ")), ["カ", "タ", "カ", "ナ"])
        XCTAssertEqual(texts(PromptScript("안녕")), ["안", "녕"])
        XCTAssertEqual(texts(PromptScript("豈")), ["豈"])
        // Plane 2 (surrogate pair in UTF-16) is still one character.
        XCTAssertEqual(texts(PromptScript("\u{20000}\u{20001}")), ["\u{20000}", "\u{20001}"])
    }

    func testCJKPunctuationIsItsOwnWordInsteadOfFusingToThePreviousCharacter() {
        // Textream's range list stopped at 9FFF, so "好。" fused. 3000-303F is in the list here.
        XCTAssertEqual(texts(PromptScript("你好。")), ["你", "好", "。"])
        XCTAssertEqual(texts(PromptScript("你、好")), ["你", "、", "好"])
        XCTAssertEqual(texts(PromptScript("「你」")), ["「", "你", "」"])
    }

    func testCJKRangeBoundaries() {
        let inside: [UInt32] = [0x4E00, 0x9FFF, 0x3400, 0x4DBF, 0x20000, 0x2A6DF, 0xF900, 0xFAFF,
                                0x3040, 0x309F, 0x30A0, 0x30FF, 0xAC00, 0xD7AF, 0x3000, 0x303F]
        let outside: [UInt32] = [0x4DFF, 0xA000, 0x33FF, 0x2A6E0, 0x1FFFF, 0xF8FF, 0xFB00, 0xABFF,
                                 0xD7B0, 0x2FFF, 0x0041]
        for v in inside { XCTAssertTrue(PromptScript.isCJK(Unicode.Scalar(v)!), String(v, radix: 16)) }
        for v in outside { XCTAssertFalse(PromptScript.isCJK(Unicode.Scalar(v)!), String(v, radix: 16)) }
    }

    func testIdeographicSpaceIsASeparatorNotAWord() {
        // Ambiguity: 3000 is both in the CJK range list and Unicode white space.
        // Step 1 (split on whitespace) runs before step 2, so whitespace wins;
        // a dedicated word for a blank would be an empty-looking stage cell.
        XCTAssertEqual(texts(PromptScript("你\u{3000}好")), ["你", "好"])
    }

    func testCJKWordsKeepSourceRangesAndCollapsedSeparators() {
        let s = PromptScript("a你好")
        XCTAssertEqual(s.collapsedText, "a 你 好")
        XCTAssertEqual(s.words.map(\.utf16Range), [0..<1, 1..<2, 2..<3])
    }

    // MARK: - Cues

    func testClosedCueMarksItsWordsAndRecordsTheSpan() {
        let s = PromptScript("Hello [pause] world")
        XCTAssertEqual(cueFlags(s), [false, true, false])
        XCTAssertEqual(s.cues, [6..<13])
    }

    func testEmptyCueIsACue() {
        let s = PromptScript("a [] b")
        XCTAssertEqual(s.cues, [2..<4])
        XCTAssertEqual(cueFlags(s), [false, true, false])
    }

    func testUnclosedBracketAndStrayCloserAreOrdinaryText() {
        let open = PromptScript("an [unclosed cue here")
        XCTAssertTrue(open.cues.isEmpty)
        XCTAssertEqual(cueFlags(open), [false, false, false, false])
        let stray = PromptScript("a stray ] closer")
        XCTAssertTrue(stray.cues.isEmpty)
        XCTAssertEqual(cueFlags(stray), [false, false, false, false])
        let strayThenCue = PromptScript("] [x]")
        XCTAssertEqual(strayThenCue.cues, [2..<5])
        XCTAssertEqual(cueFlags(strayThenCue), [false, true])
        let cueThenOpen = PromptScript("[a] [b")
        XCTAssertEqual(cueThenOpen.cues, [0..<3])
        XCTAssertEqual(cueFlags(cueThenOpen), [true, false])
    }

    func testAdjacentCuesAreTwoCues() {
        let glued = PromptScript("[a][b] x")
        XCTAssertEqual(glued.cues, [0..<3, 3..<6])
        XCTAssertEqual(cueFlags(glued), [true, false])
        let spaced = PromptScript("[a] [b]")
        XCTAssertEqual(spaced.cues, [0..<3, 4..<7])
        XCTAssertEqual(cueFlags(spaced), [true, true])
    }

    func testCueEmbeddedInAWordMakesTheWholeWordACueWord() {
        let s = PromptScript("say hello[pause]world now")
        XCTAssertEqual(s.cues, [9..<16])
        XCTAssertEqual(cueFlags(s), [false, true, false])
    }

    func testMultiWordCueCoversEveryOverlappedWord() {
        let s = PromptScript("go [look at camera] now")
        XCTAssertEqual(s.cues, [3..<19])
        XCTAssertEqual(cueFlags(s), [false, true, true, true, false])
        // A newline inside the cue collapses to a space and the cue still spans it.
        let nl = PromptScript("[look\nat] x")
        XCTAssertEqual(cueFlags(nl), [true, true, false])
    }

    func testCuesDoNotNestTheyEndAtTheFirstCloser() {
        let s = PromptScript("[a [b] c]")
        XCTAssertEqual(s.cues, [0..<6])
        // "c]" starts after the cue ended, so its stray closer is ordinary text.
        XCTAssertEqual(cueFlags(s), [true, true, false])
    }

    func testCuesAroundCJKSplitWords() {
        let s = PromptScript("[停止]你")
        XCTAssertEqual(texts(s), ["[", "停", "止", "]", "你"])
        XCTAssertEqual(cueFlags(s), [true, true, true, true, false])
    }

    // MARK: - Non-speech tokens

    func testNonSpeechTokensHaveNoLetterOrDigit() {
        let s = PromptScript("-- ... • 😀 ! a1 42 é [pause]")
        XCTAssertEqual(s.words.map(\.isNonSpeech),
                       [true, true, true, true, true, false, false, false, false])
    }

    func testNonSpeechTokenIsSkippedButNotACue() {
        let s = PromptScript("hello -- world")
        let dash = s.words[1]
        XCTAssertTrue(dash.isNonSpeech)
        XCTAssertFalse(dash.isCue)
        XCTAssertTrue(dash.isSkipped)
        XCTAssertFalse(s.words[0].isSkipped)
    }

    func testBracketsWithoutLettersAreBothCueAndNonSpeech() {
        let s = PromptScript("[]")
        XCTAssertTrue(s.words[0].isCue)
        XCTAssertTrue(s.words[0].isNonSpeech)
    }

    func testPageOfOnlyCuesAndPunctuationHasNothingSpeakable() {
        let s = PromptScript("[pause] ... [applause] --")
        XCTAssertTrue(s.words.allSatisfy(\.isSkipped))
        XCTAssertEqual(s.speakableWordCount, 0)
        XCTAssertEqual(PromptScript("a [b] c").speakableWordCount, 2)
    }

    // MARK: - Direction

    func testDirectionFromFirstStrongLetter() {
        XCTAssertEqual(PromptScript("Hello").direction, .leftToRight)
        XCTAssertEqual(PromptScript("שלום").direction, .rightToLeft)
        XCTAssertEqual(PromptScript("مرحبا").direction, .rightToLeft)
        XCTAssertEqual(PromptScript("abc שלום").direction, .leftToRight)
        XCTAssertEqual(PromptScript("שלום abc").direction, .rightToLeft)
        XCTAssertEqual(PromptScript("123 ... --").direction, .leftToRight)
        XCTAssertEqual(PromptScript("1 שלום").direction, .rightToLeft)
        // CJK is strong LTR.
        XCTAssertEqual(PromptScript("你好").direction, .leftToRight)
    }

    func testLeadingCueIsIgnoredWhenDetectingDirection() {
        XCTAssertEqual(PromptScript("[look at camera] שלום").direction, .rightToLeft)
        XCTAssertEqual(PromptScript("[שלום] Hello").direction, .leftToRight)
        XCTAssertEqual(PromptScript("[only a cue]").direction, .leftToRight)
        // An unclosed bracket is ordinary text, so its letters count.
        XCTAssertEqual(PromptScript("[שלום Hello").direction, .rightToLeft)
    }

    func testEveryRightToLeftRangeIsRecognised() {
        // One letter from each listed block: 0590-08FF, FB1D-FDFF, FE70-FEFF,
        // 10800-10FFF, 1E800-1EEFF.
        for v: UInt32 in [0x05D0, 0x0627, 0xFB1D, 0xFB50, 0xFE70, 0x10800, 0x10900, 0x1E800, 0x1EE00] {
            let letter = String(Unicode.Scalar(v)!)
            XCTAssertEqual(PromptScript("[x] \(letter)").direction, .rightToLeft, String(v, radix: 16))
        }
    }

    // MARK: - Paragraph breaks

    func testOnlyABlankLineIsAParagraphBreak() {
        func breaks(_ t: String) -> [Bool] { PromptScript(t).words.map(\.startsParagraph) }
        XCTAssertEqual(breaks("a\nb"), [false, false])
        XCTAssertEqual(breaks("a\r\nb"), [false, false])
        XCTAssertEqual(breaks("a \n b"), [false, false])
        XCTAssertEqual(breaks("a\n\nb"), [false, true])
        XCTAssertEqual(breaks("a\r\n\r\nb"), [false, true])
        XCTAssertEqual(breaks("a\n  \t\nb"), [false, true])
        XCTAssertEqual(breaks("a b\n\nc d"), [false, false, true, false])
    }

    func testConsecutiveBlankLinesCollapseToOneBreak() {
        let s = PromptScript("a\n\n\n\n\nb\n\nc")
        XCTAssertEqual(s.words.map(\.startsParagraph), [false, true, true])
    }

    func testLeadingAndTrailingBlankLinesAreNotBreaks() {
        XCTAssertEqual(PromptScript("\n\na").words.map(\.startsParagraph), [false])
        XCTAssertEqual(PromptScript("a\n\n").words.map(\.startsParagraph), [false])
    }

    func testParagraphBreakNeverSplitsACJKRun() {
        XCTAssertEqual(PromptScript("你好\n\n世").words.map(\.startsParagraph), [false, false, true])
    }

    // MARK: - Offsets and the NSRange round trip

    private let tricky = "Hi 😀 e\u{301}x  👨‍👩‍👧 🇺🇿 a\r\nb 你\u{20000}好 end"

    func testEveryWordsSourceRangeSlicesTheOriginalText() {
        let s = PromptScript(tricky)
        let ns = tricky as NSString
        XCTAssertFalse(s.words.isEmpty)
        for w in s.words { XCTAssertEqual(ns.substring(with: w.nsRange), w.text) }
    }

    func testSurrogatePairsAndCombiningMarksConvertWithoutDrift() {
        let s = PromptScript("a😀b e\u{301}x")
        // Collapsed "a😀b éx": a=0 😀=1 b=2 ' '=3 é=4 x=5
        XCTAssertEqual(s.utf16Offset(forCollapsedOffset: 1), 1)
        XCTAssertEqual(s.utf16Offset(forCollapsedOffset: 2), 3)
        XCTAssertEqual(s.utf16Offset(forCollapsedOffset: 5), 7)   // x after e + U+0301
        XCTAssertEqual(s.utf16Offset(forCollapsedOffset: 6), 8)   // end
        XCTAssertEqual(s.collapsedOffset(forUTF16: 1), 1)
        XCTAssertEqual(s.collapsedOffset(forUTF16: 2), 1, "mid-surrogate floors to the emoji")
        XCTAssertEqual(s.collapsedOffset(forUTF16: 3), 2)
        XCTAssertEqual(s.collapsedOffset(forUTF16: 6), 4, "mid-combining-mark floors to the base letter")
        XCTAssertEqual(s.collapsedOffset(forUTF16: 7), 5)
    }

    func testRoundTripAtEveryCharacterBoundaryInsideAWord() {
        let s = PromptScript(tricky)
        for w in s.words {
            for k in 0..<w.range.count {
                let o = w.range.lowerBound + k
                let u = s.utf16Offset(forCollapsedOffset: o)
                XCTAssertNotNil(u, "offset \(o)")
                XCTAssertEqual(s.collapsedOffset(forUTF16: u ?? -1), o, "offset \(o) in \(w.text)")
            }
        }
        let end = s.utf16Offset(forCollapsedOffset: s.collapsedCount)
        XCTAssertEqual(end, (tricky as NSString).range(of: "end").upperBound)
        XCTAssertEqual(s.collapsedOffset(forUTF16: end ?? -1), s.collapsedCount)
    }

    func testNSRangeForCollapsedRangeAcrossWhitespaceAndLineEndings() {
        let s = PromptScript("Hello  world\r\nnext")
        XCTAssertEqual(s.nsRange(forCollapsedRange: 6..<11), NSRange(location: 7, length: 5))
        XCTAssertEqual(s.nsRange(forCollapsedRange: 0..<11), NSRange(location: 0, length: 12))
        XCTAssertEqual(s.nsRange(forCollapsedRange: 12..<16), NSRange(location: 14, length: 4))
        // A range ending on the separator stops at the previous word, not at the next.
        XCTAssertEqual(s.nsRange(forCollapsedRange: 0..<5), NSRange(location: 0, length: 5))
        XCTAssertEqual(s.nsRange(forCollapsedRange: 0..<11 + 1), NSRange(location: 0, length: 14))
    }

    func testSeparatorOffsetPointsAtTheNextWordAndOutOfRangeIsNil() {
        let s = PromptScript("ab   cd")
        XCTAssertEqual(s.utf16Offset(forCollapsedOffset: 2), 5)
        XCTAssertNil(s.utf16Offset(forCollapsedOffset: -1))
        XCTAssertNil(s.utf16Offset(forCollapsedOffset: 6))
        XCTAssertNil(s.collapsedOffset(forUTF16: -1))
        XCTAssertEqual(s.collapsedOffset(forUTF16: 3), 3, "whitespace points at the next word")
        XCTAssertEqual(s.collapsedOffset(forUTF16: 99), 5, "past the end clamps")
        XCTAssertEqual(PromptScript("").utf16Offset(forCollapsedOffset: 0), 0)
        XCTAssertEqual(PromptScript("").collapsedOffset(forUTF16: 4), 0)
    }

    func testWordIndexContainingACollapsedOffset() {
        let s = PromptScript("ab cd")
        XCTAssertEqual(s.wordIndex(containingCollapsedOffset: 0), 0)
        XCTAssertEqual(s.wordIndex(containingCollapsedOffset: 1), 0)
        XCTAssertEqual(s.wordIndex(containingCollapsedOffset: 2), 0, "a separator belongs to the word before it")
        XCTAssertEqual(s.wordIndex(containingCollapsedOffset: 3), 1)
        XCTAssertEqual(s.wordIndex(containingCollapsedOffset: 5), 1, "the end clamps to the last word")
        XCTAssertNil(s.wordIndex(containingCollapsedOffset: 6))
        XCTAssertNil(PromptScript("").wordIndex(containingCollapsedOffset: 0))
    }

    // MARK: - Content hash

    func testContentHashIsStableAcrossLaunches() {
        // FNV-1a 64 of the UTF-8 bytes, pinned: Swift's Hasher is seeded per
        // process, so a stored resume point would never match after a relaunch.
        XCTAssertEqual(PromptScript.contentHash(of: ""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(PromptScript.contentHash(of: "a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(PromptScript("Hello").contentHash, PromptScript("Hello").contentHash)
        XCTAssertEqual(PromptScript("Hello").contentHash, PromptScript.contentHash(of: "Hello"))
    }

    func testContentHashChangesWithAnyEditToTheText() {
        // E-27: a middle word changed to another of the same length, same first and last word.
        let base = PromptScript("alpha beta gamma").contentHash
        XCTAssertNotEqual(base, PromptScript("alpha zeta gamma").contentHash)
        XCTAssertNotEqual(base, PromptScript("alpha beta  gamma").contentHash, "whitespace moves editor offsets")
        XCTAssertNotEqual(PromptScript("a\nb").contentHash, PromptScript("a\r\nb").contentHash)
        XCTAssertNotEqual(PromptScript("a b").contentHash, PromptScript("a  b").contentHash)
        XCTAssertNotEqual(PromptScript("e\u{301}").contentHash, PromptScript("\u{E9}").contentHash,
                          "canonically equal strings still have different UTF-16 offsets")
    }

    func testLayoutKeySeparatesTheCallersFontSizeAndWidthFromTheText() {
        let h = PromptScript("same text").contentHash
        let k = PromptLayoutKey(contentHash: h, fontName: "SF", pointSize: 20, columnWidth: 400)
        XCTAssertEqual(k, PromptLayoutKey(contentHash: h, fontName: "SF", pointSize: 20, columnWidth: 400))
        XCTAssertNotEqual(k, PromptLayoutKey(contentHash: h, fontName: "SF", pointSize: 22, columnWidth: 400))
        XCTAssertNotEqual(k, PromptLayoutKey(contentHash: h, fontName: "SF", pointSize: 20, columnWidth: 420))
        XCTAssertNotEqual(k, PromptLayoutKey(contentHash: h, fontName: "OpenDyslexic", pointSize: 20, columnWidth: 400))
        XCTAssertNotEqual(k, PromptLayoutKey(contentHash: PromptScript("other").contentHash,
                                             fontName: "SF", pointSize: 20, columnWidth: 400))
        XCTAssertEqual(PromptScript("same text").contentHash, h, "the text hash itself ignores font inputs")
    }

    // MARK: - Size

    func testHundredThousandWordPageTokenizesInLinearTime() {
        // E-26. Generous bound: this is a debug build, the point is catching O(n^2).
        let page = (0..<100_000).map { $0 % 50 == 0 ? "[beat]" : "word\($0)" }.joined(separator: " ")
        let start = Date()
        let s = PromptScript(page)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(s.words.count, 100_000)
        XCTAssertEqual(s.cues.count, 2_000)
        XCTAssertLessThan(elapsed, 5.0)
    }
}
