import XCTest
@testable import IslaKit

final class NotchControllerTests: XCTestCase {
    /// The Edit Lyrics sheet holds the panel open. The pointer watcher counted
    /// drags, menus and held presses as reasons to stay, but not a sheet, so
    /// moving down to the editor's lower fields left the hover rect and folded
    /// the panel, unsaved edits and all (G-012).
    func testAnAttachedSheetHoldsThePanelOpen() {
        XCTAssertTrue(NotchController.holdsOpen(
            receivingDrag: false, draggingOut: false, menuOpen: false, pressHeld: false, sheetAttached: true
        ))
        XCTAssertFalse(NotchController.holdsOpen(
            receivingDrag: false, draggingOut: false, menuOpen: false, pressHeld: false, sheetAttached: false
        ), "and nothing at all holds nothing")
        for reason in 0..<4 {
            XCTAssertTrue(NotchController.holdsOpen(
                receivingDrag: reason == 0, draggingOut: reason == 1, menuOpen: reason == 2,
                pressHeld: reason == 3, sheetAttached: false
            ), "the reasons that held it before still do")
        }
    }
}
