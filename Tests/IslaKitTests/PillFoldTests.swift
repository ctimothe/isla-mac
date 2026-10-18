import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The pill folding into the notch and growing back out of it.
///
/// Filmed on 2026-09-21: over the lock screen a pause removed the pill in a
/// single frame, and unlocked the contracting edge swept across a cover that
/// sat still at the old width. The fold had two curves then — the shape's and
/// the content's — and what made it clean was the relation between them. Since
/// spec §19.3 both ride the outline's spring, so the relation is now that they
/// are one curve, and that the content is pinned to the edges it rides.
final class PillFoldTests: XCTestCase {
    private let wing = NotchMetrics.compactMediaExtension / 2
    private let cover = Theme.artworkMetrics(isOpen: false).side

    /// Redesign 2026-10-15, spec §3.1: the cover and the bars are pinned
    /// inside the island's own edges, where they used to sit centred in a 52 pt
    /// wing — since §19.4 the cover 17.3 from the shape's left edge and the
    /// bars ending 19.3 from its right.
    ///
    /// That is why the two timing tests that stood here — the content fading
    /// before the contracting edge reached the cover, and the cover not showing
    /// until its wing was as wide as the cover — are gone. Both were arithmetic
    /// about an edge sweeping across content that stayed still while the wing
    /// shrank around it; the content now travels *with* the edge, so no edge
    /// ever crosses it, and with a 40 pt wing under a 24 pt cover the old "wing at
    /// least as wide as the cover" held only after 60 % of the unfold, well
    /// past the point the content could reasonably appear. What stays true, and
    /// is held here, is the thing those tests were protecting: at every width the
    /// island passes through while it folds, the content is inside the shape.
    func testTheContentRidesTheEdgesSoNothingIsSlicedOrDrawnBesideTheShape() {
        for notch in [CGFloat(180), 200, 220] {
            for open in stride(from: CGFloat(0), through: wing, by: 4) {
                let islandWidth = notch + 2 * open
                let coverFrame = CompactIslandLayout.coverFrame(height: 38)
                let bars = CompactIslandLayout.equalizerFrame(islandWidth: islandWidth, height: 38)
                XCTAssertEqual(coverFrame.minX, CompactIslandLayout.coverInset,
                               "the cover keeps its distance from the left edge as it moves")
                XCTAssertEqual(islandWidth - bars.maxX, CompactIslandLayout.equalizerTrailingInset, accuracy: 0.001,
                               "and the bars from the right")
                XCTAssertGreaterThanOrEqual(coverFrame.minX, 0)
                XCTAssertLessThanOrEqual(bars.maxX, islandWidth)
                XCTAssertLessThan(coverFrame.maxX, bars.minX, "the two never meet, however narrow the island is")
            }
        }
        XCTAssertEqual(cover, 22)
    }

    /// The content arrives and leaves on the outline's own spring, so it is
    /// never ahead of the shape and never outlasts it: the empty black wing
    /// H-013 found hanging past the notch after its song had left (296 ms of it
    /// at the 0.50 s fold) cannot happen when there is one curve. The fold and
    /// the unfold are the same spring, so leaving takes no longer than
    /// arriving.
    func testTheContentAndTheWingRideOneSpring() {
        for reduceMotion in [false, true] {
            XCTAssertEqual(Theme.pill(reduceMotion: reduceMotion), Theme.island(reduceMotion: reduceMotion))
        }
        XCTAssertEqual(Theme.pill(reduceMotion: false), Theme.islandSpring)
    }

    /// Folded means nothing drawn, and Reduce Motion keeps the change while
    /// refusing the travel: a fade with no shrinking and no blur.
    func testFoldedContentDrawsNothingAndReduceMotionOnlyFades() {
        let folded = PillPresence.appearance(shown: false, reduceMotion: false)
        XCTAssertEqual(folded.opacity, 0)
        XCTAssertEqual(folded.blur, 15)
        XCTAssertEqual(folded.scale, CGSize(width: 0.8, height: 1), "narrower, never shorter: a compact activity grows sideways")

        let reduced = PillPresence.appearance(shown: false, reduceMotion: true)
        XCTAssertEqual(reduced.opacity, 0)
        XCTAssertEqual(reduced.blur, 0)
        XCTAssertEqual(reduced.scale, CGSize(width: 1, height: 1))

        XCTAssertEqual(PillPresence.appearance(shown: true, reduceMotion: false), .arrived())
        XCTAssertFalse(String(describing: Theme.pill(reduceMotion: true)).contains("spring"))
    }

    /// A settled pause is `.hidden`, and `.paused` is the only state that draws
    /// the badge — so the fold used to start by lighting the cover back up to
    /// full and dropping its badge: a flash of "playing" on the way into the
    /// notch. The paused look is what the player says, and it rides the fold.
    @MainActor
    func testAPausedCoverStaysPausedWhileItFolds() {
        XCTAssertTrue(NotchContentView.showsPausedCover(activity: .paused, isPlaying: false))
        XCTAssertTrue(NotchContentView.showsPausedCover(activity: .hidden, isPlaying: false),
                      "the settled pause folds away still looking paused")
        XCTAssertFalse(NotchContentView.showsPausedCover(activity: .playing, isPlaying: true))
    }
}

/// The folded pill keeps its views but gives up its end of the travel.
final class FoldedMorphTests: XCTestCase {
    /// Shown, the pill's cover and bars answer to the names the open panel's
    /// do, so opening carries them. Folded they answer to none: opening on a
    /// settled pause must not grow the cover out of the notch's edge.
    @MainActor
    func testAFoldedPillHasNoEndOfTheTravel() {
        typealias ID = NotchContentView.MorphID
        XCTAssertEqual(ID.compact(ID.artwork, folded: false), ID.artwork)
        XCTAssertEqual(ID.compact(ID.equalizer, folded: false), ID.equalizer)
        XCTAssertNotEqual(ID.compact(ID.artwork, folded: true), ID.artwork)
        XCTAssertNotEqual(ID.compact(ID.equalizer, folded: true), ID.equalizer)
        XCTAssertNotEqual(ID.compact(ID.artwork, folded: true), ID.compact(ID.equalizer, folded: true))
    }
}
