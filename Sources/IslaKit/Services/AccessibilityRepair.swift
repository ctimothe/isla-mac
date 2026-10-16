import Foundation

/// What a finished external tool run said.
struct ToolOutcome: Equatable, Sendable {
    /// The exit status, or nil when the tool never started or was killed.
    var exitStatus: Int32?
    /// The run hit its time limit and was ended by us.
    var timedOut: Bool
    /// stdout and stderr together, as text.
    var output: String

    var succeeded: Bool { exitStatus == 0 && !timedOut }
}

/// Runs one executable with an arguments array (never a shell string), off
/// the main actor, and ends it when it takes too long. A seam: the tests hand
/// the repair a runner of their own that records its arguments, so no test
/// ever starts the real tool.
typealias ToolRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) async -> ToolOutcome

enum ToolRun {
    /// How long a run that was asked to end may ignore it before SIGKILL.
    static let killGrace: TimeInterval = 2.0

    /// The production runner. Under XCTest it refuses to start `tccutil`
    /// whatever it is asked: the suite runs on the owner's Mac, and the tool
    /// edits that Mac's real privacy database.
    static let live: ToolRunner = { executable, arguments, timeout in
        if PlayerBridge.isRunningTests, executable.path == SystemAccessibilityRepair.tool.path {
            return ToolOutcome(exitStatus: nil, timedOut: false, output: "refused under test")
        }
        return await run(executable, arguments, timeout: timeout, killGrace: killGrace)
    }

    /// Starts `executable`, waits for it on a background queue, asks it to end
    /// at `timeout` (SIGTERM) and kills it `killGrace` later if it is still
    /// there. Output is read as it arrives, so a chatty tool cannot fill the
    /// pipe and stall, and a grandchild holding the pipe open cannot hold this
    /// up past the process itself.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval,
        killGrace: TimeInterval
    ) async -> ToolOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout, killGrace: killGrace))
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private static func runBlocking(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval,
        killGrace: TimeInterval
    ) -> ToolOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collected = Collected()
        let endOfOutput = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                endOfOutput.signal()
            } else {
                collected.append(chunk)
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ToolOutcome(exitStatus: nil, timedOut: false, output: "could not start: \(error.localizedDescription)")
        }

        let timedOut = Flag()
        let stop = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            let kill = DispatchWorkItem {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace, execute: kill)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)

        finished.wait()
        stop.cancel()
        // The last bytes arrive on the handler's own queue; give them a moment,
        // but never wait on a pipe somebody else still holds open.
        _ = endOfOutput.wait(timeout: .now() + 0.5)
        pipe.fileHandleForReading.readabilityHandler = nil

        let timed = timedOut.isSet
        return ToolOutcome(
            exitStatus: timed || process.terminationReason == .uncaughtSignal ? nil : process.terminationStatus,
            timedOut: timed,
            output: collected.text
        )
    }
}

/// Clears Isla's own Accessibility decision so macOS asks again.
///
/// **Why this exists (2026-10-17, proven from tccd's log on the owner's Mac).**
/// TCC stores a grant against the app's designated requirement. An ad-hoc
/// signed build's requirement *is its cdhash*, so every release is a different
/// app to TCC, and the entry made for an older build stays in System Settings'
/// list, switched on, while tccd logs "Failed to match existing code
/// requirement for subject com.ctimothe.isla". macOS then neither applies it
/// nor asks again, and `AXIsProcessTrustedWithOptions(prompt: true)` shows
/// nothing for as long as the entry exists. Isla's own switch is not at fault.
/// Whatever the cause of such an entry — an ad-hoc release, a development
/// build, a changed certificate — removing it is what lets the prompt appear
/// and a grant apply to the running build.
@MainActor
protocol AccessibilityRepairing {
    /// Resets Isla's Accessibility decision, then calls `completion` on the
    /// main actor with whether it worked. Always calls it, exactly once.
    func reset(completion: @escaping @MainActor @Sendable (Bool) -> Void)
}

/// The real thing: `/usr/bin/tccutil reset Accessibility <Isla's bundle id>`.
///
/// `tccutil` is Apple's documented tool for this (man tccutil: "If a bundle
/// identifier is specified, the service will be reset for that bundle only").
/// It runs as the user, is not setuid, and carries Apple's own
/// `com.apple.private.tcc.manager.access.delete` entitlement, so no
/// administrator password is involved. There is no public API that resets a
/// TCC decision.
///
/// It only ever names Accessibility and Isla's own bundle identifier: never
/// `All`, never another service, never another app. When the running bundle is
/// not Isla (a test host, a renamed build) it does nothing and says it failed.
struct SystemAccessibilityRepair: AccessibilityRepairing {
    nonisolated static let tool = URL(fileURLWithPath: "/usr/bin/tccutil")
    static let timeout: TimeInterval = 5.0
    static let service = "Accessibility"

    /// The arguments to pass for the running bundle, or nil when it is not
    /// Isla's.
    static func arguments(forBundleIdentifier identifier: String?) -> [String]? {
        guard identifier == ProductIdentity.bundleIdentifier else { return nil }
        return ["reset", service, ProductIdentity.bundleIdentifier]
    }

    var bundleIdentifier: () -> String? = { Bundle.main.bundleIdentifier }
    var run: ToolRunner = ToolRun.live

    func reset(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let arguments = Self.arguments(forBundleIdentifier: bundleIdentifier()) else {
            Log.permissions.notice("accessibility reset skipped: the running bundle is not Isla")
            completion(false)
            return
        }
        let run = self.run
        Task { @MainActor in
            let outcome = await run(Self.tool, arguments, Self.timeout)
            let status = outcome.exitStatus.map(String.init) ?? "none"
            let said = String(outcome.output.prefix(300))
            if outcome.succeeded {
                Log.permissions.notice("accessibility reset ok: \(said, privacy: .public)")
            } else {
                Log.permissions.error(
                    "accessibility reset failed: status \(status, privacy: .public), timed out \(outcome.timedOut, privacy: .public): \(said, privacy: .public)"
                )
            }
            completion(outcome.succeeded)
        }
    }
}

/// What a HUD built with defaults gets: the real repair, except under XCTest,
/// where it is inert for the same reason `EventMediaKeyTap.live` becomes an
/// `InertMediaKeyTap` there. A test that forgets to inject a fake can then
/// never reset the owner's real Accessibility entry.
@MainActor
struct InertAccessibilityRepair: AccessibilityRepairing {
    func reset(completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(false) }

    static var live: AccessibilityRepairing {
        PlayerBridge.isRunningTests ? InertAccessibilityRepair() : SystemAccessibilityRepair()
    }
}

/// Remembers the last build Isla repaired for, so an update repairs once and a
/// person who declines is not asked at every launch. Internal state, not a
/// Settings row, so the key is not in `SettingsTable`.
@MainActor
protocol AccessibilityRepairLedger: AnyObject {
    var lastRepairedBuild: String? { get set }
}

final class DefaultsRepairLedger: AccessibilityRepairLedger {
    static let key = "lastAccessibilityRepairBuild"
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    var lastRepairedBuild: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// What a HUD built with defaults gets under XCTest: a ledger in memory, so a
/// test that forgets to inject one never writes the standard defaults domain.
final class MemoryRepairLedger: AccessibilityRepairLedger {
    var lastRepairedBuild: String?
    static var live: AccessibilityRepairLedger {
        PlayerBridge.isRunningTests ? MemoryRepairLedger() : DefaultsRepairLedger()
    }
}
