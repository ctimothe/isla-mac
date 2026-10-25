import XCTest
@testable import IslaKit

/// The player, the lyrics stage and the lock card draw their previous, play /
/// pause and next with one control (`TransportGlyphButton`), and their bar with
/// one scrubber (`PlaybackScrubber`). The owner found the stage's set "not
/// consistent with the icons that you are using for the normal dynamic island
/// page" (2026-10-24); these hold the shared pieces, not any one surface's look.
@MainActor
final class SharedTransportTests: XCTestCase {
    typealias Kind = TransportGlyphButton.Kind

    /// The same three SF Symbols the player has always drawn, with play and
    /// pause following the song.
    func testSymbols() {
        XCTAssertEqual(Kind.previous.symbol(isPlaying: true), "backward.fill")
        XCTAssertEqual(Kind.previous.symbol(isPlaying: false), "backward.fill")
        XCTAssertEqual(Kind.next.symbol(isPlaying: false), "forward.fill")
        XCTAssertEqual(Kind.playPause.symbol(isPlaying: false), "play.fill")
        XCTAssertEqual(Kind.playPause.symbol(isPlaying: true), "pause.fill")
    }

    /// Play / Pause is labelled with what the press does.
    func testLabels() {
        XCTAssertEqual(Kind.previous.label(isPlaying: false), localized("Previous Track"))
        XCTAssertEqual(Kind.next.label(isPlaying: true), localized("Next Track"))
        XCTAssertEqual(Kind.playPause.label(isPlaying: false), localized("Play"))
        XCTAssertEqual(Kind.playPause.label(isPlaying: true), localized("Pause"))
    }

    /// Each kind is drawn as the player's control of that name, and the player's
    /// target gets the board's glyph exactly.
    func testThePlayersGlyphsAreTheBoards() {
        let player = CGSize(width: PlayerLayout.hitTarget, height: PlayerLayout.hitTarget)
        for kind in Kind.allCases {
            XCTAssertEqual(TransportGlyphButton.glyphSize(kind, hitTarget: player), kind.control.glyph)
        }
        XCTAssertEqual(Kind.previous.control, .previous)
        XCTAssertEqual(Kind.playPause.control, .playPause)
        XCTAssertEqual(Kind.next.control, .next)
    }

    /// A smaller surface keeps the player's proportions: previous and next are
    /// the same size and play / pause is the larger of the two on every
    /// surface, and the glyph always fits the target it sits in.
    func testSmallerSurfacesScaleThePlayersGlyphs() {
        let targets = [
            CGSize(width: 24, height: 24), CGSize(width: 36, height: 36),
            CGSize(width: 32, height: 30), CGSize(width: 34, height: 30),
        ]
        for target in targets {
            let previous = TransportGlyphButton.glyphSize(.previous, hitTarget: target)
            let next = TransportGlyphButton.glyphSize(.next, hitTarget: target)
            let play = TransportGlyphButton.glyphSize(.playPause, hitTarget: target)
            XCTAssertEqual(previous, next)
            XCTAssertGreaterThan(play.height, previous.height, "\(target)")
            for glyph in [previous, next, play] {
                XCTAssertLessThanOrEqual(glyph.width, target.width, "\(target)")
                XCTAssertLessThanOrEqual(glyph.height, target.height, "\(target)")
            }
        }
        let stage = TransportGlyphButton.glyphSize(.playPause, hitTarget: StageLayout.Transport.playPause.hitTarget)
        XCTAssertEqual(stage.height, 34 * 30 / 42, accuracy: 0.001, "the stage's row is 30 tall against the player's 42")
    }

    /// The stage's hit targets are the wells they always were: 32, 34 and 32
    /// wide and 30 tall, and the same as the frames the layout places them in.
    func testTheStageKeepsItsHitTargets() {
        let layout = StageLayout(bodyWidth: 560)
        for which in StageLayout.Transport.allCases {
            XCTAssertEqual(which.hitTarget, layout.transport(which).size)
        }
        XCTAssertEqual(StageLayout.Transport.previous.hitTarget, CGSize(width: 32, height: 30))
        XCTAssertEqual(StageLayout.Transport.playPause.hitTarget, CGSize(width: 34, height: 30))
    }

    /// The stage's bar is grabbed in a taller area than the 3 pt it draws, one
    /// that does not reach the transport above it.
    func testTheStagesBarHasAGrabAreaClearOfTheTransport() {
        let layout = StageLayout(bodyWidth: 560)
        let grab = layout.progress.insetBy(dx: 0, dy: -StageLayout.progressGrabInset)
        XCTAssertGreaterThan(grab.height, layout.progress.height * 4)
        XCTAssertEqual(grab.width, layout.progress.width)
        XCTAssertGreaterThan(grab.minY, layout.transport(.playPause).maxY)
    }

    /// The bar follows the finger while one is down, and the clock otherwise;
    /// a song with no length draws nothing filled.
    func testTheScrubbersFraction() {
        XCTAssertEqual(PlaybackScrubber.fraction(scrubbing: nil, position: 30, duration: 120), 0.25)
        XCTAssertEqual(PlaybackScrubber.fraction(scrubbing: 0.8, position: 30, duration: 120), 0.8)
        XCTAssertEqual(PlaybackScrubber.fraction(scrubbing: nil, position: 500, duration: 120), 1)
        XCTAssertEqual(PlaybackScrubber.fraction(scrubbing: nil, position: -3, duration: 120), 0)
        XCTAssertEqual(PlaybackScrubber.fraction(scrubbing: nil, position: 30, duration: 0), 0)
    }
}
