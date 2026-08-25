import XCTest
@testable import DynamicIslandKit

/// What lights is what the pointer is actually on.
@MainActor
final class HoverRectTests: XCTestCase {

    /// The open target is padded so a near miss still opens the panel. The
    /// appearance must not be: driven from the padded rect, the island lit up
    /// while the cursor was visibly beside it.
    func testTheHoverRectIsTighterThanTheOpenTarget() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let width: CGFloat = 300

        let island = geometry.collapsedIslandRect(for: width)
        let target = geometry.collapsedHoverRect(for: width)

        XCTAssertEqual(island.width, width, "the drawn island is exactly its width")
        XCTAssertGreaterThan(target.width, island.width, "the open target is forgiving")
        XCTAssertTrue(target.insetBy(dx: -1, dy: -1).contains(island),
                      "and it contains the island rather than sitting beside it")
    }

    /// A point just outside the island but inside the padded target must open
    /// the panel and light nothing — that gap is the whole bug.
    func testAPointBesideTheIslandIsNotHovering() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current())
        let width: CGFloat = 300
        let island = geometry.collapsedIslandRect(for: width)
        let target = geometry.collapsedHoverRect(for: width)

        let beside = CGPoint(x: island.maxX + 3, y: island.midY)
        XCTAssertFalse(island.contains(beside), "not on the island")
        XCTAssertTrue(target.contains(beside), "but still close enough to open it")
    }
}
