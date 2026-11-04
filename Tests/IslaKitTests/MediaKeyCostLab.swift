import AppKit
import XCTest
@testable import IslaKit

/// What the volume and brightness tap costs per event, on its own thread
/// (maturity program, efficiency, B15).
///
/// The tap is a filter at the head of the session's event stream over
/// `NX_SYSDEFINED`, so every such event waits for its callback before any
/// app sees it: each media key, and every event of that type that is not a
/// key at all, like the aux mouse-button events (subtype 7), which are
/// passed on untouched. The scorecard had no number for any of it, because
/// a real tap needs the Accessibility permission and would sit in front of
/// the owner's own keys. This drives the same path without one:
/// `MediaKeyTapContext.receive` — the `NSEvent` conversion, the decoder,
/// `MediaKeyRoute`, `MediaKeyGate`, a real `SystemLevelApplier` over an
/// in-memory output and `MediaKeyHUD`'s own hop to the main actor — on a
/// user-interactive thread, as the tap's is, with synthesised events.
///
/// What it does not see: the window server's hand-off to the tap and the
/// thread's wake-up, which only a real tap has. The volume writes run on the
/// applier's writer queue as they do in the app, after the answer, and are
/// not counted.
///
/// Run by hand with `ISLA_KEYS_OUT=<folder> swift test -c release
/// -Xswiftc -enable-testing --filter MediaKeyCostLab`; `./scripts/check`
/// skips it.
@MainActor
final class MediaKeyCostLab: XCTestCase {
    private static let rounds = ProcessInfo.processInfo.environment["ISLA_KEYS_ROUNDS"].flatMap(Int.init) ?? 20_000

    private struct Row: Encodable {
        let event: String
        let consumed: Bool
        let medianMicroseconds: Double
        let p99Microseconds: Double
        let threadCPUMicrosecondsPerEvent: Double
        let events: Int
    }

    /// `NX_SYSDEFINED` as the window server posts it.
    private static func event(subtype: Int16, data1: Int) -> CGEvent {
        let ns = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: subtype, data1: data1, data2: -1
        )
        return ns!.cgEvent!
    }

    private static func key(_ key: MediaKey, down: Bool, repeating: Bool = false) -> CGEvent {
        event(subtype: Int16(MediaKeyDecoder.auxControlSubtype),
              data1: key.rawValue << 16 | (down ? 0xA : 0xB) << 8 | (repeating ? 1 : 0))
    }

    func testCostPerEvent() throws {
        guard let out = ProcessInfo.processInfo.environment["ISLA_KEYS_OUT"], !out.isEmpty else {
            throw XCTSkip("ISLA_KEYS_OUT is unset; this lab is run by hand")
        }
        let output = SleepyVolumeOutput(level: 0.5, delay: 0)
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
        let shown = ReadingCount()
        let route = MediaKeyRoute(
            gate: gate, applier: applier,
            deliver: { reading in
                // `MediaKeyHUD`'s own hop, as it is in the app; the main
                // thread drains it while the test waits.
                guard mailbox.post(reading) else { return }
                DispatchQueue.main.async { if mailbox.take() != nil { shown.add() } }
            },
            settingWentOff: {}
        )
        let context = MediaKeyTapContext(handler: { press, modifiers in
            route.receive(press, modifiers: modifiers, now: ProcessInfo.processInfo.systemUptime)
        })
        let systemDefined = CGEventType(rawValue: MediaKeyDecoder.systemDefinedType)!

        // Each case is a cycle of events, timed one by one; a press and its
        // release go together so the gate's holds stay paired.
        let cases: [(String, [CGEvent])] = [
            ("volume press and release", [
                Self.key(.volumeUp, down: true), Self.key(.volumeUp, down: false),
                Self.key(.volumeDown, down: true), Self.key(.volumeDown, down: false),
            ]),
            ("volume held, repeats", [Self.key(.volumeUp, down: true, repeating: true),
                                      Self.key(.volumeDown, down: true, repeating: true)]),
            ("brightness, no display to move", [Self.key(.brightnessUp, down: true),
                                                Self.key(.brightnessUp, down: false)]),
            // Play/Pause (16) is the system's: decoded as not ours.
            ("a media key that is not ours", [Self.event(subtype: Int16(MediaKeyDecoder.auxControlSubtype),
                                                         data1: 16 << 16 | 0xA << 8)]),
            // NX_SUBTYPE_AUX_MOUSE_BUTTONS: a button's state changing.
            ("aux mouse button, not a key", [Self.event(subtype: 7, data1: 1), Self.event(subtype: 7, data1: 0)]),
        ]

        var rows: [Row] = []
        for (name, cycle) in cases {
            if name == "volume held, repeats" {
                // A hold is decided by its key-down; repeats follow it.
                _ = context.receive(type: systemDefined, event: Self.key(.volumeUp, down: true))
            }
            var times: [UInt64] = []
            var consumed = false
            var cpu: UInt64 = 0
            let done = expectation(description: name)
            let rounds = Self.rounds
            let thread = Thread {
                times.reserveCapacity(rounds * cycle.count)
                var cpuSpent: UInt64 = 0
                for _ in 0..<rounds {
                    // A fresh event each time, as the window server sends:
                    // the same `CGEvent` converted twice is answered from a
                    // cache, and timed that way the conversion read 0.13 µs.
                    for event in cycle.map({ $0.copy()! }) {
                        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        let answer = context.receive(type: systemDefined, event: event)
                        times.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
                        cpuSpent += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart
                        if answer == nil { consumed = true }
                    }
                }
                cpu = cpuSpent
                done.fulfill()
            }
            thread.qualityOfService = .userInteractive
            thread.start()
            wait(for: [done], timeout: 120)
            if name == "volume held, repeats" {
                _ = context.receive(type: systemDefined, event: Self.key(.volumeUp, down: false))
            }
            times.sort()
            rows.append(Row(
                event: name, consumed: consumed,
                medianMicroseconds: Self.round(Double(times[times.count / 2]) / 1000),
                p99Microseconds: Self.round(Double(times[times.count * 99 / 100]) / 1000),
                threadCPUMicrosecondsPerEvent: Self.round(Double(cpu) / 1000 / Double(times.count)),
                events: times.count
            ))
        }
        applier.settle()
        // Proof the path ran to the end: levels reached the main actor.
        XCTAssertGreaterThan(shown.value, 0)

        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: folder.appendingPathComponent("media-keys.json"))
        var table = "event                             taken   median µs   p99 µs   cpu µs/event\n"
        for row in rows {
            table += row.event.padding(toLength: 33, withPad: " ", startingAt: 0)
                + (row.consumed ? " yes  " : " no   ")
                + String(format: " %9.2f %8.2f %12.2f\n", row.medianMicroseconds, row.p99Microseconds,
                         row.threadCPUMicrosecondsPerEvent)
        }
        print(table)
        try table.write(to: folder.appendingPathComponent("media-keys.txt"), atomically: true, encoding: .utf8)
    }

    private static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

/// How many readings reached the main actor.
private final class ReadingCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
