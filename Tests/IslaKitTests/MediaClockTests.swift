import SwiftUI
import XCTest
@testable import IslaKit

/// The media clock runs for the surfaces that draw it, and nothing else
/// re-renders on its tick (F-015).
///
/// Opening the panel on any tab used to start the ten-a-second position ticker
/// and, with lyrics on, the once-a-second Apple event into Spotify — for a
/// panel left open on Shelf, Clipboard or Settings, where no scrubber and no
/// lyric is drawn. And Settings observed the whole `MediaController` to read
/// one field, so the largest pane in the app re-evaluated its body on every
/// tick while music played.
@MainActor
final class MediaClockTests: XCTestCase {

    /// Only Music and the lock card draw a scrubber or a lyric, so only they
    /// run the clock. The lock card wins over everything: it is drawn with the
    /// panel closed, and whatever tab was last open says nothing about it.
    func testOnlyTheMusicTabAndTheLockCardRunTheClock() {
        XCTAssertTrue(NotchController.mediaClockWanted(isOpen: true, tab: .media, locked: false))
        for tab in NotchViewModel.Tab.allCases where tab != .media {
            XCTAssertFalse(NotchController.mediaClockWanted(isOpen: true, tab: tab, locked: false),
                           "\(tab) draws no clock and must not run one")
        }
        for tab in NotchViewModel.Tab.allCases {
            XCTAssertFalse(NotchController.mediaClockWanted(isOpen: false, tab: tab, locked: false),
                           "a closed panel on \(tab) draws nothing")
            XCTAssertTrue(NotchController.mediaClockWanted(isOpen: false, tab: tab, locked: true),
                          "the lock card draws a scrubber whatever tab was last open (\(tab))")
        }
        XCTAssertTrue(NotchController.mediaClockWanted(isOpen: false, tab: .shelf, locked: true))
    }

    /// Settings reads one published field of the controller. Observing the
    /// whole object re-evaluated the pane ten times a second while music
    /// played; the field it needs is received on its own.
    func testSettingsDoesNotObserveTheMediaController() {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let stores = isolated.stores
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
        )
        let observed = Mirror(reflecting: pane).children.filter { $0.value is ObservedObject<MediaController> }
        XCTAssertTrue(observed.isEmpty,
                      "SettingsPane observes MediaController through \(observed.map { $0.label ?? "?" })")
    }

    /// And the one field still reaches the screen: with the Now Playing reader
    /// down, Settings says so and offers Try Again. Dropping the observation
    /// without receiving the field would have silenced the only place the
    /// fallback is explained.
    func testSettingsStillExplainsTheFallback() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let stores = isolated.stores
        stores.media.switchToScriptingFallback(.keptStopping)
        defer { stores.media.stop() }
        let root = await SettingsFixture.tree(isolated, section: .music, height: 1200)
        let note = NowPlayingRouteFailure.keptStopping.explanation
        XCTAssertFalse(root.all { $0.label == note || $0.value == note || $0.title == note }.isEmpty,
                       "no fallback note\n\(root.dump)")
        let retry = localized("Try Again")
        XCTAssertFalse(root.all { $0.label == retry || $0.title == retry }.isEmpty,
                       "no Try Again\n\(root.dump)")
    }
}
