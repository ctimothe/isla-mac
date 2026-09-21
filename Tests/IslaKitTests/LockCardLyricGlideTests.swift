import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The lock card's lyrics moving a line at a time.
///
/// Its window of lines used to jump: nothing animated the window sliding, so
/// when the song moved one line every row leapt a slot at once and only the
/// highlight crossfaded. The window now glides, the leaving line going up and
/// out and the next one rising in from under the bottom — and that only reads
/// as one page moving if both travel exactly one row. Too short and the
/// arriving line pops in part-way up; too far and it lags behind the lines
/// above it.
@MainActor
final class LockCardLyricGlideTests: XCTestCase {
    func testALineEntersAndLeavesByExactlyOneRow() {
        let row = LyricRow(
            line: LyricsStore.Line(at: 12, text: "A line long enough to be a line"),
            isCurrent: false,
            distance: 1,
            at: 0,
            end: 15,
            fontSize: Theme.TypeRole.title.size,
            weight: .bold,
            lineLimit: 1
        )
        let proposal = CGSize(width: 380, height: 400)
        let height = NSHostingController(rootView: row.frame(width: proposal.width))
            .sizeThatFits(in: proposal).height
        // The card's stack spacing between two rows.
        let slot = height + 7
        XCTAssertEqual(LockScreenCard.lineTravel, slot, accuracy: 2,
                       "one row is \(slot)pt; the glide travels \(LockScreenCard.lineTravel)")
    }

    /// A seek is still a cut, and Reduce Motion still gets a fade rather than
    /// travel.
    func testAJumpIsStillACutAndReduceMotionOnlyFades() {
        XCTAssertTrue(LockScreenCard.isJump(from: 3, to: 7))
        XCTAssertFalse(LockScreenCard.isJump(from: 3, to: 4))
        let opacity = String(describing: AnyTransition.opacity)
        XCTAssertEqual(String(describing: LockScreenCard.lineTransition(reduceMotion: true)), opacity)
        XCTAssertNotEqual(String(describing: LockScreenCard.lineTransition(reduceMotion: false)), opacity,
                          "with motion allowed the line travels, not only fades")
    }
}
