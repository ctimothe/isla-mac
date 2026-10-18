import SwiftUI
import XCTest
@testable import IslaKit

/// A page swipe re-runs the root view on every frame, and the two pages on
/// screen used to follow it: their closures are rebuilt on each pass and are
/// never equal, so SwiftUI could not skip them. Measured on 2026-10-18 with a
/// body counter, a 30-frame swipe from Clipboard toward Translate ran 61 pane
/// bodies before and 2 after (`NotchContentView.pane(for:)`'s `.equatable()`).
/// These hold what the comparison may and may not ignore.
@MainActor
final class PaneEqualityTests: XCTestCase {
    func testClipboardIgnoresItsClosuresAndNothingElse() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        var claim = false
        let keyboard = Binding(get: { claim }, set: { claim = $0 })
        func pane(width: CGFloat = 560, live: Bool = true) -> ClipboardPane {
            ClipboardPane(
                clipboard: vm.clipboard, privacy: vm.privacy, browser: vm.clipboardBrowser,
                bodyWidth: width, wantsKeyboard: keyboard,
                translate: { _ in }, clearConfirmation: vm.clipboardClear,
                turnOnHistory: {}, isLive: live
            )
        }
        XCTAssertEqual(pane(), pane(), "fresh closures on every pass are not a change")
        XCTAssertNotEqual(pane(), pane(width: 600))
        XCTAssertNotEqual(pane(), pane(live: false))
        // A binding reads its source live, so the claim is compared as it
        // stood when each pane was built: otherwise both sides would read the
        // new value and a kept pane would never hear of it.
        let before = pane()
        claim = true
        XCTAssertNotEqual(before, pane(), "a keyboard claim that changed")
    }

    func testTranslateIgnoresNothingButItsOwnState() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        var claim = false, history = false
        let keyboard = Binding(get: { claim }, set: { claim = $0 })
        let shows = Binding(get: { history }, set: { history = $0 })
        func pane(live: Bool = true, travelling: Bool = false) -> TranslatePane {
            TranslatePane(
                translator: vm.translator, privacy: vm.privacy, wantsKeyboard: keyboard,
                showsHistory: shows, bodyWidth: 560, isLive: live, isTravelling: travelling
            )
        }
        XCTAssertEqual(pane(), pane())
        XCTAssertNotEqual(pane(), pane(live: false))
        XCTAssertNotEqual(pane(), pane(travelling: true), "the editor stands down for a swipe")
        var before = pane()
        claim = true
        XCTAssertNotEqual(before, pane(), "a keyboard claim that changed")
        before = pane()
        history = true
        XCTAssertNotEqual(before, pane(), "History opened")
    }

    func testMusicIgnoresItsClosuresAndNothingElse() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        func pane(live: Bool = true, tint: NSColor = .systemBlue) -> MediaPane {
            MediaPane(
                media: vm.media, lyrics: vm.lyrics,
                openStage: {}, bringPlayerForward: {}, openMusicOnlySetting: {},
                morph: nil, audio: vm.playerAudio, spotify: vm.spotifyAccount,
                coverTint: tint, isLive: live
            )
        }
        XCTAssertEqual(pane(), pane())
        XCTAssertNotEqual(pane(), pane(live: false))
        XCTAssertNotEqual(pane(), pane(tint: .systemRed), "a new cover's tint")
    }
}
