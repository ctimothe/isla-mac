import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The pill folding into the notch and growing back out of it.
///
/// Filmed on 2026-09-21: over the lock screen a pause removed the pill in a
/// single frame, and unlocked the contracting edge swept across a cover that
/// sat still at the old width. The fold is now a motion with two curves — the
/// shape's and the content's — and what makes it clean is the relation between
/// them, so that relation is what these hold. A critically damped spring has a
/// closed form, `(1 + ωt)·e^(−ωt)` of the distance still to go with
/// `ω = 2π / response`, which lets the tests ask where each curve is at a moment
/// rather than trusting that two numbers were chosen well.
final class PillFoldTests: XCTestCase {
    /// The fraction of the way still to go, `t` seconds into a critically
    /// damped spring of the given response.
    private func remaining(after t: Double, response: Double) -> Double {
        guard t > 0 else { return 1 }
        let omega = 2 * Double.pi / response
        return (1 + omega * t) * exp(-omega * t)
    }

    /// The first moment the spring has `fraction` of its distance left.
    private func time(untilRemaining fraction: Double, response: Double) -> Double {
        var low = 0.0, high = 5 * response
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if remaining(after: mid, response: response) > fraction { low = mid } else { high = mid }
        }
        return high
    }

    private let wing = NotchMetrics.compactMediaExtension / 2
    private let cover = Theme.artworkMetrics(isOpen: false).side

    /// Redesign 2026-10-15, spec §3.1: the cover and the bars are pinned 8 pt
    /// inside the island's own edges, where they used to sit centred in a 52 pt
    /// wing.
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
                XCTAssertEqual(coverFrame.minX, 8, "the cover keeps its distance from the left edge as it moves")
                XCTAssertEqual(islandWidth - bars.maxX, 8, "and the bars from the right")
                XCTAssertGreaterThanOrEqual(coverFrame.minX, 0)
                XCTAssertLessThanOrEqual(bars.maxX, islandWidth)
                XCTAssertLessThan(coverFrame.maxX, bars.minX, "the two never meet, however narrow the island is")
            }
        }
        XCTAssertEqual(cover, 24)
    }

    /// The content still waits for the shape: it is delayed past the spring's
    /// start, so a wing is opening before anything is drawn in it.
    func testTheContentArrivesAfterTheShapeHasStarted() {
        XCTAssertGreaterThan(Theme.pillContentInDelay, 0)
    }

    /// A fold is not something anybody threw, so it does not bounce, and it is
    /// slower than the 0.28 s it used to share with every pill resize — at that
    /// speed it read as a snap.
    func testTheFoldIsCalmAndDoesNotOvershoot() {
        XCTAssertGreaterThan(Theme.pillFoldResponse, 0.4)
        XCTAssertGreaterThan(Theme.pillUnfoldResponse, Theme.compactResponseForComparison)
        for animation in [Theme.pillFold, Theme.pillUnfold, Theme.pillContentIn, Theme.pillContentOut] {
            XCTAssertTrue(String(describing: animation).contains("dampingFraction: 1.0"))
        }
    }

    /// Leaving takes no longer than arriving. The fold used to be 0.50 s
    /// against the unfold's 0.42 s (settled 529 ms against 444 ms), on the
    /// argument that a fold nobody asked for should not pull the eye — but
    /// what it pulled the eye *to* was an empty black slab hanging past the
    /// notch after the song had already left it (H-013). The floor under the
    /// fold stays where `testTheFoldIsCalmAndDoesNotOvershoot` puts it.
    func testLeavingIsNoSlowerThanArriving() {
        XCTAssertLessThanOrEqual(Theme.pillFoldResponse, Theme.pillUnfoldResponse,
                                 "the fold outlasts the unfold: leaving takes longer than arriving")
    }

    /// Between the content settling out and the wing settling into the notch,
    /// the pill is a black shape with nothing on it. At 0.50 s against a
    /// 0.22 s content curve that was 296 ms of empty wing, read straight off
    /// the visual lab's keyframes (t120–t300). Settled means within 1 % of
    /// the travel, the same line the lab's `settleWithin1PercentMs` draws.
    func testTheEmptyWingIsShort() {
        let wingSettles = time(untilRemaining: 0.01, response: Theme.pillFoldResponse)
        let contentSettles = time(untilRemaining: 0.01, response: Theme.pillContentOutResponse)
        XCTAssertLessThanOrEqual(wingSettles - contentSettles, 0.24,
                                 "the wing lingers \(wingSettles - contentSettles)s after its content is gone")
    }

    /// Folded means nothing drawn, and Reduce Motion keeps the change while
    /// refusing the travel: a fade with no shrinking and no blur.
    func testFoldedContentDrawsNothingAndReduceMotionOnlyFades() {
        let folded = PillPresence.appearance(shown: false, reduceMotion: false)
        XCTAssertEqual(folded.opacity, 0)
        XCTAssertGreaterThan(folded.blur, 0)
        XCTAssertLessThan(folded.scale, 1)

        let reduced = PillPresence.appearance(shown: false, reduceMotion: true)
        XCTAssertEqual(reduced, .init(blur: 0, scale: 1, opacity: 0))

        XCTAssertEqual(PillPresence.appearance(shown: true, reduceMotion: false), .init(blur: 0, scale: 1, opacity: 1))
        XCTAssertFalse(String(describing: Theme.pill(appearing: false, reduceMotion: true)).contains("spring"))
        XCTAssertFalse(String(describing: Theme.pillContent(shown: true, reduceMotion: true)).contains("spring"))
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

private extension Theme {
    /// The response every pill resize used to share, for the comparison above.
    static var compactResponseForComparison: Double { 0.28 }
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
