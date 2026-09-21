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

    /// Folding: by the time the contracting wing is narrower than the cover —
    /// the moment its edge would start cutting through it — the cover is all
    /// but gone. Content still visible there is content being sliced.
    func testTheContentIsGoneBeforeTheEdgeReachesIt() {
        let edgeArrives = time(untilRemaining: cover / wing, response: Theme.pillFoldResponse)
        let stillVisible = remaining(after: edgeArrives, response: Theme.pillContentOutResponse)
        XCTAssertLessThan(stillVisible, 0.1,
                          "at \(edgeArrives)s the edge meets the cover while it is still \(stillVisible) opaque")
    }

    /// Unfolding: the cover does not materialize until its wing is as wide as
    /// the cover. Content drawn before its surface exists is drawn on the
    /// wallpaper beside the notch.
    func testTheContentArrivesOnlyOnceItsWingIsThere() {
        let tenPercentIn = Theme.pillContentInDelay
            + time(untilRemaining: 0.9, response: Theme.pillContentInResponse)
        let wingThen = wing * (1 - remaining(after: tenPercentIn, response: Theme.pillUnfoldResponse))
        XCTAssertGreaterThanOrEqual(wingThen, cover,
                                    "the cover shows at \(tenPercentIn)s on a \(wingThen)pt wing")
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
