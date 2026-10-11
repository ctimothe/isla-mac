import AppKit
import XCTest
@testable import IslaKit

// The tab's geometry at the three panel widths (plan T10, the T7 design note).
// All arithmetic, no window: the pane's size is derived the way
// `NotchContentView` derives it (the body's padding, the 30 pt rail, the 14 pt
// gap), and the metrics the views lay themselves out with are the ones tested
// here, so a row cannot grow past the body without a test saying so.
//
// Text widths are measured with AppKit at the panel's own type roles, in both
// languages, from the shipped tables rather than from a copy of them.

final class PrompterTabLayoutTests: XCTestCase {
    private let widths: [CGFloat] = [480, 560, 620]
    /// The shallowest and the deepest notch the body is laid out for
    /// (`NotchGeometry.deepestSupportedNotchHeight` is the 40).
    private let notches: [CGFloat] = [32, 38, NotchGeometry.deepestSupportedNotchHeight]

    // MARK: The pane

    func testThePaneIsWhatTheBodyLeavesAfterTheRailAndTheNotch() {
        let size = PrompterTabMetrics.paneSize(bodyWidth: 480, notchHeight: 38)
        XCTAssertEqual(size.width, 480 - 28 - 30 - 14)
        XCTAssertEqual(size.height, NotchMetrics.standardBodyHeight - 38 - NotchGeometry.bodyBottomPadding)
    }

    func testEveryRowFitsInsideTheBodyAtEveryWidthAndNotch() {
        for width in widths {
            for notch in notches {
                let pane = PrompterTabMetrics.paneSize(bodyWidth: width, notchHeight: notch)
                let layout = PrompterTabMetrics.layout(in: pane)
                let name = "\(width) pt body, \(notch) pt notch"
                let rows = [layout.scriptRow, layout.chipRow, layout.editor, layout.quietLine, layout.controlRow]

                var previousBottom: CGFloat = 0
                for row in rows {
                    XCTAssertGreaterThanOrEqual(row.minY, previousBottom, "rows do not overlap: \(name)")
                    XCTAssertGreaterThanOrEqual(row.height, 0, name)
                    XCTAssertLessThanOrEqual(row.maxX, pane.width + 0.001, "no row is wider than the pane: \(name)")
                    previousBottom = row.maxY
                }
                XCTAssertLessThanOrEqual(previousBottom, pane.height + 0.001, "nothing reaches past the body: \(name)")
                XCTAssertLessThanOrEqual(
                    notch + previousBottom + NotchGeometry.bodyBottomPadding,
                    NotchMetrics.standardBodyHeight + 0.001,
                    "the tab plus the notch and padding is within the 208 pt body: \(name)"
                )
                XCTAssertGreaterThanOrEqual(
                    layout.editor.height, PrompterTabMetrics.minimumEditorHeight,
                    "the editor keeps room for about three lines: \(name)"
                )
            }
        }
    }

    func testTheEditorTakesWhatTheFixedRowsLeave() {
        let pane = PrompterTabMetrics.paneSize(bodyWidth: 560, notchHeight: 38)
        let layout = PrompterTabMetrics.layout(in: pane)
        let fixed = layout.scriptRow.height + layout.chipRow.height + layout.quietLine.height + layout.controlRow.height
        XCTAssertEqual(layout.editor.height, pane.height - fixed - 4 * PrompterTabMetrics.rowGap, accuracy: 0.001)
        XCTAssertEqual(layout.editor.width, pane.width)
    }

    func testTheControlsAreAtLeastThePanelsMinimumTarget() {
        XCTAssertGreaterThanOrEqual(PrompterTabMetrics.controlRowHeight, Theme.minimumHitSize.height)
        XCTAssertGreaterThanOrEqual(PrompterTabMetrics.chipHeight, Theme.minimumHitSize.height)
        XCTAssertGreaterThanOrEqual(PrompterTabMetrics.scriptRowHeight, Theme.minimumHitSize.height)
        XCTAssertGreaterThanOrEqual(PrompterTabMetrics.addButtonWidth, Theme.minimumHitSize.width)
        XCTAssertGreaterThanOrEqual(PrompterTabMetrics.chipWidth(index: 0, read: false), Theme.minimumHitSize.width)
    }

    // MARK: Start is never truncated

    private func table(_ locale: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(
            pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";"#, options: .anchorsMatchLines
        )
        var result: [String: String] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            result[String(text[key])] = String(text[value])
        }
        return result
    }

    private func width(of text: String, role: Theme.TypeRole, weight: NSFont.Weight = .semibold) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: role.size, weight: weight)]).width.rounded(.up)
    }

    func testTheControlRowFitsAtTheNarrowestWidthInBothLanguages() throws {
        let pane = PrompterTabMetrics.paneSize(bodyWidth: 480, notchHeight: NotchGeometry.deepestSupportedNotchHeight)
        for locale in ["en", "ru"] {
            let strings = try table(locale)
            for key in ["Start", "Resume"] {
                let label = try XCTUnwrap(strings[key], "\(locale) has \(key)")
                let start = PrompterTabMetrics.startControlWidth(labelWidth: width(of: label, role: .body))
                XCTAssertLessThanOrEqual(
                    PrompterTabMetrics.controlRowMinimumWidth(startWidth: start), pane.width,
                    "\(locale) \(key): the stepper and the primary control fit one row without the label breaking"
                )
            }
        }
    }

    func testTheStartControlNeverShrinksBelowItsWord() {
        let start = PrompterTabMetrics.startControlWidth(labelWidth: 50)
        XCTAssertGreaterThanOrEqual(start, 50 + 2 * PrompterTabMetrics.startHorizontalPadding)
        XCTAssertGreaterThanOrEqual(start, PrompterTabMetrics.minimumStartWidth)
    }

    // MARK: The quiet line

    /// The capture chip and the word count share one 14 pt line. At the
    /// narrowest panel both, in the longest wording either language has, still
    /// fit side by side; a message (a limit, a failed save) takes the line
    /// alone.
    func testTheChipAndTheCountShareTheQuietLineAtTheNarrowestWidth() throws {
        let pane = PrompterTabMetrics.paneSize(bodyWidth: 480, notchHeight: NotchGeometry.deepestSupportedNotchHeight)
        for locale in ["en", "ru"] {
            let strings = try table(locale)
            let chip = try ["Hidden from screen sharing", "Visible when sharing"].map { key -> CGFloat in
                width(of: try XCTUnwrap(strings[key], "\(locale) has \(key)"), role: .caption, weight: .regular)
            }.max() ?? 0
            let format = try XCTUnwrap(strings["Words: %d · %@"], "\(locale) has the count format")
            let count = width(of: String(format: format, 99_999, "99:59"), role: .caption, weight: .regular)
            XCTAssertLessThanOrEqual(
                PrompterTabMetrics.chipIconWidth + chip + PrompterTabMetrics.quietLineGap + count,
                pane.width,
                "\(locale): the chip and a five-digit count fit one line at 480 pt"
            )
        }
    }

    // MARK: Page chips wrap by scrolling

    func testFewChipsNeedNoScrollingAndManyScrollInsteadOfOverflowing() {
        let pane = PrompterTabMetrics.paneSize(bodyWidth: 480, notchHeight: 38)
        let few = PrompterTabMetrics.chipStrip(count: 4, readCount: 0, paneWidth: pane.width)
        XCTAssertFalse(few.scrolls)
        XCTAssertEqual(few.width, PrompterTabMetrics.chipStripWidth(count: 4, readCount: 0))

        for count in [20, 200] {
            let many = PrompterTabMetrics.chipStrip(count: count, readCount: count, paneWidth: pane.width)
            XCTAssertTrue(many.scrolls, "\(count) chips do not fit 408 pt")
            XCTAssertLessThanOrEqual(many.width, pane.width, "the strip is clipped to the row; it never pushes the controls off")
            XCTAssertGreaterThan(many.width, 0)
        }
    }

    func testTheChipStripLeavesRoomForTheAddAndDeleteControls() {
        for width in widths {
            let pane = PrompterTabMetrics.paneSize(bodyWidth: width, notchHeight: 38)
            let strip = PrompterTabMetrics.chipStrip(count: 200, readCount: 0, paneWidth: pane.width)
            XCTAssertLessThanOrEqual(
                strip.width + PrompterTabMetrics.chipRowGap + PrompterTabMetrics.addButtonWidth
                    + PrompterTabMetrics.chipRowGap + PrompterTabMetrics.deleteControlWidth,
                pane.width + 0.001,
                "\(width): the strip, + and Delete Page share the row"
            )
        }
    }

    func testChipsGrowWithTheirNumberAndTheirReadMark() {
        XCTAssertLessThan(
            PrompterTabMetrics.chipWidth(index: 0, read: false), PrompterTabMetrics.chipWidth(index: 99, read: false),
            "page 100 has three digits"
        )
        XCTAssertLessThan(
            PrompterTabMetrics.chipWidth(index: 0, read: false), PrompterTabMetrics.chipWidth(index: 0, read: true)
        )
    }

    // MARK: Whole-tab blocks

    func testTheAlertAndTheEmptyStateFitTheDeepestNotchAtTheNarrowestWidth() {
        let pane = PrompterTabMetrics.paneSize(bodyWidth: 480, notchHeight: NotchGeometry.deepestSupportedNotchHeight)
        XCTAssertLessThanOrEqual(PrompterTabMetrics.alertBlockHeight, pane.height)
        XCTAssertLessThanOrEqual(PrompterTabMetrics.emptyStateHeight, pane.height)
        XCTAssertLessThanOrEqual(PrompterTabMetrics.alertTextWidth, pane.width)
    }

    func testTheAlertsTextFitsItsBlockInBothLanguages() throws {
        let all = [
            PrompterLibraryNotice.unreadable(corruptCopy: nil), .unreadable(corruptCopy: "library.corrupt-1.json"),
            .newerVersion(2), .writeFailed,
        ]
        for locale in ["en", "ru"] {
            let strings = try table(locale)
            // The refusal of a new library takes the explanation's place in
            // the same block (ruling 20.6 #4).
            let keys = all.filter(\.blocksTheTab).map(\.detailKey) + [PrompterTabModel.newLibraryRefusalKey]
            for detailKey in keys {
                let detail = try XCTUnwrap(strings[detailKey], "\(locale) has \(detailKey.prefix(30))")
                let font = NSFont.systemFont(ofSize: Theme.TypeRole.body.size)
                let rect = (detail as NSString).boundingRect(
                    with: CGSize(width: PrompterTabMetrics.alertTextWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], attributes: [.font: font]
                )
                XCTAssertLessThanOrEqual(
                    rect.height.rounded(.up), PrompterTabMetrics.alertDetailHeight,
                    "\(locale): the explanation fits its lines without clipping"
                )
            }
        }
    }
}
