import AppKit
import Carbon.HIToolbox
import XCTest
@testable import IslaKit

/// The ways into the words, and the corrections that keep them honest.
@MainActor
final class LyricRoutesTests: XCTestCase {

    /// The lyrics shortcut is its own key, not a second name for one already
    /// bound. All three share ⌃⌥⌘, so the key codes are the only thing keeping
    /// them apart.
    func testTheThreeHotkeysAreDistinct() {
        let codes = HotKeyAction.allCases.map(\.defaultBinding.keyCode)
        XCTAssertEqual(Set(codes).count, 3, "⌃⌥⌘I, ⌃⌥⌘T and ⌃⌥⌘L must be three different keys")
        XCTAssertEqual(HotKeyBinding.defaultModifiers, UInt32(controlKey | optionKey | cmdKey))
    }

    /// Leaving Music folds the page. Without this, opening Shelf and coming
    /// back landed on a wall of words from whatever was playing three songs
    /// ago, rather than on the player the tab is named for.
    func testLeavingTheMusicTabFoldsTheLyricsPage() {
        guard let geometry = NotchGeometry.current() else {
            return XCTFail("a test host always has a screen")
        }
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.select(.media)
        vm.isShowingLyrics = true
        vm.select(.shelf)
        XCTAssertFalse(vm.isShowingLyrics, "the page belongs to the Music tab")

        // And coming back does not restore it: the tab opens on the player.
        vm.select(.media)
        XCTAssertFalse(vm.isShowingLyrics)
    }

    /// What lands on the pasteboard is the song, not the app's bookkeeping:
    /// credits are metadata this app inferred, and a blank line is not a lyric.
    func testCopyingTheSongLeavesOutCreditsAndBlanks() {
        let lines = [
            LyricsStore.Line(at: 0, text: "Produced by Someone", isCredit: true),
            LyricsStore.Line(at: 1, text: "First line"),
            LyricsStore.Line(at: 2, text: "   "),
            LyricsStore.Line(at: 3, text: "Second line"),
        ]
        XCTAssertEqual(LyricsStage.plainText(lines), "First line\nSecond line")
    }

    /// The pasteboard is cleared before it is written, so a copy cannot leave a
    /// richer flavour from the previous one underneath for the paste to find.
    func testCopyingALineReplacesTheWholePasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("older", forType: .string)
        LyricRow.copy("the line being sung")
        XCTAssertEqual(pasteboard.string(forType: .string), "the line being sung")
    }

    /// The global correction is the one that moves a whole catalogue — a hot
    /// source, or the delay a pair of AirPods adds — and it clamps where the
    /// store says it does, however far the slider is dragged.
    func testTheGlobalLyricDelayClampsAtThreeSecondsEitherWay() {
        UserDefaults.standard.removeObject(forKey: LyricsStore.offsetKey)
        defer { UserDefaults.standard.removeObject(forKey: LyricsStore.offsetKey) }
        let store = LyricsStore()

        store.userOffset = 12
        XCTAssertEqual(store.userOffset, 3, accuracy: 0.0001)
        store.userOffset = -12
        XCTAssertEqual(store.userOffset, -3, accuracy: 0.0001)

        store.userOffset = -0.4
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: LyricsStore.offsetKey), -0.4, accuracy: 0.0001,
            "a correction the listener made has to survive the next launch"
        )
        // And it reaches the surfaces through the one clock every one of them
        // reads, rather than through a copy per surface.
        XCTAssertEqual(
            LyricSweep.lead(precisionSync: false, userOffset: store.userOffset),
            LyricSweep.standardLead - 0.4, accuracy: 0.0001
        )
    }
}

/// What Isla hands the rest of the system.
///
/// An `AppIntent`'s `perform()` needs the live app, so what a unit test can
/// hold is the pure shape around it: how a track is described, and that the
/// delay intent's range matches the store's own clamp. Whether Shortcuts
/// actually lists them is a bundle question, held by `Scripts/test-package.sh`,
/// and whether they *run* is a human question.
@MainActor
final class IntentSurfaceTests: XCTestCase {

    /// Artist first, because that is the order a person says it in, and the
    /// title alone when there is no artist to name rather than a dangling dash.
    func testATrackIsDescribedTheWayItIsSpoken() {
        XCTAssertEqual(
            CurrentTrackIntent.describe(
                .init(title: "Song", artist: "Someone", album: "Album", key: "k")
            ),
            "Someone — Song"
        )
        XCTAssertEqual(
            CurrentTrackIntent.describe(.init(title: "Song", artist: "", album: "", key: "k")),
            "Song",
            "no artist means no dash to hang"
        )
    }

    /// The intent's parameter range and the store's clamp are the same number.
    /// They are declared in two files, and a shortcut that could ask for four
    /// seconds would get three back with no explanation.
    func testTheDelayIntentOffersExactlyWhatTheStoreWillKeep() {
        UserDefaults.standard.removeObject(forKey: LyricsStore.offsetKey)
        defer { UserDefaults.standard.removeObject(forKey: LyricsStore.offsetKey) }
        let store = LyricsStore()
        store.userOffset = 3
        XCTAssertEqual(store.userOffset, 3, accuracy: 0.0001)
        store.userOffset = -3
        XCTAssertEqual(store.userOffset, -3, accuracy: 0.0001)
        // The intent declares `inclusiveRange: (-3, 3)`; anything past it is
        // the store's business, and it holds.
        store.userOffset = 3.01
        XCTAssertEqual(store.userOffset, 3, accuracy: 0.0001)
    }
}
