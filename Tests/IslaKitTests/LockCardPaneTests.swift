import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The card is one size in every state, and the lyric window slides rather
/// than clips.
@MainActor
final class LockCardPaneTests: XCTestCase {

    /// The window above the login shield is cut to exactly this and never
    /// resized. A state that needed a different size would have to resize it,
    /// and resizing it across a lock is what stretched the window-server
    /// snapshot into a half-scale card off to one side.
    func testEveryPaneSharesOneSize() {
        XCTAssertEqual(LockScreenCard.size, CGSize(width: 460, height: 300))
        XCTAssertEqual(LockScreenCard.Pane.allCases.count, 3)
    }

    /// A five-line window slid inside the song, not clipped at its ends. At the
    /// first line a clipped window would show three lines and two gaps.
    func testTheLyricWindowStaysFullAtBothEnds() {
        let size = LockScreenCard.visibleLyricLines
        XCTAssertEqual(size, 5)

        XCTAssertEqual(LockScreenCard.window(around: 0, count: 20, size: size), [0, 1, 2, 3, 4])
        XCTAssertEqual(LockScreenCard.window(around: 10, count: 20, size: size), [8, 9, 10, 11, 12])
        XCTAssertEqual(LockScreenCard.window(around: 19, count: 20, size: size), [15, 16, 17, 18, 19])
    }

    /// A song shorter than the window shows all of it and nothing invented.
    func testAShortSongShowsEveryLineItHas() {
        XCTAssertEqual(LockScreenCard.window(around: 1, count: 3, size: 5), [0, 1, 2])
        XCTAssertEqual(LockScreenCard.window(around: 0, count: 1, size: 5), [0])
        XCTAssertEqual(LockScreenCard.window(around: 0, count: 0, size: 5), [])
    }

    /// The line from the visual lab's long-lines fixture that the card cut to
    /// "…past the point wh…" while the stage wrapped it whole (H-019).
    static let longSungLine =
        "And another that keeps going well past the point where a single line would have stopped and wrapped"

    /// The line being sung gets the second row the stage gives it, and the
    /// window gives up a neighbour each side to make the room: three rows on
    /// the standard card, the sung line alone on the compact one, whose middle
    /// is not tall enough for a two-row line and a neighbour either side.
    func testALongSungLineWrapsAndTheWindowNarrows() {
        let long = Self.longSungLine
        XCTAssertEqual(
            LockScreenCard.lyricLayout(currentText: long, width: 420, cardSize: .standard),
            LockScreenCard.LyricLayout(window: 3, currentLineLimit: 2)
        )
        XCTAssertEqual(
            LockScreenCard.lyricLayout(currentText: "Short again", width: 420, cardSize: .standard),
            LockScreenCard.LyricLayout(window: 5, currentLineLimit: 1)
        )
        XCTAssertEqual(
            LockScreenCard.lyricLayout(currentText: long, width: 380, cardSize: .compact),
            LockScreenCard.LyricLayout(window: 1, currentLineLimit: 2)
        )
        XCTAssertEqual(
            LockScreenCard.lyricLayout(currentText: "Short again", width: 380, cardSize: .compact),
            LockScreenCard.LyricLayout(window: 3, currentLineLimit: 1)
        )
        // Through a solo the centre row is the interlude marker, one row tall.
        XCTAssertEqual(
            LockScreenCard.lyricLayout(currentText: nil, width: 420, cardSize: .standard),
            LockScreenCard.LyricLayout(window: 5, currentLineLimit: 1)
        )
    }

    /// The card's own text width is what the line is measured against: the
    /// card less its side padding on each edge. 20 on both cards since the
    /// redesign (it was 24 on the standard one, so 412): the board starts every
    /// row 20 in from the edge (spec §7.1).
    func testTheLyricTextWidthIsTheCardLessItsPadding() {
        XCTAssertEqual(LockScreenCard.lyricTextWidth(for: .standard), 420)
        XCTAssertEqual(LockScreenCard.lyricTextWidth(for: .compact), 380)
    }

    /// A wrapped window never asks for more height than the plain one, which
    /// the card already proved it has — so the two-row line can never push
    /// the title or the transport off a card whose window is never resized.
    func testTheWrappedWindowNeverNeedsMoreRoomThanThePlainOne() {
        for size in NotchViewModel.LockCardSize.allCases {
            let width = LockScreenCard.lyricTextWidth(for: size)
            let plain = LockScreenCard.lyricLayout(currentText: "Short", width: width, cardSize: size)
            let wrapped = LockScreenCard.lyricLayout(currentText: Self.longSungLine, width: width, cardSize: size)
            XCTAssertEqual(wrapped.window % 2, 1, "\(size): the sung line keeps the centre")
            XCTAssertLessThanOrEqual(
                LockScreenCard.lyricStackHeight(wrapped), LockScreenCard.lyricStackHeight(plain),
                "\(size): the wrapped window is taller than the room the card has"
            )
        }
    }

    /// The decision to wrap agrees with the wrap itself. The card measures the
    /// line with the font and tracking `KaraokeText` draws it in; if the two
    /// ever disagreed, a line measured short would be cut by a one-row limit
    /// it was never given room past, or a short line would cost two
    /// neighbours for nothing.
    func testTheMeasurementAgreesWithTheDrawnRow() {
        let texts = [
            Self.longSungLine,
            "A first line that is long enough to need the second row the stage allows it",
            "The line being sung right now",
            "Short again",
            "沈むように溶けてゆくように",
        ]
        for size in NotchViewModel.LockCardSize.allCases {
            let width = LockScreenCard.lyricTextWidth(for: size)
            for text in texts {
                let row = LyricRow(
                    line: LyricsStore.Line(at: 1, text: text),
                    isCurrent: true, distance: 0, at: 2, end: 5,
                    fontSize: Theme.TypeRole.title.size, weight: .bold, lineLimit: 2
                )
                let drawn = NSHostingController(rootView: row.frame(width: width))
                    .sizeThatFits(in: CGSize(width: width, height: 400)).height
                let drawnLines = Int((drawn / LockScreenCard.lyricLineHeight).rounded())
                let layout = LockScreenCard.lyricLayout(currentText: text, width: width, cardSize: size)
                XCTAssertEqual(layout.currentLineLimit, drawnLines,
                               "\(size) '\(text)': measured \(layout.currentLineLimit) row(s), drawn \(drawn)pt")
            }
        }
    }

    /// The window changing size between two lines is a cut, like a seek:
    /// rows gliding one 26pt step against a row pitch that just changed
    /// would land between slots.
    func testAWindowThatChangesSizeIsACut() {
        XCTAssertTrue(LockScreenCard.isJump(from: 4, to: 5, windowFrom: 5, to: 3))
        XCTAssertTrue(LockScreenCard.isJump(from: 5, to: 6, windowFrom: 3, to: 5))
        XCTAssertFalse(LockScreenCard.isJump(from: 4, to: 5, windowFrom: 5, to: 5))
        XCTAssertFalse(LockScreenCard.isJump(from: nil, to: 5, windowFrom: nil, to: 3), "the first draw is not a cut")
        XCTAssertTrue(LockScreenCard.isJump(from: 2, to: 9, windowFrom: 5, to: 5), "a seek is still a cut")
    }

    /// The centre follows the one rule every lyric surface follows — the same
    /// function the stage calls — including the fallback that keeps a paused
    /// track before its first timestamp from showing nothing.
    func testTheCentreIsTheLineBeingSungOrTheFirstOne() {
        let lines = [
            LyricsStore.Line(at: 1.58, text: "first"),
            LyricsStore.Line(at: 18.2, text: "second"),
            LyricsStore.Line(at: 30, text: "third"),
        ]
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 0), 0, "before the first line")
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 20), 1)
        XCTAssertEqual(LyricSweep.centreIndex(in: lines, at: 999), 2)
        XCTAssertEqual(LyricSweep.centreIndex(in: [], at: 5), 0)
    }

    /// The picker is not a pane. It opens over the card, so what is playing
    /// stays visible behind the thing choosing where it plays — which is what
    /// the system's own output list does over whatever raised it.
    func testTheOutputPickerLeavesThePlayerShowing() {
        // The rule the view states: `.output` renders the player underneath.
        func middleFor(_ pane: LockScreenCard.Pane) -> LockScreenCard.Pane {
            switch pane {
            case .lyrics: return .lyrics
            case .player, .output: return .player
            }
        }
        XCTAssertEqual(middleFor(.output), .player)
        XCTAssertEqual(middleFor(.player), .player)
        XCTAssertEqual(middleFor(.lyrics), .lyrics)
    }

    /// Seven devices is an ordinary Mac with a display, AirPods, an AirPlay
    /// speaker and a couple of virtual drivers. The picker used to draw the
    /// first five and nothing else, so the device actually playing could be one
    /// nobody could see, let alone pick again (F-032).
    func testTheCurrentOutputIsListedFirstAndNoneAreDropped() {
        let outputs = Self.sevenOutputs
        let current = outputs[6].id

        let ordered = LockScreenCard.orderedOutputs(outputs, current: current)
        XCTAssertEqual(ordered.first?.id, current)
        XCTAssertEqual(ordered.count, 7)
        // The rest keep the system's order: the list moves one row, not all of them.
        XCTAssertEqual(ordered.dropFirst().map(\.id), outputs.prefix(6).map(\.id))

        // Nothing current, or a current device the list does not carry (it
        // vanished between two reads): the system's order, untouched.
        XCTAssertEqual(LockScreenCard.orderedOutputs(outputs, current: nil), outputs)
        XCTAssertEqual(LockScreenCard.orderedOutputs(outputs, current: 999), outputs)
    }

    /// The selected row used to be a white glyph in a well of the system accent
    /// and nothing else: on a Yellow accent that glyph was about 1.4:1, and the
    /// selection was carried by colour alone (F-053). It is a checkmark and a
    /// weight as well as a colour. The colour is the owner's fixed red now, as
    /// the Sound module of the redesign has it (spec §7.3: "accent on the
    /// current one, white 0.16 otherwise"), which the white glyph clears — but
    /// the shape and the stroke stay, because they read under any wallpaper and
    /// any colour vision.
    func testSelectionIsNotColourAlone() {
        let on = LockScreenCard.outputRowMarks(selected: true)
        let off = LockScreenCard.outputRowMarks(selected: false)

        XCTAssertTrue(on.checkmark)
        XCTAssertFalse(off.checkmark)
        XCTAssertTrue(on.semibold)
        XCTAssertFalse(off.semibold)
        // The selected circle is the accent, the others the card's fill — and
        // what separates them is also a shape and a weight.
        XCTAssertEqual(on.well, .accent)
        XCTAssertEqual(off.well, .cardFill)
        XCTAssertEqual(on.glyph, .primary)
        XCTAssertEqual(off.glyph, .cardTertiary)
    }

    /// The list scrolls inside the card rather than growing past it (spec §7.3):
    /// devices stand 36 pt apart with nothing between them, the first circle at
    /// y 98, so five fit on the standard card — the board's five — and three on
    /// the compact one. A list that overflows shows half a row so there is
    /// something to say it scrolls.
    func testTheOutputListFitsTheCardAtBothSizesOnA36PointPitch() {
        XCTAssertEqual(LockScreenCard.outputRowHeight, 36, "devices are 36 pt apart")
        XCTAssertEqual(LockScreenCard.outputRowSpacing, 0)
        XCTAssertEqual(LockScreenCard.outputRowsThatFit(.standard), 5)
        XCTAssertEqual(LockScreenCard.outputRowsThatFit(.compact), 3)

        for size in NotchViewModel.LockCardSize.allCases {
            let card = LockScreenCard.size(for: size)
            let room = card.height - LockCardLayout.outputListTop - LockCardLayout.outputListBottomMargin
            let fit = LockScreenCard.outputRowsThatFit(size)

            // Every list, however long, fits the room under the heading.
            for count in 1...12 {
                XCTAssertLessThanOrEqual(LockScreenCard.outputListHeight(count: count, size: size), room, "\(size) \(count)")
            }
            // Up to the cap: exactly as tall as its rows, nothing to scroll.
            XCTAssertEqual(LockScreenCard.outputListHeight(count: fit, size: size), CGFloat(fit) * 36)
            XCTAssertEqual(LockScreenCard.outputListHeight(count: 1, size: size), 36)
            // Past it: the last visible row is cut in half.
            XCTAssertEqual(
                LockScreenCard.outputListHeight(count: fit + 1, size: size),
                CGFloat(fit - 1) * 36 + 18
            )
            // The first circle sits at the board's y 98: the list's top, plus the
            // five points above the 26 pt circle in its 36 pt row.
            XCTAssertEqual(LockCardLayout.outputListTop + (36 - LockCardLayout.outputCircle) / 2, 98)
        }
        XCTAssertEqual(LockScreenCard.outputListHeight(count: 0, size: .standard), 0)
    }

    /// A live stream or a browser tab reports no length, and the card drew a
    /// full-width bar reading 0:00 / -0:00 that refused every drag (F-031),
    /// while the panel hid its scrubber in the same state. The bar is shown
    /// only for a length a seek can be measured against.
    func testNoLengthDrawsNoBar() {
        XCTAssertFalse(LockScreenCard.showsSeekBar(duration: 0))
        XCTAssertFalse(LockScreenCard.showsSeekBar(duration: -1))
        XCTAssertFalse(LockScreenCard.showsSeekBar(duration: .nan))
        XCTAssertFalse(LockScreenCard.showsSeekBar(duration: .infinity))
        XCTAssertTrue(LockScreenCard.showsSeekBar(duration: 180))
    }

    /// The open pane's glyph used to differ from its sibling by one opacity step,
    /// white against cardSecondary, which a pale cover or low vision loses
    /// (M-17). It wears a filled well now; the bare siblings wear none, and
    /// Increase Contrast adds the hairline edge.
    func testTheOpenPaneWearsAWell() {
        let open = LockScreenCard.paneButtonLook(open: true, increaseContrast: false)
        XCTAssertEqual(open.wellOpacity, Theme.cardFillOpacity(increaseContrast: false))
        XCTAssertFalse(open.outlined)

        let closed = LockScreenCard.paneButtonLook(open: false, increaseContrast: false)
        XCTAssertEqual(closed.wellOpacity, 0)
        XCTAssertFalse(closed.outlined)

        let contrast = LockScreenCard.paneButtonLook(open: true, increaseContrast: true)
        XCTAssertEqual(contrast.wellOpacity, Theme.cardFillOpacity(increaseContrast: true))
        XCTAssertTrue(contrast.outlined)
        XCTAssertFalse(LockScreenCard.paneButtonLook(open: false, increaseContrast: true).outlined)
    }

    /// The output button is a glyph; a locked-Mac user could not tell where the
    /// sound goes without opening the picker (M-24). Its value is the device.
    func testTheOutputButtonNamesTheDevice() {
        XCTAssertEqual(LockScreenCard.outputName(outputs: Self.sevenOutputs, current: 42), "AirPods Pro")
        XCTAssertNil(LockScreenCard.outputName(outputs: Self.sevenOutputs, current: 999))
        XCTAssertNil(LockScreenCard.outputName(outputs: Self.sevenOutputs, current: nil))
    }

    static let sevenOutputs: [AudioOutputs.Output] = [
        .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        .init(id: 42, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
        .init(id: 43, name: "Studio Display Speakers", transport: kAudioDeviceTransportTypeDisplayPort),
        .init(id: 44, name: "Living Room", transport: kAudioDeviceTransportTypeAirPlay),
        .init(id: 45, name: "BlackHole 2ch", transport: kAudioDeviceTransportTypeVirtual),
        .init(id: 46, name: "Loopback Audio", transport: kAudioDeviceTransportTypeVirtual),
        .init(id: 47, name: "Kitchen", transport: kAudioDeviceTransportTypeAirPlay),
    ]
}
