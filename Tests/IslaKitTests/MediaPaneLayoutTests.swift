import SwiftUI
import XCTest
@testable import IslaKit

/// The caption is allowed to be empty. It is not allowed to take its height with
/// it when it goes.
@MainActor
final class MediaPaneLayoutTests: XCTestCase {

    // MARK: - Which line to show

    /// A paused track sitting before its first timestamp used to show nothing at
    /// all, because the binary search has no line to return yet. The opening line,
    /// unswept, is what should be there: the words exist, the voice has not
    /// arrived. Times are the real shape of a catalogue entry — the cached
    /// "Advice" lyric starts at 1.58 s.
    func testALineBeforeTheFirstTimestampShowsTheOpeningLineUnswept() throws {
        let lines = [
            LyricsStore.Line(at: 1.58, text: "Don't get hung on petty things"),
            LyricsStore.Line(at: 18.2, text: "String the sinner by his wings"),
            LyricsStore.Line(at: 30, text: "In his head a brittle bone"),
        ]

        let early = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 0.4))
        XCTAssertEqual(early.line.text, "Don't get hung on petty things")
        XCTAssertFalse(early.swept, "nobody has sung it yet, so it must not be swept")
        XCTAssertEqual(early.end, 18.2, accuracy: 0.001, "the end is the next line's start")

        let during = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 20))
        XCTAssertEqual(during.line.text, "String the sinner by his wings")
        XCTAssertTrue(during.swept)
        XCTAssertEqual(during.end, 30, accuracy: 0.001)

        let last = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 40))
        XCTAssertEqual(last.line.text, "In his head a brittle bone")
        XCTAssertTrue(last.swept)
        XCTAssertEqual(last.end, 36, accuracy: 0.001, "the last line borrows a spoken length")
    }

    /// A single-line lyric has no next line to borrow an end from.
    func testASingleLineBorrowsASpokenLengthBeforeItIsReached() throws {
        let lines = [LyricsStore.Line(at: 5, text: "only line")]
        let early = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 0))
        XCTAssertFalse(early.swept)
        XCTAssertEqual(early.end, 11, accuracy: 0.001)
    }

    func testNoLinesShowsNothing() {
        XCTAssertNil(LyricSweep.displayed(lines: [], at: 10))
    }

    // MARK: - What the empty tab says

    /// A YouTube video, SoundCloud in a browser or an mp3 in IINA could be
    /// audibly playing while the Music tab said "Nothing is playing." — Music
    /// Only kept it off the island, which is the recorded design, but the
    /// status line was false and nothing pointed at the switch (J-007).
    func testAPlayingSourceHiddenByMusicOnlyIsNamed() {
        XCTAssertEqual(
            MediaPane.emptyStateMessage(fallback: nil, otherMediaPlaying: true, musicOnly: true),
            .hiddenByMusicOnly
        )
        XCTAssertEqual(
            MediaPane.emptyStateMessage(fallback: nil, otherMediaPlaying: false, musicOnly: true),
            .nothingPlaying
        )
        // The filter is what hides it, so with the filter off there is nothing
        // to name: the controller's flag can trail the switch by one report.
        XCTAssertEqual(
            MediaPane.emptyStateMessage(fallback: nil, otherMediaPlaying: true, musicOnly: false),
            .nothingPlaying
        )
        XCTAssertEqual(
            MediaPane.EmptyStateMessage.hiddenByMusicOnly.headline,
            localized("Something is playing that Music Only keeps off the island.")
        )
        XCTAssertEqual(MediaPane.EmptyStateMessage.nothingPlaying.headline, localized("Nothing is playing."))
    }

    /// The reader being down explains more than the filter does: the helper
    /// cannot see a browser at all then, so it keeps its own line whatever
    /// else is true.
    func testTheReaderBeingDownKeepsPrecedence() {
        XCTAssertEqual(
            MediaPane.emptyStateMessage(fallback: .keptStopping, otherMediaPlaying: true, musicOnly: true),
            .readerDown
        )
        XCTAssertEqual(
            MediaPane.emptyStateMessage(fallback: .routeClosed, otherMediaPlaying: false, musicOnly: false),
            .readerDown
        )
        XCTAssertEqual(MediaPane.EmptyStateMessage.readerDown.headline, localized("Nothing is playing."))
        XCTAssertEqual(
            MediaPane.EmptyStateMessage.readerDown.caption,
            localized("Only Music and Spotify can be seen right now.")
        )
    }

    /// Redesign 2026-10-15, spec §4.8: every empty state has its body line now —
    /// it used to be only the reader-down one — and the reader-down state alone
    /// carries the pointer to Settings › Music, which is where the reason and Try
    /// Again live (one failure surface).
    func testEveryEmptyStateHasItsOwnBodyLine() {
        XCTAssertEqual(
            MediaPane.EmptyStateMessage.nothingPlaying.caption,
            localized("Start a song in Music or Spotify, or open one here.")
        )
        XCTAssertEqual(
            MediaPane.EmptyStateMessage.hiddenByMusicOnly.caption,
            localized("Videos and films stay off the island.")
        )
        XCTAssertEqual(
            MediaPane.EmptyStateMessage.readerDown.footnote,
            localized("Settings › Music says why, with Try Again.")
        )
        XCTAssertNil(MediaPane.EmptyStateMessage.nothingPlaying.footnote)
        XCTAssertNil(MediaPane.EmptyStateMessage.hiddenByMusicOnly.footnote)
        // The remedy: a player to open, or — when the filter hides it — Settings.
        XCTAssertTrue(MediaPane.EmptyStateMessage.hiddenByMusicOnly.offersSettings)
        XCTAssertFalse(MediaPane.EmptyStateMessage.nothingPlaying.offersSettings)
        XCTAssertFalse(MediaPane.EmptyStateMessage.readerDown.offersSettings)
    }

    /// Open Settings has to land on the switch, not on the top of a pane that
    /// scrolls: the Music section sits below General, Keyboard Shortcuts and
    /// Screenshots. The target is a one-shot — leaving Settings drops an
    /// unspent one so a later visit does not jump.
    func testOpenSettingsLandsOnTheMusicSection() throws {
        // The lab's stand-in: nothing here reads the screen, and a sandboxed
        // run has none to give.
        let geometry = try LabGeometry.make()
        // Stores rooted in a temporary directory, so building a view model
        // never reads or migrates the lyric files in Application Support.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPaneLayoutTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores(localLyricsDirectory: root))
        vm.tab = .media

        vm.openMusicOnlySetting()
        XCTAssertEqual(vm.tab, .settings)
        XCTAssertEqual(vm.settingsScrollTarget, SettingsPane.musicSectionID)

        vm.select(.media)
        XCTAssertNil(vm.settingsScrollTarget, "an unspent target must not outlive the visit it was for")
    }

    // MARK: - Where the transport sits

    /// The transport used to sit at the same height with and without words, by a
    /// slot held empty for the caption. The redesign trades that for the board's
    /// rule (spec §4.1): with no lyric the band folds away and the progress row
    /// and the transport rise by exactly 20. Held in `PlayerLayoutTests` as
    /// arithmetic and in `PlayerPaneTests` against the drawn controls; here, that
    /// the band is what decides it.
    func testTheBandIsWhatMovesTheTransport() {
        let with = PlayerLayout(bodyWidth: 560, hasLyricBand: true)
        let without = PlayerLayout(bodyWidth: 560, hasLyricBand: false)
        XCTAssertEqual(with.transport.minY - without.transport.minY, 20)
        XCTAssertEqual(with.cover, without.cover, "the cover does not move for words")
    }
}
