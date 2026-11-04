import XCTest
@testable import IslaKit

/// One of a thing is never said as many (Batch 3, 2026-10-29).
///
/// Every sentence with a count in it was tested with two or three, and three
/// of them said "1 items" or "1 entries" at one: the island's value and the
/// Shelf bubble's name with one file waiting ("Shelf, 1 items" — the first
/// thing VoiceOver says about a single dropped file), Remove All's question
/// over a one-card tray, and Clear History's over one entry. The Russian table
/// writes these as "label: N", which needs no plural; English does, and gets
/// it from a key of its own for one, as `ShelfHeader.countText` and the
/// screenshot-trash announcement already did.
@MainActor
final class CountedSentenceTests: XCTestCase {
    func testTheShelfOnTheIslandCountsOneAsOne() {
        XCTAssertEqual(IslandBubble.label(count: 1), "Shelf, 1 item")
        XCTAssertEqual(IslandBubble.label(count: 2), "Shelf, 2 items")
    }

    func testRemoveAllAsksAboutOneCardAsOne() {
        XCTAssertEqual(ShelfClearConfirmation.question(count: 1), "Remove 1 item? Its file is untouched.")
        XCTAssertEqual(ShelfClearConfirmation.question(count: 4), "Remove all 4 items? Files are untouched.")
    }

    func testClearHistoryAsksAboutOneEntryAsOne() {
        XCTAssertEqual(ClipboardClearConfirmation.question(count: 1), "Clear 1 entry? Pinned items stay.")
        XCTAssertEqual(ClipboardClearConfirmation.question(count: 2), "Clear 2 entries? Pinned items stay.")
    }

    /// What is asked aloud is what is drawn: each question has one source.
    func testTheQuestionSpokenIsTheQuestionDrawn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["ShelfPane.swift", "ClipboardPane.swift", "ClipboardLayout.swift", "NotchContentView.swift",
                     "IslandBubble.swift"]
        let sources = try files.map {
            try String(contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/\($0)"), encoding: .utf8)
        }.joined()
        for key in ["localized(\"Remove all %d items?", "localized(\"Clear %d entries?", "localized(\"Shelf, %d items\""] {
            XCTAssertEqual(sources.components(separatedBy: key).count - 1, 1, "\(key) is built in one place")
        }
    }
}
