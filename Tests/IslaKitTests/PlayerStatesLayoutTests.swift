import SwiftUI
import XCTest
@testable import IslaKit

/// The player `P`, the lyric column `C` and the tall page `T` as one table of
/// frames (spec §5.1), read at 480, 560 and 620 — the table is the contract, and
/// the view only places what it says.
final class PlayerStatesLayoutTests: XCTestCase {
    private static let widths: [CGFloat] = [480, 560, 620]

    private func frames(_ state: PlayerLayout.State, _ width: CGFloat = 560) -> PlayerLayout.StateFrames {
        PlayerLayout.frames(for: state, bodyWidth: width)
    }

    // MARK: - Body heights

    func testTheBodyIsStandardInTheColumnAndTallOnTheTallPage() {
        XCTAssertEqual(PlayerLayout.State.player.bodyHeight, 208)
        XCTAssertEqual(PlayerLayout.State.column.bodyHeight, 208, "the column grows nothing: it only replaces the band")
        XCTAssertEqual(PlayerLayout.State.tall.bodyHeight, 400)
        XCTAssertEqual(PlayerLayout.State.tall.bodyHeight, NotchMetrics.tallestBody.height)
    }

    // MARK: - The player is the existing table

    /// P is not restated: the table's player row is the instance's own frames,
    /// so the two cannot say different things about the player.
    func testThePlayerRowIsTheInstancesOwnFrames() {
        for width in Self.widths {
            let layout = PlayerLayout(bodyWidth: width)
            let f = layout.frames(for: .player)
            XCTAssertEqual(f.cover, layout.cover)
            XCTAssertEqual(f.title, layout.title)
            XCTAssertEqual(f.progress, layout.progress)
            XCTAssertEqual(f.transport, layout.transport)
            XCTAssertEqual(f.volume, layout.volume)
            XCTAssertEqual(f.output, layout.output)
            XCTAssertEqual(f.lyrics, layout.lyrics)
            XCTAssertTrue(f.showsModes, "shuffle and repeat flank the transport in the player")
            XCTAssertNil(f.lyricArea, "the player has a band, not a lyric area")
            XCTAssertEqual(f.coverRadius, 14)
            XCTAssertFalse(f.subtitleIsArtistOnly)
        }
    }

    // MARK: - The column (spec §5.1 table, column C)

    func testTheColumnFramesAtThreeWidths() {
        for width in Self.widths {
            let f = frames(.column, width)
            XCTAssertEqual(f.cover, CGRect(x: 58, y: 50, width: 52, height: 52), "cover at \(width)")
            XCTAssertEqual(f.coverRadius, 9)
            XCTAssertEqual(f.title.origin, CGPoint(x: 122, y: 53), "title at \(width)")
            XCTAssertEqual(f.titleSize, 13)
            XCTAssertEqual(f.subtitle.origin, CGPoint(x: 122, y: 71))
            XCTAssertEqual(f.subtitleSize, 11)
            XCTAssertTrue(f.subtitleIsArtistOnly, "the column names the artist alone")
            XCTAssertEqual(f.progress, CGRect(x: 58, y: 116, width: 190, height: 12))
            XCTAssertEqual(f.transport, CGRect(x: 84, y: 136, width: 138, height: 28))
            XCTAssertEqual(f.volume, CGRect(x: 58, y: 176, width: 128, height: 12))
            XCTAssertEqual(f.output, CGRect(x: 197, y: 169, width: 26, height: 26))
            XCTAssertEqual(f.lyrics, CGRect(x: 225, y: 169, width: 26, height: 26))
            XCTAssertFalse(f.showsModes, "shuffle and repeat fold away in the column")
        }
    }

    /// The lines start at x 268 and run to the pane's own right edge; the only
    /// thing that moves with the body's width is how long a line may be.
    func testTheColumnsLinesStartAtTwoSixtyEightAndRunToThePanesEdge() throws {
        for width in Self.widths {
            let f = frames(.column, width)
            let area = try XCTUnwrap(f.lyricArea)
            XCTAssertEqual(area.minX, 268, "lines at x 268 at \(width)")
            XCTAssertEqual(area.maxX, width - 14, "and to the pane's right edge")
            XCTAssertEqual(area.minY, 38, "from the header's foot")
            XCTAssertEqual(area.maxY, 194, "to the pane's bottom: 208 less the 14 pt padding")
            let sung = try XCTUnwrap(f.sungLine)
            XCTAssertEqual(sung.minX, 268)
            XCTAssertEqual(sung.minY, 96, "the sung line at y 96")
            XCTAssertEqual(f.lyricPitch, 23, "pitch 23")
            XCTAssertEqual(f.lyricSize, 13, "13 pt: the subhead role")
        }
        XCTAssertEqual(try XCTUnwrap(frames(.column, 560).lyricArea).width, 278, "the board's 278 at 560")
    }

    // MARK: - The tall page (spec §5.1 table, tall T)

    func testTheTallFramesAtThreeWidths() throws {
        for width in Self.widths {
            let f = frames(.tall, width)
            XCTAssertEqual(f.cover, CGRect(x: 58, y: 46, width: 34, height: 34), "cover at \(width)")
            XCTAssertEqual(f.coverRadius, 7)
            XCTAssertEqual(f.title.origin, CGPoint(x: 102, y: 46))
            XCTAssertEqual(f.titleSize, 13)
            XCTAssertEqual(f.subtitle.origin, CGPoint(x: 102, y: 63))
            XCTAssertEqual(f.subtitleSize, 11)
            XCTAssertEqual(f.transport, CGRect(x: 60, y: 350, width: 92, height: 28))
            XCTAssertEqual(f.progress.minX, 158)
            XCTAssertEqual(f.progress.minY, 358)
            XCTAssertEqual(f.output?.origin, CGPoint(x: width - 75, y: 351), "Output at bw − 75")
            XCTAssertEqual(f.lyrics.origin, CGPoint(x: width - 45, y: 351), "Lyrics at bw − 45")
            XCTAssertEqual(f.volume?.origin.y, 358)
            XCTAssertEqual(f.volume?.width, 78)
            XCTAssertFalse(f.showsModes)
            let area = try XCTUnwrap(f.lyricArea)
            XCTAssertEqual(area.minX, 58, "tall lines at x 58 at \(width)")
            XCTAssertEqual(area.maxX, width - 14)
            let sung = try XCTUnwrap(f.sungLine)
            XCTAssertEqual(sung.minX, 58)
            XCTAssertEqual(sung.minY, 166, "the sung line at y 166")
            XCTAssertEqual(f.lyricPitch, 34, "pitch 34")
            XCTAssertEqual(f.lyricSize, 17, "17 pt: the lyric role")
        }
    }

    /// At 560 the footer is the board's: the progress row 158…376, the volume bar
    /// at 388 and the two buttons at 485 and 515 — the arithmetic that produces
    /// them from the trailing edge is what lets 480 and 620 keep their order.
    func testTheTallFooterIsTheBoardsAtFiveSixtyAndKeepsItsOrderAtTheEnds() throws {
        let board = frames(.tall, 560)
        XCTAssertEqual(board.progress, CGRect(x: 158, y: 358, width: 218, height: 12))
        XCTAssertEqual(board.volume, CGRect(x: 388, y: 358, width: 78, height: 12))
        XCTAssertEqual(board.output, CGRect(x: 485, y: 351, width: 26, height: 26))
        XCTAssertEqual(board.lyrics, CGRect(x: 515, y: 351, width: 26, height: 26))

        for width in Self.widths {
            let f = frames(.tall, width)
            let volume = try XCTUnwrap(f.volume)
            let output = try XCTUnwrap(f.output)
            XCTAssertLessThanOrEqual(f.transport.maxX, f.progress.minX, "transport then progress at \(width)")
            XCTAssertLessThan(f.progress.maxX, volume.minX, "progress then volume at \(width)")
            XCTAssertLessThan(volume.maxX, output.minX, "volume then Output at \(width)")
            XCTAssertLessThan(output.maxX, f.lyrics.minX, "Output then Lyrics at \(width)")
            XCTAssertLessThanOrEqual(f.lyrics.maxX, width - 14, "inside the pane at \(width)")
            XCTAssertGreaterThan(f.progress.width, 120, "a scrubber, not a stub, at \(width)")
        }
        XCTAssertLessThan(frames(.tall, 480).progress.width, board.progress.width)
        XCTAssertGreaterThan(frames(.tall, 620).progress.width, board.progress.width)
    }

    // MARK: - Nothing overlaps and nothing leaves the body

    func testNoStateOverlapsItselfOrLeavesThePane() {
        for state in PlayerLayout.State.allCases where state != .player {
            for width in Self.widths {
                let f = frames(state, width)
                var parts: [(String, CGRect)] = [
                    ("cover", f.cover), ("title", f.title), ("subtitle", f.subtitle),
                    ("progress", f.progress), ("transport", f.transport), ("lyrics", f.lyrics),
                ]
                if let volume = f.volume { parts.append(("volume", volume)) }
                if let output = f.output { parts.append(("output", output)) }
                if let area = f.lyricArea { parts.append(("lyricArea", area)) }
                for (i, a) in parts.enumerated() {
                    // The board's own Output and Lyrics tiles end a point under the
                    // pane's foot in the column (169 + 26 = 195 against 194): a
                    // 26 pt target of which 14 pt is drawn, so the clip costs one
                    // transparent point of its corner.
                    XCTAssertGreaterThanOrEqual(a.1.minX, 58, "\(a.0) in \(state) at \(width)")
                    XCTAssertLessThanOrEqual(a.1.maxX, width - 14, "\(a.0) in \(state) at \(width)")
                    XCTAssertLessThanOrEqual(a.1.maxY, f.bodyHeight - 14 + 1, "\(a.0) in \(state) at \(width)")
                    for b in parts[(i + 1)...] {
                        XCTAssertFalse(
                            a.1.intersects(b.1),
                            "\(a.0) \(a.1) overlaps \(b.0) \(b.1) in \(state) at \(width)"
                        )
                    }
                }
            }
        }
    }

    /// The table converts to the pane in the one place the player does: the same
    /// `(58, headerHeight)` offset, whatever the state.
    func testTheTableConvertsToThePaneWithTheOneConversion() throws {
        let layout = PlayerLayout(bodyWidth: 560, headerHeight: 32)
        let tall = layout.frames(for: .tall)
        XCTAssertEqual(layout.inPane(tall.cover).origin, CGPoint(x: 0, y: 46 - 32), "the cover is the pane's own origin in x")
        XCTAssertEqual(layout.inPane(try XCTUnwrap(tall.lyricArea)).minX, 0)
    }

    // MARK: - The lines' ramp

    func testTheBoardsOpacities() {
        // Column: 0.22, 0.36, 1.0, 0.5, 0.32, 0.18.
        XCTAssertEqual((-2...3).map { PlayerLayout.boardLyricOpacity(offset: $0, tall: false) }, [0.22, 0.36, 1, 0.5, 0.32, 0.18])
        // Tall: 0.16, 0.30, 1.0, 0.50, 0.32, 0.20, 0.12.
        XCTAssertEqual((-2...4).map { PlayerLayout.boardLyricOpacity(offset: $0, tall: true) }, [0.16, 0.30, 1, 0.50, 0.32, 0.20, 0.12])
    }

    /// The contrast floor wins over the boards (spec §2.1): no context line is
    /// ever drawn under the ramp's floor, the neighbours under its neighbour
    /// step, and the order the board gives — the next line brighter than the
    /// previous — survives where the board clears the floor.
    func testNoContextLineIsDrawnUnderTheContrastFloor() {
        for increaseContrast in [false, true] {
            let ramp = LyricRow.Ramp.panel(increaseContrast: increaseContrast)
            for tall in [false, true] {
                for offset in -6...6 where offset != 0 {
                    let drawn = PlayerLayout.lyricOpacity(offset: offset, tall: tall, ramp: ramp, reading: false)
                    let floor = abs(offset) == 1 ? ramp.neighbour : ramp.floor
                    XCTAssertGreaterThanOrEqual(drawn, floor, "offset \(offset), tall \(tall), contrast \(increaseContrast)")
                    XCTAssertLessThan(drawn, 1, "only the sung line is full white")
                }
                XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 0, tall: tall, ramp: ramp, reading: false), 1)
                XCTAssertGreaterThan(
                    PlayerLayout.lyricOpacity(offset: 1, tall: tall, ramp: ramp, reading: false),
                    PlayerLayout.lyricOpacity(offset: -1, tall: tall, ramp: ramp, reading: false),
                    "the next line is the brightest context line, as the board draws it"
                )
            }
        }
    }

    /// Where the contrast floor raised the board — the values the spec asked
    /// to be named.
    func testTheValuesTheFloorRaisedAreTheOnesBelowIt() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        // Column: −2 (0.22), −1 (0.36 → 0.42), +2 (0.32), +3 (0.18) are raised;
        // +1 (0.5) clears.
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: -2, tall: false, ramp: ramp, reading: false), 0.36)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: -1, tall: false, ramp: ramp, reading: false), 0.42)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 1, tall: false, ramp: ramp, reading: false), 0.5)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 2, tall: false, ramp: ramp, reading: false), 0.36)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 3, tall: false, ramp: ramp, reading: false), 0.36)
        // Tall: every board value above the sung line is under the floor.
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: -1, tall: true, ramp: ramp, reading: false), 0.42)
        XCTAssertEqual(PlayerLayout.lyricOpacity(offset: 4, tall: true, ramp: ramp, reading: false), 0.36)
    }

    /// With nothing lit — an intro, an outro — every line is a context line at
    /// the far floor, never the sung line's own full white.
    func testWithNothingLitEveryLineIsAtTheFarFloor() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        for tall in [false, true] {
            let drawn = PlayerLayout.lyricOpacity(offset: LyricsStage.unlitOffset, tall: tall, ramp: ramp, reading: false)
            XCTAssertEqual(drawn, ramp.floor)
        }
    }

    func testReadingByHandLiftsEveryContextLineToTheReadingStep() {
        let ramp = LyricRow.Ramp.panel(increaseContrast: false)
        for offset in [-3, -1, 1, 4] {
            XCTAssertEqual(PlayerLayout.lyricOpacity(offset: offset, tall: true, ramp: ramp, reading: true), ramp.reading)
        }
    }

    // MARK: - Animation (spec §2.4)

    func testTheStatesAnimateOnTheSpringsTheSpecNames() {
        XCTAssertEqual(PlayerLayout.animation(from: .player, to: .column, reduceMotion: false), Theme.openAnimation)
        XCTAssertEqual(PlayerLayout.animation(from: .column, to: .player, reduceMotion: false), Theme.openAnimation)
        XCTAssertEqual(PlayerLayout.animation(from: .column, to: .tall, reduceMotion: false), Theme.expandAnimation)
        XCTAssertEqual(PlayerLayout.animation(from: .tall, to: .column, reduceMotion: false), Theme.expandAnimation)
        // The tall state remembered across a visit to the player: the body moves,
        // so the spring that moves it.
        XCTAssertEqual(PlayerLayout.animation(from: .player, to: .tall, reduceMotion: false), Theme.expandAnimation)
        for from in PlayerLayout.State.allCases {
            for to in PlayerLayout.State.allCases {
                XCTAssertEqual(PlayerLayout.animation(from: from, to: to, reduceMotion: true), Theme.reducedMotion)
            }
        }
    }

    func testTheExpandSpringIsPointFourCriticallyDamped() {
        XCTAssertEqual(Theme.expandResponse, 0.40)
        XCTAssertEqual(Theme.expandAnimation, Animation.spring(response: 0.40, dampingFraction: 1.0))
        XCTAssertTrue(Theme.criticallyDampedSprings.contains(Theme.expandAnimation))
        XCTAssertEqual(Theme.expand(reduceMotion: true), Theme.reducedMotion)
        XCTAssertEqual(Theme.expand(reduceMotion: false), Theme.expandAnimation)
    }

    func testTheTallBodysBottomRadiusIsTwentySix() {
        XCTAssertEqual(Theme.openBottomRadius(tall: false), 22)
        XCTAssertEqual(Theme.openBottomRadius(tall: true), 26)
        XCTAssertEqual(Theme.openBottomRadius, 22, "the standard body's radius is where it was")
    }

    // MARK: - A new track (spec §5.1)

    func testANewTrackReturnsToThePlayerOnlyForASettledMiss() {
        let timeline = LyricTimeline(lines: [.init(at: 1, text: "a")], granularity: .line)
        // Not waiting on a new track: never.
        for availability in [LyricsAvailability.noLocalLyrics, .disabled, .ready(timeline)] {
            XCTAssertFalse(PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: false, availability: availability))
        }
        // Waiting: a miss that has settled returns, an answer that is not in
        // yet — or lyrics — keeps the column.
        XCTAssertTrue(PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: true, availability: .noLocalLyrics))
        XCTAssertTrue(PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: true, availability: .invalidLocalFile(.malformed)))
        XCTAssertTrue(PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: true, availability: .cannotLookUp(.noLength)))
        XCTAssertFalse(PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: true, availability: .resolving))
        XCTAssertFalse(PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: true, availability: .findingLocalLyrics))
        XCTAssertFalse(PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: true, availability: .ready(timeline)))
        XCTAssertFalse(
            PlayerLayout.shouldReturnToPlayer(awaitingNewTrack: true, availability: .disabled),
            "Show Lyrics off is the column's own state to say, not a miss to flee"
        )
    }

    // MARK: - The header's tools (spec §5.2, §6)

    func testTheHeaderToolsRideTheTrailingEdge() {
        for width in Self.widths {
            let translation = HeaderToolFrames.showTranslation(bodyWidth: width)
            let more = HeaderToolFrames.more(bodyWidth: width)
            let expand = HeaderToolFrames.expand(bodyWidth: width)
            XCTAssertEqual(translation, CGRect(x: width - 91, y: 8, width: 22, height: 22))
            XCTAssertEqual(more, CGRect(x: width - 65, y: 8, width: 22, height: 22))
            XCTAssertEqual(expand, CGRect(x: width - 39, y: 8, width: 22, height: 22), "Expand at (bw − 39, 8)")
            XCTAssertEqual(translation.maxX + 4, more.minX, "the pair is 4 apart")
            XCTAssertLessThan(more.maxX, expand.minX)
            XCTAssertEqual(expand.maxX, width - 17, "the 17 the source tag's icon ends at, so the corner is one")
            // Clear of the notch at its widest the boards use.
            XCTAssertGreaterThan(translation.minX, width / 2 + 220 / 2)
        }
    }
}
