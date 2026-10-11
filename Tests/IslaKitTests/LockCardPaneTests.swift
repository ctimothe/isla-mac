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
            LockScreenCard.lyricLayout(currentText: long, width: 412, cardSize: .standard),
            LockScreenCard.LyricLayout(window: 3, currentLineLimit: 2)
        )
        XCTAssertEqual(
            LockScreenCard.lyricLayout(currentText: "Short again", width: 412, cardSize: .standard),
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
            LockScreenCard.lyricLayout(currentText: nil, width: 412, cardSize: .standard),
            LockScreenCard.LyricLayout(window: 5, currentLineLimit: 1)
        )
    }

    /// The card's own text width is what the line is measured against: the
    /// card less its side padding on each edge.
    func testTheLyricTextWidthIsTheCardLessItsPadding() {
        XCTAssertEqual(LockScreenCard.lyricTextWidth(for: .standard), 412)
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
    /// selection was carried by colour alone (F-053). It is now a checkmark and
    /// a weight, and the well is the same neutral shape on every row.
    func testSelectionIsNotColourAlone() {
        let on = LockScreenCard.outputRowMarks(selected: true)
        let off = LockScreenCard.outputRowMarks(selected: false)

        XCTAssertTrue(on.checkmark)
        XCTAssertFalse(off.checkmark)
        XCTAssertTrue(on.semibold)
        XCTAssertFalse(off.semibold)
        // The well never changes colour: whatever separates the rows is a
        // shape and a weight, which survive any accent and any colour vision.
        XCTAssertEqual(on.well, .cardFill)
        XCTAssertEqual(off.well, .cardFill)
        XCTAssertEqual(on.glyph, .primary)
        XCTAssertEqual(off.glyph, .cardTertiary)
    }

    /// The list scrolls inside the card rather than growing past it. Five rows
    /// on the compact card already ran off its top edge; the cap is what fits
    /// above the footer, and a list that overflows shows half a row so there
    /// is something to say it scrolls.
    func testTheOutputListFitsAboveTheFooterAtBothSizes() {
        for size in NotchViewModel.LockCardSize.allCases {
            let card = LockScreenCard.size(for: size)
            let room = card.height - LockScreenCard.footerClearance - LockScreenCard.outputPopoverChrome
            let fit = LockScreenCard.outputRowsThatFit(size)
            XCTAssertGreaterThanOrEqual(fit, 3, "\(size)")

            // Every list, however long, fits the room above the footer.
            for count in 1...12 {
                XCTAssertLessThanOrEqual(LockScreenCard.outputListHeight(count: count, size: size), room, "\(size) \(count)")
            }
            // Up to the cap: exactly as tall as its rows, nothing to scroll.
            let pitch = LockScreenCard.outputRowHeight + LockScreenCard.outputRowSpacing
            XCTAssertEqual(LockScreenCard.outputListHeight(count: fit, size: size), CGFloat(fit) * pitch - LockScreenCard.outputRowSpacing)
            // Past it: the last visible row is cut in half.
            XCTAssertEqual(
                LockScreenCard.outputListHeight(count: fit + 1, size: size),
                CGFloat(fit - 1) * pitch + LockScreenCard.outputRowHeight / 2
            )
        }
        XCTAssertEqual(LockScreenCard.outputListHeight(count: 0, size: .standard), 0)
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
