import XCTest
@testable import IslaKit

/// The open's first frame carries the outline and the header; the body
/// mounts a pass later (MR-H18, 2026-10-26) — except where the cover travels
/// from the pill into the player, whose two ends must share a transaction.
final class NotchContentStagingTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    func testThePlayerMountsWithTheOutlineWhileTheCoverTravels() {
        XCTAssertFalse(NotchContentView.stagesBody(opening: .player, reduceMotion: false),
                       "the cover's far end is inside the player: staged, the morph would fall back to a fade")
    }

    func testEveryOtherSurfaceMountsAPassLater() {
        for surface in Surface.allCases where surface != .player {
            XCTAssertTrue(NotchContentView.stagesBody(opening: surface, reduceMotion: false), "\(surface)")
        }
    }

    func testUnderReduceMotionNothingTravelsSoThePlayerIsStagedToo() {
        XCTAssertFalse(NotchContentView.travels(reduceMotion: true))
        XCTAssertTrue(NotchContentView.stagesBody(opening: .player, reduceMotion: true))
    }
}
