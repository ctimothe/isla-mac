import CoreGraphics
import XCTest
@testable import DynamicIslandKit

/// The panel's width is a preference. The window it is drawn in is not.
final class PanelWidthTests: XCTestCase {

    func testTheStoredWidthIsClampedToWhatTheRailAndContentCanHold() {
        let suite = "PanelWidthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NotchViewModel.bodyWidth(in: defaults), NotchMetrics.defaultBodyWidth)
        XCTAssertEqual(NotchMetrics.defaultBodyWidth, 560)

        defaults.set(9_000.0, forKey: NotchViewModel.bodyWidthKey)
        XCTAssertEqual(NotchViewModel.bodyWidth(in: defaults), NotchMetrics.maximumBodyWidth)

        defaults.set(10.0, forKey: NotchViewModel.bodyWidthKey)
        XCTAssertEqual(NotchViewModel.bodyWidth(in: defaults), NotchMetrics.minimumBodyWidth)

        defaults.set(-1.0, forKey: NotchViewModel.bodyWidthKey)
        XCTAssertEqual(
            NotchViewModel.bodyWidth(in: defaults), NotchMetrics.defaultBodyWidth,
            "a nonsense value falls back rather than clamping to the floor"
        )

        defaults.set(517.0, forKey: NotchViewModel.bodyWidthKey)
        XCTAssertEqual(NotchViewModel.bodyWidth(in: defaults), 517)
    }

    /// The window never changes size. That is the whole reason the lock card was
    /// given a window of its own: a panel window resized across a lock had its
    /// window-server snapshot stretched. A narrower body has to come out of the
    /// padding, never out of the frame.
    func testTheWindowIsTheSameSizeAtEveryBodyWidth() {
        XCTAssertEqual(NotchMetrics.maximumWindow, CGSize(width: 700, height: 444))
        for width in [NotchMetrics.minimumBodyWidth, NotchMetrics.defaultBodyWidth, NotchMetrics.maximumBodyWidth] {
            XCTAssertLessThanOrEqual(
                width + 80, NotchMetrics.maximumWindow.width,
                "the 40pt of padding on each side has to still fit a \(width) pt body"
            )
        }
        XCTAssertEqual(NotchMetrics.body(width: 512), CGSize(width: 512, height: 208))
    }

    /// The compact pill lives inside the same body, so it moves with it.
    func testThePillNeverOutgrowsTheBodyItTurnsInto() {
        let notch = CGSize(width: 200, height: 32)
        let narrow = CompactMediaActivity.playing.bodySize(
            notchSize: notch, peeking: true, bodyWidth: NotchMetrics.minimumBodyWidth
        )
        XCTAssertEqual(narrow.width, NotchMetrics.minimumBodyWidth)

        let wide = CompactMediaActivity.playing.bodySize(
            notchSize: notch, peeking: true, bodyWidth: NotchMetrics.maximumBodyWidth
        )
        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertLessThanOrEqual(wide.width, NotchMetrics.maximumBodyWidth)
    }
}
