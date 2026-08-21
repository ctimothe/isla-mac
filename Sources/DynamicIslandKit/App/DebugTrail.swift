import Foundation

/// Verification-only breadcrumb trail. Writes only when the launch carried
/// DI_OPEN_LYRICS=1 — the same gate as every other hook — so a normal run
/// never touches the disk.
enum DebugTrail {
    static func note(_ message: String) {
        guard ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" else { return }
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/di-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
