import Foundation

/// `~/Library/Application Support/Cyclop` — where everything Cyclop keeps of
/// its own lives.
///
/// One place for the path, because four stores were each spelling out the same
/// three lines: find the support directory, append the app's name, make sure it
/// exists. Identical every time, and the kind of thing that stays identical
/// only until one copy is edited and the others are not.
enum Support {
    /// The folder itself, created on first use. Repeated calls are cheap —
    /// `createDirectory` with `withIntermediateDirectories` is content to find
    /// the folder already there.
    static let folder: URL = {
        let fm = FileManager.default
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cyclop", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A file inside it, with the folder guaranteed to exist by the time the
    /// path is handed back — which is the only reason this is a function and
    /// not string concatenation at the call site.
    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A subfolder inside it, created the same way.
    static func directory(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
