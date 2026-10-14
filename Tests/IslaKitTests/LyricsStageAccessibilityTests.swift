import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The lyrics stage as VoiceOver meets it.
///
/// The per-track timing correction could only be cleared by holding the
/// pointer on its readout, while VoiceOver read out a hint promising a reset
/// that no assistive client could perform (F-029). And the blurred cover
/// lighting the stage was a nameless 488x488 image in reading order, a stop
/// that says nothing (H-011's dump).
///
/// Nothing here reaches the machine: the media controller is cut from every
/// real player, and the lyric store keeps its offsets in a temporary folder
/// and its preferences in a private suite, so a reset performed here can
/// never touch the owner's offsets.json.
@MainActor
final class LyricsStageAccessibilityTests: XCTestCase {
    private static let size = CGSize(width: 504, height: 200)

    private static let identity = LocalTrackIdentity(
        playerID: "music", title: "Waiting Room", artist: "Halcyon Static", album: "Low Light",
        duration: 238, recordingID: nil
    )

    /// A store over the temporary folder, showing the lab's timeline for the
    /// lab's track, with `offset` as this track's correction.
    private func lyrics(_ isolated: ProbeStores, offset: TimeInterval) -> LyricsStore {
        let store = LyricsStore(
            offsetsDirectory: isolated.temp.appendingPathComponent("stage-offsets", isDirectory: true),
            defaults: isolated.suite
        )
        store.present(LabFixtures.timeline())
        store.activateTrackOffset(for: Self.identity)
        if offset != 0 { store.nudgeTrackOffset(by: offset) }
        return store
    }

    /// The correction is reset from the More menu now (redesign 2026-10-15,
    /// spec §5.2): the readout that carried a long-press and a named action went
    /// with the page's header, and the menu is what VoiceOver and Switch Control
    /// reach through the More button. It shows the correction as a line that
    /// cannot be pressed, offers Reset Lyric Timing while there is one to clear,
    /// and performing it clears this track's correction and stores the clearing.
    func testTheTimingCorrectionIsResetFromTheMoreMenu() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let lyrics = lyrics(isolated, offset: 0.5)
        XCTAssertEqual(lyrics.trackOffset, 0.5, accuracy: 0.0001, "the fixture did not set a correction")

        let controller = LyricsMoreMenuController(
            context: {
                .init(localFileName: nil, hasBinding: false, onlineOn: false, offset: lyrics.trackOffset, canNudge: true)
            },
            actions: .init(nudge: { lyrics.nudgeTrackOffset(by: $0) }, resetTiming: { lyrics.clearTrackOffset() })
        )
        let menu = controller.makeMenu()
        let readout = try XCTUnwrap(menu.items.first { $0.title == "+0.50s" }, "the correction is not in the menu")
        XCTAssertFalse(readout.isEnabled, "the readout is a line, not a control")
        let reset = try XCTUnwrap(menu.items.first { $0.title == "Reset Lyric Timing" })
        XCTAssertTrue(reset.isEnabled)

        controller.perform(.reset)
        XCTAssertEqual(lyrics.trackOffset, 0, "the action did not clear the correction")
        XCTAssertEqual(lyrics.trackOffset(for: Self.identity), 0, "the cleared correction was not stored")

        // At zero there is nothing to reset.
        let after = LyricsMoreMenuController(
            context: {
                .init(localFileName: nil, hasBinding: false, onlineOn: false, offset: lyrics.trackOffset, canNudge: true)
            },
            actions: .init()
        ).makeMenu()
        XCTAssertEqual(after.items.first { $0.title == "Reset Lyric Timing" }?.isEnabled, false)
    }

    /// The cover is light, not picture: blurred to a wash behind the lines.
    /// It used to be read as a nameless image the size of the stage. The
    /// bound is a size, as on the lock card, so any icon the header carries
    /// is not what this counts.
    func testTheAmbienceIsNotAnImageToFind() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(elapsed: 27), on: isolated.stores.media)
        XCTAssertNotNil(isolated.stores.media.artwork, "the cover must be decoded for this test to mean anything")
        let lyrics = lyrics(isolated, offset: 0)

        let stage = LyricsStage(media: isolated.stores.media, lyrics: lyrics, dismiss: {})
            .defaultAppStorage(isolated.suite)
        let root = await AXProbe.tree(of: stage, size: Self.size)
        // The page's furniture is gone (its header moved to the panel), so the
        // proof it rendered is a row: a line of the song that can be jumped to.
        XCTAssertFalse(
            root.all { $0.customActions.contains("Sync Here") }.isEmpty,
            "the stage did not render\n\(root.dump)"
        )

        let decorative = root.all(role: "AXImage").filter { image in
            guard image.label.isEmpty, image.title.isEmpty, let frame = image.frame else { return false }
            return frame.width >= 300 || frame.height >= 300
        }
        XCTAssertTrue(decorative.isEmpty, "\(decorative.count) unlabelled decorative images\n\(root.dump)")
    }
}
