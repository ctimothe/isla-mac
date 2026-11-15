import CoreGraphics
import XCTest
@testable import IslaKit

/// A new track (redesign spec §3.5, amended 2026-11-15; owner: "make that new
/// song is playing motions to be exactly how the volume changer is shown, just
/// under the physical notch itself"). It used to widen the song's pill to
/// 520 × 50; it is now the volume pop-up — its shape under the notch, its
/// spring in and out, its content fade — with the song standing in the
/// pop-up's rows. Positions are read back in the spec's terms: x from the
/// shape's left edge, y under the reference's 38 pt notch.
final class NewTrackAlertTests: XCTestCase {
    private let notches: [CGSize] = [180, 185, 200, 220, 240].map { CGSize(width: $0, height: 38) }
        + [CGSize(width: 200, height: 32)]
    private let shape = ExpandedAlertShape.volume
    private let volume = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))

    private func shapeX(_ x: CGFloat) -> CGFloat { x + shape.topRadius }
    private func right(_ maxX: CGFloat, width: CGFloat) -> CGFloat { width - maxX + shape.topRadius }

    // MARK: The shape

    /// The pop-up's body at every notch and panel width: the reference's
    /// 245.4 wide less its shoulders (or the notch and 20), 65 under the notch.
    func testItIsThePopUpsShapeUnderTheNotchAtEveryNotch() {
        for notch in notches {
            for bodyWidth: CGFloat in [480, 560, 620] {
                let size = NotchViewModel.newTrackBodySize(notchSize: notch, bodyWidth: bodyWidth)
                XCTAssertEqual(size, NotchViewModel.hudBodySize(notchSize: notch, bodyWidth: bodyWidth))
                XCTAssertEqual(size.height, notch.height + 65, accuracy: 0.001, "hung under the notch as the pop-up is")
                XCTAssertGreaterThanOrEqual(size.width, notch.width + 20, "never narrower than the notch and 20")
            }
        }
        XCTAssertEqual(NewTrackAlertLayout.shape, HUDLayout.shape, "one shape, so the two cannot drift")
    }

    /// The pop-up's radii, read by the outline and both hit rects alike.
    func testItHasThePopUpsRadii() {
        XCTAssertEqual(IslandShapeRadii.closed(for: .peek).top, IslandShapeRadii.closed(for: .hud(volume)).top)
        XCTAssertEqual(IslandShapeRadii.closed(for: .peek).bottom, IslandShapeRadii.closed(for: .hud(volume)).bottom)
    }

    // MARK: The motion

    /// An expanded alert, as the pop-up is, so every change into it and out
    /// of it is the change the pop-up makes: over the song, from the bare
    /// notch, from another alert, and folding back into the song.
    func testItComesAndGoesAsThePopUpDoes() {
        let peek = IslandMotion.presentation(of: .peek)
        let hud = IslandMotion.presentation(of: .hud(volume))
        if case .expanded = peek {} else {
            XCTFail("an expanded alert, no longer the song's pill made wider")
        }
        for from in [IslandMotion.Presentation.compact("music"), .split("music"), .idle, .expanded("headphones")] {
            XCTAssertEqual(IslandMotion.transition(from: from, to: peek), IslandMotion.transition(from: from, to: hud),
                           "into it from \(from)")
        }
        for to in [IslandMotion.Presentation.compact("music"), .split("music"), .idle] {
            XCTAssertEqual(IslandMotion.transition(from: peek, to: to), IslandMotion.transition(from: hud, to: to),
                           "out of it to \(to)")
        }
    }

    /// The curves themselves, read from the source because the curve a
    /// transaction carries cannot be observed from outside a render: the
    /// controller shows and folds it on the pop-up's spring, the shell keys
    /// the pop-up's spring to it and fades its content in on the pop-up's
    /// fade, and the morph no longer carries it.
    func testItRidesThePopUpsSpringAndFade() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/NotchContentView.swift"), encoding: .utf8)
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/Notch/NotchController.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {\n            vm.isPeeking = true"),
                      "it arrives on the pop-up's spring")
        XCTAssertTrue(controller.contains("withAnimation(Theme.hud(reduceMotion: SystemAppearance.shared.reduceMotion)) {\n                vm.isPeeking = false"),
                      "and folds on it")
        XCTAssertTrue(shell.contains(".animation(Theme.hud(reduceMotion: reduceMotion), value: vm.isPeeking)"))
        // The shut island's switch: the peek's own case, up to the next one.
        let start = try XCTUnwrap(shell.range(of: "case .peek:\n"), "the peek draws its own content").upperBound
        let end = try XCTUnwrap(shell.range(of: "case .", range: start..<shell.endIndex)).lowerBound
        let peekCase = shell[start..<end]
        XCTAssertTrue(peekCase.contains("NewTrackAlertContent("))
        XCTAssertTrue(peekCase.contains(".transition(Theme.hudArrival(reduceMotion: reduceMotion))"),
                      "its content arrives on the pop-up's fade")
        XCTAssertFalse(shell.contains("peeking: vm.isPeeking"), "the morph's keys no longer carry it")
    }

    // MARK: The content

    /// The title where the output's name is: 15 regular, white 0.90, x 34,
    /// baseline 58, truncating at right 34.
    func testTheTitleIsWhereThePopUpsNameIs() {
        for notch in notches {
            let size = NotchViewModel.newTrackBodySize(notchSize: notch, bodyWidth: 560)
            XCTAssertEqual(NewTrackAlertLayout.titleLeading, HUDLayout.titleLeading)
            XCTAssertEqual(shapeX(NewTrackAlertLayout.titleLeading), 34, accuracy: 0.001)
            XCTAssertEqual(NewTrackAlertLayout.titleBaseline(notchHeight: notch.height),
                           HUDLayout.titleBaseline(notchHeight: notch.height))
            XCTAssertEqual(NewTrackAlertLayout.titleBaseline(notchHeight: 38), 58)
            XCTAssertEqual(
                right(NewTrackAlertLayout.titleLeading + NewTrackAlertLayout.titleWidth(islandWidth: size.width),
                      width: size.width),
                34, accuracy: 0.001
            )
        }
        XCTAssertEqual(NewTrackAlertLayout.titleSize, HUDLayout.titleSize)
        XCTAssertEqual(NewTrackAlertLayout.titleOpacity, HUDLayout.titleOpacity)
    }

    /// The cover where the symbol is: 20 × 20, radius 5, at (34, 70.5) under a
    /// 38 pt notch, centred on the bar's line; the artist along the bar, 10
    /// past the cover, 13 regular at white 0.55, baseline 85.
    func testTheCoverAndTheArtistStandInTheBarsRow() {
        for notch in notches {
            let size = NotchViewModel.newTrackBodySize(notchSize: notch, bodyWidth: 560)
            let cover = NewTrackAlertLayout.coverFrame(notchHeight: notch.height)
            let bar = HUDLayout.trackFrame(islandWidth: size.width, notchHeight: notch.height)
            XCTAssertEqual(cover.size, CGSize(width: 20, height: 20))
            XCTAssertEqual(shapeX(cover.minX), 34, accuracy: 0.001, "on the title's leading edge")
            XCTAssertEqual(cover.minY, 70.5 - 38 + notch.height, accuracy: 0.001)
            XCTAssertEqual(cover.midY, bar.midY, accuracy: 0.001, "centred on the bar's line")
            XCTAssertEqual(NewTrackAlertLayout.artistLeading, cover.maxX + 10, accuracy: 0.001)
            XCTAssertEqual(NewTrackAlertLayout.artistBaseline(notchHeight: notch.height), 85 - 38 + notch.height,
                           accuracy: 0.001)
        }
        XCTAssertEqual(NewTrackAlertLayout.coverRadius, 5)
        XCTAssertEqual(NewTrackAlertLayout.artistSize, 13)
        XCTAssertEqual(NewTrackAlertLayout.artistOpacity, 0.55)
    }

    /// The equalizer where the number is: the compact island's own 18 pt,
    /// ending right 34.5, centred on the bar's line; the artist stops 10
    /// before it and never runs negative.
    func testTheEqualizerStandsWhereTheNumberIs() {
        for notch in notches {
            let size = NotchViewModel.newTrackBodySize(notchSize: notch, bodyWidth: 560)
            let bars = NewTrackAlertLayout.equalizerFrame(islandWidth: size.width, notchHeight: notch.height)
            let bar = HUDLayout.trackFrame(islandWidth: size.width, notchHeight: notch.height)
            XCTAssertEqual(bars.size, CGSize(width: CompactIslandLayout.equalizerSide, height: CompactIslandLayout.equalizerSide))
            XCTAssertEqual(size.width - bars.maxX, HUDLayout.numberTrailingInset, accuracy: 0.001)
            XCTAssertEqual(right(bars.maxX, width: size.width), 34.5, accuracy: 0.001)
            XCTAssertEqual(bars.midY, bar.midY, accuracy: 0.001)
            let artistEnd = NewTrackAlertLayout.artistLeading + NewTrackAlertLayout.artistWidth(islandWidth: size.width)
            XCTAssertEqual(artistEnd, bars.minX - 10, accuracy: 0.001)
        }
        XCTAssertEqual(NewTrackAlertLayout.artistWidth(islandWidth: 40), 0, "never a negative width")
    }

    // MARK: What stays

    /// It holds as long as it did, keeps its rank, and needs a song.
    func testItKeepsItsHoldRankAndSong() {
        XCTAssertEqual(NotchMetrics.sneakPeekDuration, 2.2)
        XCTAssertEqual(IslandActivity.peek.rank, 10)
        XCTAssertEqual(
            IslandActivity.current(hud: nil, ambient: nil, isPeeking: true, musicIsVisible: false, shelfCount: 0),
            .none, "with no song there is nothing to show"
        )
        XCTAssertEqual(
            IslandActivity.current(hud: nil, ambient: nil, isPeeking: true, musicIsVisible: true, shelfCount: 0),
            .peek
        )
    }

    /// The song's pill no longer widens or grows for it: one size whatever
    /// the peek is doing, since the pill is faded under the alert.
    func testTheSongsPillNoLongerWidens() {
        let notch = CGSize(width: 220, height: 38)
        XCTAssertEqual(CompactMediaActivity.playing.bodySize(notchSize: notch, bodyWidth: 620),
                       CGSize(width: 290, height: 38))
    }
}

extension NewTrackAlertTests {
    /// Open on Hover never opens the panel over it: it hangs under the notch
    /// and comes to a resting pointer, so a skip would open the panel by
    /// itself. A click still opens the player (`Surface`).
    func testHoverNeverOpensThePanelOverIt() {
        XCTAssertFalse(NotchViewModel.arrivalMayOpen(over: .peek))
        XCTAssertTrue(NotchViewModel.arrivalMayOpen(over: .music))
        XCTAssertTrue(NotchViewModel.arrivalMayOpen(over: .none))
    }

    /// Under it the song's pill is faded, as under the pop-up, and is not the
    /// near end of the cover's travel: faded, it is laid out in the alert's
    /// height and its cover sits where nobody sees it. Read from the source,
    /// as the shell's other wiring is.
    func testThePillUnderItIsFadedAndDoesNotTravel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/NotchContentView.swift"), encoding: .utf8)
        XCTAssertTrue(shell.contains("&& !holdsLive && vm.activity != .peek ? 1 : 0"), "faded under it")
        XCTAssertTrue(shell.contains("compactActivity.isVisible && vm.activity != .peek"))
        XCTAssertTrue(shell.contains(".morph(MorphID.compact(MorphID.artwork, folded: !travelsFromThePill), in: morph)"))
        XCTAssertTrue(shell.contains(".morph(MorphID.compact(MorphID.equalizer, folded: !travelsFromThePill), in: morph)"))
    }
}
