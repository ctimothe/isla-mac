import XCTest
@testable import DynamicIslandKit

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
}
