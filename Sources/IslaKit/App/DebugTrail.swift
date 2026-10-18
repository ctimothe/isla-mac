import Foundation

/// Verification-only breadcrumb trail, and the launch switches that arm it.
/// Writes only when the launch carried DI_OPEN_LYRICS=1, DI_GEOM=1 or
/// DI_MEDIA=1, so a normal run never touches the disk.
///
/// Every switch is read once. They are set at launch or not at all, and
/// `ProcessInfo.environment` builds a fresh dictionary of the whole
/// environment on every read — 22 µs with 57 variables, measured — which the
/// hit test, the geometry watchdog's two-second tick and every media snapshot
/// each paid on a normal run, only to learn that nothing was set.
enum DebugTrail {
    /// DI_GEOM=1: the geometry trail, clicks and gestures included.
    static let geometry = flag("DI_GEOM")
    /// DI_OPEN_LYRICS=1: the lyrics stage opens without a pointer, and the
    /// lyric and media trails are written.
    static let openLyrics = flag("DI_OPEN_LYRICS")
    /// DI_MEDIA=1: the media trail alone, with nothing opened.
    static let media = flag("DI_MEDIA")
    /// DI_OPEN_PANEL=1: the panel opens on the player without a pointer.
    static let openPanel = flag("DI_OPEN_PANEL")
    /// DI_LOCK_PREVIEW=1: the lock card is presented without locking the Mac.
    static let lockPreview = flag("DI_LOCK_PREVIEW")
    /// DI_UPDATE_REHEARSAL=<folder>: Update Now reads its release from
    /// `<folder>/release.json` and downloads from that folder's own files
    /// instead of GitHub's, so an update can be rehearsed on a real Mac before a
    /// real release exists (`Scripts/rehearse-update.sh`). Only here is the
    /// variable read; everything else asks this.
    static let updateRehearsal: URL? = rehearsalFolder(from: ProcessInfo.processInfo.environment)
    /// DI_TEST_CLICK=next: a test drives lyric clicks.
    static let testClickNext = ProcessInfo.processInfo.environment["DI_TEST_CLICK"] == "next"

    /// The folder named by DI_UPDATE_REHEARSAL, with symlinks resolved, or nil
    /// when it is unset, empty, not absolute or not a folder.
    static func rehearsalFolder(from environment: [String: String]) -> URL? {
        guard let path = environment["DI_UPDATE_REHEARSAL"], path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    private static let records = geometry || openLyrics || media

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }

    /// The message is built only when something will be written.
    static func note(_ message: @autoclosure () -> String) {
        guard records else { return }
        let line = "\(Date()) \(message())\n"
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
