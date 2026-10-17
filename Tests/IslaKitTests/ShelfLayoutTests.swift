import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The tray (spec §19.7, board `R2-Shelf-Open`): every value, frame and decision
/// `ShelfLayout` makes, held at 480, 560 and 620 without drawing anything — the
/// way `PlayerLayoutTests` holds the player. It replaced §8.1's grid of 78 × 100
/// cards and §8.2's selection bar (§19.11): one row of 80 × 94 tiles, four in
/// view, scrolling sideways past four; positions are in the content's
/// coordinates, the board's less the tray's 24 pt shoulder across and the
/// reference notch's 38 down.
@MainActor
final class ShelfLayoutTests: XCTestCase {

    // MARK: - The row (§19.7)

    /// A tile is 80 × 94, radius 16, on a 90 pitch from (41.9, 47.5) on the
    /// board — (17.9, 9.5) in the content. Four are in view and the tray never
    /// widens: the row scrolls past four.
    func testTileFramesFollowTheBoard() {
        XCTAssertEqual(ShelfLayout.tile, CGSize(width: 80, height: 94))
        XCTAssertEqual(ShelfLayout.tileRadius, 16)
        XCTAssertEqual(ShelfLayout.pitch, 90)
        XCTAssertEqual(ShelfLayout.shoulder, 24)
        XCTAssertEqual(ShelfLayout.firstTile.x, 17.9, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.firstTile.y, 9.5, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.tileFrame(index: 0), CGRect(x: 17.9, y: 9.5, width: 80, height: 94))
        XCTAssertEqual(ShelfLayout.tileFrame(index: 1).minX, 107.9, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.tileFrame(index: 3).maxX, 367.9, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.visibleTiles, 4)
        XCTAssertEqual(ShelfLayout.edgeFade, 16)
    }

    /// Four tiles fit the viewport whole and the fifth is what makes the row
    /// scroll; the viewport is the body's whole width and the content below the
    /// header strip, and the tiles and the notice line under them fit in it.
    func testFourTilesFitAndAFifthScrolls() {
        let body = SurfaceLayout.bodySize(for: .tray, bodyWidth: 560, notch: CGSize(width: 185, height: 38))
        XCTAssertEqual(body.width, 433.3 - 48, accuracy: 0.0001)
        let viewport = ShelfLayout.viewport(bodyWidth: body.width)
        XCTAssertEqual(viewport, CGRect(x: 0, y: 0, width: body.width, height: 120))
        XCTAssertLessThanOrEqual(ShelfLayout.tileFrame(index: ShelfLayout.visibleTiles - 1).maxX, viewport.width)
        XCTAssertFalse(ShelfLayout.scrolls(count: 4))
        XCTAssertTrue(ShelfLayout.scrolls(count: 5))
        XCTAssertFalse(ShelfLayout.scrolls(count: 0))
        // The row's content: the same margin after the last tile as before the first.
        XCTAssertEqual(ShelfLayout.contentWidth(count: 0), 0)
        XCTAssertEqual(ShelfLayout.contentWidth(count: 1), 2 * 17.9 + 80, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.contentWidth(count: 60), 2 * 17.9 + 59 * 90 + 80, accuracy: 0.0001, "the Shelf's limit")
        // Tiles end 16.5 above the foot; the notice line takes 14 under them.
        XCTAssertLessThanOrEqual(ShelfLayout.tileFrame(index: 0).maxY + 1 + 14, viewport.height)
        // The tray's one size and its shoulders (§19.2).
        XCTAssertEqual(body.height, 158)
        XCTAssertEqual(NotchViewModel.Surface.tray.topRadius, 24)
        XCTAssertEqual(NotchViewModel.Surface.tray.bottomRadius, 34)
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
    /// comment describes). Between tiles and past the last one there is none.
    func testTileIndexAtAPoint() {
        let first = ShelfLayout.tileFrame(index: 0)
        XCTAssertEqual(ShelfLayout.tileIndex(at: CGPoint(x: first.midX, y: first.midY), count: 12), 0)
        XCTAssertEqual(ShelfLayout.tileIndex(at: CGPoint(x: first.midX + 90, y: first.midY), count: 12), 1)
        XCTAssertEqual(ShelfLayout.tileIndex(at: CGPoint(x: first.midX + 90 * 11, y: first.midY), count: 12), 11)
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: first.maxX + 5, y: first.midY), count: 12), "the 10 pt gap is no tile")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: first.midX, y: first.maxY + 3), count: 12), "below the tiles")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: first.midX, y: first.minY - 3), count: 12), "above the tiles")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: first.midX + 90, y: first.midY), count: 1), "the second tile is not there")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: 5, y: first.midY), count: 12), "left of the first tile")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: first.midX + 90 * 12, y: first.midY), count: 12), "past the last")
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

    /// The glyph (26 × 20 at the board's 52.6) and the count (SF Pro Rounded 15
    /// at 82) lead the strip; Remove All ends 44 from the shape's right edge.
    func testTheHeaderIsTheBoards() {
        XCTAssertEqual(ShelfLayout.headerGlyph, CGSize(width: 26, height: 20))
        XCTAssertEqual(ShelfLayout.headerGlyphX, 28.6, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.headerCountX, 58, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.headerCountSize, 15)
        XCTAssertEqual(ShelfLayout.removeAllTrailing(bodyWidth: 385.3), 385.3 - 20, accuracy: 0.0001)
        XCTAssertEqual(ShelfLayout.emptyLineSize, 13)
    }

    /// The tray is one size (§19.11 withdrew Expand), the Shelf's, and its click
    /// opens it on the model.
    func testTheTrayIsOneSize() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        vm.open(.tray)
        XCTAssertEqual(vm.openBodySize.height, 158 - 38 + vm.geometry.notchSize.height, accuracy: 0.001)
        XCTAssertEqual(vm.openBodySize.width, 433.3 - 48, accuracy: 0.001)
        XCTAssertEqual(vm.openTopRadius, 24)
        XCTAssertEqual(vm.openBottomRadius, 34)
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
    /// answers, in the real Russian table at the real type, fit the tray's
    /// 385 pt — the question wraps to two lines at most (the pane allows it),
    /// and the answers sit on one row beneath it.
    func testTheRussianRemoveAllQuestionFitsTheTray() throws {
        let russian = try Self.russianTable()
        func ru(_ key: String) -> String { russian[key] ?? key }
        func plate(_ text: String) -> CGFloat {
            ShelfTileName.measure(text) + 2 * ToolbarPushButtonStyle.horizontalPadding
        }
        let room = (SurfaceLayout.trayReference.width - 2 * ShelfLayout.shoulder) - 48
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
