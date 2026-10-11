import AppKit
import XCTest
@testable import IslaKit

/// The Translate pane's type ladder, as arithmetic: which rung a pair of texts
/// gets in a measured column. No view is built; the rung is a pure function of
/// the two texts and the column, which is what lets it be checked here.
@MainActor
final class TranslatePaneLayoutTests: XCTestCase {
    /// The text column at the default 560-point panel: the pane is 488 wide,
    /// so (488 − 10) / 2 − 20. And at the narrowest panel, 480 points.
    private let column560 = CGSize(width: 219, height: 110)
    private let column480 = CGSize(width: 179, height: 110)

    private func width(_ word: String, at size: CGFloat) -> CGFloat {
        (word as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    /// H-006: "железнодорожная" was set at 27 points, the top rung, because
    /// the sentence is short; at 27 the word alone is wider than the column,
    /// so it arrived as "железнодорожна / я станция?". The rung is now chosen
    /// by the widest word as well as by the length.
    func testNoRungBreaksAWord() {
        for column in [column560, column480] {
            let size = TranslatePane.fontSize(
                source: "Где находится железнодорожная станция?",
                output: "Where is the railway station?",
                column: column
            )
            XCTAssertLessThanOrEqual(width("железнодорожная", at: size), column.width,
                                     "at a \(column.width)-point column the word breaks at \(size) points")
        }
    }

    /// The acceptance in numbers: at the default width this sentence drops one
    /// rung, from 27 to 20, and no further.
    func testTheLongWordDropsOneRungAtTheDefaultWidth() {
        let size = TranslatePane.fontSize(
            source: "Где находится железнодорожная станция?",
            output: "Where is the railway station?",
            column: column560
        )
        XCTAssertEqual(size, 20)
    }

    /// Both columns share the rung, so a long word on either side decides it.
    func testTheWordCanBeOnEitherSide() {
        let fromRussian = TranslatePane.fontSize(source: "Где железнодорожная станция?", output: "Station?", column: column560)
        let intoRussian = TranslatePane.fontSize(source: "Station?", output: "Где железнодорожная станция?", column: column560)
        XCTAssertEqual(fromRussian, intoRussian)
        XCTAssertLessThan(fromRussian, 27)
    }

    /// A word is the headline it always was.
    func testAShortTextKeepsTheTopRung() {
        XCTAssertEqual(TranslatePane.fontSize(source: "Hello", output: "Привет", column: column560), 27)
        XCTAssertEqual(TranslatePane.fontSize(source: "", output: "", column: column560), 27)
    }

    /// Japanese has no spaces, and a line may break between any two of its
    /// characters. Splitting on whitespace would have measured the whole
    /// sentence as one word and dropped it a rung for nothing.
    func testTextWithoutSpacesIsNotOneWord() {
        XCTAssertEqual(TranslatePane.fontSize(source: "東京駅はどこですか。", output: "Where is Tokyo Station?", column: column560), 27)
    }

    /// A token too wide even for the bottom rung, a name with no break in it,
    /// still gets the bottom rung and wraps by character, as text must.
    func testAWordTooWideForEveryRungFallsToTheBottom() {
        let word = "Pneumonoultramicroscopicsilicovolcanoconiosis"
        XCTAssertEqual(TranslatePane.fontSize(source: word, output: word, column: column560), 11)
    }

    /// The length rule still holds on its own: short words, but too many of
    /// them for any rung above the last.
    func testALongTextOfShortWordsStillSteps() {
        let text = String(repeating: "word ", count: 30)
        XCTAssertEqual(TranslatePane.fontSize(source: text, output: text, column: column560), 11)
    }
}
