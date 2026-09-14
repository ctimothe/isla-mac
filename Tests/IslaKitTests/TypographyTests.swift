import SwiftUI
import XCTest
@testable import IslaKit

/// Tracking follows the size, the way SF's own table does.
final class TypographyTests: XCTestCase {

    /// A single letter-spacing value is wrong somewhere. As type grows the same
    /// spacing reads as letters drifting apart, so display sizes tighten; small
    /// labels open up to stay legible. SwiftUI applies Apple's table to the
    /// semantic text styles and not to `.system(size:)`, which is what a
    /// fixed-size panel is obliged to use.
    func testTrackingTightensAsTypeGrows() {
        let sizes: [CGFloat] = [10, 11, 13, 14, 16, 18, 22, 26]
        let values = sizes.map { Theme.tracking(forSize: $0) }

        XCTAssertGreaterThan(values[0], 0, "small labels open up")
        XCTAssertEqual(Theme.tracking(forSize: 13), 0, "body sits at the neutral point")
        XCTAssertLessThan(Theme.tracking(forSize: 26), 0, "display sizes tighten")

        // Never increases with size.
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(b, a, "tracking must never loosen as size grows")
        }
    }

    /// The swept line and its neighbours must be tracked identically, or the
    /// current line shifts sideways as the song moves through it — text
    /// twitching rather than a voice arriving.
    func testTheSweptLineIsTrackedLikeItsNeighbours() {
        for size in [CGFloat(15), 16] {
            XCTAssertEqual(
                Theme.tracking(forSize: size),
                Theme.tracking(forSize: size),
                "one size, one answer, both branches of a lyric row"
            )
        }
        XCTAssertEqual(Theme.tracking(forSize: 15), Theme.tracking(forSize: 16),
                       "the stage and the card sit in the same tracking band")
    }
}
