import SwiftUI
import XCTest
@testable import IslaKit

/// The media clock runs for the surfaces that draw it, and nothing else
/// re-renders on its tick (F-015).
///
/// Opening the panel on any surface used to start the ten-a-second position
/// ticker and, with lyrics on, the once-a-second Apple event into Spotify — for
/// a panel left open on the tray, Clipboard or Settings, where no scrubber and
/// no lyric is drawn. And Settings observed the whole `MediaController` to read
/// one field, so the largest pane in the app re-evaluated its body on every
/// tick while music played.
@MainActor
final class MediaClockTests: XCTestCase {

    /// Only the player, the stage and the lock card draw a scrubber or a lyric
    /// (the stage's progress and its sung line), so only they run the clock.
    /// The lock card wins over everything: it is drawn with the panel closed,
    /// and whatever surface was last open says nothing about it.
    func testOnlyThePlayerTheStageAndTheLockCardRunTheClock() {
        let drawsAClock: Set<NotchViewModel.Surface> = [.player, .stage]
        for surface in NotchViewModel.Surface.allCases {
            XCTAssertEqual(
                NotchController.mediaClockWanted(isOpen: true, surface: surface, locked: false),
                drawsAClock.contains(surface),
                "\(surface) \(drawsAClock.contains(surface) ? "draws a clock and must run one" : "draws no clock and must not run one")"
            )
            XCTAssertFalse(NotchController.mediaClockWanted(isOpen: false, surface: surface, locked: false),
                           "a closed panel on \(surface) draws nothing")
            XCTAssertTrue(NotchController.mediaClockWanted(isOpen: false, surface: surface, locked: true),
                          "the lock card draws a scrubber whatever surface was last open (\(surface))")
        }
        XCTAssertTrue(NotchController.mediaClockWanted(isOpen: false, surface: .tray, locked: true))
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
