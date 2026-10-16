import XCTest
@testable import IslaKit

/// Isla's own reset of its Accessibility entry (2026-10-17, owner). Nothing here
/// starts `tccutil`: the repair gets a recording runner, and the real runner is
/// only ever pointed at `/bin/sleep`, `/usr/bin/true` and the like.
@MainActor
final class AccessibilityRepairTests: XCTestCase {
    /// A runner that records what it was asked and answers as told.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(URL, [String], TimeInterval)] = []
        var outcome = ToolOutcome(exitStatus: 0, timedOut: false, output: "Successfully reset")
        var recorded: [(URL, [String], TimeInterval)] { lock.lock(); defer { lock.unlock() }; return calls }
        var runner: ToolRunner {
            { [self] url, args, timeout in record(url, args, timeout) }
        }
        private func record(_ url: URL, _ args: [String], _ timeout: TimeInterval) -> ToolOutcome {
            lock.lock(); defer { lock.unlock() }
            calls.append((url, args, timeout))
            return outcome
        }
    }

    private func finish(_ repair: SystemAccessibilityRepair) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            repair.reset { done.resume(returning: $0) }
        }
    }

    func testItRunsTccutilWithExactlyResetAccessibilityAndIslasBundleId() async {
        let recorder = Recorder()
        let repair = SystemAccessibilityRepair(bundleIdentifier: { "com.ctimothe.isla" }, run: recorder.runner)
        let worked = await finish(repair)
        XCTAssertTrue(worked)
        XCTAssertEqual(recorder.recorded.count, 1)
        XCTAssertEqual(recorder.recorded.first?.0.path, "/usr/bin/tccutil")
        XCTAssertEqual(recorder.recorded.first?.1, ["reset", "Accessibility", "com.ctimothe.isla"])
        XCTAssertEqual(recorder.recorded.first?.2, 5.0)
    }

    func testItRefusesAnyOtherBundleIdentifier() async {
        for identifier in [nil, "com.apple.dt.xctest.tool", "com.ctimothe.isla.helper", "COM.CTIMOTHE.ISLA", ""] as [String?] {
            let recorder = Recorder()
            let repair = SystemAccessibilityRepair(bundleIdentifier: { identifier }, run: recorder.runner)
            let worked = await finish(repair)
            XCTAssertFalse(worked, "\(String(describing: identifier))")
            XCTAssertTrue(recorder.recorded.isEmpty, "nothing was run for \(String(describing: identifier))")
        }
        XCTAssertNil(SystemAccessibilityRepair.arguments(forBundleIdentifier: "All"))
    }

    func testANonZeroExitOrATimeoutIsAFailure() async {
        let recorder = Recorder()
        let repair = SystemAccessibilityRepair(bundleIdentifier: { "com.ctimothe.isla" }, run: recorder.runner)
        recorder.outcome = ToolOutcome(exitStatus: 1, timedOut: false, output: "tccutil: Failed")
        let failed = await finish(repair)
        XCTAssertFalse(failed)
        recorder.outcome = ToolOutcome(exitStatus: nil, timedOut: true, output: "")
        let timedOut = await finish(repair)
        XCTAssertFalse(timedOut)
    }

    func testTheDefaultRepairUnderXCTestIsInert() async {
        XCTAssertTrue(InertAccessibilityRepair.live is InertAccessibilityRepair)
        // And even the production runner refuses the real tool under test.
        let outcome = await ToolRun.live(SystemAccessibilityRepair.tool, ["reset", "Accessibility", "com.ctimothe.isla"], 5)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.exitStatus)
    }

    // MARK: The runner itself, on harmless tools

    func testTheRunnerReturnsExitStatusAndBothStreams() async {
        let ok = await ToolRun.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err 1>&2; exit 0"], timeout: 5, killGrace: 1)
        XCTAssertTrue(ok.succeeded)
        XCTAssertTrue(ok.output.contains("out") && ok.output.contains("err"), ok.output)
        let bad = await ToolRun.run(URL(fileURLWithPath: "/usr/bin/false"), [], timeout: 5, killGrace: 1)
        XCTAssertEqual(bad.exitStatus, 1)
        XCTAssertFalse(bad.succeeded)
    }

    func testTheRunnerEndsAToolThatTakesTooLong() async {
        let started = Date()
        let outcome = await ToolRun.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.3, killGrace: 0.3)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTheRunnerKillsAToolThatIgnoresTheFirstRequest() async {
        let started = Date()
        let outcome = await ToolRun.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.3,
            killGrace: 0.3
        )
        XCTAssertTrue(outcome.timedOut)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAToolThatCannotStartIsAFailureNotACrash() async {
        let outcome = await ToolRun.run(URL(fileURLWithPath: "/nonexistent/tool"), [], timeout: 1, killGrace: 1)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.exitStatus)
    }

    func testTheLedgerKeepsItsBuildInItsOwnSuite() {
        let suite = "isla.test.ledger.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = DefaultsRepairLedger(defaults)
        XCTAssertNil(ledger.lastRepairedBuild)
        ledger.lastRepairedBuild = "42"
        XCTAssertEqual(DefaultsRepairLedger(defaults).lastRepairedBuild, "42")
        XCTAssertEqual(defaults.string(forKey: "lastAccessibilityRepairBuild"), "42")
    }
}
