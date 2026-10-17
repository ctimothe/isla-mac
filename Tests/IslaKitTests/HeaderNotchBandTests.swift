import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// No header control sits under the notch (driver correction, review 2026-10-15;
/// restated for the shell's header row, spec §19.6–§19.8).
///
/// Body coordinates start at the top of the screen. The first `notchSize.height`
/// points — 38 on a 14-inch — are the header row, and the notch, 185 to 220 pt
/// wide and centred on the body, occupies the middle of it; Isla draws a
/// synthetic one on a Mac that has none, so the middle of the header is never
/// free. The first redesign put the Clipboard's Kind filter at (212, 9) and its
/// search field at (250, 8), and on hardware both were largely hidden.
///
/// This holds the whole app's header controls once, at 480, 560 and 620, at both
/// notch widths and at the two notch heights the Macs report, against a band 8 pt
/// wider than the notch each side: the Tools button, History, the surfaces'
/// titles, the stage's icon, the tray's glyph, count and Remove All. The surfaces'
/// own controls are in the content, below the row, which a test can only hold
/// by their coordinates: they start at 0 and the row has already ended.
@MainActor
final class HeaderNotchBandTests: XCTestCase {
    private let widths: [CGFloat] = [480, 560, 620]
    private let notchWidths: [CGFloat] = [185, 220]
    private let notchHeights: [CGFloat] = [32, 38]
    /// The notches §19.12 holds every compact activity at, and so every
    /// surface whose width follows the notch (the tray).
    private static let everyNotchWidth: [CGFloat] = [180, 185, 200, 220, 240]
    private static let everyNotchHeight: [CGFloat] = [24, 32, 38]

    override func tearDown() {
        LabLocalization.use("en")
        super.tearDown()
    }

    private func band(bodyWidth: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        CGRect(
            x: bodyWidth / 2 - notchWidth / 2 - 8, y: 0,
            width: notchWidth + 16, height: notchHeight
        )
    }

    /// Each control against every notch width at `width` and every notch height.
    /// `frames` is built for the notch it is checked against, because the room
    /// the title and the count are given depends on the notch's width.
    private func assertClear(
        at width: CGFloat,
        _ controls: (_ notchWidth: CGFloat, _ notchHeight: CGFloat) -> [(name: String, frame: CGRect)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for notchWidth in notchWidths {
            for notchHeight in notchHeights {
                let band = band(bodyWidth: width, notchWidth: notchWidth, notchHeight: notchHeight)
                for control in controls(notchWidth, notchHeight) {
                    XCTAssertFalse(
                        control.frame.intersects(band),
                        "\(control.name) \(control.frame) is under the notch band \(band) at body \(width), notch \(notchWidth) × \(notchHeight)",
                        file: file, line: line
                    )
                    XCTAssertTrue(
                        control.frame.maxX <= band.minX || control.frame.minX >= band.maxX,
                        "\(control.name) \(control.frame) is not wholly to one side of \(band) at body \(width)",
                        file: file, line: line
                    )
                    XCTAssertLessThanOrEqual(control.frame.maxY, notchHeight + 0.001, "\(control.name) is inside the row", file: file, line: line)
                    XCTAssertGreaterThanOrEqual(control.frame.minY, 0, "\(control.name) is inside the row", file: file, line: line)
                }
            }
        }
    }

    func testTheBandIsWhereTheNotchIs() {
        let band = band(bodyWidth: 560, notchWidth: 185, notchHeight: 38)
        XCTAssertEqual(band.minX, 280 - 92.5 - 8)
        XCTAssertEqual(band.maxX, 280 + 92.5 + 8)
        XCTAssertEqual(band.height, 38)
    }

    /// The notch's own span of the row is the one part that closes the panel,
    /// so it is exactly the notch, and every control sits outside it.
    func testTheCloseSpanIsTheNotchAndNothingElse() {
        for width in widths {
            let span = SurfaceHeaderLayout.closeSpan(bodyWidth: width, notchWidth: 185, notchHeight: 38)
            XCTAssertEqual(span, CGRect(x: (width - 185) / 2, y: 0, width: 185, height: 38))
            XCTAssertEqual(span.midX, width / 2, accuracy: 0.001)
        }
    }

    // MARK: The gear and History

    /// The gear at (`bw − 46`, 6), where the Tools button stood (§19.16), and
    /// Translate's History at (`bw − 76`, 6), both 26 × 26 and centred on the
    /// row: right of the notch at every width and clear of each other.
    func testTheGearAndHistoryButtonsStayRightOfTheNotch() {
        for height in notchHeights {
            for width in widths {
                let tools = SurfaceHeaderLayout.gear(bodyWidth: width, notchHeight: height)
                let history = SurfaceHeaderLayout.history(bodyWidth: width, notchHeight: height)
                XCTAssertEqual(tools.size, CGSize(width: 26, height: 26))
                XCTAssertEqual(history.size, CGSize(width: 26, height: 26))
                XCTAssertEqual(tools.minX, width - 46)
                XCTAssertEqual(history.minX, width - 76)
                XCTAssertEqual(tools.midY, height / 2, "centred on the row")
                XCTAssertFalse(history.intersects(tools), "History and the gear at \(width)")
                XCTAssertEqual(tools.maxX, width - 20, "the gear ends 20 from the right edge")
            }
        }
        // On the reference's 38 the board's y 6 falls out of the centring.
        XCTAssertEqual(SurfaceHeaderLayout.gear(bodyWidth: 560, notchHeight: 38).minY, 6)
        for width in widths {
            assertClear(at: width) { _, height in [
                ("Settings", SurfaceHeaderLayout.gear(bodyWidth: width, notchHeight: height)),
                ("History", SurfaceHeaderLayout.history(bodyWidth: width, notchHeight: height)),
            ] }
        }
    }

    /// The tray carries the gear too, so Remove All moves left to end 8
    /// before its well, and the tray's minimum width counts the gear: Remove
    /// All never reaches the notch under any notch §19.12 names, in either
    /// language (§19.16).
    func testRemoveAllStaysClearOfTheGearAndTheNotch() {
        for notchWidth: CGFloat in [180, 185, 200, 220, 240] {
            for height in notchHeights {
                let body = SurfaceLayout.bodySize(
                    for: .tray, bodyWidth: 560, notch: CGSize(width: notchWidth, height: height)
                ).width
                let gear = SurfaceHeaderLayout.gear(bodyWidth: body, notchHeight: height)
                let removeAll = SurfaceHeaderLayout.removeAll(
                    bodyWidth: body, width: ShelfLayout.removeAllWidth(), notchHeight: height
                )
                XCTAssertEqual(removeAll.maxX, gear.minX - 8, accuracy: 0.001, "notch \(notchWidth)")
                let notchRight = (body + notchWidth) / 2
                XCTAssertGreaterThanOrEqual(
                    removeAll.minX, notchRight + SurfaceHeaderLayout.notchClearance - 0.001,
                    "Remove All keeps 8 from the notch \(notchWidth) with the gear beside it"
                )
            }
        }
    }

    // MARK: Titles

    /// A summoned surface's title ends 8 before the notch, and its words fit
    /// the room in both languages — "Буфер обмена" under the widest notch at
    /// 480 is the tightest case — shrinking a little (`minimumScaleFactor`
    /// 0.82) before they are cut.
    func testTheSurfaceTitlesStayLeftOfTheNotchAndFitInBothLanguages() {
        let titled: [NotchViewModel.Surface] = [.clipboard, .translate, .settings]
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            for width in widths {
                assertClear(at: width) { notchWidth, notchHeight in [
                    ("Title", SurfaceHeaderLayout.title(bodyWidth: width, notchWidth: notchWidth, notchHeight: notchHeight)),
                ] }
                for notchWidth in notchWidths {
                    let room = SurfaceHeaderLayout.title(bodyWidth: width, notchWidth: notchWidth, notchHeight: 38).width
                    for surface in titled {
                        let font = NSFont.systemFont(ofSize: SurfaceHeaderLayout.titleSize, weight: .semibold)
                        let name = (surface.title as NSString).size(withAttributes: [.font: font]).width
                        let needed = SurfaceHeaderLayout.titleGlyphSize + SurfaceHeaderLayout.titleGap + name * 0.82
                        XCTAssertLessThanOrEqual(
                            needed, room,
                            "\(surface.title) (\(language)) needs \(needed) of \(room) at body \(width), notch \(notchWidth)"
                        )
                    }
                }
            }
        }
    }

    // MARK: Stage

    func testTheStageIconStaysLeftOfTheNotch() {
        for height in notchHeights {
            let icon = SurfaceHeaderLayout.stageIcon(notchHeight: height)
            XCTAssertEqual(icon.size, CGSize(width: 16, height: 16))
            XCTAssertEqual(icon.minX, 20)
        }
        for width in widths {
            assertClear(at: width) { _, height in [("Stage icon", SurfaceHeaderLayout.stageIcon(notchHeight: height))] }
        }
    }

    // MARK: Tray

    /// The tray's glyph and count sit left of the notch and Remove All right of
    /// it, in both languages (Remove All's width is measured from the word in
    /// the language on screen), at the width the tray really has under each
    /// notch §19.12 names.
    ///
    /// The tray is not `bw` wide: it is the board's 385.3, widened only as a
    /// wide notch needs (`ShelfLayout.bodyWidth(notchWidth:)`). This was first
    /// checked at 480, 560 and 620, widths the tray never has, and passed
    /// while under a 220 pt notch the real header cut "60" and ran Remove All
    /// into the notch (R8 review).
    func testTheTrayHeaderStaysClearOfTheNotch() {
        let digits = ShelfLayout.maximumCountWidth()
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            let removeAll = ShelfRemoveAllButton.width()
            for notchWidth in Self.everyNotchWidth {
                for notchHeight in Self.everyNotchHeight {
                    let notch = CGSize(width: notchWidth, height: notchHeight)
                    let width = SurfaceLayout.bodySize(for: .tray, bodyWidth: 560, notch: notch).width
                    let band = band(bodyWidth: width, notchWidth: notchWidth, notchHeight: notchHeight)
                    let glyph = SurfaceHeaderLayout.trayGlyph(notchHeight: notchHeight)
                    let count = SurfaceHeaderLayout.trayCount(bodyWidth: width, notchWidth: notchWidth, notchHeight: notchHeight)
                    let remove = SurfaceHeaderLayout.removeAll(bodyWidth: width, width: removeAll, notchHeight: notchHeight)
                    let at = "\(language), notch \(notchWidth) × \(notchHeight), tray \(width)"
                    XCTAssertLessThanOrEqual(glyph.maxX, count.minX, at)
                    XCTAssertLessThanOrEqual(count.maxX, band.minX, "the count ends before the notch, \(at)")
                    XCTAssertGreaterThanOrEqual(remove.minX, band.maxX, "Remove All starts after the notch, \(at)")
                    XCTAssertLessThanOrEqual(digits, count.width, "the count has room for 60, \(at)")
                    XCTAssertEqual(
                        remove.maxX, SurfaceHeaderLayout.gear(bodyWidth: width, notchHeight: notchHeight).minX - 8,
                        accuracy: 0.0001, "8 before the gear's well (§19.16), \(at)"
                    )
                }
            }
        }
    }

    /// The tray is never narrower than the board's 385.3, and is otherwise
    /// exactly what the header's wider side needs, on both sides. Since the
    /// gear joined the tray's header (§19.16) that side is wider than the
    /// board left it, so every notch widens the tray a little; the four tiles
    /// keep the board's margins, centred.
    func testTheTrayWidensOnlyForAWideNotch() {
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            for notchWidth in Self.everyNotchWidth {
                let width = SurfaceLayout.bodySize(
                    for: .tray, bodyWidth: 560, notch: CGSize(width: notchWidth, height: 38)
                ).width
                XCTAssertGreaterThanOrEqual(width, ShelfLayout.referenceBodyWidth)
                XCTAssertEqual(
                    width, max(ShelfLayout.referenceBodyWidth, notchWidth + 2 * ShelfLayout.headerSideRoom()),
                    "\(language), notch \(notchWidth)"
                )
            }
            // With the gear on the tray (§19.16) the header's right side needs
            // more than the board left it, so even the board's own notch
            // widens the tray past 385.3; the tiles stay the board's, centred.
            XCTAssertGreaterThan(
                SurfaceLayout.bodySize(for: .tray, bodyWidth: 560, notch: CGSize(width: 185, height: 38)).width,
                385.3, "the gear's room under the board's notch (\(language))"
            )
        }
        // A widened tray keeps its four tiles on the board's margins, centred.
        let wide: CGFloat = 420
        let viewport = ShelfLayout.viewport(bodyWidth: wide)
        XCTAssertEqual(viewport.width, ShelfLayout.referenceBodyWidth, accuracy: 0.0001)
        XCTAssertEqual(viewport.midX, wide / 2, accuracy: 0.5)
        XCTAssertEqual(ShelfLayout.viewport(bodyWidth: ShelfLayout.referenceBodyWidth).minX, 0)
    }

    // MARK: Clipboard, Translate, Settings

    /// The surfaces' own controls start in the content, which begins under the
    /// row: the Clipboard's search field and Kind filter, Translate's pair row
    /// and cards. Their y is the board's less the header row, so none can ever
    /// reach the notch's band at any width or in either language.
    func testNoSurfaceControlStartsInTheHeaderRow() {
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            for width in widths {
                for control in ClipboardHeader.controlFrames(bodyWidth: width) {
                    XCTAssertGreaterThanOrEqual(control.frame.minY, 0, "\(control.name) is below the header at \(width) in \(language)")
                }
                XCTAssertTrue(
                    ClipboardHeader.filter(bodyWidth: width).minX > ClipboardHeader.searchField.maxX,
                    "the filter is right of the search field at \(width)"
                )
                for control in TranslateLayout.controlFrames(bodyWidth: width) {
                    XCTAssertGreaterThanOrEqual(control.frame.minY, 0, "\(control.name) is below the header at \(width)")
                }
                let bar = TranslateLayout.pairBar(bodyWidth: width)
                for (name, frame) in [("Translate From", bar.from), ("Swap Languages", bar.swap), ("Translate To", bar.to)] {
                    XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(name) is below the header at \(width)")
                }
                XCTAssertEqual(SettingsLayout.sidebarFrame().minY, SettingsLayout.contentTop)
                XCTAssertEqual(SettingsLayout.inContent(SettingsLayout.sidebarFrame()).minY, 8, "46 − 38")
            }
        }
    }

    /// The rows under the strip start at the board's y whatever the notch's
    /// height: the content is placed below the row, not at a fixed offset from
    /// the top of the screen.
    func testTheClipboardListStartsBelowTheStripOnEveryNotch() {
        XCTAssertEqual(ClipboardLayout.listOrigin.y, 84 - 38)
        XCTAssertEqual(ClipboardHeader.searchField.minY, 46 - 38)
        for height in notchHeights {
            let body = SurfaceLayout.bodySize(for: .clipboard, bodyWidth: 560, notch: CGSize(width: 185, height: height))
            // The content under the row is 262 tall on every notch: the body
            // moves with the notch, so the list keeps its room, and the dots
            // have their own band under it (§19.16).
            XCTAssertEqual(body.height - height - SurfaceLayout.pageDotsBand, ClipboardLayout.contentHeight, accuracy: 0.001)
        }
    }
}
