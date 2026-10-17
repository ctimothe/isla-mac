import XCTest
@testable import IslaKit

/// Show Isla and Show Lyrics open and never close.
///
/// Both intents called the hot keys' toggles, so a Shortcut or Focus
/// automation titled *Show* that ran while the panel was already open closed
/// it, and Show Lyrics folded the lyrics stage back to the player (F-024). The
/// hot keys keep their toggles — one key is the whole round trip there — and
/// the intents and the reopen route ask these verdicts instead.
final class ShowRouteTests: XCTestCase {

    func testShowLeavesAnOpenPanelAlone() {
        XCTAssertEqual(NotchViewModel.showVerdict(isOpen: true), .alreadyOpen)
        XCTAssertEqual(NotchViewModel.showVerdict(isOpen: false), .open)
    }

    func testShowLyricsNeverFoldsTheStage() {
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: true, surface: .stage),
            .alreadyOpen,
            "the toggle turns the stage back into the player here; Show Lyrics leaves the words up"
        )
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: true, surface: .player),
            .open,
            "open on the player: Show Lyrics brings the stage up"
        )
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: true, surface: .tray),
            .open,
            "open on another surface: Show Lyrics goes to the words"
        )
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: false, surface: .stage),
            .open
        )
    }
}
