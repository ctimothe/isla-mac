import AppKit
@testable import IslaKit

/// Ground-truth sync harness.
///
/// Runs the REAL pipeline — NowPlayingFeed spawning the shipped helper,
/// MediaController's anchor/adopt/tick logic — in-process, and samples it
/// against the selected scriptable player's position read over AppleScript,
/// which is the clock Apple Music or Spotify renders. Scripted events hit the edges: pause, resume,
/// forward seek, large backward seek, and a sub-threshold backward seek.
///
/// Word columns sample an authorized v5/local word timeline for the playing
/// track at the same 5Hz, or a synthetic grid anchored at the window start.
/// `werr` is the word-edge error — how far apart the two clocks' current words
/// start — so the gate speaks in lyric units, not just seconds of clock delta.
@MainActor
final class Probe {
    let controller = MediaController()
    let player: PlayerApp = ProcessInfo.processInfo.environment["SYNC_PLAYER"] == "music" ? .music : .spotify
    var out: [String] = ["t,ours,truth,delta,surfaceDelta,event,wordOurs,wordTruth,fracOurs,fracTruth,werr"]
    var event = ""
    var start = Date()
    /// Flat word starts of the fixture, sorted. A word owns its start;
    /// the next start (or the fixture end) closes it.
    var wordStarts: [TimeInterval] = []
    var fixtureEnd: TimeInterval = 0

    func runAppleScript(_ source: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truthPosition() -> (position: TimeInterval, latency: TimeInterval)? {
        let t0 = Date()
        guard let raw = runAppleScript("tell application id \"\(player.bundleID)\" to player position"),
              let value = TimeInterval(raw) else { return nil }
        return (value, Date().timeIntervalSince(t0))
    }

    /// The playing track's authorized word-tier fixture, or a synthetic grid
    /// so the word gate still runs before the licensed provider is released.
    /// The grid is anchored at the window's truth so its edges fall inside the
    /// sampling window.
    func resolveFixture(truthStart: TimeInterval) {
        if let raw = runAppleScript("""
            tell application id "\(player.bundleID)"
                set t to current track
                return (name of t) & "\u{1}" & (artist of t) & "\u{1}" & (album of t) & "\u{1}" & (duration of t)
            end tell
            """) {
            let parts = raw.components(separatedBy: "\u{1}")
            if parts.count >= 4, let rawDuration = Double(parts[3]) {
                // Spotify's scripting dictionary reports milliseconds; Music
                // reports seconds. The cache key must agree with the client
                // identity or a lawful local/authorized fixture is missed.
                let duration = player == .spotify ? rawDuration / 1_000 : rawDuration
                let identity = LyricIdentity(
                    playerID: player.rawValue, title: parts[0], artist: parts[1],
                    album: parts[2], duration: duration
                )
                if let timeline = LicensedLyricsCache().read(for: identity),
                   timeline.granularity == .word {
                    let starts = timeline.lines.flatMap { line in
                        [line.at] + line.words.map(\.at)
                    }.sorted()
                    if !starts.isEmpty {
                        wordStarts = starts
                        fixtureEnd = (timeline.lines.map(\.at).max() ?? 0) + 6
                        print("fixture: authorized cache (\(timeline.lines.count) lines, \(starts.count) edges)")
                        return
                    }
                }
            }
        }
        // No cached word timing for this track: four words a line, a line
        // every two seconds — dense enough that the steady window crosses
        // dozens of edges, sparse enough to read like a song.
        var starts: [TimeInterval] = []
        var t = (truthStart - 2).rounded(.down)
        while t < truthStart + 55 {
            starts.append(t)
            for i in 1..<4 { starts.append(t + Double(i) * 0.4) }
            t += 2.0
        }
        wordStarts = starts.sorted()
        fixtureEnd = truthStart + 55
        print("fixture: synthetic grid (\(starts.count) edges)")
    }

    /// The word owning `pos`: the last start at or before it, and how far
    /// through that word it stands. Before the first start there is no word.
    func wordCursor(at pos: TimeInterval) -> (index: Int, fraction: Double) {
        var index = -1
        for (i, start) in wordStarts.enumerated() {
            if start <= pos { index = i } else { break }
        }
        guard index >= 0 else { return (-1, 0) }
        let start = wordStarts[index]
        let end = index + 1 < wordStarts.count ? wordStarts[index + 1] : fixtureEnd
        guard end > start else { return (index, 1) }
        return (index, min(max((pos - start) / (end - start), 0), 1))
    }

    func playerCommand(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application id \"\(player.bundleID)\" to \(command)"]
        try? task.run()
        task.waitUntilExit()
    }

    func sample() {
        guard let truth = truthPosition() else { return }
        // The AppleScript call itself takes ~40-80ms; the reading describes
        // the moment it returned, near enough. Compare against ours NOW.
        let ours = controller.position
        let t = Date().timeIntervalSince(start)
        let delta = ours - truth.position
        // Words are read against the same lead the lyric surfaces use, so the
        // columns say what the screen would show, not what the raw clock says.
        let lead = LyricSweep.lead(precisionSync: controller.precisionSync, userOffset: 0)
        let surfaceDelta = ours + lead - truth.position
        let oursCursor = wordCursor(at: ours + lead)
        let truthCursor = wordCursor(at: truth.position + lead)
        let oursEdge = oursCursor.index >= 0 ? wordStarts[oursCursor.index] : 0
        let truthEdge = truthCursor.index >= 0 ? wordStarts[truthCursor.index] : 0
        let werr = abs(oursEdge - truthEdge)
        out.append(String(format: "%.2f,%.3f,%.3f,%+.3f,%+.3f,%@,%d,%d,%.3f,%.3f,%.3f",
                          t, ours, truth.position, delta, surfaceDelta, event,
                          oursCursor.index, truthCursor.index,
                          oursCursor.fraction, truthCursor.fraction, werr))
        event = ""
    }

    func run() async {
        controller.start()
        controller.precisionPlayerForTests = player
        controller.setActive(true)  // ticker on, like an open panel
        playerCommand("play")
        try? await Task.sleep(for: .seconds(3))  // pipeline warm-up
        start = Date()
        resolveFixture(truthStart: truthPosition()?.position ?? 0)

        // 45 seconds, 5Hz sampling, events at fixed offsets.
        var fired: Set<Int> = []
        while Date().timeIntervalSince(start) < 45 {
            let t = Date().timeIntervalSince(start)
            for (at, name, cmd) in events where Int(at) == Int(t) && !fired.contains(Int(at)) {
                fired.insert(Int(at))
                event = name
                playerCommand(cmd)
            }
            sample()
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Where the harness told us to write, not a fixed world-writable path
        // two runs (or two users) would share.
        let path = ProcessInfo.processInfo.environment["SYNC_PROBE_CSV"] ?? "/tmp/sync-probe.csv"
        do {
            try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // Loudly, and with a failing status. Swallowed, this left the
            // harness analysing whatever CSV happened to be lying there and
            // reporting those numbers as the current run's.
            FileHandle.standardError.write(Data("sync-probe: cannot write \(path): \(error)\n".utf8))
            exit(1)
        }
        print("done: \(out.count - 1) samples -> \(path)")
        exit(0)
    }

    let events: [(TimeInterval, String, String)] = [
        (8,  "PAUSE",        "pause"),
        (12, "RESUME",       "play"),
        (18, "SEEK+30",      "set player position to (player position) + 30"),
        (26, "SEEK-10",      "set player position to (player position) - 10"),
        (34, "SEEK-1.5",     "set player position to (player position) - 1.5"),
    ]
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await Probe().run() }
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }
}
