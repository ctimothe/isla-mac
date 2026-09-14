import CoreGraphics
import XCTest
@testable import IslaKit

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

    /// Committing is the write-side twin of the read-side clamp above. The
    /// slider hands over whatever tick it is on — fractional, and in range by
    /// construction — but the commit contract has to hold on its own, because
    /// the same call is the only sanctioned writer of the key: round, clamp,
    /// persist, and say what was persisted, so the view can rebuild against
    /// the width that is actually on disk rather than the one it asked for.
    func testCommittingAWidthClampsItToWhatTheBodyCanHoldAndPersistsThat() {
        let suite = "PanelWidthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NotchViewModel.commitBodyWidth(300, into: defaults), NotchMetrics.minimumBodyWidth)
        XCTAssertEqual(defaults.double(forKey: NotchViewModel.bodyWidthKey), Double(NotchMetrics.minimumBodyWidth))

        XCTAssertEqual(NotchViewModel.commitBodyWidth(700, into: defaults), NotchMetrics.maximumBodyWidth)
        XCTAssertEqual(defaults.double(forKey: NotchViewModel.bodyWidthKey), Double(NotchMetrics.maximumBodyWidth))
    }

    /// The slider writes fractional ticks, and the pane rounds each one before
    /// anything is persisted. The commit carries that rounding so the contract
    /// does not depend on the caller remembering to round first: a half-point
    /// persisted here would read back as a half-point panel, which is a width
    /// nobody asked for.
    func testCommittingAFractionalWidthRoundsItTheWayTheSliderAlwaysHas() {
        let suite = "PanelWidthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NotchViewModel.commitBodyWidth(517.4, into: defaults), 517)
        XCTAssertEqual(NotchViewModel.commitBodyWidth(517.6, into: defaults), 518)
    }

    /// Round-trip on empty defaults: a commit does not need the key to exist
    /// and removes nothing — it writes the width where `bodyWidth(in:)` looks,
    /// so a panel built after the drag agrees with the drag.
    func testCommittingIntoEmptyDefaultsWritesWhereTheReaderLooks() {
        let suite = "PanelWidthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(defaults.object(forKey: NotchViewModel.bodyWidthKey))
        XCTAssertEqual(NotchViewModel.commitBodyWidth(600, into: defaults), 600)
        XCTAssertNotNil(defaults.object(forKey: NotchViewModel.bodyWidthKey))
        XCTAssertEqual(NotchViewModel.bodyWidth(in: defaults), 600)
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
