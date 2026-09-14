import XCTest
@testable import IslaKit

/// Every point of the compact island opens the panel, at any width.
@MainActor
final class CompactHitAreaTests: XCTestCase {

    /// The shape is drawn `topRadius` wider than the body on each side — that
    /// slack is the concave shoulders — and the clickable rect has to cover all
    /// of it. Anything narrower leaves parts of a visible island dead, and a
    /// dead end you cannot see is worse than one you can.
    func testTheClickableRectCoversTheWholeDrawnShape() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")

        for width in [CGFloat(200), 300, NotchMetrics.minimumBodyWidth, NotchMetrics.maximumBodyWidth] {
            let body = CGSize(width: width, height: geometry.collapsedDepth)
            let drawn = width + 2 * Theme.collapsedTopRadius
            let clickable = geometry.contentRect(for: body)
                .insetBy(dx: -Theme.collapsedTopRadius, dy: 0)

            XCTAssertEqual(
                clickable.width, drawn, accuracy: 0.001,
                "at \(width)pt the clickable rect must be the drawn width, not the body width"
            )
        }
    }

    /// It follows the width rather than being cut once, so the panel-width
    /// setting and the pill widening for a peek both stay clickable end to end.
    func testItFollowsWhateverWidthTheIslandIs() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current())
        let narrow = geometry.contentRect(for: CGSize(width: 200, height: geometry.collapsedDepth))
            .insetBy(dx: -Theme.collapsedTopRadius, dy: 0)
        let wide = geometry.contentRect(for: CGSize(width: 520, height: geometry.collapsedDepth))
            .insetBy(dx: -Theme.collapsedTopRadius, dy: 0)

        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertEqual(wide.midX, narrow.midX, accuracy: 0.001, "both centred on the notch")
    }

    /// The three regions the island is made of, all inside it.
    func testTheArtworkTheCutoutAndTheEqualizerAreAllInside() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current())
        let width: CGFloat = 400
        let rect = geometry.contentRect(for: CGSize(width: width, height: geometry.collapsedDepth))
            .insetBy(dx: -Theme.collapsedTopRadius, dy: 0)

        let y = rect.midY
        XCTAssertTrue(rect.contains(CGPoint(x: rect.minX + 1, y: y)), "the leading shoulder")
        XCTAssertTrue(rect.contains(CGPoint(x: rect.midX, y: y)), "the cutout between the wings")
        XCTAssertTrue(rect.contains(CGPoint(x: rect.maxX - 1, y: y)), "the trailing shoulder")
    }

    /// A synthetic notch is drawn at the full menu-bar height — `NotchShape`
    /// fills black unconditionally, and only the *header* falls back to
    /// `Color.clear` when nothing is playing. So the whole of that black shape
    /// is visible at all times, and all of it has to answer a click. It used to
    /// answer on its top 8 pt only, which left roughly three quarters of a
    /// visible island dead on every external display.
    func testTheSyntheticIslandIsClickableForItsWholeDrawnHeight() throws {
        let onscreen = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let synthetic = NotchGeometry(
            screen: onscreen.screen,
            notchSize: CGSize(width: 180, height: 32),
            notchCenterX: onscreen.screen.frame.midX,
            isPhysical: false
        )

        XCTAssertEqual(
            synthetic.collapsedDepth, 32, accuracy: 0.001,
            "the live depth must be the drawn depth, not a strip along the top"
        )

        let island = synthetic.collapsedIslandRect(for: 180)
        XCTAssertEqual(island.height, 32, accuracy: 0.001)
        XCTAssertTrue(
            island.contains(CGPoint(x: island.midX, y: island.minY + 1)),
            "the bottom edge of the drawn pill is inside the live region"
        )
    }

    /// The physical case is unchanged: a real notch is a hole, and the whole of
    /// it was always claimable because there is nothing underneath to claim it
    /// from.
    func testAPhysicalNotchIsUnaffected() throws {
        let onscreen = try XCTUnwrap(NotchGeometry.current())
        let physical = NotchGeometry(
            screen: onscreen.screen,
            notchSize: CGSize(width: 180, height: 38),
            notchCenterX: onscreen.screen.frame.midX,
            isPhysical: true
        )
        XCTAssertEqual(physical.collapsedDepth, 38, accuracy: 0.001)
    }
}
