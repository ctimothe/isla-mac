import CoreAudio
import IOKit.ps
import XCTest
@testable import IslaKit

/// What the charger and headphones watch costs (maturity program,
/// efficiency, B15).
///
/// `AmbientWatch` polls nothing: it wakes only for IOKit's power
/// notification and CoreAudio's device-list listener, and pays for each with
/// a read — the battery (`readPower`, on the main thread), the port and the
/// reason a battery is holding (`ChargePortReading`, `ChargeHoldReading`,
/// off it) or the Bluetooth outputs (`readHeadphones`, on the main thread).
/// So its cost is those reads times how often the system calls. This times
/// each read against this Mac's own battery and outputs — reads only,
/// nothing is set — and, with `ISLA_AMBIENT_LISTEN` seconds, counts how
/// often the two sources fire while the Mac does whatever it is doing.
///
/// Run by hand with `ISLA_AMBIENT_OUT=<folder> swift test -c release
/// -Xswiftc -enable-testing --filter AmbientCostLab`; `./scripts/check`
/// skips it.
@MainActor
final class AmbientCostLab: XCTestCase {
    private struct Row: Encodable {
        let read: String
        let thread: String
        let medianMicroseconds: Double
        let p99Microseconds: Double
        let cpuMicrosecondsPerRead: Double
        let reads: Int
    }

    private static func time(_ name: String, thread: String, count: Int, _ read: () -> Void) -> Row {
        read()  // The first read loads the frameworks' caches, as the seed at launch does.
        var times: [UInt64] = []
        var cpu: UInt64 = 0
        for _ in 0..<count {
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            read()
            times.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
            cpu += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart
        }
        times.sort()
        func µs(_ ns: UInt64) -> Double { (Double(ns) / 10).rounded() / 100 }
        return Row(
            read: name, thread: thread, medianMicroseconds: µs(times[times.count / 2]),
            p99Microseconds: µs(times[times.count * 99 / 100]),
            cpuMicrosecondsPerRead: µs(cpu / UInt64(count)), reads: count
        )
    }

    func testCostOfEachRead() throws {
        guard let out = ProcessInfo.processInfo.environment["ISLA_AMBIENT_OUT"], !out.isEmpty else {
            throw XCTSkip("ISLA_AMBIENT_OUT is unset; this lab is run by hand")
        }
        let rows = [
            Self.time("battery (readPower)", thread: "main", count: 200) { _ = AmbientWatch.readPower() },
            Self.time("port and adapter (ChargePortReading)", thread: "off main", count: 100) {
                _ = ChargePortReading.read()
            },
            Self.time("holding reason (ChargeHoldReading)", thread: "off main", count: 100) {
                _ = ChargeHoldReading.read()
            },
            Self.time("outputs (readHeadphones)", thread: "main", count: 200) { _ = AmbientWatch.readHeadphones() },
        ]

        var fired = (power: 0, devices: 0)
        let listen = ProcessInfo.processInfo.environment["ISLA_AMBIENT_LISTEN"].flatMap(TimeInterval.init) ?? 0
        if listen > 0 {
            // The watch's own two sources, counting and nothing else.
            final class Counter { var power = 0 }
            let counter = Counter()
            let context = Unmanaged.passUnretained(counter).toOpaque()
            let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<Counter>.fromOpaque(context).takeUnretainedValue().power += 1
            }, context)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
            var devices = 0
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { _, _ in devices += 1 }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            let done = expectation(description: "listen")
            DispatchQueue.main.asyncAfter(deadline: .now() + listen) { done.fulfill() }
            wait(for: [done], timeout: listen + 30)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
            fired = (counter.power, devices)
        }

        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var table = "read                                   thread     median µs    p99 µs   cpu µs/read\n"
        for row in rows {
            table += row.read.padding(toLength: 38, withPad: " ", startingAt: 0)
                + " " + row.thread.padding(toLength: 9, withPad: " ", startingAt: 0)
                + String(format: " %10.1f %9.1f %12.1f\n", row.medianMicroseconds, row.p99Microseconds,
                         row.cpuMicrosecondsPerRead)
        }
        if listen > 0 {
            table += String(format: "over %.0f s: %d power notifications, %d device-list changes\n",
                            listen, fired.power, fired.devices)
        }
        print(table)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: folder.appendingPathComponent("ambient.json"))
        try table.write(to: folder.appendingPathComponent("ambient.txt"), atomically: true, encoding: .utf8)
    }
}
