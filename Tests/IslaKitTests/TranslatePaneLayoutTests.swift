import AppKit
import XCTest
@testable import IslaKit

/// The Translate pane's frames, as arithmetic (redesign 2026-10-15, spec §11).
/// No view is built: every frame is a pure function of the body, which is what
/// lets it be held at 480, 560 and 620 and with a header of any height.
///
/// This file used to hold the type ladder — four rungs from 27 down to 11 chosen
/// from the length of the text and the widest word in it (H-006). The redesign
/// fixes the cards' type at 15 (13.5 on the tall body) and lets a long text
/// scroll in its card, so there is no longer a rung to choose, and the ladder and
/// its seven tests went with it.
@MainActor
final class TranslatePaneLayoutTests: XCTestCase {
    private let widths: [CGFloat] = [480, 560, 620]

    private func contentArea(_ width: CGFloat) -> (minX: CGFloat, maxX: CGFloat) {
        (PlayerLayout.paneLeading, width - PlayerLayout.paneTrailing)
    }

    // MARK: - The pair bar

    /// The board at its own width: the pop-ups 210 × 22 at x 58 and 336, y 46, and
    /// the swap 24 pt with its left edge at 290 — the board's `btn(290, …)`, which
    /// is centred on the 302 midpoint of the content.
    func testThePairBarIsTheBoardsAtTheDefaultWidth() {
        let bar = TranslateLayout.pairBar(bodyWidth: 560)
        XCTAssertEqual(bar.from, CGRect(x: 58, y: 46, width: 210, height: 22))
        XCTAssertEqual(bar.to, CGRect(x: 336, y: 46, width: 210, height: 22))
        XCTAssertEqual(bar.swap, CGRect(x: 290, y: 45, width: 24, height: 24))
        XCTAssertEqual(bar.swap.midX, 302)
    }

    /// Both pop-ups and the swap stay inside the content area, clear of each
    /// other by at least 8 pt, and the swap is centred, at every width — the
    /// pop-ups give up width below 560 rather than run into it.
    func testThePairBarStaysInsideTheContentAndClearOfItselfAtEveryWidth() {
        for width in widths + [500, 540, 580] {
            let bar = TranslateLayout.pairBar(bodyWidth: width)
            let area = contentArea(width)
            for (name, frame) in [("from", bar.from), ("swap", bar.swap), ("to", bar.to)] {
                XCTAssertGreaterThanOrEqual(frame.minX, area.minX, "\(name) at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, area.maxX, "\(name) at \(width)")
            }
            XCTAssertGreaterThanOrEqual(bar.swap.minX - bar.from.maxX, TranslateLayout.swapGap, "from and swap at \(width)")
            XCTAssertGreaterThanOrEqual(bar.to.minX - bar.swap.maxX, TranslateLayout.swapGap, "swap and to at \(width)")
            XCTAssertFalse(bar.from.intersects(bar.to), "the pop-ups at \(width)")
            XCTAssertEqual(bar.swap.midX, PlayerLayout.paneLeading + PlayerLayout.paneWidth(bodyWidth: width) / 2, accuracy: 0.5)
            XCTAssertEqual(bar.from.width, bar.to.width, "the two pop-ups are the same width at \(width)")
            XCTAssertLessThanOrEqual(bar.from.width, 210)
            XCTAssertEqual(bar.from.minX, area.minX, "the source pop-up rides the leading edge at \(width)")
            XCTAssertEqual(bar.to.maxX, area.maxX, "the target pop-up rides the trailing edge at \(width)")
        }
        XCTAssertEqual(TranslateLayout.popUpWidth(bodyWidth: 480), 184, "narrower below 560")
        XCTAssertEqual(TranslateLayout.popUpWidth(bodyWidth: 620), 210, "never wider than the board's")
    }

    /// The bar hangs 8 under the header, whatever the header's height, so a Mac
    /// whose notch is taller than 38 does not slide it under the notch.
    func testThePairBarFollowsTheHeaderHeight() {
        for header: CGFloat in [32, 38, 50] {
            let bar = TranslateLayout.pairBar(bodyWidth: 560, headerHeight: header)
            XCTAssertEqual(bar.from.minY, header + 8)
            XCTAssertGreaterThanOrEqual(bar.from.minY, header, "below the header")
            XCTAssertEqual(TranslateLayout.cardTop(headerHeight: header), header + 38)
        }
        XCTAssertEqual(TranslateLayout.cardTop(), 76)
    }

    // MARK: - The cards

    func testTheCardsAreTheBoardsAtTheDefaultWidth() {
        let size = CGSize(width: 560, height: 208)
        let source = TranslateLayout.sourceCard(bodySize: size)
        let result = TranslateLayout.resultCard(bodySize: size)
        XCTAssertEqual(source, CGRect(x: 58, y: 76, width: 240, height: 116))
        XCTAssertEqual(result.minX, 318)
        XCTAssertEqual(result.maxX, 546)
        XCTAssertEqual(result.minY, 76)
        XCTAssertEqual(TranslateLayout.cardRadius, 12)
        // The result's text is 212 wide inside its 228, the source's 200 inside 240.
        XCTAssertEqual(TranslateLayout.resultText(card: result).width, 212)
        XCTAssertEqual(TranslateLayout.sourceText(card: source).width, 200)
        XCTAssertEqual(TranslateLayout.resultText(card: result).minX, 318)
        XCTAssertEqual(TranslateLayout.resultText(card: result).minY, 85, "the board's 85")
        XCTAssertEqual(TranslateLayout.sourceText(card: source).minX, 70, "the board's 70")
        XCTAssertEqual(TranslateLayout.sourceText(card: source).minY, 85)
    }

    /// 20 between the cards and the right one on the trailing edge, at every width.
    func testTheCardsShareTheContentAtEveryWidth() {
        for width in widths {
            let size = CGSize(width: width, height: 208)
            let source = TranslateLayout.sourceCard(bodySize: size)
            let result = TranslateLayout.resultCard(bodySize: size)
            let area = contentArea(width)
            XCTAssertEqual(source.minX, area.minX, "at \(width)")
            XCTAssertEqual(source.maxX + TranslateLayout.cardGap, result.minX, "at \(width)")
            XCTAssertEqual(result.maxX, area.maxX, "at \(width)")
            XCTAssertGreaterThan(source.width, result.width, "the board's 240 over 228, at \(width)")
        }
    }

    /// Expanded: both cards 308 tall (spec §11, `Translate-Tall`); standard 116;
    /// and both end 16 above the body's foot on any header.
    func testTheTallBodyGivesBothCards308() {
        let tall = CGSize(width: 560, height: NotchMetrics.tallestBody.height)
        XCTAssertEqual(NotchMetrics.tallestBody.height, 400)
        XCTAssertEqual(TranslateLayout.sourceCard(bodySize: tall).height, 308)
        XCTAssertEqual(TranslateLayout.resultCard(bodySize: tall).height, 308)
        XCTAssertEqual(TranslateLayout.sourceCard(bodySize: CGSize(width: 560, height: 208)).height, 116)
        for header: CGFloat in [32, 38, 50] {
            for height: CGFloat in [208, 400] {
                let card = TranslateLayout.sourceCard(bodySize: CGSize(width: 560, height: height), headerHeight: header)
                XCTAssertEqual(card.maxY, height - 16, "at header \(header), body \(height)")
            }
        }
    }

    func testTheTextIs15AndThirteenPointFiveOnTheTallBody() {
        XCTAssertEqual(TranslatePane.textSize(expanded: false), 15)
        XCTAssertEqual(TranslatePane.textSize(expanded: true), 13.5)
    }

    // MARK: - Controls

    /// Every control the pane draws in its bar and its cards is inside the
    /// content area and clear of every other, at three widths, standard and tall,
    /// with Speak and without.
    func testNoControlLeavesTheContentOrCoversAnother() {
        for width in widths {
            for height: CGFloat in [208, 400] {
                for speak in [true, false] {
                    let size = CGSize(width: width, height: height)
                    let frames = TranslateLayout.controlFrames(bodySize: size, showsSpeak: speak)
                    let area = contentArea(width)
                    for (name, frame) in frames {
                        XCTAssertGreaterThanOrEqual(frame.minX, area.minX - TranslateLayout.footerLead, "\(name) at \(width)")
                        XCTAssertLessThanOrEqual(frame.maxX, area.maxX, "\(name) at \(width)")
                        XCTAssertLessThanOrEqual(frame.maxY, height - 14, "\(name) inside the body at \(width) × \(height)")
                    }
                    for (index, a) in frames.enumerated() {
                        for b in frames[(index + 1)...] {
                            XCTAssertFalse(a.frame.intersects(b.frame), "\(a.name) \(a.frame) meets \(b.name) \(b.frame) at \(width) × \(height)")
                        }
                    }
                }
            }
        }
    }

    /// The footer: Speak at the text's own edge less 4, Copy after it, and Copy
    /// takes Speak's place when Speak is off.
    func testTheFooterLeadsWithSpeakAndCopy() {
        let card = TranslateLayout.resultCard(bodySize: CGSize(width: 560, height: 208))
        XCTAssertEqual(TranslateLayout.speakButton(card: card), CGRect(x: 314, y: 163, width: 24, height: 24), "the board's btn(314, 163)")
        XCTAssertEqual(TranslateLayout.copyButton(card: card, showsSpeak: true), CGRect(x: 342, y: 163, width: 24, height: 24))
        XCTAssertEqual(TranslateLayout.copyButton(card: card, showsSpeak: false).minX, 314)
    }

    func testPasteAndTheCounterSitAtTheSourceFoot() {
        let card = TranslateLayout.sourceCard(bodySize: CGSize(width: 560, height: 208))
        XCTAssertEqual(TranslateLayout.paste(card: card), CGRect(x: 70, y: 160, width: 66, height: 22), "the board's push(70, 76 + 116 − 32)")
        XCTAssertEqual(TranslateLayout.counter(card: card).minY, 170)
        XCTAssertEqual(TranslateLayout.counter(card: card).minX, 70)
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
