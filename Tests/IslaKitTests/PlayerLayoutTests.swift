import AppKit
import XCTest
@testable import IslaKit

/// The Music player's board, as arithmetic (redesign 2026-10-15, spec §4.1,
/// §4.5, §4.8, §13). Every frame the view places is read from `PlayerLayout`,
/// so these numbers are the pixels: a board that moves fails here first.
@MainActor
final class PlayerLayoutTests: XCTestCase {
    private func layout(
        _ width: CGFloat = 560, header: CGFloat = 38, band: Bool = true, output: Bool = true
    ) -> PlayerLayout {
        PlayerLayout(bodyWidth: width, headerHeight: header, hasLyricBand: band, hasOutputButton: output)
    }

    // MARK: - Body to pane: the one conversion

    /// The pane's origin in body coordinates is 14 (the shell's padding) + 30 (the
    /// rail) + 14 (the gap) = 58 from the left and the header's height from the
    /// top: the cover's x of 58 is the pane's own left edge.
    func testThePaneStartsWhereTheRailAndThePaddingEnd() {
        XCTAssertEqual(PlayerLayout.paneLeading, 58)
        XCTAssertEqual(PlayerLayout.bodyInset + PlayerLayout.railWidth + PlayerLayout.railGap, 58)
        XCTAssertEqual(PlayerLayout.paneTrailing, 14)
        XCTAssertEqual(layout().inPane(layout().cover).minX, 0, "the cover is the pane's origin in x")
        XCTAssertEqual(layout().inPane(layout().cover).minY, 54 - 38)
    }

    /// A Mac whose notch is 32 pt tall must put the rows where a 38 pt notch
    /// does: the pane is simply taller there, and a body y is the pane y plus
    /// the header's height whatever it is.
    func testABodyYIsTheSameOnScreenWhateverTheHeaderHeight() {
        for header in [CGFloat(24), 32, 38, 44] {
            let l = layout(header: header)
            for rect in [l.cover, l.title, l.progress, l.transport, l.lyrics] {
                XCTAssertEqual(l.inPane(rect).minY + header, rect.minY, "header \(header)")
                XCTAssertEqual(l.inPane(rect).minX + PlayerLayout.paneLeading, rect.minX)
            }
        }
    }

    func testThePaneIsTheBodyLessTheRailAndBothPaddings() {
        for width in [CGFloat(480), 540, 560, 620] {
            XCTAssertEqual(PlayerLayout.paneWidth(bodyWidth: width), width - 72)
            XCTAssertEqual(PlayerLayout.bodyWidth(paneWidth: PlayerLayout.paneWidth(bodyWidth: width)), width)
        }
        let size = layout(560, header: 38).paneSize
        XCTAssertEqual(size.width, 488)
        XCTAssertEqual(size.height, 208 - NotchGeometry.bodyBottomPadding - 38)
    }

    /// The cover is the one the morph travels to: one description of its size.
    func testTheCoverIsTheOpenEndOfTheMorph() {
        let open = Theme.artworkMetrics(isOpen: true)
        XCTAssertEqual(open.side, 132, "redesign 2026-10-15, spec §4.1: it was 118")
        XCTAssertEqual(open.cornerRadius, 14)
        XCTAssertEqual(layout().cover.size, CGSize(width: open.side, height: open.side))
        XCTAssertEqual(PlayerLayout.emptyWell.size, layout().cover.size, "the empty well keeps the cover's frame")
    }

    // MARK: - The table at 560 (§4.1)

    func testTheBoardAt560WithALyricBand() {
        let l = layout()
        XCTAssertEqual(l.cover, CGRect(x: 58, y: 54, width: 132, height: 132))
        XCTAssertEqual(l.title.origin, CGPoint(x: 206, y: 52))
        XCTAssertEqual(l.title.width, 340, "bw − 220")
        XCTAssertEqual(l.subtitle.origin, CGPoint(x: 206, y: 73))
        XCTAssertEqual(l.sungLine.origin, CGPoint(x: 206, y: 99))
        XCTAssertEqual(l.nextLine.origin, CGPoint(x: 206, y: 117))
        XCTAssertEqual(l.progress, CGRect(x: 206, y: 141, width: 340, height: 12))
        XCTAssertEqual(l.shuffle, CGRect(x: 206, y: 160, width: 24, height: 24))
        XCTAssertEqual(l.transport, CGRect(x: 236, y: 158, width: 100, height: 28))
        XCTAssertEqual(l.repeatButton, CGRect(x: 342, y: 160, width: 24, height: 24))
        XCTAssertEqual(l.output, CGRect(x: 492, y: 159, width: 26, height: 26))
        XCTAssertEqual(l.lyrics, CGRect(x: 520, y: 159, width: 26, height: 26))
    }

    /// `Music-NoLyrics`: the band folds away; the metadata steps down to 70 and
    /// 91, and the progress row and everything under it rise by 20.
    func testTheBoardAt560WithNoLyric() {
        let l = layout(band: false)
        XCTAssertEqual(l.cover, layout().cover, "the cover does not move")
        XCTAssertEqual(l.title.minY, 70)
        XCTAssertEqual(l.subtitle.minY, 91)
        XCTAssertEqual(l.progress.minY, 121)
        XCTAssertEqual(l.transport.minY, 138)
        XCTAssertEqual(l.shuffle.minY, 140)
        XCTAssertEqual(l.repeatButton.minY, 140)
        XCTAssertEqual(l.output?.minY, 139)
        XCTAssertEqual(l.lyrics.minY, 139)
        XCTAssertEqual(layout().progress.minY - l.progress.minY, PlayerLayout.noLyricRise)
        XCTAssertEqual(PlayerLayout.noLyricRise, 20)
    }

    /// The band is two lines 18 apart, each as tall as a caption slot, so a
    /// line turning out is clipped to the slot it left (`MediaPane.captionHeight`).
    func testTheBandIsTwoSlotsEighteenApart() {
        let l = layout()
        XCTAssertEqual(l.nextLine.minY - l.sungLine.minY, 18)
        XCTAssertEqual(l.sungLine.height, MediaPane.captionHeight)
        XCTAssertEqual(l.nextLine.height, MediaPane.captionHeight)
        XCTAssertLessThan(l.nextLine.maxY, l.progress.minY, "the band ends above the progress row")
    }

    // MARK: - Width: 480, 540, 560, 620 (§4.5, §13)

    /// The Output button is there at every width the panel can be. There is no
    /// slider to fold into its menu below 540 any more: the volume left the
    /// island on 2026-10-16, so the width decides nothing about the button.
    func testTheOutputButtonIsThereAtEveryWidth() {
        for width in [CGFloat(480), 500, 539.5, 540, 560, 620] {
            XCTAssertNotNil(layout(width).output, "the Output button at \(width)")
        }
    }

    /// `Stress-Music-620`: the trailing pair rides the edge — the last control ends
    /// at `bw − 14`, the pane's own right edge.
    func testTheTrailingControlsRideTheEdge() {
        for width in [CGFloat(480), 540, 560, 620] {
            let l = layout(width)
            XCTAssertEqual(l.lyrics.maxX, width - 14, "the last control ends on the pane's right edge at \(width)")
            XCTAssertEqual(l.lyrics.minX, width - 40)
            XCTAssertEqual(l.output?.minX, width - 68)
            XCTAssertEqual(l.output!.maxX + 2, l.lyrics.minX, "two pt between the pair")
            XCTAssertEqual(l.progress.maxX, width - 14, "the progress row ends at the same edge")
            XCTAssertEqual(l.title.width, width - 220)
        }
        XCTAssertEqual(layout(480).title.width, 260)
    }

    /// Nothing in the controls row overlaps its neighbour at every width the
    /// panel can be.
    func testTheControlsRowNeverOverlaps() {
        for width in stride(from: CGFloat(480), through: 620, by: 20) {
            for band in [true, false] {
                let l = layout(width, band: band)
                var row = [l.shuffle, l.transport, l.repeatButton]
                if let output = l.output { row.append(output) }
                row.append(l.lyrics)
                for (a, b) in zip(row, row.dropFirst()) {
                    XCTAssertLessThanOrEqual(a.maxX, b.minX, "\(a) overlaps \(b) at \(width), band \(band)")
                }
            }
        }
    }

    /// Every frame is inside the pane, at 480 and 620 and on both notch heights:
    /// nothing is cut by the pane's own clip.
    func testEveryFrameIsInsideThePane() {
        for width in [CGFloat(480), 540, 560, 620] {
            for header in [CGFloat(32), 38] {
                for band in [true, false] {
                    let l = layout(width, header: header, band: band)
                    let pane = CGRect(origin: .zero, size: l.paneSize)
                    var frames = [l.cover, l.title, l.subtitle, l.progress, l.shuffle, l.transport,
                                  l.repeatButton, l.lyrics]
                    if band { frames += [l.sungLine, l.nextLine] }
                    if let output = l.output { frames.append(output) }
                    for frame in frames {
                        let local = l.inPane(frame)
                        XCTAssertTrue(pane.contains(local), "\(local) leaves \(pane) at \(width), header \(header), band \(band)")
                    }
                }
            }
        }
    }

    // MARK: - Output Button off (§4.5)

    /// Off hides the button and the band keeps its place.
    func testOutputButtonOffHidesItAndTheBandKeepsItsPlace() {
        let on = layout()
        let off = layout(output: false)
        XCTAssertNil(off.output)
        XCTAssertEqual(off.sungLine, on.sungLine)
        XCTAssertEqual(off.nextLine, on.nextLine)
        XCTAssertEqual(off.progress, on.progress)
        XCTAssertEqual(off.lyrics, on.lyrics, "the lyrics button stays on the edge")
    }

    // MARK: - Nothing playing (§4.8)

    func testTheEmptyPlayersTable() {
        XCTAssertEqual(
            PlayerLayout.emptyFrames(for: .nothingPlaying),
            PlayerLayout.EmptyFrames(titleY: 80, titleSize: 16, bodyY: 103, buttonsY: 132, footerY: nil)
        )
        XCTAssertEqual(
            PlayerLayout.emptyFrames(for: .readerDown),
            PlayerLayout.EmptyFrames(titleY: 70, titleSize: 16, bodyY: 93, buttonsY: 120, footerY: 153)
        )
        XCTAssertEqual(
            PlayerLayout.emptyFrames(for: .hiddenByMusicOnly),
            PlayerLayout.EmptyFrames(titleY: 72, titleSize: 16, bodyY: 115, buttonsY: 140, footerY: nil)
        )
        XCTAssertEqual(PlayerLayout.EmptyFrames.textWidth, 330)
        XCTAssertEqual(PlayerLayout.EmptyFrames.buttonHeight, 22)
        XCTAssertEqual(PlayerLayout.EmptyFrames.buttonSpacing, 8)
        XCTAssertEqual(PlayerLayout.columnLeading, 206, "the text starts where the player's column does")
    }

    // MARK: - The "Open …" buttons: order and cap

    private func app(_ id: String, _ name: String) -> AppIcons.Installed {
        AppIcons.Installed(
            bundleID: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), name: name,
            icon: NSImage(size: NSSize(width: 4, height: 4))
        )
    }

    func testTheButtonsRoomRunsFromTheTextColumnToThePanesEdge() {
        // The column starts 148 into the pane: 408 - 148 at 480, 548 - 148 at 620.
        XCTAssertEqual(PlayerLayout.openButtonsRoom(paneWidth: PlayerLayout.paneWidth(bodyWidth: 480)), 260)
        XCTAssertEqual(PlayerLayout.openButtonsRoom(paneWidth: PlayerLayout.paneWidth(bodyWidth: 560)), 340)
        XCTAssertEqual(PlayerLayout.openButtonsRoom(paneWidth: PlayerLayout.paneWidth(bodyWidth: 620)), 400)
        XCTAssertEqual(PlayerLayout.paneWidth(bodyWidth: 480), 408)
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
        for width in [CGFloat(480), 560, 620] {
            let row = MediaPane.openOffers(from: apps, paneWidth: PlayerLayout.paneWidth(bodyWidth: width))
            XCTAssertEqual(Array(row.apps.map(\.bundleID).prefix(2)), Array(order.prefix(2)), "both leaders at \(width)")
            XCTAssertEqual(row.apps.map(\.bundleID), Array(order.prefix(row.apps.count)), "a prefix, in order")
            XCTAssertGreaterThanOrEqual(row.apps.count, previous, "a wider panel never offers fewer")
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
        for bodyWidth in [CGFloat(480), 560, 620] {
            let room = PlayerLayout.openButtonsRoom(paneWidth: PlayerLayout.paneWidth(bodyWidth: bodyWidth))
            let row = MediaPane.openOffers(from: apps, paneWidth: PlayerLayout.paneWidth(bodyWidth: bodyWidth))
            XCTAssertEqual(Array(row.apps.map(\.bundleID).prefix(2)), ["com.apple.Music", "com.spotify.client"], "\(bodyWidth)")
            XCTAssertLessThanOrEqual(width(row), room, "\(bodyWidth): \(row.form)")
        }
        let at480 = MediaPane.openOffers(from: apps, paneWidth: PlayerLayout.paneWidth(bodyWidth: 480))
        XCTAssertEqual(at480.apps.count, 2, "no room for a third at 480, and the two are not given up for it")
        XCTAssertNotEqual(at480.form, .full, "Russian at 480 does not fit the full form")
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
        let width = PlayerLayout.paneWidth(bodyWidth: 620)
        XCTAssertEqual(MediaPane.openOffers(from: apps, paneWidth: width, message: .readerDown).apps.map(\.bundleID),
                       ["com.apple.Music", "com.spotify.client"])
        XCTAssertEqual(MediaPane.openOffers(from: apps, paneWidth: width, message: .nothingPlaying).apps.count, 3)
    }

    /// Only the reader-down state has a footnote, and it is the only one with a
    /// footer position: they travel together.
    func testOnlyTheReaderDownStateHasAFooter() {
        for message in [MediaPane.EmptyStateMessage.nothingPlaying, .readerDown, .hiddenByMusicOnly] {
            XCTAssertEqual(
                message.footnote != nil, PlayerLayout.emptyFrames(for: message).footerY != nil,
                "\(message)"
            )
        }
    }
}
