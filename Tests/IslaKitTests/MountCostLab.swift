import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// What it costs the main thread to build and lay out each surface the panel
/// can show: the work a swap does inside its first frame (maturity program,
/// speed, 2026-10-29).
///
/// The player ⇄ Settings swap is the one morph the hitch lab saw drop frames,
/// and the reason was not the animation: Settings' tree is built inside the
/// frame that starts it (`SettingsStagedMountTests`, R8e). `measure-hitches.sh`
/// needs a window on the owner's screen, `yes` processes and an idle Mac; this
/// needs none of them, so a change to a pane's tree can carry its own before
/// and after. Each case hosts the panel in a never-ordered window, as the
/// visual lab does, and times only `NSHostingView` creation and its first
/// layout on the main thread's own CPU clock — the part of a swap's first
/// frame that is Isla's code. Drawing is the window server's and is left out.
///
/// The accessibility tree is not built: the lab session asks for it, and a
/// Mac without an assistive client never does, so it is switched back off.
///
/// Run by hand with `Scripts/measure-mounts.sh <label>`; skips itself without
/// ISLA_MOUNT_OUT, so `./scripts/check` only compiles it.
@MainActor
final class MountCostLab: VisualLabCase {
    private struct Sample: Encodable {
        let surface: String
        let medianMs: Double
        let minMs: Double
        let maxMs: Double
        let runs: Int
    }

    /// Two builds warm the process — fonts, symbol images, SwiftUI's own
    /// caches — as the app has been warmed by the time anyone swaps.
    private static let warmUp = 2
    /// 15 by default; `ISLA_MOUNT_RUNS` raises it, and `ISLA_MOUNT_ONLY`
    /// keeps the surfaces whose name contains it, so one surface can be
    /// built in a loop long enough for `sample` to see where its time goes.
    private static let runs = ProcessInfo.processInfo.environment["ISLA_MOUNT_RUNS"].flatMap(Int.init) ?? 15
    private static let only = ProcessInfo.processInfo.environment["ISLA_MOUNT_ONLY"].flatMap { $0.isEmpty ? nil : $0 }

    func testMountCost() async throws {
        guard let out = ProcessInfo.processInfo.environment["ISLA_MOUNT_OUT"], !out.isEmpty else {
            throw XCTSkip("ISLA_MOUNT_OUT is unset; Scripts/measure-mounts.sh sets it")
        }
        let label = ProcessInfo.processInfo.environment["ISLA_MOUNT_LABEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "run"
        let session = try makeSession()
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"),
                          with: NSNumber(value: false))
        session.apply(.base, defaults: [
            SettingsTable.volumeAndBrightnessKey: true,
            NotchViewModel.showLyricsKey: true,
        ])

        var samples: [Sample] = []
        func time(_ name: String, size: CGSize, _ view: () -> AnyView) async {
            var times: [Double] = []
            for run in 0..<(Self.warmUp + Self.runs) {
                let ms = Self.timeOneMount(view(), size: size)
                if run >= Self.warmUp { times.append(ms) }
                // A turn of the run loop between builds, as between two swaps.
                await LabRenderer.wait(0.01)
            }
            times.sort()
            samples.append(Sample(
                surface: name, medianMs: Self.round(times[times.count / 2]),
                minMs: Self.round(times.first ?? 0), maxMs: Self.round(times.last ?? 0), runs: times.count
            ))
        }
        func measure(_ name: String, height: CGFloat, _ build: () async throws -> NotchViewModel) async throws {
            if let only = Self.only, !name.contains(only) { return }
            let vm = try await build()
            // Let the view model's own first-run work (`.task`, stores
            // answering) settle, so only the tree is timed.
            await LabRenderer.wait(0.2)
            await time(name, size: CGSize(width: VisualLab.windowSize.width, height: height)) {
                Self.scene(vm, .base, height: height)
            }
        }
        // The lock card is a window of its own, built on every lock
        // (`LockCardWindow`), so its first layout is part of the lock's first
        // frame (B12). Playing with lyrics, as a lock with music finds it.
        func measureCard(_ pane: LockScreenCard.Pane) async {
            let name = "lock-card-\(pane.rawValue)"
            if let only = Self.only, !name.contains(only) { return }
            let stores = session.makeStores()
            await LabFixtures.play(.init(elapsed: 27), on: stores.media)
            stores.lyrics.present(LabFixtures.timeline())
            await LabRenderer.wait(0.2)
            let size = LockScreenCard.size(for: .standard)
            await time(name, size: size) {
                AnyView(LockScreenCard(
                    media: stores.media, lyrics: stores.lyrics, audio: VisualLabLockCardTests.audio(), initialPane: pane
                ).frame(width: size.width, height: size.height))
            }
        }

        let panel = Self.panelSize.height, tall = Self.stageSize.height
        try await measure("player-empty", height: panel) { try await self.openPanel(session) }
        try await measure("player-playing", height: panel) {
            try await self.openPanel(session, track: .init(elapsed: 27), lyrics: LabFixtures.timeline())
        }
        try await measure("lyric-stage", height: tall) {
            try await self.openPanel(session, surface: .stage, track: .init(elapsed: 27), lyrics: LabFixtures.timeline())
        }
        try await measure("shelf", height: panel) { try await self.openPanel(session, surface: .tray) }
        try await measure("clipboard", height: panel) { try await self.openPanel(session, surface: .clipboard) }
        try await measure("translate", height: panel) { try await self.openPanel(session, surface: .translate) }
        for section in SettingsSection.allCases {
            try await measure("settings-\(section.rawValue)", height: tall) {
                try await self.openPanel(session, surface: .settings, configure: { $0.settingsSection = section })
            }
        }
        for pane in LockScreenCard.Pane.allCases { await measureCard(pane) }

        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: folder.appendingPathComponent("mounts-\(label).json"))
        var table = "surface                        median ms    min    max\n"
        for s in samples {
            table += s.surface.padding(toLength: 30, withPad: " ", startingAt: 0)
                + String(format: " %9.2f %6.2f %6.2f\n", s.medianMs, s.minMs, s.maxMs)
        }
        print(table)
        try table.write(to: folder.appendingPathComponent("mounts-\(label).txt"), atomically: true, encoding: .utf8)
    }

    /// One hosting view, built and laid out once in a window that is never
    /// ordered in; the main thread's CPU time for it, in milliseconds.
    private static func timeOneMount(_ view: AnyView, size: CGSize) -> Double {
        let window = NSWindow(
            contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let hosting = NSHostingView(rootView: LabRenderer.environment(view, .base).frame(width: size.width, height: size.height))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        window.contentView = nil
        window.close()
        return Double(end - start) / 1_000_000
    }

    private static func round(_ ms: Double) -> Double { (ms * 100).rounded() / 100 }
}
