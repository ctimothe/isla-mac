import SwiftUI
import XCTest
@testable import IslaKit

/// The player's two switches (spec §4, §14): their keys, their defaults, and where
/// Settings puts them.
///
/// Every default is pinned through a private suite, never the standard domain — the
/// runner's own defaults have leaked a switch into a test before.
@MainActor
final class PlayerSettingsTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "com.ctimothe.isla.playersettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// The keys are the spec's, written once.
    func testTheKeysAreTheSpecs() {
        XCTAssertEqual(NotchViewModel.volumeAndOutputKey, "player.volumeAndOutput")
        XCTAssertEqual(NotchViewModel.lyricBandKey, "player.lyricBand")
    }

    /// An absent value is the spec's default: **on** for both. Volume and Output
    /// being on out of the box is the owner-waived exception to the default-off
    /// rule for system-wide settings (decision 8); the controls only read until a
    /// person drags the slider or picks an output.
    func testBothDefaultToOn() {
        let defaults = suite()
        XCTAssertTrue(NotchViewModel.volumeAndOutputEnabled(in: defaults))
        XCTAssertTrue(NotchViewModel.lyricBandEnabled(in: defaults))
    }

    func testAStoredValueWinsAndOffStaysOff() {
        let defaults = suite()
        defaults.set(false, forKey: NotchViewModel.volumeAndOutputKey)
        defaults.set(false, forKey: NotchViewModel.lyricBandKey)
        XCTAssertFalse(NotchViewModel.volumeAndOutputEnabled(in: defaults))
        XCTAssertFalse(NotchViewModel.lyricBandEnabled(in: defaults))
        defaults.set(true, forKey: NotchViewModel.volumeAndOutputKey)
        XCTAssertTrue(NotchViewModel.volumeAndOutputEnabled(in: defaults))
        XCTAssertFalse(NotchViewModel.lyricBandEnabled(in: defaults), "one switch does not move the other")
    }

    /// The panel's audio watch is quiet under test: a pane built here must never
    /// reach the owner's output devices, even to read them.
    func testThePanelsAudioWatchIsQuietUnderTest() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.playerAudio.start()
        XCTAssertTrue(vm.playerAudio.outputs.isEmpty)
        XCTAssertNil(vm.playerAudio.current)
        XCTAssertNil(vm.playerAudio.volume)
        vm.playerAudio.stop()
    }

    /// Settings › Music holds both rows, under "In the player", after the rows
    /// that were already there, with the spec's footnote.
    func testSettingsHoldsBothRowsUnderInThePlayer() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let stores = isolated.stores
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
        )
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 2400))

        let labels = root.flattened.map { $0.label.isEmpty ? $0.value : $0.label }
        let peek = try XCTUnwrap(labels.firstIndex(of: "Peek at New Tracks"), root.dump)
        let header = try XCTUnwrap(labels.firstIndex(of: "In the player"), root.dump)
        let volume = try XCTUnwrap(labels.firstIndex(of: "Volume and Output"), root.dump)
        let band = try XCTUnwrap(labels.firstIndex(of: "Lyric Band"), root.dump)
        let note = try XCTUnwrap(labels.firstIndex(where: { $0.hasPrefix("Volume and Output put the system volume") }), root.dump)
        XCTAssertLessThan(peek, header)
        XCTAssertLessThan(header, volume)
        XCTAssertLessThan(volume, band)
        XCTAssertLessThan(band, note)
        XCTAssertEqual(
            labels[note],
            "Volume and Output put the system volume and the AirPlay menu in the player. Lyric Band is the sung line and the next one, under the title."
        )
    }
}
