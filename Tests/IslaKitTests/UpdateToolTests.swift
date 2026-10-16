import Foundation
import XCTest
@testable import IslaKit

/// The process runner under every system tool the installer calls. The failure
/// it exists for is a tool that does not come back: it hangs, it ignores a polite
/// request to stop, or it leaves a child holding its pipe.
final class UpdateToolTests: XCTestCase {
    private func timed<T>(_ body: () async -> T) async -> (T, TimeInterval) {
        let start = Date()
        let value = await body()
        return (value, Date().timeIntervalSince(start))
    }

    func testOutputAndStatusComeBack() async throws {
        let run = await UpdateTool.run("/bin/sh", ["-c", "echo hello; exit 3"])
        let result = try XCTUnwrap(run)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "hello\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testOutputLargerThanAPipeBufferIsComplete() async throws {
        let run = await UpdateTool.run("/bin/sh", ["-c", "yes isla | head -c 500000"])
        let result = try XCTUnwrap(run)
        XCTAssertEqual(result.output.count, 500_000)
        XCTAssertTrue(result.succeeded)
    }

    func testAMissingToolIsNil() async {
        let result = await UpdateTool.run("/nonexistent/tool", [])
        XCTAssertNil(result)
    }

    func testAProcessThatNeverExitsIsEndedAtTheTimeout() async throws {
        let (result, seconds) = await timed {
            await UpdateTool.run("/bin/sleep", ["60"], timeout: 0.3, killGrace: 0.3)
        }
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertLessThan(seconds, 3, "SIGTERM at the timeout ended it")
    }

    func testAProcessThatIgnoresSIGTERMIsKilled() async throws {
        let script = #"trap '' TERM; while :; do sleep 1; done"#
        let (result, seconds) = await timed {
            await UpdateTool.run("/bin/sh", ["-c", script], timeout: 0.3, killGrace: 0.3, drainGrace: 0.3)
        }
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertLessThan(seconds, 5, "SIGKILL ended it after the grace")
    }

    /// The old reader waited for the pipe to close, which a child that outlives
    /// its parent never does.
    func testAChildHoldingThePipeDoesNotHoldUpTheRun() async throws {
        let (result, seconds) = await timed {
            await UpdateTool.run("/bin/sh", ["-c", "sleep 20 & echo done"], timeout: 30, drainGrace: 0.3)
        }
        XCTAssertEqual(String(decoding: result?.output ?? Data(), as: UTF8.self), "done\n")
        XCTAssertEqual(result?.succeeded, true)
        XCTAssertLessThan(seconds, 3)
    }

    func testCancellingTheTaskEndsTheProcess() async throws {
        let task = Task { await UpdateTool.run("/bin/sleep", ["60"], timeout: 60, killGrace: 0.3) }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        let result = await task.value
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testATaskCancelledBeforeItStartsRunsNothing() async {
        let task = Task { () -> UpdateTool.Result? in
            try? await Task.sleep(for: .milliseconds(50))
            return await UpdateTool.run("/bin/sleep", ["60"], timeout: 60)
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result?.succeeded ?? false, false)
    }

    func testUncancellableCleanupRunsInACancelledTask() async throws {
        let task = Task { () -> Bool in
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(Task.isCancelled)
            return await UpdateTool.uncancellable {
                await UpdateTool.run("/usr/bin/true", [])?.succeeded ?? false
            }
        }
        task.cancel()
        let ran = await task.value
        XCTAssertTrue(ran, "a cancelled install still detaches")
    }

    /// A process no signal reaches: the run still returns, `timedOut`, a grace
    /// after SIGKILL was sent, instead of waiting for it for ever.
    func testAProcessThatIgnoresEverySignalDoesNotHoldTheRunForever() async throws {
        let deaf = UpdateTool.Signals(terminate: { _ in }, kill: { _ in })
        let (result, seconds) = await timed {
            await UpdateTool.run("/bin/sleep", ["4"], timeout: 0.2, killGrace: 0.2, drainGrace: 0.2, signals: deaf)
        }
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertLessThan(seconds, 2.5, "timeout + two graces, not the four seconds the process takes")
    }

    func testKillIsOnlySentAfterTheGraceAndTermFirst() async throws {
        let sent = SentSignals()
        let signals = UpdateTool.Signals(terminate: { _ in sent.note("term") }, kill: { _ in sent.note("kill") })
        _ = await UpdateTool.run("/bin/sleep", ["2"], timeout: 0.1, killGrace: 0.2, drainGrace: 0.1, signals: signals)
        XCTAssertEqual(sent.all, ["term", "kill"])
    }

    /// A cancel that lands after the process has launched and before the job
    /// says so used to be lost: the run went on to its timeout.
    func testACancelWhileTheProcessIsStartingStillEndsIt() async throws {
        let task = Task { () -> (UpdateTool.Result?, TimeInterval) in
            let start = Date()
            let result = await UpdateTool.run(
                "/bin/sleep", ["60"], timeout: 60, killGrace: 0.3,
                afterLaunch: { withUnsafeCurrentTask { $0?.cancel() } }
            )
            return (result, Date().timeIntervalSince(start))
        }
        let (result, seconds) = await task.value
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertLessThan(seconds, 5, "ended by the cancel, not by the 60 s timeout")
    }

    /// The output stream ending while the process goes on is not the end of the
    /// run, and does not spin: the run ends with the process.
    func testAProcessThatClosesItsOutputEarlyStillEndsCleanly() async throws {
        let (result, seconds) = await timed {
            await UpdateTool.run("/bin/sh", ["-c", "echo early; exec 1>&-; sleep 0.5; exit 4"], timeout: 10)
        }
        XCTAssertEqual(String(decoding: result?.output ?? Data(), as: UTF8.self), "early\n")
        XCTAssertEqual(result?.status, 4)
        XCTAssertLessThan(seconds, 3)
    }
}

private final class SentSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func note(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}
