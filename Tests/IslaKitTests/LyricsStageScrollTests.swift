import SwiftUI
import XCTest
@testable import IslaKit

/// The reading page: how far it may drift from the song before the way back is
/// worth offering, and how much air each end needs to reach the centre.
@MainActor
final class LyricsStageScrollTests: XCTestCase {
    func testBothEndsCanReachTheReadingCentre() {
        // Half the viewport, less half a line: the first line's own height
        // already covers the rest of the way to the middle.
        XCTAssertEqual(LyricsStage.centeringAir(viewport: 128), 128 / 2 - LyricsStage.slotHeight / 2)
        // A viewport shorter than a single line asks for nothing rather than
        // for negative padding, which would drag the whole column upward.
        XCTAssertEqual(LyricsStage.centeringAir(viewport: 10), 0)
    }

    /// The page reports the row it is reading by index, not by timestamp: two
    /// lines at one stamp used to share a scroll id, so the page could not say
    /// which of them it was on.
    func testTheSungLineOnScreenCountsAsNoDrift() {
        // Reading exactly the sung line.
        XCTAssertEqual(LyricsStage.linesStrayed(reading: 8, from: 8), 0)
        // One line either side is still on the stage, which shows about three.
        XCTAssertEqual(LyricsStage.linesStrayed(reading: 9, from: 8), 1)
        XCTAssertLessThan(1, LyricsStage.strayedEnoughToOfferSync)
    }

    func testReadingAheadOrBehindBothCount() {
        XCTAssertEqual(LyricsStage.linesStrayed(reading: 3, from: 1), 2)
        XCTAssertEqual(LyricsStage.linesStrayed(reading: 14, from: 8), 6)
        XCTAssertEqual(LyricsStage.linesStrayed(reading: 2, from: 8), 6)
        XCTAssertGreaterThanOrEqual(
            LyricsStage.linesStrayed(reading: 2, from: 8),
            LyricsStage.strayedEnoughToOfferSync,
            "six lines away from the voice must offer the way back"
        )
    }

    func testNoReportedPositionMeansNoDrift() {
        // Before the scroll view has said anything, the page is wherever we put
        // it — which is on the song. Reading that silence as drift would flash
        // the pill on every stage that opens.
        XCTAssertEqual(LyricsStage.linesStrayed(reading: nil, from: 4), 0)
    }
}
