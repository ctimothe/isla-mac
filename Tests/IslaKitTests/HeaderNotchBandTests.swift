import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// No header control sits under the notch (driver correction, review 2026-10-15).
///
/// Body coordinates start at the top of the screen. The first `notchSize.height`
/// points — 38 on a 14-inch — are the header row, and the notch, 185 to 220 pt
/// wide and centred on the body, occupies the middle of it; Isla draws a
/// synthetic one on a Mac that has none, so the middle of the header is never
/// free. The redesign spec put the Clipboard's Kind filter at (212, 9) and its
/// search field at (250, 8), and on hardware both were largely hidden.
///
/// This holds the whole app's header controls once, at 480, 560 and 620 and at
/// both notch widths, against a band 8 pt wider than the notch each side: the
/// Clipboard's tools and filter row, the Shelf's count and Expand, the lyric
/// header's three tools, Translate's History and Expand, and the player's source tag.
@MainActor
final class HeaderNotchBandTests: XCTestCase {
    private let widths: [CGFloat] = [480, 560, 620]
    private let notchWidths: [CGFloat] = [185, 220]
    private let notchHeight: CGFloat = PlayerLayout.referenceHeaderHeight

    override func tearDown() {
        LabLocalization.use("en")
        super.tearDown()
    }

    private func band(bodyWidth: CGFloat, notchWidth: CGFloat) -> CGRect {
        CGRect(
            x: bodyWidth / 2 - notchWidth / 2 - 8, y: 0,
            width: notchWidth + 16, height: notchHeight
        )
    }

    /// Each control, drawn at `width`, against both notch widths' bands; `name`
    /// says which one failed where.
    private func assertClear(
        at width: CGFloat, _ controls: [(name: String, frame: CGRect)], file: StaticString = #filePath, line: UInt = #line
    ) {
        for notch in notchWidths {
            let band = band(bodyWidth: width, notchWidth: notch)
            for control in controls {
                XCTAssertFalse(
                    control.frame.intersects(band),
                    "\(control.name) \(control.frame) is under the notch band \(band) at body \(width), notch \(notch)",
                    file: file, line: line
                )
            }
        }
    }

    func testTheBandIsWhereTheNotchIs() {
        let band = band(bodyWidth: 560, notchWidth: 185)
        XCTAssertEqual(band.minX, 280 - 92.5 - 8)
        XCTAssertEqual(band.maxX, 280 + 92.5 + 8)
        XCTAssertEqual(band.height, 38)
    }

    // MARK: Clipboard

    func testNoClipboardControlReachesTheNotch() {
        for width in widths {
            for searching in [false, true] {
                let frames = ClipboardHeader.controlFrames(bodyWidth: width, isSearching: searching)
                for notch in notchWidths {
                    let band = band(bodyWidth: width, notchWidth: notch)
                    for control in frames {
                        XCTAssertFalse(
                            control.frame.intersects(band),
                            "\(control.name) \(control.frame) is under the notch band at \(width), notch \(notch), searching \(searching)"
                        )
                        if control.isTrailingTool {
                            XCTAssertGreaterThan(control.frame.minX, band.maxX, "\(control.name) is right of the notch")
                        } else {
                            XCTAssertGreaterThanOrEqual(control.frame.minY, notchHeight, "\(control.name) is below the header")
                        }
                    }
                }
            }
        }
    }

    func testTheClipboardFilterRowIsBelowTheHeaderWithWordsInEnglishAndRussian() {
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            for width in widths {
                XCTAssertGreaterThanOrEqual(ClipboardHeader.filter(bodyWidth: width).minY, notchHeight, language)
                XCTAssertGreaterThanOrEqual(ClipboardHeader.searchField(bodyWidth: width).minY, notchHeight, language)
                XCTAssertTrue(
                    ClipboardHeader.filterRow(bodyWidth: width).contains(ClipboardHeader.filter(bodyWidth: width)),
                    "the control sits inside the row at \(width) in \(language)"
                )
            }
        }
    }

    /// Re-review 2026-10-15: the row followed a fixed 44, so a header above 38
    /// could reach it. Headers of 32, 38 and 50: the row and the list start
    /// below the header at every width and in both searching states.
    func testTheClipboardFilterRowFollowsTheHeaderHeight() {
        for header: CGFloat in [32, 38, 50] {
            for width in widths {
                XCTAssertEqual(ClipboardHeader.filterRow(bodyWidth: width, headerHeight: header).minY, header + 6)
                XCTAssertEqual(ClipboardLayout.listOrigin(headerHeight: header).y, header + 36)
                for searching in [false, true] {
                    for control in ClipboardHeader.controlFrames(bodyWidth: width, isSearching: searching, headerHeight: header)
                    where !control.isTrailingTool {
                        XCTAssertGreaterThanOrEqual(control.frame.minY, header, "\(control.name) at header \(header), width \(width)")
                    }
                }
            }
        }
        XCTAssertEqual(ClipboardLayout.listOrigin(headerHeight: 38), ClipboardLayout.listOrigin)
        XCTAssertEqual(ClipboardLayout.listOriginWithoutFilterRow(headerHeight: 38), ClipboardLayout.listOriginWithoutFilterRow)
    }

    // MARK: Shelf

    func testTheShelfCountAndExpandStayRightOfTheNotch() {
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            // The Shelf holds 60 at most. Russian read "Объектов: 60" until this
            // test found it 1 pt inside the band at 480 with the widest notch;
            // "Всего: 60" is 14 pt shorter and clears it.
            for count in [1, 12, 60] {
                let text = ShelfHeader.countText(count)
                let textWidth = ShelfTileName.measure(text, selected: true)
                for width in widths {
                    assertClear(at: width, [
                        ("Shelf count \"\(text)\" (\(language))", ShelfHeader.countFrame(bodyWidth: width, textWidth: textWidth)),
                        ("Shelf Expand", HeaderToolFrames.expand(bodyWidth: width)),
                    ])
                }
            }
        }
    }

    // MARK: Lyrics

    func testTheLyricHeaderToolsStayRightOfTheNotch() {
        for width in widths {
            assertClear(at: width, [
                ("Show Translation", HeaderToolFrames.showTranslation(bodyWidth: width)),
                ("More", HeaderToolFrames.more(bodyWidth: width)),
                ("Expand", HeaderToolFrames.expand(bodyWidth: width)),
            ])
        }
    }

    // MARK: Translate

    /// Translate's header tools (redesign 2026-10-15, spec §11): History at
    /// (`bw − 67`, 8) and Expand beside it, both right of the notch at every width
    /// and both notch widths, and clear of each other. The pair bar and the cards
    /// are below the header, from y 46.
    func testTheTranslateHeaderToolsStayRightOfTheNotch() {
        for width in widths {
            let history = TranslateHeader.history(bodyWidth: width)
            let expand = HeaderToolFrames.expand(bodyWidth: width)
            XCTAssertEqual(history, CGRect(x: width - 67, y: 8, width: 22, height: 22))
            XCTAssertFalse(history.intersects(expand), "History and Expand at \(width)")
            assertClear(at: width, [("History", history), ("Expand", expand)])
            let bar = TranslateLayout.pairBar(bodyWidth: width, headerHeight: notchHeight)
            for (name, frame) in [("Translate From", bar.from), ("Swap Languages", bar.swap), ("Translate To", bar.to)] {
                XCTAssertGreaterThanOrEqual(frame.minY, notchHeight, "\(name) is below the header at \(width)")
            }
        }
    }

    // MARK: Settings

    /// The Settings header carries no control at any width — no Expand (the body is
    /// always 400), no tools — so nothing of the redesign's sidebar and form can be
    /// under the notch, and the one thing in the strip, the tab's title at the
    /// leading edge, stays left of the band in both languages at every width and
    /// both notch widths (redesign 2026-10-15, spec §10).
    func testSettingsHeaderHasNoControlAndItsTitleStaysLeftOfTheNotch() {
        XCTAssertTrue(SettingsLayout.headerControlFrames.isEmpty, "a control added to the strip has to be listed and held here")
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            // The strip draws the title in capitals at the caption role, semibold,
            // tracked (`NotchContentView.headerRow`), from 16 pt in.
            let title = NotchViewModel.Tab.settings.title.uppercased()
            let font = NSFont.systemFont(ofSize: Theme.TypeRole.caption.size, weight: .semibold)
            let measured = (title as NSString).size(withAttributes: [.font: font]).width
                + Theme.capsTracking * CGFloat(title.count)
            let frame = CGRect(x: 16, y: 0, width: measured, height: notchHeight)
            for width in widths {
                assertClear(at: width, [("Settings title (\(language))", frame)])
            }
        }
    }

    // MARK: Player

    /// The source tag: the equalizer, 8 pt, the 18 pt icon, 1 pt, and the
    /// header's 16 pt trailing padding.
    func testThePlayerSourceTagStaysRightOfTheNotch() {
        for width in widths {
            let iconRight = width - 16 - 1
            let icon = CGRect(x: iconRight - NotchContentView.sourceIconSide, y: 10, width: NotchContentView.sourceIconSide, height: NotchContentView.sourceIconSide)
            let equalizer = CGRect(
                x: icon.minX - 8 - CompactIslandLayout.equalizerSide, y: 12,
                width: CompactIslandLayout.equalizerSide, height: CompactIslandLayout.equalizerSide
            )
            assertClear(at: width, [("Source icon", icon), ("Equalizer", equalizer)])
        }
    }
}
