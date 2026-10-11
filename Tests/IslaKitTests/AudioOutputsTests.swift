import XCTest
@testable import IslaKit

/// What CoreAudio says the output adds between a sample leaving the player
/// and reaching the ear, and the watch that re-reads it when the route moves.
@MainActor
final class AudioOutputsTests: XCTestCase {

    /// Device latency, safety offset, IO buffer and the first stream's
    /// latency, all in frames, over the nominal sample rate — the sum the
    /// lyric lab read for L7, now the one the app reads.
    func testOutputLatencyArithmetic() throws {
        let reading = AudioOutputs.OutputLatency(
            sampleRate: 48_000, deviceFrames: 100, safetyOffsetFrames: 50,
            bufferFrames: 512, streamFrames: 300
        )
        XCTAssertEqual(reading.frames, 962)
        XCTAssertEqual(try XCTUnwrap(reading.seconds), 962.0 / 48_000, accuracy: 1e-12)

        // A device that reports no rate has no latency to give, not an
        // infinite one.
        let silent = AudioOutputs.OutputLatency(
            sampleRate: 0, deviceFrames: 100, safetyOffsetFrames: 50,
            bufferFrames: 512, streamFrames: 300
        )
        XCTAssertNil(silent.seconds)
    }

    /// The listener belongs to the lyrics: installed once when the watch
    /// starts, removed once when it stops, never touched by an unstarted
    /// watch.
    func testTheMonitorListensOnlyWhileStarted() {
        var installs = 0, removals = 0
        let monitor = OutputLatencyMonitor(
            read: { 0.0273 },
            installListener: { installs += 1 },
            removeListener: { removals += 1 }
        )
        monitor.defaultOutputChanged()
        XCTAssertEqual(installs, 0)
        XCTAssertNil(monitor.latency, "an unstarted watch reads nothing")

        monitor.start()
        monitor.start()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(monitor.latency, 0.0273)

        monitor.stop()
        monitor.stop()
        XCTAssertEqual(removals, 1)
        XCTAssertFalse(monitor.isRunning)
    }

    /// A route change re-reads the latency and reports it only when it
    /// moved: CoreAudio sends a burst of notifications for one physical
    /// change, and each report re-arms the lyric wakes.
    func testARouteChangeIsReportedOnceWhenTheLatencyMoves() {
        var route: TimeInterval? = 0.0273
        var reports: [TimeInterval?] = []
        let monitor = OutputLatencyMonitor(read: { route }, installListener: {}, removeListener: {})
        monitor.onChange = { reports.append($0) }

        monitor.start()
        XCTAssertEqual(reports, [0.0273], "the first reading is a report")

        monitor.defaultOutputChanged()
        XCTAssertEqual(reports, [0.0273], "the same route again is not a change")

        route = 0.200
        monitor.defaultOutputChanged()
        monitor.defaultOutputChanged()
        XCTAssertEqual(reports, [0.0273, 0.200])

        route = nil
        monitor.defaultOutputChanged()
        XCTAssertEqual(reports, [0.0273, 0.200, nil], "a vanished device is reported as unknown")
    }
}
