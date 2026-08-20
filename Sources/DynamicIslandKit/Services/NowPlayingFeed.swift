import AppKit

/// Runs the Now Playing helper inside `/usr/bin/perl` and turns its stdout into
/// snapshots. See `Sources/DynamicIslandMediaHelper/helper.m` for why perl is the host.
@MainActor
final class NowPlayingFeed {
    struct Snapshot {
        var isPlaying = false
        var title = ""
        var artist = ""
        var album = ""
        var duration: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var rate: Double = 0
        /// When `elapsed` was read. MediaRemote reports a reading, not a
        /// running clock — without this the reading cannot be aged.
        var takenAt: Date?
        /// Only present on the update where the track changed.
        var artwork: Data?
        /// Name of the app owning the session, resolved from its pid.
        var source: String?
        /// Process that owned the snapshot. Transport commands carry this
        /// identity so another media session cannot steal the click between
        /// display and dispatch.
        var playerPID: pid_t?
        /// Command codes the player offers right now, or nil when the helper
        /// could not ask. Nil means unknown, not none — a browser tab with a
        /// single video offers no skip commands at all, and that is worth
        /// showing, but a missing answer is not the same as an empty one.
        var commands: Set<Int>?

        func offers(_ command: Command) -> Bool {
            commands?.contains(command.rawValue) ?? true
        }

        var isEmpty: Bool { title.isEmpty }
    }

    /// Codes the per-client MediaRemote API actually answers to — read off a
    /// live session's `GetSupportedCommandsForPlayer`, not assumed from the
    /// old global enum. There is no separate toggle among them: play and
    /// pause are sent explicitly, by whichever state the caller already
    /// knows it is in.
    enum Command: Int {
        case play = 0, pause = 1, next = 4, previous = 5

        func wireLine(playerPID: pid_t?) -> String {
            guard let playerPID, playerPID > 0 else { return "cmd \(rawValue)" }
            return "cmd \(rawValue) \(playerPID)"
        }
    }

    var onUpdate: ((Snapshot) -> Void)?
    /// Raised when the helper cannot run at all, so the caller can fall back.
    var onUnavailable: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = NDJSONBuffer()
    private var failurePolicy = NowPlayingFailurePolicy()
    private var stopped = false

    private var helperPath: String? {
        Bundle.main.path(forResource: ProductIdentity.helperResourceName, ofType: "dylib")
    }

    // MARK: - Lifecycle

    func start() {
        stopped = false
        buffer = NDJSONBuffer()
        failurePolicy.recordSuccess()
        // A pid is recycled by the system, so a cached name has to die with
        // the process that earned it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appNames.removeValue(forKey: app.processIdentifier) }
        }
        launch()
    }

    func stop() {
        stopped = true
        output?.readabilityHandler = nil
        output = nil
        try? input?.close()
        input = nil
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped else { return }
        guard let helperPath, FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            onUnavailable?()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [
            "-e",
            "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0x01); while (1) { sleep 3600; }",
            helperPath,
        ]

        let output = Pipe()
        let commands = Pipe()
        task.standardOutput = output
        task.standardInput = commands
        task.standardError = FileHandle.nullDevice

        let outputHandle = output.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try task.run()
        } catch {
            NSLog("Dynamic Island: helper failed to launch: \(error.localizedDescription)")
            onUnavailable?()
            return
        }

        process = task
        input = commands.fileHandleForWriting
        self.output = outputHandle
    }

    private func handleTermination() {
        guard !stopped else { return }
        output?.readabilityHandler = nil
        output = nil
        process = nil
        input = nil
        switch failurePolicy.recordFailure() {
        case .fallback:
            onUnavailable?()
        case .restart(let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.launch()
            }
        }
    }

    // MARK: - Commands

    func refresh() { write("get") }
    func send(_ command: Command, playerPID: pid_t?) {
        write(command.wireLine(playerPID: playerPID))
    }
    /// Seeks the player currently shown in the panel — the same target
    /// identity `send(_:playerPID:)` carries, so a seek can never land on
    /// whichever session macOS considers active in the moment it arrives.
    func seek(to seconds: TimeInterval, playerPID: pid_t?) {
        write(Self.seekWireLine(seconds: seconds, playerPID: playerPID))
    }

    nonisolated static func seekWireLine(seconds: TimeInterval, playerPID: pid_t?) -> String {
        guard let playerPID, playerPID > 0 else { return "seek \(Int(seconds))" }
        return "seek \(Int(seconds)) \(playerPID)"
    }

    private func write(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        // The helper can die between our check and the write; a broken pipe
        // would raise SIGPIPE-flavoured NSException from FileHandle.
        do {
            try input.write(contentsOf: data)
        } catch {
            NSLog("Dynamic Island: helper write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private func consume(_ chunk: Data) {
        for line in buffer.append(chunk) {
            handle(line: line)
        }
    }

    /// pid → app name, because resolving one is a synchronous cross-process
    /// XPC round trip (`_LSCopyApplicationInformation`) on the main thread, and
    /// the poll asked for the same answer every two seconds forever. Measured
    /// at 70µs uncached against 0.4µs cached. Dropped when the app quits, so a
    /// recycled pid can never inherit the previous owner's name.
    private var appNames: [pid_t: String] = [:]

    private func handle(line: Data) {
        let event = NowPlayingPayloadDecoder.decode(line) { [weak self] pid in
            guard let self else { return NSRunningApplication(processIdentifier: pid)?.localizedName }
            if let cached = self.appNames[pid] { return cached }
            guard let name = NSRunningApplication(processIdentifier: pid)?.localizedName else { return nil }
            self.appNames[pid] = name
            return name
        }
        switch event {
        case .unavailable:
            // The helper just said it cannot work at all. Left alone, its perl
            // host would idle in the sleep loop for the rest of the app's life,
            // holding memory for a route that is closed (#8) — so the process
            // goes down with the route, and `stopped` keeps it down.
            stop()
            onUnavailable?()
        case .snapshot(let snapshot):
            failurePolicy.recordSuccess()
            onUpdate?(snapshot)
        case nil:
            return
        }
    }
}
