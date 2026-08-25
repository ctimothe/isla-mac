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
    private var terminationToken: NSObjectProtocol?
    /// Fires when the helper has gone quiet for too long.
    private var watchdog: Timer?
    private var lastLineAt = Date()
    /// Identifies the helper generation a chunk belongs to.
    ///
    /// The readability handler runs on a dispatch thread and hops to the main
    /// actor, so a chunk read from a dying helper can arrive after its
    /// replacement has started — and land in the fresh buffer, corrupting the
    /// new helper's first line. Each launch stamps its own epoch and chunks
    /// from any other are dropped.
    private var epoch = 0
    /// Commands written while the helper was down, replayed once it is back.
    /// Only the most recent one: transport is a statement about now, and
    /// replaying a queue of stale taps would fight the user.
    private var pendingCommand: String?

    /// The helper publishes at least every two seconds, idle or not, so silence
    /// for several times that means it is not going to speak again. Generous,
    /// because a machine under heavy load can stall a poll.
    private static let silenceTimeout: TimeInterval = 12

    private var helperPath: String? {
        Bundle.main.path(forResource: ProductIdentity.helperResourceName, ofType: "dylib")
    }

    // MARK: - Lifecycle

    func start() {
        stopped = false
        epoch += 1
        buffer = NDJSONBuffer()
        buffer.onOversizedRecord = { [weak self] in
            // The record that could not be assembled is gone for good — the
            // helper considers its artwork delivered. Ask for a fresh one.
            self?.refresh()
        }
        failurePolicy.recordSuccess()
        // A pid is recycled by the system, so a cached name has to die with
        // the process that earned it. The token is kept so `stop` can actually
        // remove the registration: discarded, it left one live block per feed
        // for the life of the app.
        if terminationToken == nil {
            terminationToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.appNames.removeValue(forKey: app.processIdentifier) }
            }
        }
        launch()
    }

    func stop() {
        stopped = true
        epoch += 1
        stopWatchdog()
        if let terminationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationToken)
            self.terminationToken = nil
        }
        output?.readabilityHandler = nil
        output = nil
        try? input?.close()
        input = nil
        pendingCommand = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Watchdog

    /// A helper that is running but saying nothing is the failure mode no
    /// process-level check can see: `terminationHandler` never fires, so the
    /// failure policy is never consulted and the panel shows an empty media
    /// tab forever with no fallback. It has happened before — a nested
    /// MediaRemote call that silenced the feed while the process stayed up —
    /// and it can happen again the first time a macOS release renames a symbol
    /// the helper looks up.
    private func startWatchdog() {
        stopWatchdog()
        lastLineAt = Date()
        let timer = Timer(timeInterval: Self.silenceTimeout / 3, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.checkForSilence() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func checkForSilence() {
        guard !stopped, process != nil else { return }
        guard Date().timeIntervalSince(lastLineAt) > Self.silenceTimeout else { return }
        NSLog("Dynamic Island: helper went silent; restarting")
        // Treated exactly like a crash, so the same budget and backoff apply
        // and a helper that is reliably mute eventually hands over to scripting.
        //
        // The termination handler is cleared *before* terminating, or the
        // process's own exit would call `handleTermination` a second time: two
        // failures recorded for one event, two `launch()` calls two seconds
        // apart, and the first perl process left running and still feeding the
        // shared line buffer.
        let task = process
        task?.terminationHandler = nil
        process = nil
        task?.terminate()
        handleTermination()
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

        let epoch = epoch
        let outputHandle = output.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // Empty means end of file, and the readability source keeps
                // firing on a closed pipe: without clearing the handler here
                // the dispatch thread spun at full tilt from the moment the
                // helper died until the main actor got around to the deferred
                // cleanup — unbounded, if the main actor was busy.
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.consume(chunk, epoch: epoch) }
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
        startWatchdog()

        // A tap made while the helper was restarting is honoured now rather
        // than dropped in silence — the panel had already flipped its icon to
        // match, and letting the command evaporate meant the icon flipped back
        // a second and a half later for no reason the user could see.
        if let pendingCommand {
            self.pendingCommand = nil
            write(pendingCommand)
        }
    }

    private func handleTermination() {
        guard !stopped else { return }
        // Once per death. The process's own termination handler and the
        // watchdog can both reach here for the same event, and two failures
        // recorded for one death spends the restart budget twice and launches
        // two helpers.
        guard process != nil || output != nil || input != nil else { return }
        stopWatchdog()
        // A fresh helper must not inherit half a line from the dead one — and
        // the epoch is bumped with the buffer, not only at launch. Bumped only
        // there, a chunk read from the dying helper could still drain onto the
        // main actor during the restart delay, match the unchanged epoch, and
        // append a fragment to the buffer the next helper was about to use.
        epoch += 1
        buffer = NDJSONBuffer()
        buffer.onOversizedRecord = { [weak self] in self?.refresh() }
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

    /// Asks the helper to send the current track's cover again.
    ///
    /// Artwork rides only the update where it changed, so once the app has lost
    /// its copy — the session going empty while another player takes the
    /// display is enough — nothing will resend it for the rest of the track.
    /// Not folded into `refresh()`: that is asked on every panel open, and
    /// answering all of those with a cover nobody needed is the cost the
    /// helper's dedupe exists to avoid.
    static let artworkRequestLine = "art"

    func requestArtwork() { write(Self.artworkRequestLine) }
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
        guard let input, let data = (line + "\n").data(using: .utf8) else {
            // The helper is between lives. Hold the command — a transport tap
            // has an optimistic icon change riding on it — and replay it when
            // the replacement is up. A `get` is not worth holding: the fresh
            // helper publishes on its own the moment it starts.
            if !stopped, !line.hasPrefix("get") { pendingCommand = line }
            return
        }
        // The helper can die between our check and the write; a broken pipe
        // would raise SIGPIPE-flavoured NSException from FileHandle.
        do {
            try input.write(contentsOf: data)
        } catch {
            NSLog("Dynamic Island: helper write failed: \(error.localizedDescription)")
            // The pipe broke mid-write, which is the same situation as writing
            // with no pipe at all: hold the command for the replacement.
            if !stopped, !line.hasPrefix("get") { pendingCommand = line }
        }
    }

    // MARK: - Parsing

    private func consume(_ chunk: Data, epoch: Int) {
        // From the helper that is actually running, not from one that has since
        // been replaced.
        guard epoch == self.epoch else { return }
        // Any byte from the helper counts as a sign of life, whether or not it
        // completes a line.
        lastLineAt = Date()
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
