import XCTest
@testable import IslaKit

final class ScrubPreviewTests: XCTestCase {
    // MARK: fraction

    func testFractionClampsBelowZeroAndAboveWidth() {
        XCTAssertEqual(ScrubPreview.fraction(x: -20, width: 200, duration: 100), 0)
        XCTAssertEqual(ScrubPreview.fraction(x: 250, width: 200, duration: 100), 1)
    }

    func testFractionMapsMidpointToHalf() {
        XCTAssertEqual(ScrubPreview.fraction(x: 100, width: 200, duration: 100), 0.5)
    }

    func testFractionIsNilWithoutDurationOrWidth() {
        // A live stream reports duration 0 and must show no preview.
        XCTAssertNil(ScrubPreview.fraction(x: 50, width: 200, duration: 0))
        XCTAssertNil(ScrubPreview.fraction(x: 50, width: 0, duration: 100))
        XCTAssertNil(ScrubPreview.fraction(x: 50, width: 200, duration: -1))
    }

    // MARK: bubbleCenterX

    func testBubbleCenterClampsAtBothEdges() {
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 0, width: 200, bubbleWidth: 40), 20)
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 200, width: 200, bubbleWidth: 40), 180)
    }

    func testBubbleCenterPassesThroughMidBar() {
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 77, width: 200, bubbleWidth: 40), 77)
    }

    func testBubbleCenterPinsToCenterWhenBarNarrowerThanBubble() {
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 3, width: 30, bubbleWidth: 40), 15)
    }
}
