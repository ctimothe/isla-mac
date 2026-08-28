import AppKit
import XCTest
@testable import IslaKit

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

    /// The window is a little bigger than the card, so its edge is never the
    /// thing that clips a rounded corner.
    ///
    /// It was 48pt when the card carried two drop shadows. Cut to exactly the
    /// card, those shadows had nowhere outside to fall and were clipped square
    /// — measured on the running app, the drawn footprint held a constant
    /// 459pt width top to bottom, bottom corners inset 5pt where a 30pt radius
    /// wants about 19. The shadows are gone now, because the system's own lock
    /// player has none; the margin stays small and the corners stay round.
    func testTheWindowLeavesRoomForTheCardsShadow() {
        XCTAssertEqual(
            LockCardWindow.windowSize,
            CGSize(
                width: LockScreenCard.size.width + LockCardWindow.shadowMargin * 2,
                height: LockScreenCard.size.height + LockCardWindow.shadowMargin * 2
            )
        )
        // Small, but never zero: a window flush with the card clips its own
        // rounded edge.
        XCTAssertGreaterThan(LockCardWindow.shadowMargin, 0)
        XCTAssertLessThanOrEqual(
            LockCardWindow.shadowMargin, 16,
            "the drop shadows are gone; this should not creep back up"
        )
    }

    /// And every point of that margin belongs to whatever is underneath, which
    /// while locked is the password field.
    func testTheTransparentMarginTakesNoClicks() {
        let card = CGRect(
            x: LockCardWindow.shadowMargin, y: LockCardWindow.shadowMargin,
            width: LockScreenCard.size.width, height: LockScreenCard.size.height
        )
        let root = LockCardRootView(
            frame: CGRect(origin: .zero, size: LockCardWindow.windowSize)
        )
        root.cardRect = card

        XCTAssertNil(root.hitTest(NSPoint(x: 4, y: 4)), "the corner of the margin")
        XCTAssertNil(
            root.hitTest(NSPoint(x: card.midX, y: 8)),
            "directly below the card, where the shadow is drawn"
        )
        XCTAssertNotNil(
            root.hitTest(NSPoint(x: card.midX, y: card.midY)),
            "the card itself still answers"
        )
    }
}
