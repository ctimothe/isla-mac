import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

// MARK: - The idle-cost lab
//
// What each resting state of the island costs while nothing changes on it:
// shut and paused, shut and playing, shut with the lyric caption running, and
// open on each page. The efficiency column of the scorecard had no number for
// any of them, because `Scripts/measure-idle.sh` samples the installed Isla and
// can only run while the owner has it open (B0.6). This lab measures the same
// views without it, the way the hitch lab measures the morphs: one `NotchPanel`
// at the real notch at an alpha of 0.02 and deaf to the pointer (`HitchRig`),
// the visual lab's private defaults, pasteboard and refused network, under
// `NSApplication.run()`. Isla is never launched, quit or signalled.
//
// What it is not: the whole app. The controller's always-on timers (the
// pointer sampler at 8 Hz, the 2 s geometry watchdog, the Clipboard's 2 Hz
// poll, the helper's silence watch) are not built here, so what this reads is
// the cost of each state's views and the model behind them, on top of those.
// The render server's share of a frame is not this process's either; a view
// that redraws shows here as main-thread wake-ups and CPU, and its GPU cost is
// R8d-H9's, by eye in Activity Monitor.
//
// What it records, per state, over `ISLA_IDLE_SECONDS` (default 15) after a
// 2 s settle:
// - the process's CPU time and the main thread's, as a percentage of one core;
// - how often the main run loop woke (a run-loop observer on `afterWaiting`),
//   which is how often anything on the main thread had to run;
// - the kernel's wake-up counters for the task (`TASK_POWER_INFO`): interrupt
//   wake-ups and the ones that took a core out of idle.
// With ISLA_IDLE_DUMP set it also writes the main run loop's description
// halfway through each state (`runloop-<state>.txt`): its timers, with their
// intervals, are where a wake-up rate comes from.
// `floor` is the same process with the panel ordered out and the music
// paused: the runner's own cost, which every other row stands on.
//
// The `lock-*` states (B12) are the Mac locked with music: the island's locked
// pill in the panel, and the card in a window of its own as `LockCardWindow`
// hosts it, at the same alpha and as deaf to the pointer. The shield and the
// SkyLight space are not built, so these read the card's views and nothing of
// the lock's own.
//
// A rate under about 40 wake-ups a second is not resolved on a busy Mac: the
// runner's floor alone reached 38 on 2026-10-29, at a load of about 50. What
// this finds is a frame clock, 100 or more.
//
// Run by hand with `Scripts/measure-idle-lab.sh`; `./scripts/check` skips it
// (ISLA_IDLE_OUT unset).

@MainActor
private final class RunLoopWakes {
    private(set) var count = 0
    private var observer: CFRunLoopObserver?

    func start() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
}

/// Every layer under a root, by its path in the tree, with the properties an
/// animation changes: two of these a few frames apart name what is moving.
@MainActor
private enum LayerSnapshot {
    struct Entry: Equatable {
        var kind: String
        /// The Core Animation animations on the layer: the render server's
        /// motion, which costs the main thread nothing and never shows as a
        /// change of the layer's own values.
        var animations: [String]
        /// The ones among them whose time is over. Core Animation takes a
        /// finished animation off its layer at the next commit, so on a
        /// panel where nothing commits after it — the welcome over a paused
        /// song, B14 — the outline's opening spring was still listed nine
        /// seconds on, and read as motion that never ended.
        var ended: Set<String>
        var frame: CGRect
        var opacity: Float
        var transform: [CGFloat]
        var contents: ObjectIdentifier?
        var detail: String
    }

    static func take(_ root: CALayer?) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        func walk(_ layer: CALayer, path: String) {
            let t = layer.transform
            let frame = root.map { layer.convert(layer.bounds, to: $0) } ?? layer.frame
            var detail = layer.name ?? ""
            if let shape = layer as? CAShapeLayer, let path = shape.path { detail += " path \(path.boundingBox)" }
            if let delegate = layer.delegate { detail += " delegate \(type(of: delegate))" }
            let keys = layer.animationKeys() ?? []
            let local = layer.convertTime(CACurrentMediaTime(), from: nil)
            let ended = Set(keys.filter { key in
                guard let animation = layer.animation(forKey: key), animation.repeatCount.isFinite,
                      animation.repeatDuration == 0 else { return false }
                let runs = max(Double(animation.repeatCount), 1) * (animation.autoreverses ? 2 : 1)
                return local > animation.beginTime + animation.duration * runs
            })
            entries[path] = Entry(
                kind: String(describing: type(of: layer)), animations: keys, ended: ended,
                frame: frame, opacity: layer.opacity,
                transform: [t.m11, t.m12, t.m21, t.m22, t.m41, t.m42],
                contents: (layer.contents as AnyObject?).map(ObjectIdentifier.init), detail: detail
            )
            for (index, sub) in (layer.sublayers ?? []).enumerated() { walk(sub, path: path + "/\(index)") }
        }
        if let root { walk(root, path: "") }
        return entries
    }

    static func changes(from a: [String: Entry], to b: [String: Entry]) -> [String] {
        var lines: [String] = ["\(b.count) layers, \(Set(a.keys).symmetricDifference(b.keys).count) added or gone"]
        for key in b.keys.sorted() {
            guard let entry = b[key], !entry.animations.isEmpty else { continue }
            let running = entry.animations.filter { !entry.ended.contains($0) }
            let ended = entry.animations.filter { entry.ended.contains($0) }
            if !running.isEmpty {
                lines.append("\(key) \(entry.kind) [\(entry.detail)] animating on Core Animation: \(running.joined(separator: ", "))")
            }
            if !ended.isEmpty {
                lines.append("\(key) \(entry.kind) [\(entry.detail)] ended, not yet collected: \(ended.joined(separator: ", "))")
            }
        }
        for key in b.keys.sorted() {
            guard let new = b[key], let old = a[key], new != old else { continue }
            var what: [String] = []
            if new.frame != old.frame { what.append("frame \(old.frame) -> \(new.frame)") }
            if new.opacity != old.opacity { what.append("opacity \(old.opacity) -> \(new.opacity)") }
            if new.transform != old.transform { what.append("transform \(old.transform) -> \(new.transform)") }
            if new.contents != old.contents { what.append("contents") }
            if new.detail != old.detail { what.append("detail \(old.detail) -> \(new.detail)") }
            lines.append("\(key) \(new.kind) [\(new.detail)] at \(new.frame): " + what.joined(separator: "; "))
        }
        return lines
    }
}

/// One reading of the counters this lab compares.
private struct IdleCounters {
    var wall: CFTimeInterval
    var processCPU: TimeInterval
    var mainCPU: TimeInterval
    var interruptWakeups: UInt64
    var idleWakeups: UInt64
    var runLoopWakes: Int

    @MainActor
    static func read(main: mach_port_t, wakes: RunLoopWakes) -> IdleCounters {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let process = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6

        var thread = thread_basic_info()
        var threadCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let threadStatus = withUnsafeMutablePointer(to: &thread) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                thread_info(main, thread_flavor_t(THREAD_BASIC_INFO), $0, &threadCount)
            }
        }
        let mainCPU = threadStatus == KERN_SUCCESS
            ? Double(thread.user_time.seconds) + Double(thread.user_time.microseconds) / 1e6
                + Double(thread.system_time.seconds) + Double(thread.system_time.microseconds) / 1e6
            : 0

        var power = task_power_info()
        var powerCount = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<natural_t>.size)
        let powerStatus = withUnsafeMutablePointer(to: &power) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
            }
        }
        return IdleCounters(
            wall: CACurrentMediaTime(), processCPU: process, mainCPU: mainCPU,
            interruptWakeups: powerStatus == KERN_SUCCESS ? power.task_interrupt_wakeups : 0,
            idleWakeups: powerStatus == KERN_SUCCESS ? power.task_platform_idle_wakeups : 0,
            runLoopWakes: wakes.count
        )
    }

    /// Per second, between two readings.
    static func rates(from a: IdleCounters, to b: IdleCounters) -> [String: Double] {
        let seconds = max(b.wall - a.wall, 0.001)
        func rounded(_ value: Double, _ places: Double = 100) -> Double { (value * places).rounded() / places }
        return [
            "seconds": rounded(seconds, 10),
            "processCPUPercent": rounded((b.processCPU - a.processCPU) / seconds * 100),
            "mainCPUPercent": rounded((b.mainCPU - a.mainCPU) / seconds * 100),
            "runLoopWakesPerSecond": rounded(Double(b.runLoopWakes - a.runLoopWakes) / seconds, 10),
            "interruptWakeupsPerSecond": rounded(Double(b.interruptWakeups &- a.interruptWakeups) / seconds, 10),
            "idleWakeupsPerSecond": rounded(Double(b.idleWakeups &- a.idleWakeups) / seconds, 10),
        ]
    }
}

@MainActor
final class IdleCostLab: VisualLabCase {
    static let envKey = "ISLA_IDLE_OUT"

    private var seconds: TimeInterval {
        Double(ProcessInfo.processInfo.environment["ISLA_IDLE_SECONDS"] ?? "") ?? 15
    }
    private var label: String { ProcessInfo.processInfo.environment["ISLA_IDLE_LABEL"] ?? "run" }
    private var stateFilter: Set<String>? {
        ProcessInfo.processInfo.environment["ISLA_IDLE_STATES"].map { Set($0.split(separator: ",").map(String.init)) }
    }

    struct State {
        var name: String
        var prepare: @MainActor (HitchRig) async -> Void
    }

    /// The lock card's window while a `lock-*` state runs.
    private var cardWindow: NSWindow?

    /// The shield's two windows, as a locked Mac with music shows them: the
    /// panel's locked pill and the card.
    private func lock(_ rig: HitchRig, pane: LockScreenCard.Pane) {
        rig.vm.isOpen = false
        rig.vm.isLockedPresentation = true
        rig.panel.orderFrontRegardless()
        let size = LockScreenCard.size(for: .standard)
        let screen = rig.panel.screen?.frame ?? NSScreen.screens.first?.frame ?? .zero
        let window = NSWindow(
            contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .statusBar
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: LockScreenCard(
            media: rig.vm.media, lyrics: rig.vm.lyrics, audio: VisualLabLockCardTests.audio(), initialPane: pane
        ).frame(width: size.width, height: size.height))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        cardWindow = window
    }

    /// Back to an unlocked Mac, with no welcome and no update alert, before
    /// every state.
    private func reset(_ rig: HitchRig) {
        cardWindow?.orderOut(nil)
        cardWindow?.contentView = nil
        cardWindow = nil
        rig.vm.isLockedPresentation = false
        rig.vm.isShowingWelcome = false
        rig.vm.updateOffer = nil
        UpdateInstaller.sharedOverride = nil
    }

    /// The update alert on the shut island, with the installer at `phase`: a
    /// stand-in that never installs. The controller that folds the alert after
    /// its hold is not built here, so it stays up for the whole window.
    private func offerUpdate(_ rig: HitchRig, phase: UpdateInstaller.Phase) {
        let release = UpdateCheck.Release(
            version: "0.4.0.11", page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v0.4.0.11")!
        )
        let installer = UpdateInstaller(environment: .neverInstalls)
        installer.presentForTests(phase, release: release)
        UpdateInstaller.sharedOverride = installer
        rig.panel.orderFrontRegardless()
        rig.vm.isOpen = false
        rig.vm.updateOffer = UpdateOffer(release: release)
    }

    private func states() -> [State] {
        let playing = LabFixtures.Track()
        func shut(_ rig: HitchRig) {
            rig.panel.orderFrontRegardless()
            rig.vm.isOpen = false
        }
        func open(_ rig: HitchRig, on surface: NotchViewModel.Surface) {
            rig.panel.orderFrontRegardless()
            rig.vm.isOpen = true
            rig.vm.open(surface)
        }
        return [
            State(name: "floor") { rig in
                rig.vm.isOpen = false
                LabFixtures.pause(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                rig.panel.orderOut(nil)
            },
            State(name: "shut-paused") { rig in
                shut(rig)
                LabFixtures.pause(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
            },
            State(name: "shut-playing") { rig in
                shut(rig)
                await LabFixtures.play(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
            },
            State(name: "shut-caption") { rig in
                shut(rig)
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                rig.vm.lyrics.present(LabFixtures.timeline())
            },
            State(name: "open-player") { rig in
                await LabFixtures.play(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                open(rig, on: .player)
            },
            State(name: "open-player-lyrics") { rig in
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                rig.vm.lyrics.present(LabFixtures.timeline())
                open(rig, on: .player)
            },
            // The same player reached the way a song change reaches it: open
            // first, then the lyrics arrive (or the position jumps) under it.
            State(name: "lyrics-arrive") { rig in
                rig.vm.isOpen = false
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                open(rig, on: .player)
                try? await Task.sleep(for: .seconds(1))
                rig.vm.lyrics.present(LabFixtures.timeline())
            },
            State(name: "seek-while-open") { rig in
                rig.vm.isOpen = false
                await LabFixtures.play(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                open(rig, on: .player)
                try? await Task.sleep(for: .seconds(1))
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
            },
            State(name: "open-stage") { rig in
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                rig.vm.lyrics.present(LabFixtures.timeline())
                open(rig, on: .stage)
            },
            State(name: "open-tray") { rig in
                await LabFixtures.play(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                open(rig, on: .tray)
            },
            State(name: "open-clipboard") { rig in
                await LabFixtures.play(playing, on: rig.vm.media)
                open(rig, on: .clipboard)
            },
            State(name: "open-translate") { rig in
                await LabFixtures.play(playing, on: rig.vm.media)
                open(rig, on: .translate)
            },
            State(name: "open-settings") { rig in
                await LabFixtures.play(playing, on: rig.vm.media)
                open(rig, on: .settings)
            },
            // B14: the welcome over the player, as a new install opens on
            // it, and the update alert offered and mid-download.
            State(name: "open-welcome") { rig in
                LabFixtures.pause(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                open(rig, on: .player)
                rig.vm.isShowingWelcome = true
            },
            State(name: "update-offer") { rig in
                await LabFixtures.play(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                self.offerUpdate(rig, phase: .idle)
            },
            State(name: "update-downloading") { rig in
                await LabFixtures.play(playing, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                self.offerUpdate(rig, phase: .downloading(received: 4_000_000, total: 10_000_000))
            },
            State(name: "lock-player") { rig in
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                rig.vm.lyrics.present(LabFixtures.timeline())
                self.lock(rig, pane: .player)
            },
            State(name: "lock-lyrics") { rig in
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                rig.vm.lyrics.present(LabFixtures.timeline())
                self.lock(rig, pane: .lyrics)
            },
            State(name: "lock-long-title") { rig in
                await LabFixtures.play(LabFixtures.longTitle, on: rig.vm.media)
                rig.vm.lyrics.present(.disabled)
                self.lock(rig, pane: .player)
            },
            State(name: "lock-paused") { rig in
                await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                LabFixtures.pause(.init(elapsed: 27), on: rig.vm.media)
                rig.vm.lyrics.present(LabFixtures.timeline())
                self.lock(rig, pane: .lyrics)
            },
        ]
    }

    /// Under `NSApplication.run()`, for the hitch lab's reason: a loop the
    /// test runner spins by hand lays SwiftUI out thousands of times a second.
    func testIdleCost() throws {
        guard let path = ProcessInfo.processInfo.environment[Self.envKey], !path.isEmpty else {
            throw XCTSkip("set \(Self.envKey) (Scripts/measure-idle-lab.sh) to run the idle-cost lab")
        }
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("the idle-cost lab needs a window-server session") }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let session = try makeSession()
        session.apply(.base)

        NSApplication.shared.setActivationPolicy(.accessory)
        var outcome: Result<[[String: Any]], Error>?
        Task { @MainActor in
            do {
                let rig = try await HitchRig(session: session)
                defer { rig.tearDown() }
                outcome = .success(try await self.measure(rig: rig, dump: ProcessInfo.processInfo.environment["ISLA_IDLE_DUMP"] == nil ? nil : out))
            } catch {
                outcome = .failure(error)
            }
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) { NSApp.postEvent(wake, atStart: true) }
        }
        NSApp.run()

        let report = try XCTUnwrap(outcome, "the run loop ended before the lab finished").get()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let document: [String: Any] = [
            "label": label,
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "loadAverageAtStart": load[0],
            "secondsPerState": seconds,
            "screen": NSScreen.screens.first.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) @ \($0.maximumFramesPerSecond) Hz" } ?? "?",
            "results": report,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("idle-\(label).json"))
        print(Self.table(results: report))
    }

    private func measure(rig: HitchRig, dump: URL?) async throws -> [[String: Any]] {
        let main = mach_thread_self()
        let wakes = RunLoopWakes()
        wakes.start()
        defer { wakes.stop() }
        var report: [[String: Any]] = []
        for state in states() where stateFilter?.contains(state.name) ?? true {
            reset(rig)
            await state.prepare(rig)
            try await Task.sleep(for: .seconds(2))
            let before = IdleCounters.read(main: main, wakes: wakes)
            try await Task.sleep(for: .seconds(seconds / 2))
            // The main run loop's own account of itself mid-window: every
            // timer with its interval and next fire, every source and
            // observer, which is how a wake-up rate is traced to who asked.
            if let dump {
                let text = CFCopyDescription(CFRunLoopGetMain()) as String
                try? text.write(to: dump.appendingPathComponent("runloop-\(state.name).txt"), atomically: true, encoding: .utf8)
                // And what is moving: a frame clock with no Isla code under it
                // is an animation that has not ended, and the layer it moves
                // says whose it is.
                let card = cardWindow?.contentView?.layer
                let first = LayerSnapshot.take(rig.root.layer)
                let firstCard = LayerSnapshot.take(card)
                try await Task.sleep(for: .milliseconds(50))
                let moved = LayerSnapshot.changes(from: first, to: LayerSnapshot.take(rig.root.layer))
                    + LayerSnapshot.changes(from: firstCard, to: LayerSnapshot.take(card)).map { "card " + $0 }
                try? moved.joined(separator: "\n").write(
                    to: dump.appendingPathComponent("moving-\(state.name).txt"), atomically: true, encoding: .utf8
                )
            }
            try await Task.sleep(for: .seconds(seconds / 2))
            let after = IdleCounters.read(main: main, wakes: wakes)
            var row: [String: Any] = IdleCounters.rates(from: before, to: after)
            row["state"] = state.name
            report.append(row)
        }
        reset(rig)
        return report
    }

    private static func table(results: [[String: Any]]) -> String {
        var lines = ["state                 process%  main%  loop/s  intr/s  idle/s"]
        for row in results {
            func number(_ key: String) -> String { String(format: "%7.2f", row[key] as? Double ?? 0) }
            let name = (row["state"] as? String ?? "?").padding(toLength: 20, withPad: " ", startingAt: 0)
            lines.append("\(name) \(number("processCPUPercent"))  \(number("mainCPUPercent")) \(number("runLoopWakesPerSecond")) \(number("interruptWakeupsPerSecond")) \(number("idleWakeupsPerSecond"))")
        }
        return lines.joined(separator: "\n")
    }
}
