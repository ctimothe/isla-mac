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

    func testTheDefaultRepairUnderXCTestIsInert() {
        XCTAssertTrue(InertAccessibilityRepair.live is InertAccessibilityRepair)
    }

    /// The refusal is a predicate, so no test ever hands the real runner the
    /// real tool to see it refuse.
    func testTheRunnerRefusesTccutilUnderTestInAnyDress() {
        for path in ["/usr/bin/tccutil", "/usr/local/bin/tccutil", "tccutil", "/tmp/../usr/bin/tccutil"] {
            XCTAssertTrue(ToolRun.refusesUnderTest(URL(fileURLWithPath: path), isTesting: true), path)
            XCTAssertFalse(ToolRun.refusesUnderTest(URL(fileURLWithPath: path), isTesting: false), "outside a test it runs: \(path)")
        }
        for path in ["/bin/sleep", "/usr/bin/true", "/bin/sh"] {
            XCTAssertFalse(ToolRun.refusesUnderTest(URL(fileURLWithPath: path), isTesting: true), path)
        }
        XCTAssertTrue(SystemAccessibilityRepair.tool.lastPathComponent == "tccutil")
        // This very process is a test, by both of the two ways of knowing.
        XCTAssertTrue(PlayerBridge.isRunningTests)
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        XCTAssertTrue(ToolRun.refusesUnderTest(SystemAccessibilityRepair.tool))
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

    func testAToolNoSignalReachesIsReportedTimedOutAndDoesNotHangTheRepair() async {
        // `terminate` and `kill` that do nothing: the stand-in for a process in
        // the kernel that SIGKILL cannot end. It exits by itself after three
        // seconds, long after the bound.
        let inert = ToolRun.Ending(terminate: { _ in }, kill: { _ in })
        let started = Date()
        let outcome = await ToolRun.run(
            URL(fileURLWithPath: "/bin/sleep"), ["3"], timeout: 0.2, killGrace: 0.2, slack: 0.3, ending: inert
        )
        XCTAssertTrue(outcome.timedOut)
        XCTAssertNil(outcome.exitStatus)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "bounded by timeout + grace + slack, not by the tool")
        XCTAssertEqual(ToolRun.wedgeSlack, 1.0)
    }

    func testTheCodeIdentityIsTheUniqueHashAsHexAndFallsBackToTheBundleVersion() {
        XCTAssertEqual(CodeIdentity.identity(unique: { Data([0x4d, 0x93, 0x0a]) }, bundleVersion: { "7" }), "4d930a")
        XCTAssertEqual(CodeIdentity.identity(unique: { nil }, bundleVersion: { "7" }), "7")
        XCTAssertEqual(CodeIdentity.identity(unique: { Data() }, bundleVersion: { "7" }), "7")
        XCTAssertEqual(CodeIdentity.identity(unique: { nil }, bundleVersion: { nil }), "dev")
        XCTAssertFalse(CodeIdentity.running.isEmpty)
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
