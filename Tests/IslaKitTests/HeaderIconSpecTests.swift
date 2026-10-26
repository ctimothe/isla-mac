import AppKit
import XCTest
@testable import IslaKit

/// One icon spec for every page (owner, 2026-10-26: "the exact icon size
/// consistently across the pages ... literally every icon"; spec §19.8,
/// amended 2026-10-26). Before it there were six glyph sizes (11, 12, 12
/// semibold, 13, 14 and a 16 pt app squircle) for one kind of thing.
final class HeaderIconSpecTests: XCTestCase {
    func testEveryHeaderGlyphIsTheOneSize() {
        XCTAssertEqual(HeaderIcon.size, 14)
        XCTAssertEqual(HeaderIcon.weight, .medium)
        XCTAssertEqual(SurfaceHeaderLayout.titleGlyphSize, HeaderIcon.size, "the identity glyph")
        XCTAssertEqual(SurfaceHeaderLayout.toolGlyphSize, HeaderIcon.size, "the gear, History, Remove All")
        XCTAssertEqual(SurfaceHeaderLayout.appIconSquircleSide, HeaderIcon.size, "the playing app's squircle")
        XCTAssertEqual(ShelfLayout.removeAllTextSize, HeaderIcon.wordSize)
    }

    /// A tool's well is the one size, and nothing a pointer aims at on a
    /// page's header or toolbar is under 24 pt on either side.
    func testEveryToolMeetsTheHitTarget() {
        let minimum = HeaderIcon.minimumHitTarget
        XCTAssertGreaterThanOrEqual(minimum, 24)
        let gear = SurfaceHeaderLayout.gear(bodyWidth: 560, notchHeight: 38)
        let history = SurfaceHeaderLayout.history(bodyWidth: 560, notchHeight: 38)
        let removeAll = SurfaceHeaderLayout.removeAll(bodyWidth: 560, width: ShelfLayout.removeAllWidth(), notchHeight: 38)
        for (name, size) in [
            ("gear", gear.size), ("History", history.size), ("Remove All", removeAll.size),
            ("a stage tool", CGSize(width: StageToolFrames.side, height: StageToolFrames.side)),
            ("Swap", CGSize(width: TranslateLayout.swapWidth, height: TranslateLayout.pairHeight)),
            ("Speak and Copy", TranslateLayout.footerButton),
            ("Paste", CGSize(width: ShelfLayout.removeAllWidth(), height: TranslateLayout.pasteHeight)),
        ] {
            XCTAssertGreaterThanOrEqual(size.width, minimum, name)
            XCTAssertGreaterThanOrEqual(size.height, minimum, name)
        }
        XCTAssertEqual(gear.size, CGSize(width: HeaderIcon.well, height: HeaderIcon.well))
        XCTAssertEqual(removeAll.height, HeaderIcon.well, "a glyph with a word is the same well's height")
        XCTAssertEqual(TranslateLayout.pasteHeight, HeaderIcon.well, "Paste is Remove All's kind of button")
    }

    /// No header grows for the spec: every item still fits the notch's strip
    /// on the shortest notch the app supports.
    func testNoHeaderIsTallerThanTheStrip() {
        for notchHeight: CGFloat in [32, 38] {
            let strip = CGRect(x: 0, y: 0, width: 560, height: notchHeight)
            let title = SurfaceHeaderLayout.title(bodyWidth: 560, notchWidth: 200, notchHeight: notchHeight)
            let gear = SurfaceHeaderLayout.gear(bodyWidth: 560, notchHeight: notchHeight)
            XCTAssertTrue(strip.contains(gear), "gear at \(notchHeight)")
            XCTAssertTrue(strip.contains(title), "title at \(notchHeight)")
            XCTAssertLessThanOrEqual(SurfaceHeaderLayout.appIconSide, notchHeight)
        }
    }
}
