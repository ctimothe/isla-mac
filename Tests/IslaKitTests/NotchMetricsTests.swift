import CoreGraphics
import XCTest
@testable import IslaKit

final class NotchMetricsTests: XCTestCase {
    func testApprovedGeometryAndTimingDriveTheShell() {
        XCTAssertEqual(NotchMetrics.standardBody, CGSize(width: 620, height: 208))
        XCTAssertEqual(NotchMetrics.tallestBody, CGSize(width: 620, height: 400))
        XCTAssertEqual(NotchMetrics.maximumWindow, CGSize(width: 700, height: 444))
        XCTAssertEqual(NotchMetrics.openDelay, 0.05)
        XCTAssertEqual(NotchMetrics.closeDelay, 0.32)
        XCTAssertEqual(NotchMetrics.fastPointerInterval, 1.0 / 60.0)
        XCTAssertEqual(NotchMetrics.idlePointerInterval, 1.0 / 8.0)
        XCTAssertEqual(NotchMetrics.restThreshold, 3.0)
        XCTAssertEqual(NotchMetrics.warmZoneHeight, 260)
        XCTAssertEqual(NotchMetrics.coolMargin, 80)
        XCTAssertEqual(NotchMetrics.collapseRectShrinkDelay, 0.45)
        XCTAssertEqual(NotchMetrics.pointerAwayCollapseDelay, 0.6)
    }

    /// `verifySyntheticNotch` ran only from `install()`, so a display change or
    /// a wake that rebuilt the panel while the built-in display was still
    /// settling drew the synthetic pill on a notched Mac for the rest of the
    /// session (F-047). Every synthetic build now asks again, twice; a build
    /// that a newer one superseded, or one that found the physical notch,
    /// asks nothing — which is also what bounds a rebuild storm to one pair of
    /// looks per live build.
    func testASyntheticBuildSchedulesItsOwnRecheck() {
        XCTAssertEqual(
            NotchController.syntheticRecheckDelays(isPhysical: false, generation: 2, current: 2),
            [1.5, 5.0]
        )
        XCTAssertEqual(
            NotchController.syntheticRecheckDelays(isPhysical: false, generation: 2, current: 3), []
        )
        XCTAssertEqual(
            NotchController.syntheticRecheckDelays(isPhysical: true, generation: 2, current: 2), []
        )
    }

    /// `NotchGeometry.windowSize` used to return a locally computed `size`
    /// that only matched `NotchMetrics.maximumWindow` because of an
    /// `assert()` — which vanishes in Release builds, so the contract held
    /// only in debug. It must return the constant unconditionally.
    @MainActor
    func testWindowSizeAlwaysReturnsTheMaximumWindowContract() {
        // Optional since the geometry has no screen to describe while the
        // system reports none — a real window during display reconfiguration.
        // A test host always has one.
        XCTAssertEqual(NotchGeometry.current()?.windowSize, NotchMetrics.maximumWindow)
    }

    // MARK: - The rail's icon height (Prompter spec 5.1)

    /// The deepest notch the panel is laid out for. `WelcomePane` budgets its
    /// legend column against the same figure.
    private let deepestNotch = NotchGeometry.deepestSupportedNotchHeight
    private var body208: CGFloat { NotchMetrics.standardBody.height }

    private func height(icons: Int, notch: CGFloat) -> CGFloat {
        NotchGeometry.railIconHeight(iconCount: icons, notchHeight: notch, bodyHeight: body208)
    }

    /// Six icons on the smallest body the code supports stay at least 20 pt,
    /// and the rail they make fits the room it is given: every icon, every gap
    /// the VStack puts between children, and the footer gap. The expected
    /// height is asserted through the fit, not through a copy of the formula.
    func testSixIconsStayAtLeastTwentyPointsOnTheSmallestBody() {
        for notch in stride(from: CGFloat(24), through: deepestNotch, by: 1) {
            let icon = height(icons: 6, notch: notch)
            XCTAssertGreaterThanOrEqual(icon, 20, "notch \(notch)")
            XCTAssertLessThanOrEqual(icon, 24)
            XCTAssertLessThanOrEqual(
                NotchGeometry.railHeight(iconCount: 6, iconHeight: icon),
                body208 - notch - NotchGeometry.bodyBottomPadding,
                "six icons at \(icon) overflow the rail at notch \(notch)"
            )
        }
    }

    /// Five icons are exactly what they were before the sixth existed: the full
    /// 24 pt on every notch the panel supports.
    func testFiveIconsAreUnchanged() {
        for notch in stride(from: CGFloat(24), through: deepestNotch, by: 1) {
            XCTAssertEqual(height(icons: 5, notch: notch), 24, "notch \(notch)")
        }
    }

    /// The instance form reads the same one function with the visible count,
    /// so the rail and the Welcome legend cannot disagree with the tests.
    @MainActor
    func testTheGeometryAsksTheVisibleTabCount() throws {
        let geometry = try LabGeometry.make()
        XCTAssertEqual(
            geometry.railIconHeight(prompterEnabled: false),
            NotchGeometry.railIconHeight(
                iconCount: NotchViewModel.Tab.visibleTabs(prompterEnabled: false).count,
                notchHeight: geometry.notchSize.height, bodyHeight: geometry.expandedSize.height
            )
        )
        XCTAssertLessThanOrEqual(
            geometry.railIconHeight(prompterEnabled: true), geometry.railIconHeight(prompterEnabled: false)
        )
        XCTAssertGreaterThanOrEqual(geometry.railIconHeight(prompterEnabled: true), 20)
    }
}
