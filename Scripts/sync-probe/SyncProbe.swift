import AppKit
@testable import IslaKit

/// Ground-truth sync harness.
///
/// Runs the REAL pipeline — NowPlayingFeed spawning the shipped helper,
/// MediaController's anchor/adopt/tick logic — in-process, and samples it
/// against Spotify's own player position read over AppleScript, which is the
/// clock Spotify's UI renders. Scripted events hit the edges: pause, resume,
/// forward seek, large backward seek, and a sub-threshold backward seek.
@MainActor
final class Probe {
    let controller = MediaController()
    var out: [String] = ["t,ours,truth,delta,event"]
    var event = ""
    var start = Date()

    func truthPosition() -> (position: TimeInterval, latency: TimeInterval)? {
        let t0 = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Spotify\" to player position"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let value = TimeInterval(String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (value, Date().timeIntervalSince(t0))
    }

    func spotify(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Spotify\" to \(command)"]
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
        out.append(String(format: "%.2f,%.3f,%.3f,%+.3f,%@", t, ours, truth.position, delta, event))
        event = ""
    }

    func run() async {
        controller.start()
        controller.setActive(true)  // ticker on, like an open panel
        spotify("play")
        try? await Task.sleep(for: .seconds(3))  // pipeline warm-up
        start = Date()

        // 45 seconds, 5Hz sampling, events at fixed offsets.
        var fired: Set<Int> = []
        while Date().timeIntervalSince(start) < 45 {
            let t = Date().timeIntervalSince(start)
            for (at, name, cmd) in events where Int(at) == Int(t) && !fired.contains(Int(at)) {
                fired.insert(Int(at))
                event = name
                spotify(cmd)
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
