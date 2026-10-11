import XCTest
@testable import IslaKit

/// Show Isla and Show Lyrics open and never close.
///
/// Both intents called the hot keys' toggles, so a Shortcut or Focus
/// automation titled *Show* that ran while the panel was already open closed
/// it, and Show Lyrics folded the lyrics page back to the player (F-024). The
/// hot keys keep their toggles — one key is the whole round trip there — and
/// the intents and the reopen route ask these verdicts instead.
final class ShowRouteTests: XCTestCase {

    func testShowLeavesAnOpenPanelAlone() {
        XCTAssertEqual(NotchViewModel.showVerdict(isOpen: true), .alreadyOpen)
        XCTAssertEqual(NotchViewModel.showVerdict(isOpen: false), .open)
    }

    func testShowLyricsNeverFoldsThePage() {
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: true, tab: .media, showingLyrics: true),
            .alreadyOpen,
            "the toggle folds the page here; Show Lyrics leaves the words up"
        )
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: true, tab: .media, showingLyrics: false),
            .open,
            "open on the player: Show Lyrics brings the page up"
        )
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: true, tab: .shelf, showingLyrics: true),
            .open,
            "open on another tab: Show Lyrics goes to the words"
        )
        XCTAssertEqual(
            NotchViewModel.showLyricsVerdict(isOpen: false, tab: .media, showingLyrics: true),
            .open
        )
    }
}
