import AppKit
import XCTest
@testable import DynamicIslandKit

/// Where the lock card's own window goes.
///
/// It used to be the notch panel grown to the size of the display, with the
/// card centred inside it by SwiftUI — which meant every lock resized a live
/// window across the moment the shield goes up, and a resize the window server
/// deferred left the card drawn at a fraction of its size, off to one side. The
/// window is the card now, so its placement is one piece of arithmetic with
/// nothing to defer.
@MainActor
final class LockCardWindowTests: XCTestCase {
    func testTheCardSitsAtTheCentreOfItsDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = LockCardWindow.frame(on: screen, size: LockScreenCard.size)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.midY, screen.midY)
        XCTAssertEqual(frame.size, LockScreenCard.size, "the window is exactly the card")
    }

    /// The notch is not always on the display whose origin is zero.
    func testTheCardFollowsTheDisplayItBelongsTo() {
        let secondary = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let frame = LockCardWindow.frame(on: secondary, size: LockScreenCard.size)
        XCTAssertEqual(frame.midX, secondary.midX)
        XCTAssertEqual(frame.midY, secondary.midY)
        XCTAssertTrue(secondary.contains(frame), "the card must land on its own display")
    }

    /// Whole points, so the glass and its 1pt rim land on the pixel grid
    /// instead of straddling it.
    func testThePlacementIsWholePoints() {
        let odd = CGRect(x: 0, y: 0, width: 1511, height: 981)
        let frame = LockCardWindow.frame(on: odd, size: LockScreenCard.size)
        XCTAssertEqual(frame.origin.x, frame.origin.x.rounded())
        XCTAssertEqual(frame.origin.y, frame.origin.y.rounded())
    }
}
