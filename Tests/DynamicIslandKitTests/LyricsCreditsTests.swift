import XCTest
@testable import DynamicIslandKit

/// The lines before the singing starts.
///
/// LRC files routinely open with who wrote, produced and mixed the track,
/// stamped at or near zero. They were dropped outright, which threw away the
/// only thing on screen during a long intro. They are kept now — marked as
/// credits, never swept like a sung line, and spaced far enough apart to be
/// read rather than flashed.
@MainActor
final class LyricsCreditsTests: XCTestCase {
    func testCreditsAreKeptAndMarkedRatherThanDropped() {
        let lines = [
            LyricsStore.Line(at: 0, text: "Produced by Metro Boomin"),
            LyricsStore.Line(at: 0, text: "Mixed by Sean Solymar"),
            LyricsStore.Line(at: 19.3, text: "Tell me what you really like"),
            LyricsStore.Line(at: 22.0, text: "Baby I can take my time"),
        ]
        let cleaned = LyricsStore.cleaned(lines, title: "Some Song", artist: "Some Artist")
        XCTAssertEqual(cleaned.count, 4)
        XCTAssertTrue(cleaned[0].isCredit)
        XCTAssertTrue(cleaned[1].isCredit)
        XCTAssertFalse(cleaned[2].isCredit, "the sung line is not a credit")
    }

    func testTheTracksOwnTitleAndArtistIsStillACredit() {
        let lines = [
            LyricsStore.Line(at: 0, text: "Some Song - Some Artist"),
            LyricsStore.Line(at: 12, text: "First real line"),
            LyricsStore.Line(at: 16, text: "Second real line"),
        ]
        let cleaned = LyricsStore.cleaned(lines, title: "Some Song", artist: "Some Artist")
        XCTAssertTrue(cleaned[0].isCredit)
    }

    func testAFileOfNothingButCreditsIsNotLyrics() {
        let lines = [
            LyricsStore.Line(at: 0, text: "Produced by Someone"),
            LyricsStore.Line(at: 3, text: "Mixed by Someone Else"),
        ]
        XCTAssertTrue(LyricsStore.cleaned(lines, title: "T", artist: "A").isEmpty)
    }

    func testCreditsStackedAtZeroAreSpacedAcrossTheIntro() {
        let lines = [
            LyricsStore.Line(at: 0, text: "Produced by A", isCredit: true),
            LyricsStore.Line(at: 0, text: "Mixed by B", isCredit: true),
            LyricsStore.Line(at: 0, text: "Mastered by C", isCredit: true),
            LyricsStore.Line(at: 19.5, text: "First sung line"),
        ]
        let spaced = LyricsStore.spacedCredits(lines)
        XCTAssertEqual(spaced.count, 4)
        // Each credit gets its own moment, in order, all before the singing.
        XCTAssertLessThan(spaced[0].at, spaced[1].at)
        XCTAssertLessThan(spaced[1].at, spaced[2].at)
        XCTAssertLessThan(spaced[2].at, spaced[3].at)
        for index in 0..<3 {
            XCTAssertGreaterThanOrEqual(
                spaced[index + 1].at - spaced[index].at,
                LyricsStore.minimumCreditSlot - 0.01,
                "credit \(index) is on screen too briefly to read"
            )
        }
    }

    func testCreditsAreNeverPushedPastTheFirstSungLine() {
        let lines = [
            LyricsStore.Line(at: 0, text: "Produced by A", isCredit: true),
            LyricsStore.Line(at: 0, text: "Mixed by B", isCredit: true),
            LyricsStore.Line(at: 2.0, text: "First sung line"),
        ]
        let spaced = LyricsStore.spacedCredits(lines)
        for line in spaced where line.isCredit {
            XCTAssertLessThan(line.at, 2.0, "a credit must never sit on top of the singing")
        }
    }

    func testATrackWithNoCreditsIsUntouched() {
        let lines = [
            LyricsStore.Line(at: 4, text: "First"),
            LyricsStore.Line(at: 8, text: "Second"),
        ]
        XCTAssertEqual(LyricsStore.spacedCredits(lines), lines)
    }
}
