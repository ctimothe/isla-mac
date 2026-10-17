import AppKit
import XCTest
@testable import IslaKit

/// The Translate surface's frames, as arithmetic (spec §19.8, board
/// `R2-Translate`). No view is built: every frame is a pure function of the
/// body's width, in the content's coordinates under the header row (the board's
/// y less 38), which is what lets it be held at 480, 560 and 620.
///
/// This file used to hold the type ladder — four rungs from 27 down to 11 chosen
/// from the length of the text and the widest word in it (H-006), and then two
/// sizes, 15 and 13.5 on the tall body. The tall body went with Expand / Collapse
/// (§19.11), so there is one text size and one height.
@MainActor
final class TranslatePaneLayoutTests: XCTestCase {
    private let widths: [CGFloat] = [480, 560, 620]

    // MARK: - The pair row

    /// The board at its own width (§19.8): the From pop-up from x 16 to
    /// `bw / 2 − 24`, Swap 28 wide at `bw / 2 − 14`, the To pop-up from
    /// `bw / 2 + 30` to `bw − 16`, all 26 tall at y 46 (8 in the content).
    func testThePairRowIsTheSpecsAtTheDefaultWidth() {
        let bar = TranslateLayout.pairBar(bodyWidth: 560)
        XCTAssertEqual(bar.from, CGRect(x: 16, y: 8, width: 240, height: 26))
        XCTAssertEqual(bar.swap, CGRect(x: 266, y: 8, width: 28, height: 26))
        XCTAssertEqual(bar.to, CGRect(x: 310, y: 8, width: 234, height: 26))
        XCTAssertEqual(bar.swap.midX, 280, "centred on the body")
    }

    /// The pop-ups and the swap stay inside the margins, clear of each other by
    /// at least 8 pt, and the swap is centred, at every width.
    func testThePairRowStaysInsideTheMarginsAndClearOfItselfAtEveryWidth() {
        for width in widths + [500, 540, 580] {
            let bar = TranslateLayout.pairBar(bodyWidth: width)
            for (name, frame) in [("from", bar.from), ("swap", bar.swap), ("to", bar.to)] {
                XCTAssertGreaterThanOrEqual(frame.minX, 16, "\(name) at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, width - 16, "\(name) at \(width)")
                XCTAssertEqual(frame.height, 26, "\(name) at \(width)")
            }
            XCTAssertGreaterThanOrEqual(bar.swap.minX - bar.from.maxX, 8, "from and swap at \(width)")
            XCTAssertGreaterThanOrEqual(bar.to.minX - bar.swap.maxX, 8, "swap and to at \(width)")
            XCTAssertFalse(bar.from.intersects(bar.to), "the pop-ups at \(width)")
            XCTAssertEqual(bar.swap.midX, width / 2, accuracy: 0.5)
            XCTAssertEqual(bar.from.minX, 16, "the source pop-up rides the leading margin at \(width)")
            XCTAssertEqual(bar.to.maxX, width - 16, "the target pop-up rides the trailing margin at \(width)")
            XCTAssertEqual(bar.from.maxX, width / 2 - 24, accuracy: 0.001)
            XCTAssertEqual(bar.to.minX, width / 2 + 30, accuracy: 0.001)
        }
    }

    // MARK: - The cards

    func testTheCardsAreTheSpecsAtTheDefaultWidth() {
        let source = TranslateLayout.sourceCard(bodyWidth: 560)
        let result = TranslateLayout.resultCard(bodyWidth: 560)
        XCTAssertEqual(source, CGRect(x: 16, y: 46, width: 256, height: 160), "(16, 84) less the header row, bw / 2 − 24 wide")
        XCTAssertEqual(result.minX, 290, "bw / 2 + 10")
        XCTAssertEqual(result.maxX, 544, "bw − 16")
        XCTAssertEqual(result.minY, 46)
        XCTAssertEqual(result.height, 160)
        XCTAssertEqual(TranslateLayout.cardRadius, 14)
        // The source's text is inset 12 / 14 and leaves room for the Clear ⓧ;
        // the result, which has no plate, insets its text 12 and 4.
        XCTAssertEqual(TranslateLayout.sourceText(card: source).minX, 30)
        XCTAssertEqual(TranslateLayout.sourceText(card: source).minY, 58)
        XCTAssertEqual(TranslateLayout.sourceText(card: source).width, 256 - 14 - 28)
        XCTAssertEqual(TranslateLayout.resultText(card: result).minX, 294)
        XCTAssertEqual(TranslateLayout.resultText(card: result).minY, 58)
        XCTAssertEqual(TranslateLayout.resultText(card: result).width, 254 - 8)
    }

    /// The source on the leading margin, the result on the trailing one, the
    /// gap between them 18 and the source a little the wider, at every width.
    func testTheCardsShareTheBodyAtEveryWidth() {
        for width in widths {
            let source = TranslateLayout.sourceCard(bodyWidth: width)
            let result = TranslateLayout.resultCard(bodyWidth: width)
            XCTAssertEqual(source.minX, 16, "at \(width)")
            XCTAssertEqual(source.width, width / 2 - 24, accuracy: 0.001, "at \(width)")
            XCTAssertEqual(result.minX - source.maxX, 18, accuracy: 0.001, "at \(width)")
            XCTAssertEqual(result.maxX, width - 16, "at \(width)")
            XCTAssertGreaterThan(source.width, result.width, "the source plate is the wider, at \(width)")
            XCTAssertEqual(source.height, 160)
            XCTAssertEqual(result.height, 160)
        }
    }

    /// One size (§19.11 withdrew Expand): the cards end 24 above the foot of
    /// the 268 pt body, and the text is 15.
    func testTheCardsEndAboveTheFootAndTheTextIs15() {
        XCTAssertEqual(TranslateLayout.contentHeight, 268 - 38)
        for width in widths {
            XCTAssertEqual(TranslateLayout.resultCard(bodyWidth: width).maxY, 206)
            XCTAssertLessThanOrEqual(TranslateLayout.resultCard(bodyWidth: width).maxY, TranslateLayout.contentHeight - 24)
        }
        XCTAssertEqual(TranslateLayout.textSize, 15)
    }

    // MARK: - Controls

    /// Every control the surface draws in its pair row and its cards is inside
    /// the margins and the body, and clear of every other, at three widths, with
    /// Speak and without.
    func testNoControlLeavesTheBodyOrCoversAnother() {
        for width in widths {
            for speak in [true, false] {
                let frames = TranslateLayout.controlFrames(bodyWidth: width, showsSpeak: speak)
                XCTAssertEqual(frames.count, speak ? 6 : 5)
                for (name, frame) in frames {
                    XCTAssertGreaterThanOrEqual(frame.minX, 16, "\(name) at \(width)")
                    XCTAssertLessThanOrEqual(frame.maxX, width - 16, "\(name) at \(width)")
                    XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(name) is below the header at \(width)")
                    XCTAssertLessThanOrEqual(frame.maxY, TranslateLayout.contentHeight - 14, "\(name) inside the body at \(width)")
                }
                for (index, a) in frames.enumerated() {
                    for b in frames[(index + 1)...] {
                        XCTAssertFalse(a.frame.intersects(b.frame), "\(a.name) \(a.frame) meets \(b.name) \(b.frame) at \(width)")
                    }
                }
            }
        }
    }

    /// The footer: Speak at the result's leading edge, Copy after it, 26 × 24
    /// each (§19.8), on the row of the source's count; Copy takes Speak's
    /// place when Speak is off.
    func testTheFooterLeadsWithSpeakAndCopy() {
        let card = TranslateLayout.resultCard(bodyWidth: 560)
        XCTAssertEqual(TranslateLayout.speakButton(card: card), CGRect(x: 290, y: 178, width: 26, height: 24))
        XCTAssertEqual(TranslateLayout.copyButton(card: card, showsSpeak: true), CGRect(x: 320, y: 178, width: 26, height: 24))
        XCTAssertEqual(TranslateLayout.copyButton(card: card, showsSpeak: false).minX, 290)
        let source = TranslateLayout.sourceCard(bodyWidth: 560)
        XCTAssertEqual(
            TranslateLayout.speakButton(card: card).midY, TranslateLayout.counter(card: source).midY,
            "the two feet line up across the gap"
        )
    }

    func testPasteAndTheCounterSitAtTheSourceFoot() {
        let card = TranslateLayout.sourceCard(bodyWidth: 560)
        XCTAssertEqual(TranslateLayout.counter(card: card), CGRect(x: 30, y: 184, width: 228, height: 12), "10 from the card's bottom")
        XCTAssertEqual(TranslateLayout.paste(card: card), CGRect(x: 30, y: 179, width: 66, height: 22))
    }

    // MARK: - The counter and the limit

    func testTheCounterCountsAgainstTheLimitTheHotKeyAlreadyHas() {
        let en = Locale(identifier: "en")
        XCTAssertEqual(Translator.commandInputLimit, 20_000, "the existing limit is 20,000, not the board's 5,000, and is the one shown")
        XCTAssertEqual(TranslatePane.counterText(count: 35, locale: en), "35 / 20,000")
        XCTAssertEqual(TranslatePane.counterText(count: 0, locale: en), "0 / 20,000")
        XCTAssertEqual(TranslatePane.counterText(count: 261, locale: Locale(identifier: "ru")).hasPrefix("261 / "), true)
    }

    func testTypingPastTheLimitIsCutAndSaysSo() {
        let rig = TranslateRig()
        defer { rig.release() }
        let limit = Translator.commandInputLimit
        TranslatePane.typed(String(repeating: "a", count: limit + 50), privacy: rig.privacy, translator: rig.translator)
        XCTAssertEqual(rig.translator.input.count, limit)
        XCTAssertNotNil(rig.translator.notice, "the cut is said, as the hot key says its own")
        XCTAssertEqual(TranslatePane.limited("short").text, "short")
        XCTAssertNil(TranslatePane.limited("short").notice)
        XCTAssertNil(TranslatePane.limited(String(repeating: "b", count: limit)).notice, "exactly the limit is not a cut")
    }
}
