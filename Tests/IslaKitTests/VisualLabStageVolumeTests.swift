import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// A player that answers every volume question at once with the same reply.
/// The lab's stand-in for Spotify: nothing leaves the process.
@MainActor
final class ImmediateVolumeScripter: PlayerVolumeScripting {
    let percent: Int?
    let outcome: OSStatus

    init(percent: Int?, outcome: OSStatus = noErr) {
        self.percent = percent
        self.outcome = outcome
    }

    func readVolume(of app: PlayerApp, completion: @escaping @MainActor @Sendable (Int?, OSStatus) -> Void) {
        completion(percent, outcome)
    }

    func writeVolume(_ percent: Int, to app: PlayerApp, completion: @escaping @MainActor @Sendable (OSStatus) -> Void) {
        completion(outcome)
    }
}

/// The lyric stage with its volume slider open (spec §19.6, amended
/// 2026-10-26): Spotify's own volume, and the fallback to the Mac's with its
/// one line after a refused Automation. Every collaborator is a fake.
@MainActor
final class VisualLabStageVolumeTests: VisualLabCase {
    private func stage(
        _ session: LabSession, _ variant: LabVariant, scripter: ImmediateVolumeScripter
    ) async throws -> AnyView {
        let vm = try await openPanel(session, lyrics: LabFixtures.timeline()) { stores in
            // A Spotify session, so the control picks Spotify's own volume.
            stores.media.bundleIdentifierForPID = { _ in PlayerApp.spotify.bundleID }
            var snapshot = NowPlayingFeed.Snapshot()
            snapshot.title = "Waiting Room"
            snapshot.artist = "Phoebe Bridgers"
            snapshot.album = "Stranger in the Alps"
            snapshot.duration = 240
            snapshot.elapsed = 27
            snapshot.rate = 1
            snapshot.isPlaying = true
            snapshot.takenAt = Date()
            snapshot.playerPID = 4242
            snapshot.artwork = LabFixtures.cover()
            stores.media.apply(snapshot)
            for _ in 0..<150 where stores.media.artwork == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let volume = PlayerVolume(
            scripter: scripter, mac: FakeMacVolume(),
            consent: { _ in .allowed },
            schedule: { _, _ in {} }
        )
        volume.sourceChanged(bundleID: PlayerApp.spotify.bundleID)
        volume.open()
        PlayerVolume.shared = volume
        vm.openStage()
        return Self.scene(vm, variant, height: Self.stageSize.height)
    }

    func testStageVolume() async throws {
        let saved = PlayerVolume.shared
        defer { PlayerVolume.shared = saved }
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-lyrics-stage")
        let size = Self.stageSize
        try await shoot.shoot("volume-open-spotify", variants: LabVariant.panel, size: size, settle: 0.3) { variant in
            try await self.stage(session, variant, scripter: ImmediateVolumeScripter(percent: 40))
        }
        try await shoot.shoot("volume-automation-refused", variants: LabVariant.panel, size: size, settle: 0.3) { variant in
            try await self.stage(session, variant, scripter: ImmediateVolumeScripter(percent: nil, outcome: AutomationAccess.refused))
        }
    }
}
