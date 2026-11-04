import AppKit
import QuartzCore
import SwiftUI
import XCTest
import os
@testable import IslaKit

// MARK: - The hitch lab
//
// How the island's own morphs behave on a real screen, with the Mac idle and
// with its cores taken, and what a stalled main thread costs them (redesign
// spec §19.12, "the island lags while I work").
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
// - The main thread's CPU time over the morph, and per frame: the costliest
//   frame, the frames that took more than three quarters of their slot, and
//   how much CPU time went past the slot. A wall-clock gap is stretched by
//   every other process on the Mac; the CPU a frame cost is not, so these are
//   what two builds are compared on.
// A scenario blocks the main thread for 50 ms, 120 ms into a morph, to count
// what a stall costs the frames the main thread owes. What it cannot say is
// what the *outline* does meanwhile: that is Core Animation's, in the render
// server, and nothing in this process can read it. `presentation()` read from
// a thread of its own returns the value it had when first read and never moves
// (measured: a path animated from 200 to 600 pt read 200 pt throughout), and
// walking the layer tree off the main thread crashed the lab; the only honest
// probe is a captured frame, which needs a Screen Recording grant this lab does
// not ask for. R8d-H1 in checklist.md is that check, by eye, on hardware.
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
    /// The main thread's CPU time when the step began.
    var cpuBefore: TimeInterval = 0
    /// The moments the step answered an input, by name ("input" is the
    /// step's own start; a pull adds the frame it first stretched on and its
    /// release), for the latency from each to the first frame drawn after it.
    var marks: [String: CFTimeInterval] = [:]
    /// The outline's applies inside the window, and the scroll events a pull
    /// fed it: more applies than display frames is work no frame shows.
    var outlineApplies: Int = 0
    var scrollEvents: Int = 0
}

@MainActor
private final class FrameRecorder: NSObject {
    /// `cpu` is the main thread's CPU time so far, read as the callback runs:
    /// the difference between two callbacks is the work the main thread did
    /// for that frame, which the other processes on the Mac cannot inflate the
    /// way they stretch a gap.
    struct Tick { var timestamp: CFTimeInterval; var target: CFTimeInterval; var ranAt: CFTimeInterval; var cpu: TimeInterval }
    private(set) var ticks: [Tick] = []
    private var link: CADisplayLink?
    private let clock = MainThreadClock()

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
        ticks.append(Tick(
            timestamp: link.timestamp, target: link.targetTimestamp, ranAt: CACurrentMediaTime(), cpu: clock.cpu()
        ))
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

// MARK: - A held volume key, end to end (2026-10-25)
//
// The owner: "only the volume pop-up lags and delays … if ours lags while
// replacing the Mac's own HUD the app is meaningless". The `hud-repeat` case
// above sets the view model's level straight from a timer, so it measures the
// drawing and nothing else; what lagged was everything in front of it — the
// write each press waited for. This case drives the real key path instead: a
// synthetic key repeat on a thread of its own (the tap's), through
// `MediaKeyRoute`, `MediaKeyGate` and the real `SystemLevelApplier`, over a
// fake output whose every write sleeps (20 ms, a quiet Mac; 50 ms, CoreAudio
// while music plays on a busy one), then the same mailbox and main hop
// `MediaKeyHUD` uses, onto the island's pop-up. No real volume is ever read or
// written.
//
// Recorded per hold: press→frame latency (the first frame whose bar shows that
// press or a later one), p50 and p95 over every press; how many frames still
// changed the bar after the key was let go, and how long after it the last one
// came; and how many writes the fake took.

/// An output that takes `delay` seconds per write and holds the level in
/// memory. Never a device.
final class SleepyVolumeOutput: VolumeOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float
    private var muted = false
    private let delay: TimeInterval
    private(set) var writes = 0

    init(level: Float, delay: TimeInterval) {
        self.level = level
        self.delay = delay
    }

    func read() -> VolumeState? {
        lock.withLock { VolumeState(device: 42, level: level, muted: muted) }
    }

    func write(level: Float, muted: Bool, from old: VolumeState) -> VolumeWriteResult {
        Thread.sleep(forTimeInterval: delay)
        lock.withLock {
            self.level = level
            self.muted = muted
            writes += 1
        }
        return .written
    }

    var writeCount: Int { lock.withLock { writes } }
}

/// What one held key left behind: when each press was made, and when and
/// which press each reading that reached the main thread belonged to.
final class HUDHoldProbe: @unchecked Sendable {
    struct Run {
        var name: String
        var pressTimes: [CFTimeInterval] = []
        /// (when it reached the main thread, the press it shows)
        var arrivals: [(time: CFTimeInterval, press: Int)] = []
        var writes = 0
    }

    private let lock = NSLock()
    private var current: Run?
    private var cursor = -1
    private var expected: [Float] = []
    private(set) var runs: [Run] = []

    func begin(_ name: String, expected: [Float]) {
        lock.withLock {
            current = Run(name: name)
            self.expected = expected
            cursor = -1
        }
    }

    func pressed(at time: CFTimeInterval) {
        lock.withLock { current?.pressTimes.append(time) }
    }

    /// Readings arrive in press order (both architectures deliver in order and
    /// only ever skip ahead), so the press a level belongs to is the first one
    /// after the last matched whose expected level it is.
    func arrived(level: Float, at time: CFTimeInterval) {
        lock.withLock {
            let next = expected.indices.first { $0 > cursor && expected[$0] == level } ?? cursor
            cursor = max(cursor, next)
            current?.arrivals.append((time, cursor))
        }
    }

    func reset() {
        lock.withLock {
            runs = []
            current = nil
        }
    }

    func end(writes: Int) {
        lock.withLock {
            guard var run = current else { return }
            run.writes = writes
            runs.append(run)
            current = nil
        }
    }
}

/// The real island on a real screen: the panel the controller cuts, the root
/// view, the hosting view, built the way `NotchController.build` builds them.
@MainActor
final class HitchRig {
    let panel: NotchPanel
    let vm: NotchViewModel
    let root: NotchRootView
    let hosting: NSHostingView<NotchContentView>
    let outline: IslandOutlineHost
    /// How many times the outline was asked for a state, for the pull's
    /// one-update-per-frame check.
    fileprivate(set) var outlineApplies = 0
    /// The current step's marks and scroll events (`HitchWindow.marks`).
    fileprivate var marks: [String: CFTimeInterval] = [:]
    fileprivate var scrollEvents = 0
    private var pullTimer: DispatchSourceTimer?
    /// The main thread's deliberate blocks, in order, taken by the case.
    fileprivate var stalls: [ClosedRange<CFTimeInterval>] = []
    /// The `hud-hold` case's records.
    let hudProbe = HUDHoldProbe()
    /// Keeps the hold's route and applier alive while its presses run.
    private var hudHoldParts: [AnyObject] = []

    init(session: LabSession) async throws {
        guard let geometry = NotchGeometry.current() else { throw XCTSkip("no display") }
        // On a real screen, the app's own marquee and word sweep (the visual
        // lab draws their stills instead).
        MarqueeTiming.travelsOnCoreAnimation = true
        KaraokeTrack.drawsLayers = true
        let stores = session.makeStores()
        await LabFixtures.play(.init(), on: stores.media)
        vm = NotchViewModel(geometry: geometry, stores: stores, defaults: session.suite)

        panel = NotchPanel(contentRect: geometry.windowFrame)
        let stage = NotchStage.make(viewModel: vm, windowSize: geometry.windowSize)
        root = stage.root
        hosting = stage.hosting
        outline = stage.outline
        root.wantsLayer = true
        panel.contentView = root

        // Composited and ticked, not seen and not clicked.
        panel.alphaValue = 0.02
        panel.ignoresMouseEvents = true
        root.activeRect = CGRect(origin: .zero, size: geometry.windowSize)
        panel.orderFrontRegardless()
        outline.onApply = { [unowned self] _, _ in
            self.outlineApplies += 1
            // The same for the release of a pull: the open or the close it
            // commits, as the outline takes it.
            if marks["release"] != nil, marks["releaseApplied"] == nil {
                marks["releaseApplied"] = CACurrentMediaTime()
                DispatchQueue.main.async { [unowned self] in
                    if self.marks["releaseCommitted"] == nil { self.marks["releaseCommitted"] = CACurrentMediaTime() }
                }
            }
            // The first change of the outline after the input: when SwiftUI
            // reached the bridge, and when the commit carrying it was over
            // (the next pass of the main queue runs after it), which is when
            // the render server has the outline's motion.
            guard marks["input"] != nil, marks["outlineApplied"] == nil else { return }
            marks["outlineApplied"] = CACurrentMediaTime()
            DispatchQueue.main.async { [unowned self] in
                if self.marks["outlineCommitted"] == nil { self.marks["outlineCommitted"] = CACurrentMediaTime() }
            }
        }
    }

    /// The controller's open, as `NotchController.openFromIsland` does it:
    /// the surface and the pin first, then the shell on the island's spring.
    func openFromIsland(_ surface: NotchViewModel.Surface?, reduceMotion: Bool) {
        vm.clickOpened(opening: surface) { _ in true }
        withAnimation(Theme.open(reduceMotion: reduceMotion)) { vm.isOpen = true }
    }

    func close(reduceMotion: Bool) {
        withAnimation(Theme.close(reduceMotion: reduceMotion)) { vm.isOpen = false }
    }

    /// Two fingers down over the shut island (or up on the open header): a
    /// trackpad's precise scroll, `events` of them `interval` apart — 240 a
    /// second, two per frame on a ProMotion display, which is what a fast
    /// trackpad sends — then the lift. Fed through `NotchViewModel.pullScroll`
    /// as the controller's monitor feeds it, and played out the controller's
    /// way when the pull commits.
    func pull(down: Bool, region: IslandPull.Region, reduceMotion: Bool,
              events: Int = 30, interval: TimeInterval = 1.0 / 240, step: CGFloat = 1.6) {
        pullTimer?.cancel()
        var sent = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(200))
        timer.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                let phase: ScrollSample.Phase = sent == 0 ? .began : (sent == events ? .ended : .changed)
                let delta: CGFloat = sent == events ? 0 : (down ? step : -step)
                let event = PageScroll(
                    deltaX: 0, deltaY: delta, phase: phase, precise: true,
                    time: ProcessInfo.processInfo.systemUptime, invertedFromDevice: true
                )
                scrollEvents += 1
                let outcome = vm.pullScroll(event, region: region)
                let now = CACurrentMediaTime()
                switch outcome {
                case .stretch: if marks["stretch"] == nil { marks["stretch"] = now }
                case .open(let surface):
                    marks["release"] = now
                    openFromIsland(surface, reduceMotion: reduceMotion)
                case .close:
                    marks["release"] = now
                    close(reduceMotion: reduceMotion)
                default: break
                }
                sent += 1
                if sent > events { pullTimer?.cancel(); pullTimer = nil }
            }
        }
        pullTimer = timer
        timer.resume()
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

    static let hudHoldInterval: TimeInterval = 0.030
    static let hudHoldSeconds: TimeInterval = 3.0
    /// ⌥⇧ quarter steps from silence: sixty up, then forty down, so that no
    /// press lands on a clamped end and every level says which press it is.
    static let hudHoldUp = 60

    /// A held volume key through the real key path (see the note above
    /// `SleepyVolumeOutput`). Returns at once; the presses run on a thread of
    /// their own for `hudHoldSeconds`.
    func hudHold(name: String, writeDelay: TimeInterval) {
        let presses = Int(Self.hudHoldSeconds / Self.hudHoldInterval)
        let expected = (0..<presses).map { i -> Float in
            i < Self.hudHoldUp ? Float(i + 1) / 64 : Float(2 * Self.hudHoldUp - 1 - i) / 64
        }
        let output = SleepyVolumeOutput(level: 0, delay: writeDelay)
        let applier = SystemLevelApplier(
            volume: output,
            displays: FakeDisplayResolver(client: nil),
            topology: { DisplayTopology(builtIn: nil, active: [], main: 0) },
            keyboards: FakeKeyboardResolver(client: nil),
            watch: InertLevelWatch(),
            describe: { _ in DeviceLabel(symbol: "speaker.wave.2.fill", name: "MacBook Pro Speakers") }
        )
        applier.prepare()
        let gate = MediaKeyGate()
        gate.mirror(enabled: true, locked: false)
        let mailbox = LatestReadingMailbox()
        let probe = hudProbe
        let vm = vm
        let reduceMotion = SystemAppearance.shared.reduceMotion
        let route = MediaKeyRoute(
            gate: gate, applier: applier,
            deliver: { reading in
                // `MediaKeyHUD`'s own hop, as it is in the app.
                guard mailbox.post(reading) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let latest = mailbox.take() else { return }
                        probe.arrived(level: latest.level, at: CACurrentMediaTime())
                        let moment = HUDMoment(latest)
                        if vm.hud == nil {
                            withAnimation(Theme.hud(reduceMotion: reduceMotion)) { vm.hud = moment }
                        } else {
                            vm.hud = moment
                        }
                    }
                }
            },
            settingWentOff: {}
        )
        hudHoldParts = [applier, route, output]
        probe.begin(name, expected: expected)
        let thread = Thread {
            let start = CACurrentMediaTime()
            let fine = MediaKeyModifiers(fine: true)
            for i in 0..<presses {
                let deadline = start + Double(i) * Self.hudHoldInterval
                let wait = deadline - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let key: MediaKey = i < Self.hudHoldUp ? .volumeUp : .volumeDown
                if i == Self.hudHoldUp {
                    _ = route.receive(MediaKeyPress(key: .volumeUp, isDown: false, isRepeat: false),
                                      modifiers: fine, now: ProcessInfo.processInfo.systemUptime)
                }
                let isRepeat = i != 0 && i != Self.hudHoldUp
                probe.pressed(at: CACurrentMediaTime())
                _ = route.receive(MediaKeyPress(key: key, isDown: true, isRepeat: isRepeat),
                                  modifiers: fine, now: ProcessInfo.processInfo.systemUptime)
            }
            _ = route.receive(MediaKeyPress(key: .volumeDown, isDown: false, isRepeat: false),
                              modifiers: fine, now: ProcessInfo.processInfo.systemUptime)
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The hold that ran last is over: its writes are counted.
    func endHUDHold() {
        if let output = hudHoldParts.last as? SleepyVolumeOutput { hudProbe.end(writes: output.writeCount) }
        hudHoldParts = []
    }

    func tearDown() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

@MainActor
final class OutlineHitchLab: VisualLabCase {
    static let envKey = "ISLA_HITCH_OUT"
    // Points of Interest, so a Time Profiler trace of the lab (`xctrace record
    // --template "Time Profiler"`) carries each morph's interval beside the
    // samples, and the first frames of a morph can be cut out of it.
    private let signposter = OSSignposter(subsystem: "com.ctimothe.isla.hitchlab", category: .pointsOfInterest)

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

    /// A key held down: fifty-four presses about 35 ms apart (two seconds), each a
    /// sixteenth step up the bar and round again.
    static let heldKeyPresses = 54
    static let heldKeyInterval: TimeInterval = 1.0 / 30
    static func heldKey(press: Int) -> HUDMoment {
        HUDMoment(HUDReading(kind: .volume, level: Float(press % 17) / 16, muted: false, deviceSymbol: nil))
    }

    struct Scenario {
        var name: String
        /// Puts the island where the scenario starts, and returns when it has settled.
        var prepare: @MainActor (HitchRig) async -> Void
        /// The morphs of one cycle, in order; each is watched for a window.
        var steps: [(name: String, run: @MainActor (HitchRig) -> Void)]
        /// How long each step is watched, where the morph is not one second
        /// long: a held key is two.
        var window: TimeInterval?
        /// A step's own window, where it differs from the scenario's.
        var stepWindows: [String: TimeInterval] = [:]
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
        // A held volume key against the shut island's pop-up: the arrival once,
        // inside `Theme.hud`, then a new level every 33 ms for two seconds (the
        // fastest key repeat macOS offers), then the fold. Through the view
        // model's `hud`, which is what the controller sets per press: whatever
        // the build does with a level that changes (re-draw the island, or only
        // the bar) is what this measures.
        // The same hold with the panel open: the capsule under it
        // (`NotchViewModel.hudStrip`) instead of the pill.
        func hold(strip: Bool) -> @MainActor (HitchRig) -> Void {
            { rig in
                @MainActor func set(_ moment: HUDMoment?) {
                    if strip { rig.vm.hudStrip = moment } else { rig.vm.hud = moment }
                }
                withAnimation(Theme.hud(reduceMotion: reduceMotion)) { set(Self.heldKey(press: 1)) }
                Task { @MainActor in
                    for press in 2...Self.heldKeyPresses {
                        try? await Task.sleep(for: .seconds(Self.heldKeyInterval))
                        set(Self.heldKey(press: press))
                    }
                }
            }
        }
        func fold(strip: Bool) -> @MainActor (HitchRig) -> Void {
            { rig in
                withAnimation(Theme.hud(reduceMotion: reduceMotion)) {
                    if strip { rig.vm.hudStrip = nil } else { rig.vm.hud = nil }
                }
            }
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
            // The controller's own open (surface, pin, then the shell), onto
            // each kind of body: the player, the Shelf's tray, the lyric stage
            // (MR-H18, 2026-10-26).
            Scenario(
                name: "click-player",
                prepare: { rig in rig.vm.isOpen = false; await LabFixtures.play(.init(), on: rig.vm.media) },
                steps: [("open", { $0.openFromIsland(.player, reduceMotion: reduceMotion) }),
                        ("close", { $0.close(reduceMotion: reduceMotion) })]
            ),
            Scenario(
                name: "click-tray",
                prepare: { rig in rig.vm.isOpen = false },
                steps: [("open", { $0.openFromIsland(.tray, reduceMotion: reduceMotion) }),
                        ("close", { $0.close(reduceMotion: reduceMotion) })]
            ),
            Scenario(
                name: "click-stage",
                prepare: { rig in
                    rig.vm.isOpen = false
                    await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                    rig.vm.lyrics.present(LabFixtures.timeline())
                },
                steps: [("open", { $0.openFromIsland(.stage, reduceMotion: reduceMotion) }),
                        ("close", { $0.close(reduceMotion: reduceMotion) })]
            ),
            // Two fingers: down over the shut island, up on the open header,
            // 240 events a second (see `HitchRig.pull`).
            Scenario(
                name: "pull-player",
                prepare: { rig in rig.vm.isOpen = false; await LabFixtures.play(.init(), on: rig.vm.media) },
                steps: [("pull-open", { $0.pull(down: true, region: .island, reduceMotion: reduceMotion) }),
                        ("pull-close", { $0.pull(down: false, region: .header, reduceMotion: reduceMotion) })],
                window: 1.2
            ),
            Scenario(
                name: "pull-tray",
                prepare: { rig in rig.vm.isOpen = false },
                steps: [("pull-open", { $0.pull(down: true, region: .bubble, reduceMotion: reduceMotion) }),
                        ("pull-close", { $0.pull(down: false, region: .header, reduceMotion: reduceMotion) })],
                window: 1.2
            ),
            Scenario(
                name: "pull-stage",
                prepare: { rig in
                    rig.vm.isOpen = false
                    await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                    rig.vm.lyrics.present(LabFixtures.timeline())
                },
                steps: [("click-open", { $0.openFromIsland(.stage, reduceMotion: reduceMotion) }),
                        ("pull-close", { $0.pull(down: false, region: .header, reduceMotion: reduceMotion) })],
                window: 1.2
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
            // The pages turned by their dots (§19.16, B13): one page at a
            // time along the strip, then the long jump back, three pages at
            // once. `travel` is what a dot's click calls; the travel draws on
            // the display's own clock and settles on the island's spring.
            Scenario(
                name: "page-turn",
                prepare: { rig in
                    await LabFixtures.play(.init(elapsed: 27), on: rig.vm.media)
                    rig.vm.lyrics.present(LabFixtures.timeline())
                    rig.vm.isOpen = true
                    rig.vm.open(.player)
                },
                steps: [
                    ("music-to-shelf", { $0.vm.travel(to: .tray, reduceMotion: reduceMotion) }),
                    ("shelf-to-clipboard", { $0.vm.travel(to: .clipboard, reduceMotion: reduceMotion) }),
                    ("clipboard-to-translate", { $0.vm.travel(to: .translate, reduceMotion: reduceMotion) }),
                    ("translate-to-music", { $0.vm.travel(to: .player, reduceMotion: reduceMotion) }),
                ]
            ),
            Scenario(
                name: "alert",
                prepare: { rig in rig.vm.isOpen = false; rig.vm.ambient = nil },
                steps: [("headphones-in", headphonesIn), ("headphones-out", headphonesOut)]
            ),
            // The main thread blocked for 50 ms, 120 ms into the morph: the
            // frames everything that waits on it loses.
            Scenario(
                name: "open-stall",
                prepare: { rig in rig.vm.isOpen = false },
                steps: [
                    ("open+50ms-block", { rig in open(rig); rig.block(after: 0.12, for: 0.05) }),
                    ("close", close),
                ]
            ),
            Scenario(
                name: "hud-repeat",
                prepare: { rig in rig.vm.isOpen = false; rig.vm.hud = nil },
                steps: [("hold-2s", hold(strip: false)), ("fold", fold(strip: false))],
                window: 2.0
            ),
            // The panel open, the key held: the capsule's arrival, its bar
            // following 54 presses, its fold. Absent from builds before the
            // capsule existed.
            Scenario(
                name: "hud-strip-repeat",
                prepare: { rig in rig.vm.isOpen = true; rig.vm.open(.player); rig.vm.hud = nil; rig.vm.hudStrip = nil },
                steps: [("hold-2s", hold(strip: true)), ("fold", fold(strip: true))],
                window: 2.0
            ),
            // The real key path under a held key, over an output whose writes
            // take 20 ms and then 50 ms (see `SleepyVolumeOutput`). Each hold
            // is watched for six seconds: a path that queues a write per press
            // is still drawing the 50 ms hold's backlog five seconds in, and
            // that tail is what is measured.
            Scenario(
                name: "hud-hold",
                prepare: { rig in rig.vm.isOpen = false; rig.vm.hud = nil },
                steps: [
                    ("hold-3s-write-20ms", { rig in rig.hudHold(name: "hold-3s-write-20ms", writeDelay: 0.020) }),
                    ("fold-20ms", { rig in rig.endHUDHold(); fold(strip: false)(rig) }),
                    ("hold-3s-write-50ms", { rig in rig.hudHold(name: "hold-3s-write-50ms", writeDelay: 0.050) }),
                    ("fold-50ms", { rig in rig.endHUDHold(); fold(strip: false)(rig) }),
                ],
                window: 1.0,
                stepWindows: ["hold-3s-write-20ms": 6.0, "hold-3s-write-50ms": 6.0]
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
                defer { stress.stop() }
                // idle: nothing added. stressed: one `yes` per core, the brief's
                // recipe. saturated: three per core, so the main thread is one of
                // forty-odd runnable threads, which is a Mac mid-build.
                switch load {
                case "stressed": stress.start(count: cores); try await settle(0.6)
                case "saturated": stress.start(count: cores * 3); try await settle(0.6)
                default: break
                }

                let frames = FrameRecorder()
                frames.start(on: rig.hosting)
                let clock = MainThreadClock()
                var windows: [HitchWindow] = []
                // Two cycles are warm-up: first-use costs (fonts, glyph caches,
                // layer trees) are not what an owner's tenth open feels like.
                for cycle in 0..<(cycles + 2) {
                    for step in scenario.steps {
                        let began = CACurrentMediaTime()
                        let cpuBefore = clock.cpu()
                        let stallsBefore = rig.stalls.count
                        let appliesBefore = rig.outlineApplies
                        rig.marks = ["input": began]
                        rig.scrollEvents = 0
                        let id = signposter.makeSignpostID()
                        let state = signposter.beginInterval("morph", id: id, "\(scenario.name)/\(step.name) \(load)")
                        step.run(rig)
                        try await settle(scenario.stepWindows[step.name] ?? scenario.window ?? window)
                        signposter.endInterval("morph", state)
                        if cycle >= 2 {
                            windows.append(HitchWindow(
                                name: step.name, start: began, end: CACurrentMediaTime(),
                                cpu: clock.cpu() - cpuBefore,
                                stall: rig.stalls.count > stallsBefore ? rig.stalls.last : nil,
                                cpuBefore: cpuBefore, marks: rig.marks,
                                outlineApplies: rig.outlineApplies - appliesBefore, scrollEvents: rig.scrollEvents
                            ))
                        }
                        try await settle(hold)
                    }
                }
                frames.stop()
                stress.stop()

                var summary = summarise(
                    scenario: scenario.name, load: load, windows: windows,
                    ticks: frames.ticks
                )
                if scenario.name == "hud-hold" {
                    summary["holds"] = Self.holdSummary(runs: rig.hudProbe.runs, ticks: frames.ticks)
                    rig.hudProbe.reset()
                }
                report.append(summary)
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
        ticks: [FrameRecorder.Tick]
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
            // Over every pair of ticks that ends inside the window, like the
            // CPU below: the change is committed in the turn before the first
            // tick inside the window, and the gap into that tick holds the
            // morph's costliest frame. Pairs taken only among the ticks
            // inside it left that frame out of the missed frames of the
            // build that has it first and counted it for a build that has
            // it later (found in review, 2026-10-18).
            for (a, b) in zip(ticks, ticks.dropFirst()) where b.timestamp >= w.start && b.timestamp <= w.end {
                let gap = b.timestamp - a.timestamp
                let late = gap - period
                if late > period * 0.5 { hitch += late; missed += Int((late / period).rounded()) }
                worstGap = max(worstGap, gap)
            }
            // What each frame cost the main thread, and how much of that was
            // over the frame's slot: the hitch the morph would have on a Mac
            // with nothing else to do, which is what the code can be blamed for.
            var frameCPU: [Double] = []
            for (a, b) in zip(ticks, ticks.dropFirst()) where b.timestamp >= w.start && b.timestamp <= w.end {
                frameCPU.append(b.cpu - a.cpu)
            }
            let overrun = frameCPU.map { max(0, $0 - period) }.reduce(0, +)
            let heavy = frameCPU.filter { $0 > period * 0.75 }.count
            let span = w.end - w.start
            // Input to the frame that shows it: the first display-link
            // callback the main thread ran after the mark (it cannot run
            // until the turn that answered the input, and the commit with
            // it, is over), and that callback's target — when the frame is
            // on the glass.
            func latency(_ mark: String) -> Double? {
                guard let at = w.marks[mark], let tick = ticks.first(where: { $0.ranAt > at }) else { return nil }
                return (tick.target - at) * 1000
            }
            // The first 100 ms of the morph, where a hitch reads as a delay:
            // the main thread's CPU and the frames it missed.
            let early = w.start + 0.1
            let earlyCPU = (ticks.last(where: { $0.timestamp <= early && $0.timestamp >= w.start })?.cpu)
                .map { $0 - w.cpuBefore } ?? 0
            var earlyMissed = 0
            for (a, b) in zip(ticks, ticks.dropFirst()) where b.timestamp >= w.start && b.timestamp <= early {
                let late = (b.timestamp - a.timestamp) - period
                if late > period * 0.5 { earlyMissed += Int((late / period).rounded()) }
            }
            let lateness = inside.map { max(0, $0.ranAt - $0.timestamp) }
            var sample: [String: Double] = [
                "frames": Double(inside.count),
                "expectedFrames": span / period,
                "missedFrames": Double(missed),
                "hitchMsPerSecond": hitch / span * 1000,
                "worstGapMs": worstGap * 1000,
                "worstCallbackLatenessMs": (lateness.max() ?? 0) * 1000,
                "mainCPUMs": w.cpu * 1000,
                "worstFrameCPUMs": (frameCPU.max() ?? 0) * 1000,
                "heavyFrames": Double(heavy),
                "cpuOverrunMs": overrun * 1000,
                "first100CPUMs": earlyCPU * 1000,
                "first100MissedFrames": Double(earlyMissed),
                "outlineApplies": Double(w.outlineApplies),
                "scrollEvents": Double(w.scrollEvents),
            ]
            for mark in ["input", "stretch", "release"] {
                if let value = latency(mark) { sample["latencyMs." + mark] = value }
            }
            // From the input to the first frame the outline moves in: its
            // commit over, then the render server's next frame on the vsync
            // grid (the display link's own timestamps), on the glass one
            // period after that. Not the next display-link callback: that is
            // the main thread's, and a heavy commit right behind the outline's
            // holds the callback but not the render server, which already has
            // the motion.
            if let input = w.marks["input"], let committed = w.marks["outlineCommitted"],
               let base = ticks.last(where: { $0.timestamp <= committed }) {
                let next = base.timestamp + (((committed - base.timestamp) / period).rounded(.up)) * period
                sample["outlineLatencyMs"] = (next + period - input) * 1000
                sample["outlineCommitMs"] = (committed - input) * 1000
            }
            if let release = w.marks["release"], let committed = w.marks["releaseCommitted"],
               let base = ticks.last(where: { $0.timestamp <= committed }) {
                let next = base.timestamp + (((committed - base.timestamp) / period).rounded(.up)) * period
                sample["releaseOutlineLatencyMs"] = (next + period - release) * 1000
            }
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
                "worstFrameCPUMs": worst("worstFrameCPUMs"),
                "meanHeavyFrames": mean("heavyFrames"),
                "meanCPUOverrunMs": mean("cpuOverrunMs"),
                "meanFirst100CPUMs": mean("first100CPUMs"),
                "meanFirst100MissedFrames": mean("first100MissedFrames"),
                "meanOutlineApplies": mean("outlineApplies"),
                "meanScrollEvents": mean("scrollEvents"),
                "meanInputLatencyMs": mean("latencyMs.input"),
                "worstInputLatencyMs": worst("latencyMs.input"),
                "meanStretchLatencyMs": mean("latencyMs.stretch"),
                "meanReleaseLatencyMs": mean("latencyMs.release"),
                "meanOutlineLatencyMs": mean("outlineLatencyMs"),
                "worstOutlineLatencyMs": worst("outlineLatencyMs"),
                "meanOutlineCommitMs": mean("outlineCommitMs"),
                "meanReleaseOutlineLatencyMs": mean("releaseOutlineLatencyMs"),
            ])
        }
        return ["scenario": scenario, "load": load, "periodMs": period * 1000, "steps": steps]
    }

    /// Press→frame latency and the tail, per hold, over the measured cycles
    /// (the first two of each are warm-up, as everywhere in this lab).
    ///
    /// A reading that reaches the main thread at `t` is drawn in the frame of
    /// the first display-link callback that runs after it: that callback's
    /// target timestamp is when the bar is on the glass.
    private static func holdSummary(runs: [HUDHoldProbe.Run], ticks: [FrameRecorder.Tick]) -> [[String: Any]] {
        func frame(after time: CFTimeInterval) -> CFTimeInterval? {
            ticks.first { $0.ranAt >= time }?.target
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        var result: [[String: Any]] = []
        for name in Set(runs.map(\.name)).sorted() {
            let measured = runs.filter { $0.name == name }.dropFirst(2)
            var latencies: [Double] = []
            var tailFrames: [Double] = []
            var tailMs: [Double] = []
            var writes: [Double] = []
            for run in measured {
                let shown = run.arrivals.compactMap { arrival in frame(after: arrival.time).map { ($0, arrival.press) } }
                for (index, pressed) in run.pressTimes.enumerated() {
                    guard let first = shown.first(where: { $0.1 >= index }) else { continue }
                    latencies.append((first.0 - pressed) * 1000)
                }
                guard let last = run.pressTimes.last else { continue }
                let after = Set(run.arrivals.filter { $0.time > last }.compactMap { frame(after: $0.time) })
                tailFrames.append(Double(after.count))
                tailMs.append(((shown.map(\.0).max() ?? last) - last) * 1000)
                writes.append(Double(run.writes))
            }
            func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }
            result.append([
                "hold": name,
                "samples": measured.count,
                "pressToFrameP50Ms": percentile(latencies, 0.5),
                "pressToFrameP95Ms": percentile(latencies, 0.95),
                "pressToFrameMaxMs": latencies.max() ?? 0,
                "meanFramesChangedAfterRelease": mean(tailFrames),
                "meanLastChangeAfterReleaseMs": mean(tailMs),
                "meanWrites": mean(writes),
            ])
        }
        return result
    }

    private static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads[0]
    }

    private static func table(label: String, results: [[String: Any]]) -> String {
        var lines = ["", "hitch lab \(label)", String(format: "%-18@ %-9@ %-26@ %8@ %6@ %7@ %8@ %8@ %6@ %8@",
                                                    "scenario" as NSString, "load" as NSString, "step" as NSString,
                                                    "hitch/s" as NSString, "missed" as NSString, "cpu ms" as NSString,
                                                    "gap ms" as NSString, "worst f" as NSString, "heavy" as NSString,
                                                    "overrun" as NSString) + "  cpu100 miss100  lat ms (in/stretch/release)  applies/events"]
        for result in results {
            for step in (result["steps"] as? [[String: Any]]) ?? [] {
                lines.append(String(
                    format: "%-18@ %-9@ %-26@ %8.1f %6.1f %7.0f %8.1f %8.1f %6.1f %8.1f",
                    (result["scenario"] as? String ?? "") as NSString, (result["load"] as? String ?? "") as NSString,
                    (step["step"] as? String ?? "") as NSString,
                    step["meanHitchMsPerSecond"] as? Double ?? 0, step["meanMissedFrames"] as? Double ?? 0,
                    step["meanMainCPUMs"] as? Double ?? 0, step["worstGapMs"] as? Double ?? 0,
                    step["worstFrameCPUMs"] as? Double ?? 0, step["meanHeavyFrames"] as? Double ?? 0,
                    step["meanCPUOverrunMs"] as? Double ?? 0
                ) + String(
                    format: "  %6.1f %6.1f  %5.1f / %5.1f / %5.1f  %5.1f / %5.1f  outline %5.1f (worst %5.1f, commit %5.1f)",
                    step["meanFirst100CPUMs"] as? Double ?? 0, step["meanFirst100MissedFrames"] as? Double ?? 0,
                    step["meanInputLatencyMs"] as? Double ?? 0, step["meanStretchLatencyMs"] as? Double ?? 0,
                    step["meanReleaseLatencyMs"] as? Double ?? 0,
                    step["meanOutlineApplies"] as? Double ?? 0, step["meanScrollEvents"] as? Double ?? 0,
                    step["meanOutlineLatencyMs"] as? Double ?? 0, step["worstOutlineLatencyMs"] as? Double ?? 0,
                    step["meanOutlineCommitMs"] as? Double ?? 0
                ))
            }
        }
        for result in results {
            for hold in (result["holds"] as? [[String: Any]]) ?? [] {
                lines.append(String(
                    format: "%-18@ %-9@ %-26@ press→frame p50 %6.1f ms  p95 %6.1f ms  max %6.1f ms  after release: %4.1f frames, last %6.1f ms  writes %5.1f",
                    "hud-hold" as NSString, (result["load"] as? String ?? "") as NSString,
                    (hold["hold"] as? String ?? "") as NSString,
                    hold["pressToFrameP50Ms"] as? Double ?? 0, hold["pressToFrameP95Ms"] as? Double ?? 0,
                    hold["pressToFrameMaxMs"] as? Double ?? 0,
                    hold["meanFramesChangedAfterRelease"] as? Double ?? 0,
                    hold["meanLastChangeAfterReleaseMs"] as? Double ?? 0,
                    hold["meanWrites"] as? Double ?? 0
                ))
            }
        }
        return lines.joined(separator: "\n")
    }
}
