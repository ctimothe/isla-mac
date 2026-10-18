import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The tray (spec §19.7, board `R2-Shelf-Open`): every value, frame and decision
/// `ShelfLayout` makes, held at 480, 560 and 620 without drawing anything — the
/// way `PlayerLayoutTests` holds the player. It replaced §8.1's grid of 78 × 100
/// cards and §8.2's selection bar (§19.11) with the board's 80 × 94 tiles, which
/// since 2026-10-18 fill the shared page in rows and scroll down; positions are
/// in the content's coordinates, under the header strip.
@MainActor
final class ShelfLayoutTests: XCTestCase {

    // MARK: - The grid (§19.7, amended 2026-10-18)

    /// A tile is 80 × 94, radius 16, on the board's 90 pt pitch across and 104
    /// down — 10 apart either way. The first row's top is the board's 47.5 less
    /// the 38 pt header strip.
    func testTileMetricsFollowTheBoard() {
        XCTAssertEqual(ShelfLayout.tile, CGSize(width: 80, height: 94))
        XCTAssertEqual(ShelfLayout.tileRadius, 16)
        XCTAssertEqual(ShelfLayout.pitch, 90)
        XCTAssertEqual(ShelfLayout.rowPitch, 104)
        XCTAssertEqual(ShelfLayout.firstRowTop, 9.5, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.minimumSideMargin, 14)
        XCTAssertEqual(ShelfLayout.edgeFade, 16)
    }

    /// As many tiles to a row as fit with 14 pt either side — five at 480, six
    /// at 560 and 620 — the grid centred on a whole point, each row starting
    /// under the first.
    func testTheGridFillsTheWidthCentred() {
        XCTAssertEqual(ShelfLayout.columns(bodyWidth: 480), 5)
        XCTAssertEqual(ShelfLayout.columns(bodyWidth: 560), 6)
        XCTAssertEqual(ShelfLayout.columns(bodyWidth: 620), 6)
        for width in [CGFloat(480), 560, 620] {
            let columns = ShelfLayout.columns(bodyWidth: width)
            let first = ShelfLayout.tileFrame(index: 0, bodyWidth: width)
            let last = ShelfLayout.tileFrame(index: columns - 1, bodyWidth: width)
            XCTAssertEqual(first.size, ShelfLayout.tile, "\(width)")
            XCTAssertEqual(first.minY, 9.5, accuracy: 0.0001, "\(width)")
            XCTAssertGreaterThanOrEqual(first.minX, 14, "\(width)")
            XCTAssertLessThanOrEqual(last.maxX, width - 14, "\(width)")
            XCTAssertEqual(first.minX, width - last.maxX, accuracy: 1, "centred at \(width)")
            XCTAssertEqual(first.minX, first.minX.rounded(), "on a whole point at \(width)")
            XCTAssertEqual(last.minY, first.minY, "one row at \(width)")
            let next = ShelfLayout.tileFrame(index: columns, bodyWidth: width)
            XCTAssertEqual(next.minX, first.minX, "the next row starts under the first at \(width)")
            XCTAssertEqual(next.minY, first.minY + 104, accuracy: 0.0001, "\(width)")
        }
    }

    /// The viewport is the body's width and the content between the header
    /// strip and the dots: 262 on any notch. Two rows and part of a third show,
    /// so a cut row says there is more; past what fits the grid scrolls down.
    func testTwoRowsAndPartOfAThirdShow() {
        let body = SurfaceLayout.bodySize(for: .tray, bodyWidth: 560, notch: CGSize(width: 185, height: 38))
        XCTAssertEqual(body, CGSize(width: 560, height: 316), "the three tools' shared size (§19.16)")
        let viewport = ShelfLayout.viewport(bodyWidth: 560)
        XCTAssertEqual(viewport, CGRect(x: 0, y: 0, width: 560, height: 262))
        XCTAssertLessThanOrEqual(ShelfLayout.tileFrame(index: 6, bodyWidth: 560).maxY, viewport.height, "two rows whole")
        let third = ShelfLayout.tileFrame(index: 12, bodyWidth: 560)
        XCTAssertLessThan(third.minY, viewport.height, "part of a third")
        XCTAssertGreaterThan(third.maxY, viewport.height)
        XCTAssertFalse(ShelfLayout.scrolls(count: 0, bodyWidth: 560))
        XCTAssertFalse(ShelfLayout.scrolls(count: 12, bodyWidth: 560))
        XCTAssertTrue(ShelfLayout.scrolls(count: 13, bodyWidth: 560))
        XCTAssertTrue(ShelfLayout.scrolls(count: 11, bodyWidth: 480), "five to a row: three rows")
        // The content: the same margin under the last row as over the first,
        // and on a grid that scrolls the notice's 14 more.
        XCTAssertEqual(ShelfLayout.contentHeight(count: 0, bodyWidth: 560), 0)
        XCTAssertEqual(ShelfLayout.contentHeight(count: 1, bodyWidth: 560), 2 * 9.5 + 94, accuracy: 0.0001)
        XCTAssertEqual(
            ShelfLayout.contentHeight(count: 60, bodyWidth: 560), CGFloat(2 * 9.5 + 9 * 104 + 94 + 14), accuracy: 0.0001,
            "the Shelf's limit, ten rows"
        )
        // One shape with Clipboard and Translate (§19.16).
        XCTAssertEqual(NotchViewModel.Surface.tray.topRadius, NotchViewModel.Surface.clipboard.topRadius)
        XCTAssertEqual(NotchViewModel.Surface.tray.bottomRadius, NotchViewModel.Surface.clipboard.bottomRadius)
        XCTAssertEqual(NotchViewModel.Surface.drop.topRadius, 24, "the drop surface keeps its own")
    }

    /// A notice sits under the last row while the grid fits, and at the foot
    /// of the viewport, over the fade, once it scrolls: it never covers a tile
    /// in full view.
    /// Scrolled to the end, a grid that scrolls lifts its last row clear of
    /// the notice at the viewport's foot: the notice covered 5.5 pt of tiles
    /// in full view, exactly when the Shelf was full and a notice said so
    /// (review 5, S6). The room is there whether a notice shows or not, so a
    /// notice coming or going moves no tile (re-review 6, F3). A grid that
    /// fits keeps its even margins.
    func testANoticeNeverCoversTheLastRowScrolledToTheEnd() {
        let viewport = ShelfLayout.viewport(bodyWidth: 560).height
        for count in [13, 18, 30, 60] {
            let content = ShelfLayout.contentHeight(count: count, bodyWidth: 560)
            let lastRow = ShelfLayout.tileFrame(index: count - 1, bodyWidth: 560)
            let bottomScrolledToEnd = lastRow.maxY - (content - viewport)
            XCTAssertLessThanOrEqual(
                bottomScrolledToEnd, ShelfLayout.noticeTop(count: count, bodyWidth: 560), "\(count) files"
            )
        }
        for count in [1, 6, 12] {
            let rows = CGFloat(ShelfLayout.rows(count: count, bodyWidth: 560))
            XCTAssertEqual(
                ShelfLayout.contentHeight(count: count, bodyWidth: 560),
                2 * 9.5 + (rows - 1) * 104 + 94, accuracy: 0.0001, "\(count) files fit"
            )
        }
    }

    func testTheNoticeSitsUnderTheGrid() {
        XCTAssertEqual(ShelfLayout.noticeTop(count: 3, bodyWidth: 560), 9.5 + 94 + 1, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.noticeTop(count: 12, bodyWidth: 560), 9.5 + 104 + 94 + 1, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.noticeTop(count: 30, bodyWidth: 560), 262 - 14 - 1, accuracy: 0.0001)
    }

    func testTheIconNameAndBadgeSitWhereTheBoardPutsThem() {
        XCTAssertEqual(ShelfLayout.icon, CGRect(x: 19, y: 9, width: 42, height: 42))
        XCTAssertEqual(ShelfLayout.nameOrigin.x, 4)
        XCTAssertEqual(ShelfLayout.nameOrigin.y, 60.4, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.nameWidth, 72)
        XCTAssertEqual(ShelfLayout.nameSize, 11.5)
        XCTAssertEqual(ShelfLayout.maximumNameLines, 2)
        XCTAssertEqual(ShelfLayout.badge, CGRect(x: 57.75, y: 5.5, width: 17, height: 17))
        XCTAssertEqual(ShelfLayout.badgeDisc, 14)
        // The icon is centred in the tile; the name sits under it, inside it.
        XCTAssertEqual(ShelfLayout.icon.midX, ShelfLayout.tile.width / 2)
        XCTAssertLessThan(ShelfLayout.icon.maxY, ShelfLayout.nameOrigin.y)
        XCTAssertLessThanOrEqual(
            ShelfLayout.nameOrigin.y + CGFloat(ShelfLayout.maximumNameLines) * ShelfLayout.nameLineHeight, ShelfLayout.tile.height
        )
        XCTAssertLessThanOrEqual(ShelfLayout.badge.maxX, ShelfLayout.tile.width)
    }

    /// Hover is a decision made from the pointer and the layout, so a tile that
    /// slides under a pointer that has not moved is hovered (the bug the pane's
    /// comment describes). Between tiles, between rows and past the last
    /// there is none.
    func testTileIndexAtAPoint() {
        let width: CGFloat = 560
        let first = ShelfLayout.tileFrame(index: 0, bodyWidth: width)
        func index(_ x: CGFloat, _ y: CGFloat, count: Int = 20) -> Int? {
            ShelfLayout.tileIndex(at: CGPoint(x: x, y: y), count: count, bodyWidth: width)
        }
        XCTAssertEqual(index(first.midX, first.midY), 0)
        XCTAssertEqual(index(first.midX + 90, first.midY), 1)
        XCTAssertEqual(index(first.midX, first.midY + 104), 6, "the second row")
        XCTAssertEqual(index(first.midX + 90 * 5, first.midY + 104 * 2), 17)
        XCTAssertNil(index(first.maxX + 5, first.midY), "the 10 pt gap across is no tile")
        XCTAssertNil(index(first.midX, first.maxY + 5), "nor the 10 pt between rows")
        XCTAssertNil(index(first.midX, first.minY - 3), "above the first row")
        XCTAssertNil(index(5, first.midY), "left of the grid")
        XCTAssertNil(index(first.midX + 90 * 6, first.midY), "right of the last column")
        XCTAssertNil(index(first.midX + 90 * 2, first.midY + 104 * 3), "past the last tile")
        XCTAssertNil(index(first.midX + 90, first.midY, count: 1), "the second tile is not there")
    }

    /// A thumbnail keeps its own shape, long side 42, and never fills the
    /// square: the white border hugs the picture, not the box.
    func testAThumbnailKeepsItsShape() {
        XCTAssertEqual(ShelfLayout.fittedSize(of: CGSize(width: 192, height: 120)), CGSize(width: 42, height: 26))
        XCTAssertEqual(ShelfLayout.fittedSize(of: CGSize(width: 96, height: 96)), CGSize(width: 42, height: 42))
        XCTAssertEqual(ShelfLayout.fittedSize(of: CGSize(width: 50, height: 100)), CGSize(width: 21, height: 42))
        XCTAssertEqual(ShelfLayout.fittedSize(of: .zero), CGSize(width: 42, height: 42), "an image of no size is the square")
    }

    // MARK: - The name under a tile (§8.1)

    /// One point per character, so a width is a character budget and the test
    /// reads the same on every machine; the real measure is checked below.
    private let measure: (String) -> CGFloat = { CGFloat($0.count) }

    func testAShortNameIsOneLine() {
        XCTAssertEqual(ShelfTileName.lines("todo.md", width: 12, measure: measure), ["todo.md"])
        XCTAssertEqual(ShelfTileName.lines("exactly12.txt", width: 13, measure: measure), ["exactly12.txt"])
    }

    /// Finder breaks between words first: the name wraps to a second line before
    /// anything is cut.
    func testALongNameWrapsAtASpaceBeforeItIsCut() {
        XCTAssertEqual(ShelfTileName.lines("Meeting notes.txt", width: 12, measure: measure), ["Meeting", "notes.txt"])
        XCTAssertEqual(ShelfTileName.lines("Launch deck.key", width: 12, measure: measure), ["Launch", "deck.key"],
                       "the break is at the last space within reach, and the rest is the second line")
    }

    /// The second line is cut in the *middle* and the extension survives: the
    /// start says what family, the end says which and what kind. The old card
    /// dropped the start (H-025); this keeps both ends.
    func testTheSecondLineIsCutInTheMiddleAndKeepsTheExtension() {
        let capture = "Screenshot 2026-10-14 at 09.12.44.png"
        let lines = ShelfTileName.lines(capture, width: 14, measure: measure)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertEqual(lines[0], "Screenshot")
        XCTAssertTrue(lines[1].hasSuffix(".png"), "the extension survives: \(lines[1])")
        XCTAssertTrue(lines[1].contains("…"), "and the middle is what went: \(lines[1])")
        XCTAssertTrue(lines[1].hasPrefix("2026"), "the start of the line is kept as well: \(lines[1])")
        XCTAssertTrue(lines[1].contains("44.png"), "and so is the end of the stem: \(lines[1])")
        XCTAssertLessThanOrEqual(measure(lines[1]), 14)
    }

    func testEveryCutNameFitsAndKeepsItsExtension() {
        let names = [
            "Screenshot 2026-10-14 at 09.12.44.png",
            "Isla 0.3.0.zip",
            "IMG_20261011_150444.jpg",
            "a verylongnamewithoutanybreaks-at-all-really.txt",
            "Отчёт за III квартал (окончательный вариант).pdf",
            "README-final-version-22",
        ]
        for width in stride(from: CGFloat(8), through: 30, by: 2) {
            for name in names {
                let lines = ShelfTileName.lines(name, width: width, measure: measure)
                XCTAssertLessThanOrEqual(lines.count, 2, "\(name) at \(width): \(lines)")
                for line in lines {
                    XCTAssertLessThanOrEqual(measure(line), width, "\"\(line)\" of \(name) at \(width)")
                }
                let ext = (name as NSString).pathExtension
                if !ext.isEmpty, width >= 8 {
                    XCTAssertTrue(
                        lines.last?.hasSuffix(ext) ?? false,
                        "the extension of \(name) at \(width) survives: \(lines)"
                    )
                }
            }
        }
    }

    /// A name with no spaces — a camera's, a hash — wraps mid-word and is still
    /// cut in the middle of what is left.
    func testANameWithNoSpacesBreaksMidWord() {
        let lines = ShelfTileName.lines("IMG_20261011_150444.jpg", width: 12, measure: measure)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].count, 12)
        XCTAssertTrue(lines[1].hasSuffix(".jpg"), "\(lines)")
    }

    /// With the real font and the real column, a capture's name takes two lines
    /// that fit and keep ".png" — the measure and the drawing are one function.
    func testARealCaptureNameFitsItsColumn() {
        let capture = "Screenshot 2026-10-14 at 09.12.44.png"
        let lines = ShelfTileName.lines(capture) { ShelfTileName.measure($0) }
        XCTAssertEqual(lines.count, 2, "\(lines)")
        for line in lines {
            XCTAssertLessThanOrEqual(ShelfTileName.measure(line), ShelfLayout.nameWidth, line)
        }
        XCTAssertTrue(lines.last?.hasSuffix(".png") ?? false)
        // Picked, the name is medium and measures a hair wider; the lines are computed for it.
        let picked = ShelfTileName.lines(capture) { ShelfTileName.measure($0, selected: true) }
        for line in picked {
            XCTAssertLessThanOrEqual(ShelfTileName.measure(line, selected: true), ShelfLayout.nameWidth, line)
        }
    }

    /// Not even an ellipsis and an extension fit: the end is cut and the result
    /// still fits, rather than looping or overflowing.
    func testAnExtensionTooLongForTheLineStillFits() {
        let lines = ShelfTileName.lines("abc.verylongextension", width: 6, measure: measure)
        for line in lines { XCTAssertLessThanOrEqual(measure(line), 6, line) }
    }

    // MARK: - Tile wells (§19.7)

    func testTheWellsPriority() {
        XCTAssertNil(ShelfWell.state(isSelected: false, isHovered: false, isAlreadyKept: false))
        XCTAssertEqual(ShelfWell.state(isSelected: false, isHovered: true, isAlreadyKept: false), .hover)
        XCTAssertEqual(ShelfWell.state(isSelected: true, isHovered: true, isAlreadyKept: false), .selected,
                       "a picked tile under the pointer keeps its stronger well")
        XCTAssertEqual(ShelfWell.state(isSelected: true, isHovered: true, isAlreadyKept: true), .alreadyKept,
                       "the flash is the one that has to be seen in its second")
        // White 0.10, 0.14 under the pointer; picked, white 0.18 inside a 1.5 pt
        // blue ring.
        XCTAssertEqual(Theme.shelfTilePlate, Color.white.opacity(0.10))
        XCTAssertEqual(Theme.shelfHoverWell, Color.white.opacity(0.14))
        XCTAssertEqual(Theme.shelfSelectedWell, Color.white.opacity(0.18))
        XCTAssertEqual(Theme.shelfSelectedRingWidth, 1.5)
    }

    /// The remove badge shows on the hovered and the selected tile (decision 9).
    func testTheBadgeShowsOnTheHoveredAndTheSelectedTile() {
        XCTAssertFalse(ShelfWell.showsBadge(isSelected: false, isHovered: false))
        XCTAssertTrue(ShelfWell.showsBadge(isSelected: false, isHovered: true))
        XCTAssertTrue(ShelfWell.showsBadge(isSelected: true, isHovered: false))
        XCTAssertEqual(Theme.shelfBadgeGlyph, Color.white.opacity(0.62))
        XCTAssertEqual(Theme.shelfBadgeDisc, Color.black.opacity(0.28))
        XCTAssertEqual(Theme.offlineThumbnailOpacity, 0.4, "spec §8.4: α 0.4, in greyscale")
    }

    // MARK: - The header (§19.7)

    func testHeaderCount() {
        XCTAssertEqual(ShelfHeader.countText(12), "12 items")
        XCTAssertEqual(ShelfHeader.countText(60), "60 items")
        XCTAssertEqual(ShelfHeader.countText(1), "1 item", "never \"1 items\"")
        XCTAssertTrue(ShelfHeader.showsCount(itemCount: 1))
        XCTAssertFalse(ShelfHeader.showsCount(itemCount: 0), "the empty tray has no count")
        XCTAssertTrue(ShelfHeader.showsRemoveAll(itemCount: 1))
        XCTAssertFalse(ShelfHeader.showsRemoveAll(itemCount: 0), "and nothing to remove")
    }

    /// The glyph (26 × 20) starts at 20, where every summoned surface's title
    /// does, and the count (SF Pro Rounded 15) keeps the board's 29.4 after it;
    /// Remove All ends 8 before the gear's well, which stands where the board
    /// ended Remove All (§19.16, §19.7 amended 2026-10-18).
    func testTheHeaderIsTheBoards() {
        XCTAssertEqual(ShelfLayout.headerGlyph, CGSize(width: 26, height: 20))
        XCTAssertEqual(ShelfLayout.headerGlyphX, SurfaceHeaderLayout.titleLeading)
        XCTAssertEqual(ShelfLayout.headerCountX, 20 + 29.4, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.headerCountSize, 15)
        XCTAssertEqual(ShelfLayout.removeAllTrailing(bodyWidth: 385.3), 385.3 - 46 - 8, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.emptyLineSize, 13)
    }

    /// The tray is one size (§19.11 withdrew Expand), the Shelf's, and its click
    /// opens it on the model.
    func testTheTrayIsOneSize() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        vm.open(.tray)
        XCTAssertEqual(vm.openBodySize.height, 316 - 38 + vm.geometry.notchSize.height, accuracy: 0.001)
        XCTAssertEqual(vm.openBodySize.width, vm.geometry.expandedSize.width, accuracy: 0.001)
        XCTAssertEqual(vm.openTopRadius, 34)
        XCTAssertEqual(vm.openBottomRadius, 44)
    }

    // MARK: - Dropping in (§19.7)

    /// Two targets at y 46, each `(bw − 48) / 2` × 114, 16 apart from x 16, on
    /// every notch (the y moves with the notch's height).
    func testDropTargetsSideBySideAcrossTheBody() {
        for width in [CGFloat(480), 560, 620] {
            for notch in [CGFloat(32), 38] {
                let keep = ShelfDropTarget.well(.keep, bodyWidth: width, notchHeight: notch)
                let airDrop = ShelfDropTarget.well(.airDrop, bodyWidth: width, notchHeight: notch)
                XCTAssertEqual(keep.minX, 16)
                XCTAssertEqual(keep.width, (width - 48) / 2, accuracy: 0.0001)
                XCTAssertEqual(keep.width, airDrop.width)
                XCTAssertEqual(airDrop.minX - keep.maxX, 16)
                XCTAssertEqual(airDrop.maxX, width - 16, accuracy: 0.0001, "the body's trailing margin")
                XCTAssertEqual(keep.minY, 46 - 38 + notch, "the board's 46, less the reference header, plus this one")
                XCTAssertEqual(keep.height, 114)
                XCTAssertEqual(keep.maxY, airDrop.maxY)
            }
        }
        XCTAssertEqual(ShelfDropTarget.well(.keep, bodyWidth: 560, notchHeight: 38).width, 256)
        XCTAssertEqual(ShelfDropTarget.radius, 14)
        // The drop surface is 176 tall: the wells end 16 above the foot.
        XCTAssertEqual(ShelfDropTarget.well(.keep, bodyWidth: 560).maxY, 176 - 16)
    }

    /// The pointer over AirDrop's target takes AirDrop; everywhere else — the
    /// Keep target, the header, the margins — is Keep. A stray release must
    /// never send somebody's file to a stranger's phone.
    func testDropTargetChoiceByPointerPosition() {
        let bw: CGFloat = 560
        let keep = ShelfDropTarget.well(.keep, bodyWidth: bw)
        let airDrop = ShelfDropTarget.well(.airDrop, bodyWidth: bw)
        func target(_ point: CGPoint) -> ShelfDropTarget { ShelfDropTarget.target(atBodyPoint: point, bodyWidth: bw) }

        XCTAssertEqual(target(CGPoint(x: keep.midX, y: keep.midY)), .keep)
        XCTAssertEqual(target(CGPoint(x: airDrop.midX, y: airDrop.midY)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: airDrop.maxX - 1, y: airDrop.maxY - 1)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: airDrop.minX + 1, y: airDrop.minY + 1)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: keep.maxX - 1, y: keep.midY)), .keep)
        // The 16 pt gap counts as AirDrop's half: no dead strip to flicker through.
        XCTAssertEqual(target(CGPoint(x: keep.maxX + 12, y: keep.midY)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: keep.maxX + 4, y: keep.midY)), .keep)
        // Outside the targets' rows: Keep, even straight above or below AirDrop.
        XCTAssertEqual(target(CGPoint(x: airDrop.midX, y: 20)), .keep, "the header")
        XCTAssertEqual(target(CGPoint(x: airDrop.midX, y: airDrop.maxY + 4)), .keep, "below the targets")
        XCTAssertEqual(target(CGPoint(x: 5, y: keep.midY)), .keep, "the margin")
        XCTAssertEqual(target(CGPoint(x: -50, y: -50)), .keep)
        XCTAssertEqual(target(CGPoint(x: 5000, y: 5000)), .keep)
    }

    func testTheWindowPointBecomesABodyPoint() {
        // A 620 × 208 body in a 700 × 444 window: centred, hanging from the top.
        let rect = CGRect(x: 40, y: 444 - 208, width: 620, height: 208)
        XCTAssertEqual(ShelfDropTarget.bodyPoint(windowPoint: CGPoint(x: 40, y: 444), contentRect: rect), .zero)
        XCTAssertEqual(
            ShelfDropTarget.bodyPoint(windowPoint: CGPoint(x: 140, y: 444 - 100), contentRect: rect),
            CGPoint(x: 100, y: 100)
        )
    }

    // MARK: - AirDrop wears Apple's icon

    func testAirDropResolvesToTheSharingServicesImage() throws {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            throw XCTSkip("this Mac has no AirDrop sharing service")
        }
        let served = service.image
        guard case .image(let image) = ShelfIcon.airDrop(service: service) else {
            return XCTFail("the service has an image, so the icon is that image")
        }
        XCTAssertFalse(image.isTemplate, "full colour, never tinted")
        XCTAssertEqual(image.size, served.size, "the service's own size")

        // And the target resolves to it on this Mac.
        guard case .image(let drawn) = ShelfDropTarget.airDrop.icon else { return XCTFail("AirDrop drew a symbol") }
        XCTAssertFalse(drawn.isTemplate)
        XCTAssertEqual(drawn.size, served.size)
        XCTAssertEqual(ShelfDropTarget.airDrop.icon.nsImage?.size, NSSize(width: 16, height: 16), "a menu row's size")
    }

    /// No service, or a service with no image: the symbol the Shelf used before.
    func testAirDropFallsBackToTheSymbolWithoutAService() {
        guard case .symbol(let name) = ShelfIcon.airDrop(service: nil) else {
            return XCTFail("no service should give the symbol")
        }
        XCTAssertEqual(name, "dot.radiowaves.up.forward")
        XCTAssertEqual(ShelfDropTarget.airDrop.symbol, name)
    }

    /// Only AirDrop changes: the Keep target keeps its symbol.
    func testKeepKeepsItsSymbol() {
        guard case .symbol(let keep) = ShelfDropTarget.keep.icon else { return XCTFail("Keep lost its symbol") }
        XCTAssertEqual(keep, "tray.full")
        XCTAssertNotNil(ShelfDropTarget.keep.icon.nsImage, "tray.full is a real symbol")
    }

    func testTheTargetsNameTheirActions() {
        XCTAssertEqual(ShelfDropTarget.keep.symbol, "tray.full")
        XCTAssertEqual(ShelfDropTarget.keep.title, "Keep on Shelf")
        XCTAssertEqual(ShelfDropTarget.keep.caption, "Release to add to the Shelf")
        XCTAssertEqual(ShelfDropTarget.airDrop.title, "AirDrop")
        XCTAssertEqual(ShelfDropTarget.airDrop.caption, "Send to a nearby device")
        XCTAssertEqual(Theme.shelfDropWellLit, Theme.shelfBlue.opacity(0.18))
        XCTAssertEqual(Theme.shelfDropWellResting, Color.white.opacity(0.07))
        XCTAssertEqual(Theme.shelfDropRingWidth, 2)
        XCTAssertEqual(Theme.shelfDropCaptionLit, 0.75)
        XCTAssertEqual(Theme.shelfDropCaptionResting, 0.55)
    }

    // MARK: - Russian at the narrowest and the widest

    /// "No truncation of controls" (spec §13): Remove All's question and its two
    /// answers, in the real Russian table at the real type, fit the narrowest
    /// tray, 480 — the question wraps to two lines at most (the pane allows
    /// it), and the answers sit on one row beneath it.
    func testTheRussianRemoveAllQuestionFitsTheTray() throws {
        let russian = try Self.russianTable()
        func ru(_ key: String) -> String { russian[key] ?? key }
        func plate(_ text: String) -> CGFloat {
            ShelfTileName.measure(text) + 2 * ToolbarPushButtonStyle.horizontalPadding
        }
        let room: CGFloat = 480 - 48
        let answers = plate(ru("Cancel")) + 8 + plate(ru("Remove All")) + 16
        XCTAssertLessThanOrEqual(answers, room, "the answers on one row")
        let font = NSFont.systemFont(ofSize: Theme.TypeRole.body.size, weight: .regular)
        let question = (String(format: ru("Remove all %d items? Files are untouched."), 60) as NSString)
            .size(withAttributes: [.font: font]).width
        XCTAssertLessThanOrEqual(question / 2, room, "two lines hold the question")
        XCTAssertNotEqual(ru("Remove All"), "Remove All", "the Russian pass must measure Russian")
    }

    static func russianTable() throws -> [String: String] {
        let url = VisualLab.repositoryRoot.appendingPathComponent("Resources/ru.lproj/Localizable.strings")
        let table = NSDictionary(contentsOf: url) as? [String: String]
        return try XCTUnwrap(table, "ru.lproj/Localizable.strings reads as a property list")
    }
}
