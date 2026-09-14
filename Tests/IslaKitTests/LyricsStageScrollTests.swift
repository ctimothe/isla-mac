import SwiftUI
import XCTest
@testable import IslaKit

/// The reading page: how far it may drift from the song before the way back is
/// worth offering, and how much air each end needs to reach the centre.
@MainActor
final class LyricsStageScrollTests: XCTestCase {
    private func lines(_ count: Int) -> [LyricsStore.Line] {
        (0..<count).map { LyricsStore.Line(at: Double($0) * 4, text: "Line \($0)") }
    }

    func testBothEndsCanReachTheReadingCentre() {
        // Half the viewport, less half a line: the first line's own height
        // already covers the rest of the way to the middle.
        XCTAssertEqual(LyricsStage.centeringAir(viewport: 128), 128 / 2 - LyricsStage.slotHeight / 2)
        // A viewport shorter than a single line asks for nothing rather than
        // for negative padding, which would drag the whole column upward.
        XCTAssertEqual(LyricsStage.centeringAir(viewport: 10), 0)
    }

    func testTheSungLineOnScreenCountsAsNoDrift() {
        let catalogue = lines(20)
        // Reading exactly the sung line.
        XCTAssertEqual(LyricsStage.linesStrayed(reading: catalogue[8].at, from: 8, in: catalogue), 0)
        // One line either side is still on the stage, which shows about three.
        XCTAssertEqual(LyricsStage.linesStrayed(reading: catalogue[9].at, from: 8, in: catalogue), 1)
        XCTAssertLessThan(1, LyricsStage.strayedEnoughToOfferSync)
    }

    func testReadingAheadOrBehindBothCount() {
        let catalogue = lines(20)
        XCTAssertEqual(LyricsStage.linesStrayed(reading: catalogue[14].at, from: 8, in: catalogue), 6)
        XCTAssertEqual(LyricsStage.linesStrayed(reading: catalogue[2].at, from: 8, in: catalogue), 6)
        XCTAssertGreaterThanOrEqual(
            LyricsStage.linesStrayed(reading: catalogue[2].at, from: 8, in: catalogue),
            LyricsStage.strayedEnoughToOfferSync,
            "six lines away from the voice must offer the way back"
        )
    }

    func testNoReportedPositionMeansNoDrift() {
        // Before the scroll view has said anything, the page is wherever we put
        // it — which is on the song. Reading that silence as drift would flash
        // the pill on every stage that opens.
        XCTAssertEqual(LyricsStage.linesStrayed(reading: nil, from: 4, in: lines(20)), 0)
    }
}
