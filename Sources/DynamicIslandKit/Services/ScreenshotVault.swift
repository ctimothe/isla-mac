import AppKit

/// Where clipboard screenshots are kept.
///
/// A screenshot taken to the clipboard exists only in memory: paste it once and
/// it is gone. The vault writes it to disk so the shelf can hold on to it.
/// Nothing here is ever deleted automatically — the folder is the user's.
struct ScreenshotVault {
    private let paths: AppPaths

    init(paths: AppPaths = .live) {
        self.paths = paths
    }

    /// `~/Pictures/DynamicIsland` when it can be created — it is findable, and unlike
    /// Desktop or Documents it is not behind a TCC prompt. Falls back to the
    /// app's own support folder, which always works.
    private var folder: URL {
        let fm = FileManager.default
        let pictures = paths.screenshotDirectory
        if (try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)) != nil {
            return pictures
        }
        let fallback = paths.supportDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = localized("yyyy-MM-dd 'at' HH.mm.ss")
        return formatter
    }()

    func save(_ png: Data, at date: Date = Date()) -> URL? {
        let base = "\(localized("Screenshot")) \(Self.stamp.string(from: date))"
        var url = folder.appendingPathComponent("\(base).png")
        // Two screenshots inside one second would otherwise collide.
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(attempt)).png")
            attempt += 1
        }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("Dynamic Island: failed to save image: \(error.localizedDescription)")
            return nil
        }
    }

    func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// What the folder holds right now — for the menu item that offers to
    /// clear it, so the offer names its price.
    func usage() -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (urls.count, bytes)
    }

    /// To the Trash, not gone. The folder's promise is that nothing in it is
    /// ever deleted behind the user's back; the menu item is the user's own
    /// hand, and the Trash keeps even that reversible.
    func clear() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
