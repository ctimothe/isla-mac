import AppKit

/// Where clipboard screenshots are kept.
///
/// A screenshot taken to the clipboard exists only in memory: paste it once and
/// it is gone. The vault writes it to disk so the shelf can hold on to it. The
/// folder is the user's — nothing already in it is touched — but the vault caps
/// what it adds itself, so switching the feature on cannot fill a disk with
/// copies of every image that ever passed through the pasteboard.
@MainActor
final class ScreenshotVault {
    private let paths: AppPaths

    /// How many of its own screenshots the vault keeps. Older ones go to the
    /// Trash, never straight to deletion.
    nonisolated static let retentionLimit = 200

    init(paths: AppPaths = .live) {
        self.paths = paths
        self.folder = Self.resolveFolder(paths)
    }

    /// Resolved once, not per call.
    ///
    /// It used to be a computed property that re-picked between Pictures and
    /// the fallback on every access, so a moment of unwritability sent one
    /// screenshot to the fallback and the next back to Pictures — splitting
    /// the vault across two folders, only one of which "Clear" could see.
    /// Resolved in `init`, not lazily. A `lazy var` is not atomic, and this one
    /// was reachable from two threads at once — a Settings pane refreshing its
    /// usage figures on a background queue while a copied screenshot resolved
    /// it on the main one.
    private let folder: URL

    private static func resolveFolder(_ paths: AppPaths) -> URL {
        let fm = FileManager.default
        let pictures = paths.screenshotDirectory
        if (try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)) != nil {
            return pictures
        }
        let fallback = paths.supportDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// The literal every file this vault writes begins with.
    nonisolated static let filenamePrefix = "Screenshot"

    /// Fixed, not localized.
    ///
    /// This is a `DateFormatter` *pattern*, and routing it through
    /// `Localizable.strings` handed translators the format itself: a
    /// translation that dropped the quotes around the literal, or introduced a
    /// `/` or `:`, either reinterprets the letters as format specifiers or puts
    /// a path separator in a filename, and the screenshot is then lost to a
    /// write that cannot succeed. Filenames also stopped matching between
    /// languages, so the same Mac produced two naming schemes.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// Writes off the main thread and answers on it.
    ///
    /// The data is a full-size PNG — several megabytes for a Retina screen —
    /// and the write used to be a synchronous `.atomic` one on the main actor,
    /// where it stalled the panel, the pointer sampler and any animation for
    /// as long as it took.
    func save(_ png: Data, at date: Date = Date(), completion: @escaping (URL?) -> Void) {
        let folder = folder
        // Fixed, not localized — same reason as the stamp. The retention trim
        // recognises its own files by this prefix, and a prefix that changes
        // with the app's language orphans everything written before the change:
        // the cap then silently stops applying.
        let base = "\(Self.filenamePrefix) \(Self.stamp.string(from: date))"
        let limit = Self.retentionLimit
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var url = folder.appendingPathComponent("\(base).png")
            // Two screenshots inside one second would otherwise collide.
            var attempt = 2
            while fm.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(base) (\(attempt)).png")
                attempt += 1
            }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                NSLog("Dynamic Island: failed to save image: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            Self.trimToLimit(folder: folder, limit: limit)
            DispatchQueue.main.async { completion(url) }
        }
    }

    /// Trashes the oldest of the vault's own screenshots once there are more
    /// than the limit. Only files this vault could have written are considered,
    /// matched by the name it gives them — anything else in the folder is the
    /// user's and is left alone.
    private nonisolated static func trimToLimit(folder: URL, limit: Int) {
        let fm = FileManager.default
        let prefix = filenamePrefix
        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let ours = urls.filter {
            $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix(prefix)
        }
        guard ours.count > limit else { return }
        _ = prefix
        let dated = ours.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }
        .sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(ours.count - limit) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// What the folder holds right now — for the menu item that offers to
    /// clear it, so the offer names its price.
    /// Only the vault's own files, matching what `clear()` will actually
    /// remove — the offer has to name the price it is going to charge.
    nonisolated func usage() -> (files: Int, bytes: Int64) {
        let urls = Self.ownFiles(in: folder)
        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (urls.count, bytes)
    }

    /// Files this vault wrote, by the name it gives them. Everything else in
    /// the folder belongs to the user and is never touched — the promise the
    /// class doc makes, now kept by `clear()` as well as by the trim.
    private nonisolated static func ownFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter {
            $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix(filenamePrefix)
        }
    }

    /// To the Trash, not gone. The folder's promise is that nothing in it is
    /// ever deleted behind the user's back; the menu item is the user's own
    /// hand, and the Trash keeps even that reversible.
    func clear() {
        let folder = folder
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for url in Self.ownFiles(in: folder) {
                try? fm.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }
}
