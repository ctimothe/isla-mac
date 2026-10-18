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

    /// An absent value is the spec's default: **on** for both. The Output button
    /// (stored as `player.volumeAndOutput`, its name before 2026-10-16) being on
    /// out of the box is the owner-waived exception to the default-off rule for
    /// system-wide settings (decision 8); the button only reads until a person
    /// picks an output.
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

    /// Settings › Music holds both rows, under "In the player", after Music Only,
    /// with the spec's footnote (redesign 2026-10-15, spec §10: Peek at New Tracks
    /// left this section for General, as New Tracks).
    func testSettingsHoldsBothRowsUnderInThePlayer() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .music, height: 1000)

        let labels = root.flattened.map { $0.label.isEmpty ? $0.value : $0.label }
        let musicOnly = try XCTUnwrap(labels.firstIndex(of: "Music Only"), root.dump)
        let header = try XCTUnwrap(labels.firstIndex(of: "In the player"), root.dump)
        let volume = try XCTUnwrap(labels.firstIndex(of: "Output Button"), root.dump)
        let band = try XCTUnwrap(labels.firstIndex(of: "Lyric Band"), root.dump)
        let note = try XCTUnwrap(labels.firstIndex(where: { $0.hasPrefix("Output Button puts the sound output menu") }), root.dump)
        XCTAssertLessThan(musicOnly, header)
        XCTAssertLessThan(header, volume)
        XCTAssertLessThan(volume, band)
        XCTAssertLessThan(band, note)
        XCTAssertNil(labels.firstIndex(of: "Peek at New Tracks"), "the renamed row is not here")
        XCTAssertEqual(
            labels[note],
            "Output Button puts the sound output menu in the player. Lyric Band is the sung line and the next one, under the title."
        )
    }
}
