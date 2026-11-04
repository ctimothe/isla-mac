import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The player's board, as arithmetic (spec §19.6, board `R2-Music-Open`). Every
/// frame the view places is read from `PlayerLayout`, so these numbers are the
/// pixels: a board that moves fails here first.
///
/// The board measures from the shape's left edge, shoulders and all: 425.4 wide
/// with a 34 pt shoulder each side, so the body the panel lays out is 357.4 and a
/// board x is a body x plus 34. Vertically the content starts under the header
/// row, so a board y is a content y plus 38. The rail, the tall page and the
/// lyric band that stood between the title and the progress are gone (§19.11):
/// the sung line is the subtitle's, so no frame depends on the lyrics.
@MainActor
final class PlayerLayoutTests: XCTestCase {
    private func layout(output: Bool = true) -> PlayerLayout {
        PlayerLayout(hasOutputButton: output)
    }

    // MARK: - The board to the content: the one conversion

    func testABoardXIsTheBodysPlusTheShoulderAndABoardYIsTheContentsPlus38() {
        XCTAssertEqual(PlayerLayout.shoulder, 34)
        XCTAssertEqual(PlayerLayout.referenceBodyWidth, 425.4 - 68, accuracy: 0.0001)
        XCTAssertEqual(PlayerLayout.x(54), 20)
        XCTAssertEqual(PlayerLayout.y(38), 0)
        XCTAssertEqual(PlayerLayout.y(164.6), 126.6, accuracy: 0.0001)
        XCTAssertEqual(layout().right(54.2), 357.4 + 34 - 54.2, accuracy: 0.0001, "an edge given from the shape's right")
        XCTAssertEqual(layout().centre, 357.4 / 2, accuracy: 0.0001, "m, the shape's centre, which is the body's")
        XCTAssertEqual(PlayerLayout.referenceHeaderHeight, 38)
        // The body's own size is the same arithmetic, from the layout type.
        let notch = CGSize(width: 185, height: 38)
        XCTAssertEqual(SurfaceLayout.bodySize(for: .player, bodyWidth: 560, notch: notch).width, PlayerLayout.referenceBodyWidth, accuracy: 0.0001)
    }

    /// The content is 160 tall on every notch: the body moves with the notch
    /// (`SurfaceLayout.y`), the content starts under the header row, and the
    /// dots have their own 16 under it (§19.16).
    func testTheContentIs160TallOnEveryNotch() {
        for height in [CGFloat(24), 32, 38, 44] {
            let body = SurfaceLayout.bodySize(for: .player, bodyWidth: 560, notch: CGSize(width: 185, height: height))
            XCTAssertEqual(body.height - height - SurfaceLayout.pageDotsBand, 160, accuracy: 0.0001, "notch \(height)")
        }
    }

    // MARK: - The table (§19.6)

    func testTheBoard() {
        let l = layout()
        XCTAssertEqual(l.cover, CGRect(x: 20, y: 5, width: 60, height: 60), "(54, 38), 60 × 60, 5 lower")
        XCTAssertEqual(PlayerLayout.coverRadius, 10)
        XCTAssertEqual(l.textLeading, 95.2, accuracy: 0.0001, "x 129.2")
        XCTAssertEqual(l.titleBaseline, 32, accuracy: 0.0001, "baseline 65, 5 lower")
        XCTAssertEqual(l.subtitleBaseline, 51.5, accuracy: 0.0001, "baseline 84.5, 5 lower")
        XCTAssertEqual(PlayerLayout.titleSize, 16)
        XCTAssertEqual(PlayerLayout.subtitleSize, 14)
        XCTAssertEqual(l.equalizer.size, CGSize(width: 23, height: 18))
        XCTAssertEqual(l.equalizer.minY, 16, accuracy: 0.0001, "top 49, 5 lower")
        XCTAssertEqual(l.equalizer.maxX, 337.2, accuracy: 0.0001, "ending 54.2 from the shape's right edge")
        XCTAssertEqual(l.timesTop, 76, accuracy: 0.0001, "114")
        XCTAssertEqual(l.elapsedLeading, 19.5, accuracy: 0.0001, "53.5")
        XCTAssertEqual(l.timesTrailing, 337.2, accuracy: 0.0001, "ending 54.2 from the right")
        XCTAssertEqual(l.progress.minX, 62.7, accuracy: 0.0001, "96.7")
        XCTAssertEqual(l.progress.minY, 79.4, accuracy: 0.0001, "117.4")
        XCTAssertEqual(l.progress.width, 231.3, accuracy: 0.0001)
        XCTAssertEqual(l.progress.height, 7)
        XCTAssertEqual(PlayerLayout.progressRadius, 3.5)
        XCTAssertEqual(l.controlsMidY, 126.6, accuracy: 0.0001, "164.6")
        XCTAssertEqual(PlayerLayout.hitTarget, 42, "every control is a 42 × 42 target")
    }

    /// The cover sits evenly between the header's 26 pt icons and the times
    /// row on the reference notch — 11 above and 11 below — and on every
    /// notch the icons never reach it (owner, 2026-10-18: "too close with the
    /// top-left and top-right icons").
    func testTheCoverSitsEvenlyBetweenTheHeaderIconsAndTheTimes() {
        let l = layout()
        let notch = SurfaceLayout.referenceNotchHeight
        let iconBottom = SurfaceHeaderLayout.gear(bodyWidth: 560, notchHeight: notch).maxY - notch
        XCTAssertEqual(l.cover.minY - iconBottom, 11, accuracy: 0.0001, "above the cover")
        XCTAssertEqual(l.timesTop - l.cover.maxY, 11, accuracy: 0.0001, "below the cover")
        for height in [CGFloat(24), 32, 38, 44] {
            let bottom = SurfaceHeaderLayout.gear(bodyWidth: 560, notchHeight: height).maxY - height
            XCTAssertGreaterThan(l.cover.minY - bottom, 3, "notch \(height)")
        }
        XCTAssertEqual(l.timesTop, 76, accuracy: 0.0001, "the times, the bar and the controls do not move")
    }

    /// Title and artist are joined by a dash, in the row, its tooltip and its
    /// label; a song with no artist is its title alone.
    func testTheTitleAndArtistAreJoinedByADash() {
        XCTAssertEqual(MediaPane.artistSeparator, " – ")
        XCTAssertEqual(
            MediaPane.titleLine(title: "Lover, You Should've Come Over", artist: "Jeff Buckley"),
            "Lover, You Should've Come Over – Jeff Buckley"
        )
        XCTAssertEqual(MediaPane.titleLine(title: "Be a Ghost", artist: nil), "Be a Ghost")
        XCTAssertEqual(MediaPane.titleLine(title: "Be a Ghost", artist: ""), "Be a Ghost")
    }

    /// A line that fits stands still; one that does not travels its own width
    /// and the gap at 30 pt a second, so the copy lands where it began, after
    /// a 2.5 s rest. "Lover, You Should've Come Over – Jeff Buckley" at 16
    /// medium is longer than the title's 211 pt at 480 and scrolls.
    func testALongTitleScrollsAndAShortOneStandsStill() {
        typealias Line = MarqueeLine<EmptyView>
        let room = layout().titleWidth
        XCTAssertFalse(Line.overflows(contentWidth: room, room: room))
        XCTAssertFalse(Line.overflows(contentWidth: room + 0.4, room: room), "a rounding is not a scroll")
        XCTAssertTrue(Line.overflows(contentWidth: room + 1, room: room))
        XCTAssertEqual(Line.travel(contentWidth: 300), 332)
        XCTAssertEqual(Line.travelTime(contentWidth: 300), 332.0 / 30, accuracy: 0.0001)
        XCTAssertEqual(Line.rest, 2.5)
        let font = NSFont.systemFont(ofSize: PlayerLayout.titleSize, weight: .medium)
        let words = MediaPane.titleLine(title: "Lover, You Should've Come Over", artist: "Jeff Buckley") as NSString
        XCTAssertTrue(Line.overflows(contentWidth: words.size(withAttributes: [.font: font]).width, room: room))
        let short = MediaPane.titleLine(title: "Be a Ghost", artist: "M25") as NSString
        XCTAssertFalse(Line.overflows(contentWidth: short.size(withAttributes: [.font: font]).width, room: room))
    }

    /// The title truncates before the equalizer, 8 short of it; the subtitle
    /// runs to the equalizer's right edge, with nothing standing beside it.
    func testTheTextColumnEndsAtTheEqualizer() {
        let l = layout()
        XCTAssertEqual(l.titleWidth, l.equalizer.minX - 8 - l.textLeading, accuracy: 0.0001)
        XCTAssertEqual(l.titleWidth, 211, accuracy: 0.0001)
        XCTAssertEqual(l.subtitleWidth, 242, accuracy: 0.0001)
        XCTAssertEqual(l.textLeading + l.subtitleWidth, l.equalizer.maxX, accuracy: 0.0001)
        XCTAssertGreaterThan(l.textLeading, l.cover.maxX, "the text starts right of the cover")
    }

    /// The five controls' centres: `m − 133`, `m − 69`, `m`, `m + 69`, `m + 133`,
    /// each a 42 pt target on the row, with the glyph sizes the board gives.
    func testTheFiveControlsAreCentredWhereTheBoardSaysTheyAre() {
        let l = layout()
        let m = l.centre
        for (control, offset) in [
            (PlayerLayout.Control.favourite, -133), (.previous, -69), (.playPause, 0), (.next, 69), (.output, 133),
        ] as [(PlayerLayout.Control, CGFloat)] {
            let target = l.target(control)
            XCTAssertEqual(target.midX, m + offset, accuracy: 0.0001, "\(control)")
            XCTAssertEqual(target.midY, 126.6, accuracy: 0.0001, "\(control)")
            XCTAssertEqual(target.size, CGSize(width: 42, height: 42), "\(control)")
        }
        XCTAssertEqual(PlayerLayout.Control.favourite.glyph, CGSize(width: 28, height: 27))
        XCTAssertEqual(PlayerLayout.Control.output.glyph, CGSize(width: 28, height: 27))
        XCTAssertEqual(PlayerLayout.Control.previous.glyph, CGSize(width: 35, height: 22))
        XCTAssertEqual(PlayerLayout.Control.next.glyph, CGSize(width: 35, height: 22))
        XCTAssertEqual(PlayerLayout.Control.playPause.glyph, CGSize(width: 29, height: 34))
        XCTAssertEqual(l.output, l.target(.output))
    }

    /// Nothing in the controls row overlaps its neighbour: the 69 pt pitch is
    /// wider than a 42 pt target, and a glyph is never wider than its target.
    func testTheControlsRowNeverOverlaps() {
        let l = layout()
        let row = PlayerLayout.Control.allCases.sorted { $0.offset < $1.offset }
        for (a, b) in zip(row, row.dropFirst()) {
            XCTAssertLessThanOrEqual(l.target(a).maxX, l.target(b).minX, "\(a) overlaps \(b)")
        }
        for control in row {
            XCTAssertLessThanOrEqual(control.glyph.width, PlayerLayout.hitTarget)
            XCTAssertLessThanOrEqual(control.glyph.height, PlayerLayout.hitTarget)
        }
    }

    /// Every frame is inside the content, at the reference width and at the
    /// wider body a wide notch asks for (§19.2: never narrower than the notch plus
    /// 20): nothing is cut by the pane's own clip.
    func testEveryFrameIsInsideTheContent() {
        for bodyWidth in [PlayerLayout.referenceBodyWidth, 420, 460] {
            let l = PlayerLayout(bodyWidth: bodyWidth)
            let content = CGRect(x: 0, y: 0, width: bodyWidth, height: 160)
            var frames = [l.cover, l.equalizer, l.progress]
            frames += PlayerLayout.Control.allCases.map { l.target($0) }
            for frame in frames {
                XCTAssertTrue(content.contains(frame), "\(frame) leaves \(content) at \(bodyWidth)")
            }
            XCTAssertLessThanOrEqual(l.timesTrailing, bodyWidth)
        }
    }

    /// A body wider than the reference — the notch plus 20 asks for it — moves
    /// the trailing edge with the shape and leaves the leading content where
    /// it was (§19.2).
    func testAWiderBodyKeepsTheLeadingContentAndMovesTheTrailingEdge() {
        let narrow = PlayerLayout(bodyWidth: PlayerLayout.referenceBodyWidth)
        let wide = PlayerLayout(bodyWidth: PlayerLayout.referenceBodyWidth + 60)
        XCTAssertEqual(wide.cover, narrow.cover)
        XCTAssertEqual(wide.textLeading, narrow.textLeading)
        XCTAssertEqual(wide.elapsedLeading, narrow.elapsedLeading)
        XCTAssertEqual(wide.progress.minX, narrow.progress.minX)
        XCTAssertEqual(wide.equalizer.maxX - narrow.equalizer.maxX, 60, accuracy: 0.0001)
        XCTAssertEqual(wide.timesTrailing - narrow.timesTrailing, 60, accuracy: 0.0001)
        XCTAssertEqual(wide.progress.width - narrow.progress.width, 60, accuracy: 0.0001)
    }

    /// The cover is the one the morph travels to: one description of its size.
    /// The player's cover is 60 pt at radius 10 (§19.6) — and
    /// `Theme.artworkMetrics(isOpen: true)`, the morph's open end, must say the
    /// same, or the cover travels to a size it is not drawn at.
    func testTheCoverIsTheOpenEndOfTheMorph() {
        let open = Theme.artworkMetrics(isOpen: true)
        XCTAssertEqual(open.side, 60, "§19.6: the cover is 60 × 60")
        XCTAssertEqual(open.cornerRadius, PlayerLayout.coverRadius)
        XCTAssertEqual(layout().cover.size, CGSize(width: open.side, height: open.side))
        XCTAssertEqual(layout().emptyWell, layout().cover, "the empty well keeps the cover's frame")
    }

    // MARK: - Output Button off (§4.5)

    /// Off hides the button and the other four keep their places.
    func testOutputButtonOffHidesItAndTheOthersKeepTheirPlaces() {
        let on = layout()
        let off = layout(output: false)
        XCTAssertNotNil(on.output)
        XCTAssertNil(off.output)
        for control in PlayerLayout.Control.allCases where control != .output {
            XCTAssertEqual(off.target(control), on.target(control), "\(control)")
        }
        XCTAssertEqual(off.progress, on.progress)
    }

    // MARK: - Nothing playing (§4.8, in §19.6's frame)

    /// The empty player keeps the player's frame: the well where the cover goes,
    /// the status and its line beside it in the title's column, the remedy on
    /// the controls row (8 above its middle, a 22 pt row as wide as the times'),
    /// and the reader-down pointer 8 under it.
    func testTheEmptyPlayersTable() {
        let l = layout()
        for message in [MediaPane.EmptyStateMessage.nothingPlaying, .hiddenByMusicOnly] {
            let frames = PlayerLayout.emptyFrames(for: message)
            XCTAssertEqual(frames.text, CGRect(x: l.textLeading, y: l.cover.minY, width: l.subtitleWidth, height: 92), "\(message)")
            XCTAssertEqual(frames.headlineSize, 14)
            XCTAssertEqual(frames.buttons.minX, l.elapsedLeading, accuracy: 0.0001)
            XCTAssertEqual(frames.buttons.width, l.timesTrailing - l.elapsedLeading, accuracy: 0.0001)
            XCTAssertEqual(frames.buttons.minY, l.controlsMidY - 11 - 8, accuracy: 0.0001)
            XCTAssertEqual(frames.buttons.height, 22)
            XCTAssertNil(frames.footer, "\(message)")
        }
        let down = PlayerLayout.emptyFrames(for: .readerDown)
        guard let footer = down.footer else { return XCTFail("the reader-down state has a footer") }
        XCTAssertEqual(footer, CGRect(x: l.elapsedLeading, y: down.buttons.maxY + 8, width: down.buttons.width, height: 14))
        XCTAssertLessThanOrEqual(footer.maxY, 160, "the footer is inside the content")
        XCTAssertEqual(PlayerLayout.EmptyFrames.buttonHeight, 22)
        XCTAssertEqual(PlayerLayout.EmptyFrames.buttonSpacing, 8)
    }

    // MARK: - The "Open …" buttons: order and cap

    private func app(_ id: String, _ name: String) -> AppIcons.Installed {
        AppIcons.Installed(
            bundleID: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), name: name,
            icon: NSImage(size: NSSize(width: 4, height: 4))
        )
    }

    /// The row of buttons has the controls row's own span: from the elapsed
    /// time's leading edge to the remaining time's trailing one — 317.7 at the
    /// reference body — and a wider body, which the notch plus 20 can ask for,
    /// gives it the extra.
    func testTheButtonsRoomRunsFromTheElapsedTimeToTheRemainingOne() {
        let reference = PlayerLayout.referenceBodyWidth
        XCTAssertEqual(PlayerLayout.openButtonsRoom(bodyWidth: reference), 317.7, accuracy: 0.0001)
        XCTAssertEqual(PlayerLayout.openButtonsRoom(bodyWidth: reference + 60), 377.7, accuracy: 0.0001)
        XCTAssertEqual(
            PlayerLayout.openButtonsRoom(bodyWidth: reference),
            PlayerLayout().timesTrailing - PlayerLayout().elapsedLeading, accuracy: 0.0001
        )
    }

    func testAButtonIsPaddingIconGapAndLabel() {
        XCTAssertEqual(PlayerLayout.openButtonWidth(labelWidth: 70), 10 + 10 + 16 + 6 + 70)
        XCTAssertEqual(PlayerLayout.openButtonIconSide, 16)
    }

    /// Fits all three: the first three in order, no more than three.
    func testAtMostThreeButtonsInTheGivenOrder() {
        let apps = [app("a", "A"), app("b", "B"), app("c", "C"), app("d", "D"), app("e", "E")]
        let chosen = PlayerLayout.openButtonApps(apps, room: 10_000) { _ in 40 }
        XCTAssertEqual(chosen.map(\.bundleID), ["a", "b", "c"])
        XCTAssertEqual(PlayerLayout.maxOpenButtons, 3)
        XCTAssertEqual(PlayerLayout.openButtonApps([], room: 400) { _ in 40 }, [])
    }

    /// Never a truncated button: what does not fit is left out. Each button is
    /// 42 + 40 = 82 wide; three need 82 × 3 + 16 = 262.
    func testTheCapFollowsTheRoomAtEachWidth() {
        let apps = [app("a", "A"), app("b", "B"), app("c", "C")]
        func count(_ room: CGFloat) -> Int { PlayerLayout.openButtonApps(apps, room: room) { _ in 40 }.count }
        XCTAssertEqual(count(262), 3, "exactly fits")
        XCTAssertEqual(count(261), 2, "one point short: the third is left out, not squeezed")
        XCTAssertEqual(count(172), 2)
        XCTAssertEqual(count(171), 1)
        XCTAssertEqual(count(82), 1)
        XCTAssertEqual(count(81), 0)
    }

    /// A long name stops the row where it stands: a shorter one behind it does
    /// not jump the queue, because Apple Music and Spotify lead on purpose.
    func testALongNameEndsTheRowAndNothingSkipsAheadOfIt() {
        let apps = [app("a", "A"), app("b", "Bbbbbbbbbbbbbbbbbbbb"), app("c", "C")]
        let chosen = PlayerLayout.openButtonApps(apps, room: 260) { $0.bundleID == "b" ? 200 : 20 }
        XCTAssertEqual(chosen.map(\.bundleID), ["a"])
    }

    /// Measured, not guessed: the real label in the `body` role grows with its
    /// text, and with the real Russian labels the row at every width still
    /// holds Apple Music and Spotify, in order, ahead of anything else.
    func testAMeasuredLabelIsPositiveAndGrowsWithTheText() {
        LabLocalization.use("ru")
        defer { LabLocalization.use("en") }
        let short = PlayerLayout.measuredLabelWidth(localized("Open %@", "Spotify"))
        let long = PlayerLayout.measuredLabelWidth(localized("Open %@", "Яндекс Музыка"))
        XCTAssertEqual(localized("Open %@", "Spotify"), "Открыть Spotify")
        XCTAssertGreaterThan(short, 30)
        XCTAssertGreaterThan(long, short)
        let apps = [app("com.apple.Music", "Apple Music"), app("com.spotify.client", "Spotify"), app("x", "Яндекс Музыка")]
        let order = ["com.apple.Music", "com.spotify.client", "x"]
        var previous = 0
        let reference = PlayerLayout.referenceBodyWidth
        for width in [reference, reference + 60, reference + 120] {
            let row = MediaPane.openOffers(from: apps, bodyWidth: width)
            XCTAssertEqual(Array(row.apps.map(\.bundleID).prefix(2)), Array(order.prefix(2)), "both leaders at \(width)")
            XCTAssertEqual(row.apps.map(\.bundleID), Array(order.prefix(row.apps.count)), "a prefix, in order")
            XCTAssertGreaterThanOrEqual(row.apps.count, previous, "a wider body never offers fewer")
            previous = row.apps.count
        }
    }

    /// The compact rule with the real Russian labels: Apple Music and Spotify are
    /// always offered; whatever does not fit at full size is drawn tighter, then
    /// without icons; and the row is never wider than the room.
    func testRussianKeepsAppleMusicAndSpotifyAtEveryWidth() {
        LabLocalization.use("ru")
        defer { LabLocalization.use("en") }
        let apps = [app("com.apple.Music", "Apple Music"), app("com.spotify.client", "Spotify"), app("x", "Deezer")]
        func width(_ row: PlayerLayout.OpenButtonRow) -> CGFloat {
            row.apps.reduce(0) {
                $0 + PlayerLayout.openButtonWidth(
                    labelWidth: PlayerLayout.measuredLabelWidth(localized("Open %@", $1.name)), form: row.form)
            } + PlayerLayout.EmptyFrames.buttonSpacing * CGFloat(row.apps.count - 1)
        }
        let reference = PlayerLayout.referenceBodyWidth
        for bodyWidth in [reference, reference + 60] {
            let room = PlayerLayout.openButtonsRoom(bodyWidth: bodyWidth)
            let row = MediaPane.openOffers(from: apps, bodyWidth: bodyWidth)
            XCTAssertEqual(Array(row.apps.map(\.bundleID).prefix(2)), ["com.apple.Music", "com.spotify.client"], "\(bodyWidth)")
            XCTAssertLessThanOrEqual(width(row), room, "\(bodyWidth): \(row.form)")
        }
        let atReference = MediaPane.openOffers(from: apps, bodyWidth: reference)
        XCTAssertEqual(atReference.apps.count, 2, "no room for a third, and the two are not given up for it")
    }

    /// The forms in order, by number: leaders that fit at full size stay full and
    /// let extras follow; otherwise tight, then iconless, and no extras.
    func testTheCompactFormsComeInOrderAndExtrasNeedTheFullForm() {
        let lead = [app("com.apple.Music", "A"), app("com.spotify.client", "S")]
        let extra = app("x", "X")
        // Each leader: full 42 + 40 = 82, tight 34 + 40 = 74, iconless 12 + 40 = 52.
        func row(_ room: CGFloat, _ apps: [AppIcons.Installed]) -> PlayerLayout.OpenButtonRow {
            PlayerLayout.openButtonRow(apps, room: room) { _ in 40 }
        }
        XCTAssertEqual(row(172, lead + [extra]).form, .full)
        XCTAssertEqual(row(172, lead + [extra]).apps.count, 2, "172 holds two full, not three")
        XCTAssertEqual(row(262, lead + [extra]).apps.count, 3)
        XCTAssertEqual(row(171, lead + [extra]).form, .tight)
        XCTAssertEqual(row(156, lead + [extra]).form, .tight)
        XCTAssertEqual(row(156, lead + [extra]).apps.map(\.bundleID), ["com.apple.Music", "com.spotify.client"], "no extras in a compact form")
        XCTAssertEqual(row(155, lead + [extra]).form, .iconless)
        XCTAssertEqual(row(112, lead).form, .iconless)
        XCTAssertFalse(PlayerLayout.OpenButtonForm.iconless.showsIcon)
        XCTAssertLessThan(PlayerLayout.OpenButtonForm.tight.horizontalPadding, PlayerLayout.OpenButtonForm.full.horizontalPadding)
    }

    /// Reader down: only `PlayerBridge` works, so only Music and Spotify are
    /// offered, whatever else is installed.
    func testReaderDownOffersOnlyWhatPlayerBridgeCanShow() {
        let apps = [app("com.apple.Music", "Apple Music"), app("com.spotify.client", "Spotify"), app("com.deezer.deezer-desktop", "Deezer")]
        // Room is not the variable here: a body wide enough for all three.
        let width: CGFloat = 700
        XCTAssertEqual(MediaPane.openOffers(from: apps, bodyWidth: width, message: .readerDown).apps.map(\.bundleID),
                       ["com.apple.Music", "com.spotify.client"])
        XCTAssertEqual(MediaPane.openOffers(from: apps, bodyWidth: width, message: .nothingPlaying).apps.count, 3)
    }

    /// Only the reader-down state has a footnote, and it is the only one with a
    /// footer position: they travel together.
    func testOnlyTheReaderDownStateHasAFooter() {
        for message in [MediaPane.EmptyStateMessage.nothingPlaying, .readerDown, .hiddenByMusicOnly] {
            XCTAssertEqual(
                message.footnote != nil, PlayerLayout.emptyFrames(for: message).footer != nil,
                "\(message)"
            )
        }
    }

    // MARK: - Nothing playing, in Russian (spec §13)

    /// The height SwiftUI gives `text` wrapped at `width` in the empty player's
    /// fonts — the real layout, measured the way the pane draws it, so a line
    /// the view would wrap or cut is one here.
    private func wrappedHeight(_ text: String, size: CGFloat, weight: Font.Weight, width: CGFloat) -> CGFloat {
        let view = Text(text).islandFont(size, weight: weight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
        return NSHostingView(rootView: view).fittingSize.height
    }

    private func lineCount(_ text: String, size: CGFloat, weight: Font.Weight, width: CGFloat) -> Int {
        let one = wrappedHeight("Ag", size: size, weight: weight, width: width)
        return Int((wrappedHeight(text, size: size, weight: weight, width: width) / one).rounded())
    }

    /// The reader-down pointer's natural width: the symbol, 6, the words, in
    /// the body role, as `MediaPane.emptyState` lays out its footer.
    private func footnoteWidth(_ text: String) -> CGFloat {
        let view = HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(text)
        }
        .islandFont(.body, weight: .regular)
        .fixedSize()
        return NSHostingView(rootView: view).fittingSize.width
    }

    /// "Every layout must hold at 480 and 620 and in Russian" (spec §13). The
    /// player is the same 357.4 at every panel width, so its empty state is
    /// one layout; in both languages the headline must fit its two lines, the
    /// line of why its three, the pointer its one, and the column must end
    /// above the buttons. The Russian pointer used to need 379 pt of a 317.7 pt
    /// row and end in "…", and the Music Only headline wrapped to three lines
    /// and lost its last word, the very word that says where to look.
    func testTheEmptyPlayerCutsNothingInEnglishOrRussian() {
        let notch = CGSize(width: 185, height: 38)
        for panel in [CGFloat(480), 560, 620] {
            XCTAssertEqual(SurfaceLayout.bodySize(for: .player, bodyWidth: panel, notch: notch).width,
                           PlayerLayout.referenceBodyWidth, accuracy: 0.0001, "the player is one width at \(panel)")
        }
        defer { LabLocalization.use("en") }
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            for message in [MediaPane.EmptyStateMessage.nothingPlaying, .readerDown, .hiddenByMusicOnly] {
                let frames = PlayerLayout.emptyFrames(for: message)
                let column = frames.text.width
                let headline = lineCount(message.headline, size: frames.headlineSize, weight: .semibold, width: column)
                XCTAssertLessThanOrEqual(headline, 2, "\(language) \(message): «\(message.headline)» wraps to \(headline) lines in \(column)")
                let caption = lineCount(message.caption, size: Theme.TypeRole.reading.size, weight: .regular, width: column)
                XCTAssertLessThanOrEqual(caption, 3, "\(language) \(message): «\(message.caption)» wraps to \(caption) lines in \(column)")
                let tall = wrappedHeight(message.headline, size: frames.headlineSize, weight: .semibold, width: column) + 3
                    + wrappedHeight(message.caption, size: Theme.TypeRole.reading.size, weight: .regular, width: column)
                XCTAssertLessThanOrEqual(frames.text.minY + tall, frames.buttons.minY,
                                         "\(language) \(message): the column (\(tall) tall) runs into the buttons")
                if let footnote = message.footnote, let footer = frames.footer {
                    let width = footnoteWidth(footnote)
                    XCTAssertLessThanOrEqual(width, footer.width, "\(language): «\(footnote)» needs \(width) of \(footer.width)")
                }
            }
        }
    }
}
