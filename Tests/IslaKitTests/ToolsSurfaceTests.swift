import XCTest
@testable import IslaKit

/// Tools (spec §19.8): three cards under the header row, each a button that
/// opens its tool, with a preview line and a hint at its foot. The previews
/// are values (`ToolsCard`), so what each card says is held here without
/// drawing it.
@MainActor
final class ToolsSurfaceTests: XCTestCase {
    /// 142 × 140 at y 46 from x 16 on a 153 pitch, in the content's
    /// coordinates (y less the 38 pt header row).
    func testTheCardsSitWhereTheBoardPutsThem() {
        XCTAssertEqual(ToolsLayout.cardFrame(.shelf), CGRect(x: 16, y: 8, width: 142, height: 140))
        XCTAssertEqual(ToolsLayout.cardFrame(.clipboard), CGRect(x: 169, y: 8, width: 142, height: 140))
        XCTAssertEqual(ToolsLayout.cardFrame(.translate), CGRect(x: 322, y: 8, width: 142, height: 140))
    }

    /// The three fit Tools' 480 × 204 body with 16 to spare on the right, and
    /// none touches another.
    func testTheCardsFitTheBodyAndNeverOverlap() {
        let content = CGRect(
            x: 0, y: 0, width: SurfaceLayout.toolsWidth,
            height: SurfaceLayout.toolsHeight - SurfaceLayout.referenceNotchHeight
        )
        let frames = ToolsCard.Tool.allCases.map(ToolsLayout.cardFrame)
        for frame in frames {
            XCTAssertTrue(content.contains(frame), "\(frame) leaves \(content)")
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)") }
        }
        XCTAssertEqual(content.maxX - frames.last!.maxX, 16)
    }

    /// Each card opens its own surface: the Shelf's is the tray.
    func testEachCardOpensItsTool() {
        XCTAssertEqual(ToolsCard.Tool.shelf.surface, .tray)
        XCTAssertEqual(ToolsCard.Tool.clipboard.surface, .clipboard)
        XCTAssertEqual(ToolsCard.Tool.translate.surface, .translate)
        XCTAssertEqual(ToolsCard.Tool.allCases.map(\.symbol), ["tray.full", "doc.on.clipboard", "translate"])
    }

    /// Shelf: "Empty", or the count; its hint says how files arrive.
    func testTheShelfCardCountsItsFiles() {
        XCTAssertEqual(ToolsCard.shelf(itemCount: 0).preview, .text("Empty"))
        XCTAssertEqual(ToolsCard.shelf(itemCount: 1).preview, .text(ShelfHeader.countText(1)))
        XCTAssertEqual(ToolsCard.shelf(itemCount: 7).preview, .text(ShelfHeader.countText(7)))
        XCTAssertEqual(ToolsCard.shelf(itemCount: 7).hint, "or drag files here")
    }

    /// Clipboard: the newest clip — behind the cover while Privacy covers the
    /// Clipboard, since Tools is one click from anywhere and a password copied
    /// a moment ago would otherwise be on show — and "Empty" with none.
    func testTheClipboardCardKeepsTheNewestClipCovered() {
        let clip = ClipItem(payload: .text("hunter2"), date: Date())
        XCTAssertEqual(ToolsCard.clipboard(newest: clip, covered: true, shortcut: nil).preview, .covered)
        XCTAssertEqual(ToolsCard.clipboard(newest: clip, covered: false, shortcut: nil).preview, .text(clip.preview))
        XCTAssertEqual(ToolsCard.clipboard(newest: nil, covered: true, shortcut: nil).preview, .text("Empty"))
    }

    /// The hints are the shortcuts as bound, and none where one was cleared.
    func testTheHintsAreTheBoundShortcuts() {
        XCTAssertEqual(ToolsCard.clipboard(newest: nil, covered: false, shortcut: "⌃⌥⌘V").hint, "⌃⌥⌘V")
        XCTAssertNil(ToolsCard.clipboard(newest: nil, covered: false, shortcut: nil).hint)
        XCTAssertEqual(ToolsCard.translate(source: nil, target: "English", shortcut: "⌃⌥⌘T").hint, "⌃⌥⌘T")
        XCTAssertNil(ToolsCard.translate(source: nil, target: "English", shortcut: nil).hint)
    }

    /// Translate: the last pair, and "Detect Language" before a source was
    /// chosen.
    func testTheTranslateCardNamesTheLastPair() {
        XCTAssertEqual(ToolsCard.translate(source: nil, target: "English", shortcut: nil).preview, .text("Detect Language → English"))
        XCTAssertEqual(ToolsCard.translate(source: "Russian", target: "English", shortcut: nil).preview, .text("Russian → English"))
    }

    /// The Tools button is on every summoned surface and the stage, and on
    /// none that a click opens or that lies over another.
    func testTheToolsButtonIsOnTheSummonedSurfacesAndTheStage() {
        let with = NotchViewModel.Surface.allCases.filter(\.hasToolsButton)
        XCTAssertEqual(Set(with), [.stage, .clipboard, .translate, .settings])
        for bw: CGFloat in [480, 560, 620] {
            XCTAssertEqual(SurfaceLayout.toolsButtonX(bodyWidth: bw), bw - 46)
        }
    }
}
