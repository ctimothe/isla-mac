import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Shelf as Finder's icon view (redesign 2026-10-15, spec §8): every value,
/// frame and decision `ShelfLayout` makes, held at 480, 560 and 620 without
/// drawing anything — the way `PlayerLayoutTests` holds the player.
@MainActor
final class ShelfLayoutTests: XCTestCase {

    // MARK: - The grid (§8.1)

    /// Six tiles fill the 560 body to the point — 6 × 78 + 5 × 4 = 488, the
    /// pane's whole width — and five fill 480, which is also the floor. The
    /// spec's prose writes `(bw − 72) / 82`, which is 5.95 at 560 and so drops
    /// the sixth column its own paragraph and every board draw; the last tile
    /// has no gap after it, so the room a row needs is `82 n − 4`.
    func testColumnsPerWidth() {
        XCTAssertEqual(ShelfLayout.columns(bodyWidth: 480), 5)
        XCTAssertEqual(ShelfLayout.columns(bodyWidth: 560), 6)
        XCTAssertEqual(ShelfLayout.columns(bodyWidth: 620), 6, "620 has 69 pt to spare, and not a tile's worth")
        XCTAssertEqual(
            CGFloat(ShelfLayout.columns(bodyWidth: 560)) * ShelfLayout.tile.width
                + CGFloat(ShelfLayout.columns(bodyWidth: 560) - 1) * ShelfLayout.columnGap,
            PlayerLayout.paneWidth(bodyWidth: 560), "six tiles are exactly the 560 pane"
        )
        for width in stride(from: CGFloat(480), through: 620, by: 4) {
            let columns = ShelfLayout.columns(bodyWidth: width)
            XCTAssertGreaterThanOrEqual(columns, ShelfLayout.minimumColumns, "never below five (\(width))")
            let rowWidth = CGFloat(columns) * ShelfLayout.pitch.width - ShelfLayout.columnGap
            XCTAssertLessThanOrEqual(rowWidth, PlayerLayout.paneWidth(bodyWidth: width), "a row fits the pane at \(width)")
        }
    }

    /// A tile is 78 × 100, 4 apart across and 8 down, from (58, 44) in body
    /// coordinates — the pane's own leading edge.
    func testTileFramesFollowTheBoard() {
        XCTAssertEqual(ShelfLayout.tile, CGSize(width: 78, height: 100))
        XCTAssertEqual(ShelfLayout.gridOrigin, CGPoint(x: 58, y: 44))
        XCTAssertEqual(ShelfLayout.gridOrigin.x, PlayerLayout.paneLeading)
        XCTAssertEqual(ShelfLayout.tileFrame(index: 0, columns: 6), CGRect(x: 0, y: 0, width: 78, height: 100))
        XCTAssertEqual(ShelfLayout.tileFrame(index: 1, columns: 6).minX, 82)
        XCTAssertEqual(ShelfLayout.tileFrame(index: 5, columns: 6).maxX, 488)
        XCTAssertEqual(ShelfLayout.tileFrame(index: 6, columns: 6), CGRect(x: 0, y: 108, width: 78, height: 100), "row two")
        // The pane's frame of the first tile is body (58, 44) less (58, header).
        let first = PlayerLayout.inPane(
            ShelfLayout.tileFrame(index: 0, columns: 6).offsetBy(dx: ShelfLayout.gridOrigin.x, dy: ShelfLayout.gridOrigin.y),
            headerHeight: 38
        )
        XCTAssertEqual(first.origin, CGPoint(x: 0, y: 6))
    }

    func testTheIconWellAndBadgeSitWhereTheBoardPutsThem() {
        XCTAssertEqual(ShelfLayout.icon, CGRect(x: 13, y: 5, width: 52, height: 52))
        XCTAssertEqual(ShelfLayout.well, CGRect(x: 9, y: 1, width: 60, height: 60))
        XCTAssertEqual(ShelfLayout.wellRadius, 8, "spec §2.3: the Shelf's selection and hover wells")
        XCTAssertEqual(ShelfLayout.badge, CGRect(x: 4, y: -3, width: 18, height: 18))
        XCTAssertEqual(ShelfLayout.nameTop, 65)
        // The well is centred on the icon.
        XCTAssertEqual(ShelfLayout.well.midX, ShelfLayout.icon.midX)
        XCTAssertEqual(ShelfLayout.well.midY, ShelfLayout.icon.midY)
    }

    /// Hover is a decision made from the pointer and the layout, so a tile that
    /// slides under a pointer that has not moved is hovered (the bug the pane's
    /// comment describes). Between tiles and past the last one there is none.
    func testTileIndexAtAPoint() {
        let columns = 6
        XCTAssertEqual(ShelfLayout.tileIndex(at: CGPoint(x: 10, y: 10), count: 12, columns: columns), 0)
        XCTAssertEqual(ShelfLayout.tileIndex(at: CGPoint(x: 90, y: 10), count: 12, columns: columns), 1)
        XCTAssertEqual(ShelfLayout.tileIndex(at: CGPoint(x: 10, y: 120), count: 12, columns: columns), 6, "the second row")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: 80, y: 10), count: 12, columns: columns), "the 4 pt gap is no tile")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: 10, y: 103), count: 12, columns: columns), "the 8 pt row gap is no tile")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: 10, y: 10 + 216), count: 12, columns: columns), "past the last row")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: 90, y: 10), count: 1, columns: columns), "the second tile is not there")
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: -1, y: 5), count: 12, columns: columns))
        XCTAssertNil(ShelfLayout.tileIndex(at: CGPoint(x: 600, y: 5), count: 12, columns: columns), "right of the last column")
    }

    // MARK: - The regions

    /// On the 208 body the grid's window is 121 pt tall — one row and 21 of the
    /// next, faded under 26 pt — and 313 at 400. The bar is 22 tall at 171 (and
    /// 363 on the tall body), 15 clear of the foot.
    func testViewportAndBarOnBothBodies() {
        let standard = CGSize(width: 560, height: 208)
        let tall = CGSize(width: 560, height: 400)
        XCTAssertEqual(ShelfLayout.bar(bodySize: standard), CGRect(x: 58, y: 171, width: 488, height: 22))
        XCTAssertEqual(ShelfLayout.bar(bodySize: tall).minY, 363)
        XCTAssertEqual(ShelfLayout.viewport(bodySize: standard), CGRect(x: 58, y: 44, width: 488, height: 121))
        XCTAssertEqual(ShelfLayout.viewport(bodySize: tall).height, 313)
        XCTAssertEqual(ShelfLayout.overflowFade, 26)
        // The viewport ends above the bar and the bar ends inside the body's padding.
        for body in [standard, tall] {
            XCTAssertLessThan(ShelfLayout.viewport(bodySize: body).maxY, ShelfLayout.bar(bodySize: body).minY)
            XCTAssertLessThanOrEqual(ShelfLayout.bar(bodySize: body).maxY, body.height - NotchGeometry.bodyBottomPadding)
        }
        // At 208 a row and a bit is what shows; expanded, 12 tiles at six a row (two rows) are whole.
        let columns = ShelfLayout.columns(bodyWidth: 560)
        XCTAssertGreaterThan(ShelfLayout.contentHeight(count: 12, columns: columns), ShelfLayout.viewport(bodySize: standard).height)
        XCTAssertLessThan(ShelfLayout.contentHeight(count: 12, columns: columns), ShelfLayout.viewport(bodySize: tall).height)
        XCTAssertEqual(ShelfLayout.contentHeight(count: 0, columns: columns), 0)
    }

    func testBodySizeIsTheInverseOfThePaneTheShellCuts() {
        for header in [CGFloat(32), 38] {
            let body = CGSize(width: 560, height: 208)
            let pane = CGSize(
                width: PlayerLayout.paneWidth(bodyWidth: body.width),
                height: body.height - header - NotchGeometry.bodyBottomPadding
            )
            XCTAssertEqual(ShelfLayout.bodySize(paneSize: pane, headerHeight: header), body)
        }
    }

    /// A thumbnail keeps its own shape, long side 52, and never fills the
    /// square: the white border hugs the picture, not the box.
    func testAThumbnailKeepsItsShape() {
        XCTAssertEqual(ShelfLayout.fittedSize(of: CGSize(width: 192, height: 120)), CGSize(width: 52, height: 33))
        XCTAssertEqual(ShelfLayout.fittedSize(of: CGSize(width: 96, height: 96)), CGSize(width: 52, height: 52))
        XCTAssertEqual(ShelfLayout.fittedSize(of: CGSize(width: 50, height: 100)), CGSize(width: 26, height: 52))
        XCTAssertEqual(ShelfLayout.fittedSize(of: .zero), CGSize(width: 52, height: 52), "an image of no size is the square")
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

    // MARK: - Tile wells (§8.2, §8.4)

    func testTheWellsPriority() {
        XCTAssertNil(ShelfWell.state(isSelected: false, isHovered: false, isAlreadyKept: false))
        XCTAssertEqual(ShelfWell.state(isSelected: false, isHovered: true, isAlreadyKept: false), .hover)
        XCTAssertEqual(ShelfWell.state(isSelected: true, isHovered: true, isAlreadyKept: false), .selected,
                       "a picked tile under the pointer keeps its stronger well")
        XCTAssertEqual(ShelfWell.state(isSelected: true, isHovered: true, isAlreadyKept: true), .alreadyKept,
                       "the flash is the one that has to be seen in its second")
        XCTAssertEqual(Theme.shelfSelectedWell, Color.white.opacity(0.14))
        XCTAssertEqual(Theme.shelfHoverWell, Color.white.opacity(0.07))
    }

    func testTheBadgeIsTheBoardsGrey() {
        XCTAssertEqual(Theme.shelfBadgeFill, Color(red: 80.0 / 255, green: 80.0 / 255, blue: 84.0 / 255).opacity(0.96))
        XCTAssertEqual(Theme.offlineThumbnailOpacity, 0.4, "spec §8.4: α 0.4, in greyscale")
    }

    // MARK: - The header (§8.1)

    func testHeaderCount() {
        XCTAssertEqual(ShelfHeader.countText(12), "12 items")
        XCTAssertEqual(ShelfHeader.countText(60), "60 items")
        XCTAssertEqual(ShelfHeader.countText(1), "1 item", "never \"1 items\"")
        XCTAssertTrue(ShelfHeader.showsCount(itemCount: 1))
        XCTAssertFalse(ShelfHeader.showsCount(itemCount: 0), "the empty well has no count (Shelf-Empty)")
    }

    func testExpandIsThereWhileThereIsSomethingOrWhileTall() {
        XCTAssertFalse(ShelfHeader.showsExpand(itemCount: 0, isExpanded: false))
        XCTAssertTrue(ShelfHeader.showsExpand(itemCount: 3, isExpanded: false))
        XCTAssertTrue(
            ShelfHeader.showsExpand(itemCount: 0, isExpanded: true),
            "Clear on the tall Shelf must not strand the person at 400 with no Collapse"
        )
    }

    /// The count's right edge is `bw − 47`: the header's 16, the count's own 31.
    func testTheCountKeepsClearOfExpand() {
        XCTAssertEqual(16 + ShelfHeader.countClearance, 47)
        XCTAssertEqual(
            HeaderToolFrames.expand(bodyWidth: 560).minX - (560 - 47), 8,
            "the count ends 8 pt before the 22 pt Expand button, which starts at bw − 39"
        )
    }

    /// The Shelf expands to 400 through `expandedTabs`, like every tab (§6).
    func testTheShelfExpandsThroughExpandedTabs() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        vm.select(.shelf)
        XCTAssertEqual(vm.openBodySize.height, 208)
        vm.setExpanded(true, for: .shelf)
        XCTAssertEqual(vm.openBodySize.height, 400)
        XCTAssertTrue(vm.expandedTabs.contains(.shelf))
        XCTAssertEqual(
            NotchViewModel.openBodyHeight(tab: .shelf, showingLyrics: false, expandedTabs: [.shelf]), 400
        )
        vm.setExpanded(false, for: .shelf)
        XCTAssertEqual(vm.openBodySize.height, 208)
    }

    // MARK: - The bar (§8.2, §13)

    private func bar(
        items: Int = 12, selected: Int = 0, notice: ShelfStore.Notice? = nil, clearing: Bool = false, width: CGFloat = 560
    ) -> ShelfBar {
        ShelfBar.make(itemCount: items, selectionCount: selected, notice: notice, isConfirmingClear: clearing, bodyWidth: width)
    }

    func testTheBarWithASelectionAtEachWidth() {
        for width in [CGFloat(540), 560, 620] {
            XCTAssertEqual(
                bar(selected: 2, width: width),
                ShelfBar(
                    leading: .selection(count: 2),
                    trailing: .verbs(inline: [.quickLook, .airDrop, .copy, .showInFinder, .remove], overflow: [])
                ),
                "all five verbs at \(width)"
            )
        }
        for width in [CGFloat(480), 500, 539] {
            XCTAssertEqual(
                bar(selected: 2, width: width),
                ShelfBar(
                    leading: .selection(count: 2),
                    trailing: .verbs(inline: [.quickLook, .remove], overflow: [.airDrop, .copy, .showInFinder])
                ),
                "below 540 the bar keeps Quick Look and Remove and folds the rest into More (\(width))"
            )
        }
        XCTAssertEqual(ShelfBar.moreWidth, 540)
    }

    func testTheVerbsInTheSpecsOrder() {
        XCTAssertEqual(ShelfVerb.allCases, [.quickLook, .airDrop, .copy, .showInFinder, .remove])
        XCTAssertEqual(ShelfVerb.allCases.map(\.title), ["Quick Look", "AirDrop", "Copy", "Show in Finder", "Remove"])
    }

    func testWithoutASelectionTheBarHintsAndOffersClear() {
        XCTAssertEqual(bar(), ShelfBar(leading: .hint, trailing: .clear))
        XCTAssertEqual(bar(width: 480), ShelfBar(leading: .hint, trailing: .clear), "Clear does not fold")
        XCTAssertEqual(localized("Drag an item out to use it anywhere."), "Drag an item out to use it anywhere.")
    }

    /// A notice owns the leading slot: over nothing selected, and over a
    /// selection only when it answers a press of a verb in this bar (an AirDrop
    /// refusal), as before the redesign.
    func testANoticeTakesTheLeadingSlot() {
        XCTAssertEqual(bar(notice: .evicted(1)).leading, .notice(.evicted(1)))
        XCTAssertEqual(bar(notice: .alreadyOnShelf).leading, .notice(.alreadyOnShelf))
        XCTAssertEqual(bar(selected: 2, notice: .alreadyOnShelf).leading, .selection(count: 2), "a drop's result waits")
        XCTAssertEqual(bar(selected: 2, notice: .airDropCannotSend).leading, .notice(.airDropCannotSend),
                       "a refusal answers the verb just pressed")
        XCTAssertEqual(bar(notice: .alreadyOnShelf).trailing, .clear)
    }

    /// Clear asks once, in place: the question names how many, and its two
    /// answers replace everything else in the bar.
    func testClearAsksOnceInPlace() {
        let asking = bar(items: 12, selected: 3, notice: .alreadyOnShelf, clearing: true)
        XCTAssertEqual(asking, ShelfBar(leading: .clearQuestion(count: 12), trailing: .confirmClear))
        XCTAssertEqual(
            localized("Remove all %d items? Files are untouched.", 12), "Remove all 12 items? Files are untouched."
        )
        // An empty shelf has nothing to ask about.
        XCTAssertEqual(bar(items: 0, clearing: true).trailing, .nothing)
    }

    /// The folded bar is what the view falls back to when the full row does not
    /// fit — Russian's longest verbs overrun a 560 pane.
    func testTheFoldedBarKeepsQuickLookAndRemove() {
        let full = bar(selected: 1, width: 620)
        XCTAssertEqual(
            full.folded.trailing,
            .verbs(inline: [.quickLook, .remove], overflow: [.airDrop, .copy, .showInFinder])
        )
        XCTAssertEqual(full.folded.leading, full.leading)
        XCTAssertEqual(bar().folded, bar(), "a bar with no verbs has nothing to fold")
    }

    // MARK: - The key hints and More

    func testMoreMenuHintsOnlyTheKeysTheContextMenuNames() {
        XCTAssertEqual(ShelfMoreMenuPresenter.keyEquivalent(for: .copy), "c")
        XCTAssertEqual(ShelfMoreMenuPresenter.keyEquivalent(for: .showInFinder), "r")
        XCTAssertNil(ShelfMoreMenuPresenter.keyEquivalent(for: .airDrop))
        XCTAssertNil(ShelfMoreMenuPresenter.keyEquivalent(for: .remove))
    }

    // MARK: - Dropping in (§8.3)

    func testDropWellsSideBySideAcrossThePane() {
        for width in [CGFloat(480), 560, 620] {
            let body = CGSize(width: width, height: 208)
            let keep = ShelfDropTarget.well(.keep, bodySize: body)
            let airDrop = ShelfDropTarget.well(.airDrop, bodySize: body)
            XCTAssertEqual(keep.minX, 58)
            XCTAssertEqual(keep.width, airDrop.width)
            XCTAssertEqual(airDrop.minX - keep.maxX, 8)
            XCTAssertEqual(airDrop.maxX, width - 14, "the pane's trailing edge")
            XCTAssertEqual(keep.minY, 46)
            XCTAssertEqual(keep.height, 140, "the board's 140 on the standard body")
        }
        XCTAssertEqual(ShelfDropTarget.well(.keep, bodySize: CGSize(width: 560, height: 208)).width, 240)
        XCTAssertGreaterThan(ShelfDropTarget.well(.keep, bodySize: CGSize(width: 560, height: 400)).height, 300, "fills the tall body")
    }

    /// The pointer over AirDrop's well takes AirDrop; everywhere else — the
    /// Keep well, the header, the rail, the margins — is Keep. A stray release
    /// must never send somebody's file to a stranger's phone.
    func testDropTargetChoiceByPointerPosition() {
        let body = CGSize(width: 560, height: 208)
        let keep = ShelfDropTarget.well(.keep, bodySize: body)
        let airDrop = ShelfDropTarget.well(.airDrop, bodySize: body)
        func target(_ point: CGPoint) -> ShelfDropTarget { ShelfDropTarget.target(atBodyPoint: point, bodySize: body) }

        XCTAssertEqual(target(CGPoint(x: keep.midX, y: keep.midY)), .keep)
        XCTAssertEqual(target(CGPoint(x: airDrop.midX, y: airDrop.midY)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: airDrop.maxX - 1, y: airDrop.maxY - 1)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: airDrop.minX + 1, y: airDrop.minY + 1)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: keep.maxX - 1, y: keep.midY)), .keep)
        // The 8 pt gap counts as AirDrop's half: no dead strip to flicker through.
        XCTAssertEqual(target(CGPoint(x: keep.maxX + 5, y: keep.midY)), .airDrop)
        XCTAssertEqual(target(CGPoint(x: keep.maxX + 2, y: keep.midY)), .keep)
        // Outside the wells' rows: Keep, even straight above or below AirDrop.
        XCTAssertEqual(target(CGPoint(x: airDrop.midX, y: 20)), .keep, "the header")
        XCTAssertEqual(target(CGPoint(x: airDrop.midX, y: airDrop.maxY + 4)), .keep, "below the wells")
        XCTAssertEqual(target(CGPoint(x: 20, y: keep.midY)), .keep, "the rail")
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

    /// The AirDrop verb and the AirDrop well draw the image macOS shows in its
    /// share menus — `NSSharingService(named: .sendViaAirDrop)?.image`, full
    /// colour — and the old symbol only where the service is missing.
    private func drawnSize(_ verb: ShelfVerb) -> NSSize? {
        guard case .image(let image) = verb.icon else { return nil }
        return image.size
    }

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

        // And the two call sites resolve to it on this Mac.
        for icon in [ShelfVerb.airDrop.icon, ShelfDropTarget.airDrop.icon] {
            guard case .image(let drawn) = icon else { return XCTFail("AirDrop drew a symbol") }
            XCTAssertFalse(drawn.isTemplate)
            XCTAssertEqual(drawn.size, served.size)
        }
        XCTAssertEqual(ShelfVerb.airDrop.icon.nsImage?.size, NSSize(width: 16, height: 16), "a menu row's size")
        XCTAssertEqual(drawnSize(.airDrop), served.size, "the shared service image is left as it was")
    }

    /// No service, or a service with no image: the symbol the Shelf used before.
    func testAirDropFallsBackToTheSymbolWithoutAService() {
        guard case .symbol(let name) = ShelfIcon.airDrop(service: nil) else {
            return XCTFail("no service should give the symbol")
        }
        XCTAssertEqual(name, "dot.radiowaves.up.forward")
        XCTAssertEqual(ShelfVerb.airDrop.symbol, name)
        XCTAssertEqual(ShelfDropTarget.airDrop.symbol, name)
    }

    /// Only AirDrop changes: every other verb and the Keep well keep their
    /// symbols.
    func testEveryOtherVerbKeepsItsSymbol() {
        for verb in ShelfVerb.allCases where verb != .airDrop {
            guard case .symbol(let name) = verb.icon else { return XCTFail("\(verb) lost its symbol") }
            XCTAssertEqual(name, verb.symbol)
            XCTAssertNotNil(verb.icon.nsImage, "\(name) is a real symbol")
        }
        guard case .symbol(let keep) = ShelfDropTarget.keep.icon else { return XCTFail("Keep lost its symbol") }
        XCTAssertEqual(keep, "tray.and.arrow.down")
    }

    func testTheWellsNameTheirActions() {
        XCTAssertEqual(ShelfDropTarget.keep.symbol, "tray.and.arrow.down")
        XCTAssertEqual(ShelfDropTarget.keep.title, "Keep on Shelf")
        XCTAssertEqual(ShelfDropTarget.keep.litCaption, "Release to add to the Shelf")
        XCTAssertEqual(ShelfDropTarget.keep.restingCaption, "Drop to keep on the Shelf")
        XCTAssertEqual(ShelfDropTarget.airDrop.title, "AirDrop")
        XCTAssertEqual(ShelfDropTarget.airDrop.restingCaption, "Send to a nearby device")
        XCTAssertEqual(ShelfDropTarget.airDrop.litCaption, "Release to send with AirDrop")
        XCTAssertEqual(Theme.shelfDropWellLit, Theme.accent.opacity(0.18))
        XCTAssertEqual(Theme.shelfDropRingWidth, 2)
    }

    // MARK: - Russian at the narrowest and the widest

    /// "No truncation of controls" (spec §13): the bar's controls are measured
    /// in the real Russian table at the real type, and the folded row has to fit
    /// the 480 pane (408) with the count in front of it. The full row is allowed
    /// not to fit at 560 — the view falls back to the folded one by measure —
    /// and is held to fit where it claims to, at 620, or fold.
    func testTheRussianBarFitsEveryWidth() throws {
        let russian = try Self.russianTable()
        func ru(_ key: String) -> String { russian[key] ?? key }
        func plate(_ text: String) -> CGFloat {
            ShelfTileName.measure(text) + 2 * ToolbarPushButtonStyle.horizontalPadding
        }
        let count = ShelfTileName.measure(String(format: ru("%d selected"), 12)) + 6 + 24
        let folded = plate(ru("Quick Look")) + 6 + plate(ru("Remove")) + 6 + ToolbarPushButtonStyle.height
        let full = ShelfVerb.allCases.map { plate(ru($0.title)) }.reduce(0, +) + 6 * 4
        XCTAssertLessThanOrEqual(count + 8 + folded, PlayerLayout.paneWidth(bodyWidth: 480), "folded row at 480")
        XCTAssertLessThan(folded, full, "folding is what makes room")
        // At 620 the pane is 548: the full row either fits or the view folds it,
        // and the folded one always does.
        XCTAssertLessThanOrEqual(count + 8 + folded, PlayerLayout.paneWidth(bodyWidth: 620))
        let question = ShelfTileName.measure(String(format: ru("Remove all %d items? Files are untouched."), 60))
        let answers = plate(ru("Cancel")) + 6 + plate(ru("Remove All")) + 20
        // The question may wrap to two lines (the bar allows it), never run under the answers.
        XCTAssertLessThanOrEqual(question / 2 + 8 + answers, PlayerLayout.paneWidth(bodyWidth: 480))
    }

    static func russianTable() throws -> [String: String] {
        let url = VisualLab.repositoryRoot.appendingPathComponent("Resources/ru.lproj/Localizable.strings")
        let table = NSDictionary(contentsOf: url) as? [String: String]
        return try XCTUnwrap(table, "ru.lproj/Localizable.strings reads as a property list")
    }
}
