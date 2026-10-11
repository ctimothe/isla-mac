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

    /// What the trim and Clear do with a file the vault is done with. The
    /// Trash, always, in the app; a test hands in a recorder instead, so a
    /// test run can never move anything into the owner's own Trash.
    ///
    /// Throws when the move is refused — a volume with no Trash, a file
    /// locked in Finder — so Clear can say how many files actually went
    /// rather than how many it asked to send (F-034).
    private let discard: @Sendable (URL) throws -> Void

    /// Every write, trim and clear runs here, one at a time.
    ///
    /// They ran on the concurrent global queue, where two captures stamped in
    /// the same second could both find the name free and the second `.atomic`
    /// write silently replaced the first (G-022). One serial queue makes the
    /// collision loop's look-then-write a single step, and a Clear can no
    /// longer interleave with a save that is halfway through.
    private let queue = DispatchQueue(label: "com.ctimothe.isla.vault", qos: .utility)

    private let location: Location

    /// Stores the paths and nothing else. `init` used to create
    /// `~/Pictures/Isla` at every launch, with the feature off — and in every
    /// test that built a `NotchStores` — a folder nobody had asked for
    /// (J-013). The folder is now made by the first save, or by the user
    /// asking to see it.
    init(paths: AppPaths = .live, discard: @escaping @Sendable (URL) throws -> Void = ScreenshotVault.trash) {
        self.paths = paths
        self.discard = discard
        self.location = Location(paths)
    }

    @Sendable nonisolated static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Where the vault's files live: Pictures, or the support fallback when
    /// Pictures cannot be written.
    ///
    /// Chosen once and kept. It used to be a computed property that re-picked
    /// on every access, so a moment of unwritability sent one screenshot to
    /// the fallback and the next back to Pictures — splitting the vault across
    /// two folders, only one of which "Clear" could see. Then it was resolved
    /// in `init`, which kept that rule but created the folder at launch and
    /// never again: a user who deleted it in Finder lost every screenshot
    /// after that until the next launch (G-022). Now the choice is made by
    /// the first save, cached, and the folder is re-created before every
    /// write. The lock is there because the choice is read from three places
    /// — the vault's queue, the Settings pane's usage refresh on a background
    /// queue, and Reveal on the main thread — and a `lazy var` was once found
    /// racing across exactly those.
    private final class Location: @unchecked Sendable {
        private let pictures: URL
        private let fallback: URL
        private let lock = NSLock()
        private var chosen: URL?

        init(_ paths: AppPaths) {
            pictures = paths.screenshotDirectory
            fallback = paths.supportDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        }

        /// The folder holding the vault's files, or nil when there is none.
        /// Creates nothing: the usage figures and Clear only look.
        ///
        /// Before anything is chosen, a folder that already exists wins,
        /// Pictures first — the same order `prepared()` uses, so what Settings
        /// counts and where the next save lands never disagree.
        func existing() -> URL? {
            let chosen = lock.withLock { self.chosen }
            if let chosen { return Self.isDirectory(chosen) ? chosen : nil }
            return [pictures, fallback].first(where: Self.isDirectory)
        }

        /// The folder to write into, created if it is missing — including when
        /// the user deleted it since the last save.
        func prepared() -> URL? {
            lock.withLock {
                let fm = FileManager.default
                if let chosen {
                    return (try? fm.createDirectory(at: chosen, withIntermediateDirectories: true)) != nil
                        ? chosen : nil
                }
                let candidates = [pictures, fallback].filter(Self.isDirectory) + [pictures, fallback]
                for candidate in candidates
                where (try? fm.createDirectory(at: candidate, withIntermediateDirectories: true)) != nil {
                    chosen = candidate
                    return candidate
                }
                return nil
            }
        }

        private static func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// The extended attribute the vault leaves on every file it writes, so
    /// what it owns is decided by a mark it made and not by a name macOS also
    /// uses (J-013).
    nonisolated static let ownershipAttribute = "com.ctimothe.isla.vault"

    /// The literal every file this vault writes begins with.
    nonisolated static let filenamePrefix = "Screenshot"

    /// The literal every recording this vault writes begins with. A prefix of
    /// its own rather than sharing the screenshot one: the trim recognises
    /// its files by name, and one prefix for two containers would let a
    /// future rename of either orphan the other.
    ///
    /// Fixed, not localized, for the same reason as the stamp below.
    nonisolated static let movieFilenamePrefix = "Screen Recording"

    /// Containers the vault itself writes. Everything else in the folder —
    /// the user's own movies included — is left alone by the trim and the
    /// usage figures.
    nonisolated static let movieExtensions: Set<String> = ["mov", "mp4", "m4v"]

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
        // Fixed, not localized — same reason as the stamp. The retention trim
        // recognises its own files by this prefix, and a prefix that changes
        // with the app's language orphans everything written before the change:
        // the cap then silently stops applying.
        write(png, base: "\(Self.filenamePrefix) \(Self.stamp.string(from: date))", ext: "png", completion: completion)
    }

    /// Keeps a captured recording the way `save` keeps a screenshot: one file
    /// per capture under the vault's own name, counted and trimmed by the same
    /// cap. The extension travels with the bytes — the pasteboard names the
    /// container the recording was copied as, and re-housing every capture as
    /// one format regardless would corrupt what a player expects to open.
    func saveMovie(
        _ data: Data, fileExtension: String,
        at date: Date = Date(), completion: @escaping (URL?) -> Void
    ) {
        // The extension arrives from a UTI the system vended, but this is a
        // filename all the same: only alphanumerics survive, and anything else
        // falls back to the container recordings are captured as.
        let ext = fileExtension.lowercased()
        let safe = !ext.isEmpty && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? ext : "mov"
        write(
            data,
            base: "\(Self.movieFilenamePrefix) \(Self.stamp.string(from: date))",
            ext: safe,
            completion: completion
        )
    }

    private func write(_ data: Data, base: String, ext: String, completion: @escaping (URL?) -> Void) {
        let location = location
        let discard = discard
        let limit = Self.retentionLimit
        queue.async {
            guard let folder = location.prepared() else {
                Log.shelf.error("failed to save capture: no folder could be created")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let fm = FileManager.default
            var url = folder.appendingPathComponent("\(base).\(ext)")
            // Two captures inside one second would otherwise collide. Safe
            // only because every write runs on this one serial queue: the
            // name found free here is still free when the write lands.
            var attempt = 2
            while fm.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(base) (\(attempt)).\(ext)")
                attempt += 1
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Log.shelf.error("failed to save capture: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // After the write, not before: an `.atomic` write lands as a new
            // file renamed into place, and a mark set on anything earlier
            // would not survive it. A volume that refuses extended attributes
            // leaves the file unmarked, and the legacy rule in `isOwnFile`
            // still claims it — a vault file never carries the system's mark.
            Self.markAsOwn(url)
            Self.trimToLimit(folder: folder, limit: limit, discard: discard)
            DispatchQueue.main.async { completion(url) }
        }
    }

    private nonisolated static func markAsOwn(_ url: URL) {
        let value = Data("1".utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = value.withUnsafeBytes { bytes in
                setxattr(path, ownershipAttribute, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
    }

    private nonisolated static func hasOwnMark(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, ownershipAttribute, nil, 0, 0, 0) >= 0
        }
    }

    /// Whether the vault wrote this file itself. Everything else in the folder
    /// belongs to the user and is never touched — the promise the class doc
    /// makes.
    ///
    /// This used to be the name alone: any PNG beginning "Screenshot", any
    /// movie beginning "Screen Recording". Those are exactly the names
    /// Screenshot.app gives its own captures, so a user who pointed the system
    /// at the folder Isla revealed had the oldest of their captures trashed by
    /// the trim past 200, and all of them by Clear (J-013). Now a file must
    /// carry the vault's name *and* either the vault's own mark or, for one
    /// written before the mark existed, no system capture mark — macOS stamps
    /// every capture it writes with one, and the vault never does. The name
    /// still comes first so a folder of the user's own photos costs no
    /// attribute reads.
    private nonisolated static func isOwnFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let namedByVault: Bool
        if url.pathExtension == "png" {
            namedByVault = name.hasPrefix(filenamePrefix)
        } else if movieExtensions.contains(url.pathExtension.lowercased()) {
            namedByVault = name.hasPrefix(movieFilenamePrefix)
        } else {
            namedByVault = false
        }
        guard namedByVault else { return false }
        if hasOwnMark(url) { return true }
        return !CaptureMetadata.hasScreenCaptureAttribute(url)
    }

    /// Discards the oldest of the vault's own captures once there are more
    /// than the limit. Only files this vault wrote are considered — anything
    /// else in the folder is the user's and is left alone.
    private nonisolated static func trimToLimit(
        folder: URL, limit: Int, discard: @Sendable (URL) throws -> Void
    ) {
        let ours = ownFiles(in: folder)
        guard ours.count > limit else { return }
        let dated = ours.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }
        .sorted { $0.1 < $1.1 }
        // A refused move leaves the file where it is, over the cap; the next
        // save tries again, and nothing here is worth stopping a save for.
        for (url, _) in dated.prefix(ours.count - limit) {
            try? discard(url)
        }
    }

    /// Creates the folder first: the user asked to see it, and Finder shown a
    /// folder that does not exist yet opens nothing at all.
    func reveal() {
        guard let folder = location.prepared() else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// What the folder holds right now — for the menu item that offers to
    /// clear it, so the offer names its price.
    /// Only the vault's own files, matching what `clear()` will actually
    /// remove — the offer has to name the price it is going to charge.
    /// Nothing at all when the folder does not exist — looking never makes it.
    nonisolated func usage() -> (files: Int, bytes: Int64) {
        guard let folder = location.existing() else { return (0, 0) }
        let urls = Self.ownFiles(in: folder)
        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (urls.count, bytes)
    }

    /// Files this vault wrote, as `isOwnFile` decides it. Everything else in
    /// the folder belongs to the user and is never touched — the promise the
    /// class doc makes, kept by `clear()` and the trim alike.
    private nonisolated static func ownFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter(isOwnFile)
    }

    /// To the Trash, not gone. The folder's promise is that nothing in it is
    /// ever deleted behind the user's back; the menu item is the user's own
    /// hand, and the Trash keeps even that reversible.
    ///
    /// On the vault's own queue, so a save already queued finishes first and
    /// a save queued after it lands in a cleared folder — never a half-cleared
    /// one. With no folder there is nothing to clear, and nothing is created.
    ///
    /// Answers on the main thread with how many files reached the Trash, once
    /// the last of them has. There was no answer at all once: Settings called
    /// this and reloaded the Shelf and the size label on the next line, while
    /// the trash had not started, so the cards and the size stayed until the
    /// next visit (F-034). The answer comes even when nothing moved — the
    /// caller disables its row while it waits, and must hear back to undo
    /// that.
    func clear(completion: @escaping @MainActor (Int) -> Void) {
        let location = location
        let discard = discard
        queue.async {
            var moved = 0
            if let folder = location.existing() {
                for url in Self.ownFiles(in: folder) where (try? discard(url)) != nil {
                    moved += 1
                }
            }
            let count = moved
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(count) }
            }
        }
    }
}
