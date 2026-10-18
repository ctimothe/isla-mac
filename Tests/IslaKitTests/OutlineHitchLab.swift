import AppKit
import QuartzCore
import SwiftUI
import XCTest
import os
@testable import IslaKit

// MARK: - The hitch lab
//
// How the island's own morphs behave on a real screen, with the Mac idle and
// with its cores taken, and what its outline does while the main thread is
// busy or blocked (redesign spec §19.12, "the island lags while I work").
//
// This lab is not the visual lab. The visual lab never orders a window in;
// this one must, because a display link only ticks for a window the window
// server is compositing, and a main thread that is late for a vsync is the
// measurement. It therefore needs a window-server session and is run by hand
// with `Scripts/measure-hitches.sh`, outside the shell sandbox.
// `./scripts/check` skips every case here: ISLA_HITCH_OUT is unset.
//
// What it touches, and what it does not:
// - One borderless `NotchPanel` at the real notch, the size the app cuts, at
//   an alpha of 0.02 and with mouse events ignored: composited and ticked as
//   any window is, invisible to the person at the keyboard and deaf to their
//   pointer. Isla itself is never launched, quit, clicked or signalled.
// - The view model is built the visual lab's way: private defaults, a private
//   pasteboard, players cut off, the network refused in-process.
// - `yes` processes (one per core, or three), for the loaded runs only,
//   started and ended by the case itself and never left behind.
//
// What it records, per morph:
// - The display link's callbacks (one per vsync the main thread was free for,
//   so a gap is a frame it did not deliver): Apple's hitch time from them.
// - The main thread's CPU time over the morph.
// - How long the outline's *presented* width stood still while it was moving,
//   sampled a thousand times a second from a thread of its own (below). With
//   a deliberate 50 ms block of the main thread in the middle, that is the
//   outline's own stall, and what it travelled during the block.
//
// It runs under `NSApplication.run()`, not under the test runner's wait. The
// runner spins the main run loop by hand, and a hand-spun loop is not the
// app's: under it a SwiftUI animation lays out its hosting view some 27 000
// times a second (one rectangle: 640 ms of CPU a second, against 81 layouts
// and 25 ms under `NSApp.run()`), so every figure this lab gave before it ran
// the way the app runs measured the runner, not the island.

/// One morph's window on the recorded streams.
private struct HitchWindow {
    var name: String
    var start: CFTimeInterval
    var end: CFTimeInterval
    var cpu: TimeInterval
    /// The main thread's deliberate block inside the window, if there was one.
    var stall: ClosedRange<CFTimeInterval>?
}

@MainActor
private final class FrameRecorder: NSObject {
    struct Tick { var timestamp: CFTimeInterval; var target: CFTimeInterval; var ranAt: CFTimeInterval }
    private(set) var ticks: [Tick] = []
    private var link: CADisplayLink?

    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        ticks.append(Tick(timestamp: link.timestamp, target: link.targetTimestamp, ranAt: CACurrentMediaTime()))
    }
}

/// The main thread's own CPU time, user and system, from the kernel: the work
/// a morph costs whatever else the Mac is doing.
@MainActor
private struct MainThreadClock {
    let port = mach_thread_self()

    func cpu() -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + system
    }
}

/// Watches how wide the island's outline is *drawn*, from a thread of its own,
/// a thousand times a second — and so how long it stands still while it should
/// be moving.
///
/// Read from the layer tree's presentation values, which is what the render
/// server is last told, not from anything the main thread publishes. A main
/// thread that is late (or blocked, on purpose) leaves the width where it was
/// when SwiftUI draws the outline, one commit per frame; it does not when Core
/// Animation does. Width is the widest of the shape layers and of the layers
/// hung from the top edge; the outline is the widest thing in the island.
private final class OutlineProbe: @unchecked Sendable {
    struct Sample { var time: CFTimeInterval; var width: Double }
    private let roots: [CALayer]
    /// Layers as wide as the window are containers, not the island: the
    /// outline is the widest thing that is not.
    private let ceiling: Double
    private let lock = NSLock()
    private var running = false
    private var samples: [Sample] = []

    init(roots: [CALayer], windowWidth: CGFloat) {
        self.roots = roots
        ceiling = Double(windowWidth) - 2
    }

    func start() {
        lock.withLock { running = true; samples = [] }
        Thread.detachNewThread { [self] in
            Thread.current.qualityOfService = .userInteractive
            while lock.withLock({ running }) {
                let now = CACurrentMediaTime()
                let width = autoreleasepool { roots.map { Self.extent(of: $0, depth: 0, below: ceiling) }.max() ?? 0 }
                lock.withLock { samples.append(Sample(time: now, width: width)) }
                usleep(1000)
            }
        }
    }

    func stop() -> [Sample] {
        lock.withLock { running = false }
        usleep(5000)
        return lock.withLock { samples }
    }

    private static func extent(of layer: CALayer, depth: Int, below ceiling: Double) -> Double {
        let shown = layer.presentation() ?? layer
        var widest = 0.0
        if let shape = shown as? CAShapeLayer, let path = shape.path {
            let width = Double(path.boundingBox.width)
            if width < ceiling, !shown.isHidden { widest = width }
        } else if depth > 0, shown.frame.minY <= 0.5, shown.frame.height > 8, !shown.isHidden {
            let width = Double(shown.frame.width)
            if width < ceiling { widest = width }
        }
        guard depth < 5 else { return widest }
        for child in layer.sublayers ?? [] {
            widest = max(widest, extent(of: child, depth: depth + 1, below: ceiling))
        }
        return widest
    }
}

/// `yes > /dev/null`, as many as asked. Ended by `stop()`, by `deinit`, and by
/// the script that runs the lab, which kills the pids this file names.
private final class CPUStress {
    private var processes: [Process] = []
    private let pidFile: URL?

    init(pidFile: URL?) { self.pidFile = pidFile }

    func start(count: Int) {
        for _ in 0..<count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            processes.append(process)
        }
        if let pidFile {
            let pids = processes.map { String($0.processIdentifier) }.joined(separator: "\n")
            try? pids.write(to: pidFile, atomically: true, encoding: .utf8)
        }
    }

    func stop() {
        for process in processes where process.isRunning { process.terminate() }
        for process in processes { process.waitUntilExit() }
        processes = []
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
    }

    deinit { for process in processes where process.isRunning { process.terminate() } }
}

/// The real island on a real screen: the panel the controller cuts, the root
/// view, the hosting view, built the way `NotchController.build` builds them.
@MainActor
final class HitchRig {
    let panel: NotchPanel
    let vm: NotchViewModel
    let root: NotchRootView
    let hosting: NSHostingView<NotchContentView>
    /// The main thread's deliberate blocks, in order, taken by the case.
    fileprivate var stalls: [ClosedRange<CFTimeInterval>] = []

    init(session: LabSession) async throws {
        guard let geometry = NotchGeometry.current() else { throw XCTSkip("no display") }
        let stores = session.makeStores()
        await LabFixtures.play(.init(), on: stores.media)
        vm = NotchViewModel(geometry: geometry, stores: stores, defaults: session.suite)

        panel = NotchPanel(contentRect: geometry.windowFrame)
        let stage = NotchStage.make(viewModel: vm, windowSize: geometry.windowSize)
        root = stage.root
        hosting = stage.hosting
        root.wantsLayer = true
        panel.contentView = root

        // Composited and ticked, not seen and not clicked.
        panel.alphaValue = 0.02
        panel.ignoresMouseEvents = true
        root.activeRect = CGRect(origin: .zero, size: geometry.windowSize)
        panel.orderFrontRegardless()
    }

    /// Blocks the main thread for `duration` seconds, `delay` from now: a
    /// 50 ms stretch of work the main thread did not have to do, which is what
    /// a synchronous AppleScript, a page fault or a long layout looks like to
    /// everything that waits on it.
    func block(after delay: TimeInterval, for duration: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let began = CACurrentMediaTime()
            Thread.sleep(forTimeInterval: duration)
            stalls.append(began...CACurrentMediaTime())
        }
    }

    func tearDown() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

@MainActor
final class OutlineHitchLab: VisualLabCase {
    static let envKey = "ISLA_HITCH_OUT"
    private let signposter = OSSignposter(subsystem: "com.ctimothe.isla.hitchlab", category: "morph")

    /// How long each morph is watched: the spring's settle (0.63 s to half a
    /// point over the widest travel, 0.98 s to rest) plus the content's curves.
    private let window: TimeInterval = 1.0
    private let hold: TimeInterval = 0.35

    private var output: URL {
        get throws {
            guard let path = ProcessInfo.processInfo.environment[Self.envKey], !path.isEmpty else {
                throw XCTSkip("set \(Self.envKey) (Scripts/measure-hitches.sh) to run the hitch lab")
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private var label: String { ProcessInfo.processInfo.environment["ISLA_HITCH_LABEL"] ?? "run" }
    private var cycles: Int { Int(ProcessInfo.processInfo.environment["ISLA_HITCH_CYCLES"] ?? "") ?? 8 }
    private var scenarioFilter: Set<String>? {
        ProcessInfo.processInfo.environment["ISLA_HITCH_SCENARIOS"].map { Set($0.split(separator: ",").map(String.init)) }
    }
    private var loads: [String] {
        (ProcessInfo.processInfo.environment["ISLA_HITCH_LOADS"] ?? "idle,stressed,saturated")
            .split(separator: ",").map(String.init)
    }

    struct Scenario {
        var name: String
        /// Puts the island where the scenario starts, and returns when it has settled.
        var prepare: @MainActor (HitchRig) async -> Void
        /// The morphs of one cycle, in order; each is watched for a window.
        var steps: [(name: String, run: @MainActor (HitchRig) -> Void)]
    }

    private func scenarios() -> [Scenario] {
        let reduceMotion = SystemAppearance.shared.reduceMotion
        let open: @MainActor (HitchRig) -> Void = { rig in
            withAnimation(Theme.open(reduceMotion: reduceMotion)) { rig.vm.isOpen = true }
        }
        let close: @MainActor (HitchRig) -> Void = { rig in
            withAnimation(Theme.close(reduceMotion: reduceMotion)) { rig.vm.isOpen = false }
        }
        let headphonesIn: @MainActor (HitchRig) -> Void = { rig in
            withAnimation(Theme.pill(reduceMotion: reduceMotion)) {
                rig.vm.ambient = .headphones(name: "AirPods Pro", symbol: "airpods.pro")
            }
        }
        let headphonesOut: @MainActor (HitchRig) -> Void = { rig in
            withAnimation(Theme.pill(reduceMotion: reduceMotion)) { rig.vm.ambient = nil }
        }
        return [
            // Nothing moves: what the island costs the main thread standing
            // still, with the music playing (the equalizer's bars run) and
            // paused. The floor every morph below sits on.
            Scenario(
                name: "rest-playing",
                prepare: { rig in
                    rig.vm.isOpen = false
                    await LabFixtures.play(.init(), on: rig.vm.media)
                },
                steps: [("rest", { _ in })]
            ),
            Scenario(
                name: "rest-paused",
                prepare: { rig in
                    rig.vm.isOpen = false
                    LabFixtures.pause(.init(), on: rig.vm.media)
                },
                steps: [("rest", { _ in })]
            ),
            Scenario(
                name: "open-close",
                prepare: { rig in rig.vm.isOpen = false },
                steps: [("open", open), ("close", close)]
            ),
            // The player with its lyric caption running: the heaviest thing
            // the panel draws while it opens.
            Scenario(
                name: "open-close-lyrics",
                prepare: { rig in
                    rig.vm.isOpen = false
                    await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                    rig.vm.lyrics.present(LabFixtures.timeline())
                },
                steps: [("open", open), ("close", close)]
            ),
            Scenario(
                name: "surface-change",
                prepare: { rig in rig.vm.isOpen = true; rig.vm.open(.player) },
                steps: [
                    ("player-to-settings", { rig in
                        withAnimation(Theme.island(reduceMotion: reduceMotion)) { rig.vm.open(.settings) }
                    }),
                    ("settings-to-player", { rig in
                        withAnimation(Theme.island(reduceMotion: reduceMotion)) { rig.vm.open(.player) }
                    }),
                ]
            ),
            Scenario(
                name: "alert",
                prepare: { rig in rig.vm.isOpen = false; rig.vm.ambient = nil },
                steps: [("headphones-in", headphonesIn), ("headphones-out", headphonesOut)]
            ),
            // The main thread blocked for 50 ms, 120 ms into the morph: what
            // the outline does while everything on the main thread waits.
            Scenario(
                name: "open-stall",
                prepare: { rig in rig.vm.isOpen = false },
                steps: [
                    ("open+50ms-block", { rig in open(rig); rig.block(after: 0.12, for: 0.05) }),
                    ("close", close),
                ]
            ),
            Scenario(
                name: "alert-stall",
                prepare: { rig in rig.vm.isOpen = false; rig.vm.ambient = nil },
                steps: [
                    ("headphones-in+50ms-block", { rig in headphonesIn(rig); rig.block(after: 0.12, for: 0.05) }),
                    ("headphones-out", headphonesOut),
                ]
            ),
        ]
    }

    /// Runs under a real `NSApplication.run()`, not under the test runner's
    /// own wait (see the note at the top). The case is synchronous for the
    /// same reason: an `async` test body is itself a job on the main queue, and
    /// a loop run from inside one is nested in it.
    func testMorphHitches() throws {
        let out = try output
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("the hitch lab needs a window-server session") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let session = try makeSession()
        session.apply(.base)

        NSApplication.shared.setActivationPolicy(.accessory)
        var outcome: Result<[[String: Any]], Error>?
        Task { @MainActor in
            do {
                let rig = try await HitchRig(session: session)
                defer { rig.tearDown() }
                outcome = .success(try await self.runScenarios(rig: rig, out: out))
            } catch {
                outcome = .failure(error)
            }
            NSApp.stop(nil)
            // `stop` only takes effect when the loop next handles an event.
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) { NSApp.postEvent(wake, atStart: true) }
        }
        NSApp.run()

        let report = try XCTUnwrap(outcome, "the run loop ended before the lab finished").get()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let document: [String: Any] = [
            "label": label,
            "cores": cores,
            "loadAverageAtStart": Self.loadAverage(),
            "cyclesPerStep": cycles,
            "windowSeconds": window,
            "screen": NSScreen.screens.first.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) @ \($0.maximumFramesPerSecond) Hz" } ?? "?",
            "results": report,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("hitches-\(label).json"))
        print(Self.table(label: label, results: report))
    }

    private func runScenarios(rig: HitchRig, out: URL) async throws -> [[String: Any]] {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var report: [[String: Any]] = []
        for load in loads {
            for scenario in scenarios() where scenarioFilter?.contains(scenario.name) ?? true {
                await scenario.prepare(rig)
                try await settle(0.8)
                let stress = CPUStress(pidFile: out.appendingPathComponent("stress.pids"))
                // idle: nothing added. stressed: one `yes` per core, the brief's
                // recipe. saturated: three per core, so the main thread is one of
                // forty-odd runnable threads, which is a Mac mid-build.
                switch load {
                case "stressed": stress.start(count: cores); try await settle(0.6)
                case "saturated": stress.start(count: cores * 3); try await settle(0.6)
                default: break
                }
                defer { stress.stop() }

                let frames = FrameRecorder()
                frames.start(on: rig.hosting)
                let probe = OutlineProbe(
                    roots: [rig.root.layer, rig.hosting.layer].compactMap { $0 },
                    windowWidth: rig.panel.frame.width
                )
                probe.start()
                let clock = MainThreadClock()
                var windows: [HitchWindow] = []
                // Two cycles are warm-up: first-use costs (fonts, glyph caches,
                // layer trees) are not what an owner's tenth open feels like.
                for cycle in 0..<(cycles + 2) {
                    for step in scenario.steps {
                        let began = CACurrentMediaTime()
                        let cpuBefore = clock.cpu()
                        let stallsBefore = rig.stalls.count
                        let id = signposter.makeSignpostID()
                        let state = signposter.beginInterval("morph", id: id, "\(scenario.name)/\(step.name) \(load)")
                        step.run(rig)
                        try await settle(window)
                        signposter.endInterval("morph", state)
                        if cycle >= 2 {
                            windows.append(HitchWindow(
                                name: step.name, start: began, end: CACurrentMediaTime(),
                                cpu: clock.cpu() - cpuBefore,
                                stall: rig.stalls.count > stallsBefore ? rig.stalls.last : nil
                            ))
                        }
                        try await settle(hold)
                    }
                }
                let widths = probe.stop()
                frames.stop()
                stress.stop()

                report.append(summarise(
                    scenario: scenario.name, load: load, windows: windows,
                    ticks: frames.ticks, widths: widths
                ))
            }
        }
        return report
    }

    /// Spins the main run loop for `seconds`, so the display link, the commit
    /// and the animations are serviced exactly as in the app.
    private func settle(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Analysis

    private func summarise(
        scenario: String, load: String, windows: [HitchWindow],
        ticks: [FrameRecorder.Tick], widths: [OutlineProbe.Sample]
    ) -> [String: Any] {
        let period = ticks.first.map { $0.target - $0.timestamp } ?? 1.0 / 60

        var perStep: [String: [[String: Double]]] = [:]
        for w in windows {
            let inside = ticks.filter { $0.timestamp >= w.start && $0.timestamp <= w.end }
            // Apple's hitch time: how much longer than its slot a frame stayed
            // on screen. Here, the vsyncs the main thread did not answer.
            var hitch = 0.0
            var missed = 0
            var worstGap = 0.0
            for (a, b) in zip(inside, inside.dropFirst()) {
                let gap = b.timestamp - a.timestamp
                let late = gap - period
                if late > period * 0.5 { hitch += late; missed += Int((late / period).rounded()) }
                worstGap = max(worstGap, gap)
            }
            let span = w.end - w.start
            let lateness = inside.map { max(0, $0.ranAt - $0.timestamp) }
            var sample: [String: Double] = [
                "frames": Double(inside.count),
                "expectedFrames": span / period,
                "missedFrames": Double(missed),
                "hitchMsPerSecond": hitch / span * 1000,
                "worstGapMs": worstGap * 1000,
                "worstCallbackLatenessMs": (lateness.max() ?? 0) * 1000,
                "mainCPUMs": w.cpu * 1000,
            ]
            sample.merge(Self.outline(in: w, widths: widths)) { $1 }
            perStep[w.name, default: []].append(sample)
        }
        var steps: [[String: Any]] = []
        for (name, samples) in perStep.sorted(by: { $0.key < $1.key }) {
            func mean(_ key: String) -> Double { samples.map { $0[key] ?? 0 }.reduce(0, +) / Double(max(1, samples.count)) }
            func worst(_ key: String) -> Double { samples.map { $0[key] ?? 0 }.max() ?? 0 }
            steps.append([
                "step": name,
                "samples": samples.count,
                "meanHitchMsPerSecond": mean("hitchMsPerSecond"),
                "worstHitchMsPerSecond": worst("hitchMsPerSecond"),
                "meanMissedFrames": mean("missedFrames"),
                "worstGapMs": worst("worstGapMs"),
                "meanFrames": mean("frames"),
                "expectedFrames": mean("expectedFrames"),
                "meanMainCPUMs": mean("mainCPUMs"),
                "longestOutlineStillMs": worst("outlineStillMs"),
                "meanOutlineStillMs": mean("outlineStillMs"),
                "meanOutlineTravelDuringStallPt": mean("outlineTravelDuringStall"),
                "stalledSamples": Double(samples.filter { $0["outlineTravelDuringStall"] != nil }.count),
            ])
        }
        return ["scenario": scenario, "load": load, "periodMs": period * 1000, "steps": steps]
    }

    /// The outline's own stillness in a window: from the probe's samples, the
    /// longest stretch in which the presented width did not change while it was
    /// still more than 3 pt from where it ended up — and, when the main
    /// thread was blocked, how far it travelled during the block.
    private static func outline(in w: HitchWindow, widths: [OutlineProbe.Sample]) -> [String: Double] {
        let inside = widths.filter { $0.time >= w.start && $0.time <= w.end }
        guard let final = inside.last?.width, inside.count > 2 else { return [:] }
        var changes: [CFTimeInterval] = []
        var previous = inside[0].width
        for sample in inside.dropFirst() where abs(sample.width - previous) > 0.02 {
            changes.append(sample.time)
            previous = sample.width
        }
        var result: [String: Double] = [:]
        if let first = changes.first {
            // Until it is within 3 pt of its end: the tail of a spring moves
            // too slowly to tell standing still from arriving.
            let arrived = inside.last(where: { abs($0.width - final) > 3 })?.time ?? first
            var still = 0.0
            for (a, b) in zip(changes, changes.dropFirst()) where a < arrived { still = max(still, b - a) }
            result["outlineStillMs"] = still * 1000
        }
        if let stall = w.stall {
            func width(at time: CFTimeInterval) -> Double {
                inside.min(by: { abs($0.time - time) < abs($1.time - time) })?.width ?? 0
            }
            result["outlineTravelDuringStall"] = abs(width(at: stall.upperBound) - width(at: stall.lowerBound))
        }
        return result
    }

    private static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads[0]
    }

    private static func table(label: String, results: [[String: Any]]) -> String {
        var lines = ["", "hitch lab \(label)", String(format: "%-18@ %-9@ %-26@ %8@ %6@ %7@ %9@ %8@ %10@",
                                                    "scenario" as NSString, "load" as NSString, "step" as NSString,
                                                    "hitch/s" as NSString, "missed" as NSString, "cpu ms" as NSString,
                                                    "still ms" as NSString, "stall pt" as NSString, "gap ms" as NSString)]
        for result in results {
            for step in (result["steps"] as? [[String: Any]]) ?? [] {
                lines.append(String(
                    format: "%-18@ %-9@ %-26@ %8.1f %6.1f %7.0f %9.1f %8.1f %10.1f",
                    (result["scenario"] as? String ?? "") as NSString, (result["load"] as? String ?? "") as NSString,
                    (step["step"] as? String ?? "") as NSString,
                    step["meanHitchMsPerSecond"] as? Double ?? 0, step["meanMissedFrames"] as? Double ?? 0,
                    step["meanMainCPUMs"] as? Double ?? 0, step["longestOutlineStillMs"] as? Double ?? 0,
                    step["meanOutlineTravelDuringStallPt"] as? Double ?? 0, step["worstGapMs"] as? Double ?? 0
                ))
            }
        }
        return lines.joined(separator: "\n")
    }
}
