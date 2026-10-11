import Foundation

struct AppPaths: Sendable {
    let supportDirectory: URL
    let screenshotDirectory: URL

    static let live: AppPaths = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
        // Asked for by search-path constant rather than assembled from the home
        // directory and the literal "Pictures". The two agree on an ordinary
        // Mac and disagree on a relocated or localized one, where building the
        // path by hand quietly created a second folder beside the real
        // Pictures instead of writing into it.
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        let screenshots = pictures
            .appendingPathComponent(ProductIdentity.screenshotDirectoryName, isDirectory: true)
        return AppPaths(supportDirectory: support, screenshotDirectory: screenshots)
    }()

    func ensureSupportDirectory(using fm: FileManager = .default) throws {
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    /// Nil when the support directory cannot be created, rather than a URL into
    /// a folder that does not exist. Swallowing that failure handed every store
    /// a path whose writes were guaranteed to fail — some of them silently.
    func supportFile(_ name: String, using fm: FileManager = .default) -> URL? {
        do {
            try ensureSupportDirectory(using: fm)
        } catch {
            Log.storage.error("cannot create support directory: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return nil
        }
        return supportDirectory.appendingPathComponent(name)
    }

    /// Where promised files land when they are dropped on the panel. The
    /// source writes them here, and the shelf then points at them.
    ///
    /// A fresh subfolder per drop. One flat directory meant a second
    /// `IMG_0001.jpeg` from Photos overwrote the bytes the existing shelf card
    /// pointed at — and, because the shelf dedupes by URL, added no card of its
    /// own: the drop silently did nothing while corrupting an older one.
    static func dropInbox(using fm: FileManager = .default) -> URL? {
        let inbox = live.supportDirectory
            .appendingPathComponent("Dropped", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            Log.storage.error("cannot create drop inbox: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return nil
        }
        return inbox
    }

    /// Trashes drop folders older than a week, so the inbox does not grow for
    /// the life of the install. Called on launch, off the main thread.
    ///
    /// - Parameter keeping: the files the Shelf's cards point at. A folder
    ///   holding any of them stays, however old. The prune used to go by age
    ///   alone, and a Mail attachment or a Photos original kept on the Shelf
    ///   for a project went to the Trash at the first relaunch after a week —
    ///   and the next Shelf open dropped its card, because a file in the Trash
    ///   is a deleted card (F-019). Refreshing the folder's date whenever the
    ///   Shelf opens was the other way out, and was turned down: it writes to
    ///   the user's files to keep a cache from eating them.
    /// - Parameter discard: what happens to a folder that goes. The Trash by
    ///   default, so a mistake here is recoverable; tests pass a recorder so
    ///   nothing of theirs ever lands in the owner's Trash.
    static func pruneDropInbox(
        root: URL = live.supportDirectory.appendingPathComponent("Dropped", isDirectory: true),
        keeping: Set<URL> = [],
        now: Date = Date(),
        using fm: FileManager = .default,
        discard: ((URL) -> Void)? = nil
    ) {
        // A test that reached this through the stores, with no recorder of its
        // own, would be pruning the owner's real inbox into the owner's real
        // Trash. Tests pass a temporary root and a recorder; the Trash is the
        // app's alone.
        if discard == nil, PlayerBridge.isRunningTests { return }
        let discard = discard ?? { try? fm.trashItem(at: $0, resultingItemURL: nil) }
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        // Compared by folder name: the listing above spells its URLs however
        // it likes, and a name inside one root means one folder.
        let used = Set(keeping.compactMap { dropFolder(containing: $0, root: root) })
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for entry in entries where !used.contains(entry.lastPathComponent) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if modified < cutoff { discard(entry) }
        }
    }

    /// The name of the drop folder under `root` that `url` lives in — the
    /// `<uuid>` of `Dropped/<uuid>/mail.pdf` — or nil for a file anywhere else.
    ///
    /// By path components, never by string prefix: `Dropped` is a prefix of
    /// `DroppedElsewhere`, and a prefix test would let a file there protect a
    /// folder it has nothing to do with. And against the root as written and
    /// as the disk resolves it, because a card's URL comes back from its
    /// bookmark resolved — `/private/var/…` where the root says `/var/…` —
    /// and a card that failed to match its own folder is exactly the card the
    /// prune would trash. Only the root, which is Isla's own folder, is
    /// resolved; the card's URL is only tidied, never looked up, so a card on
    /// an unplugged or hung disk costs the prune nothing.
    static func dropFolder(containing url: URL, root: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        var spellings = [root.standardizedFileURL.pathComponents]
        if let resolved = realpath(root.path, nil) {
            // Standardized as well, which is what folds realpath's
            // `/private/var` back into the `/var` the card's tidied URL uses.
            spellings.append(URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL.pathComponents)
            free(resolved)
        }
        for base in spellings where components.count > base.count
            && Array(components.prefix(base.count)) == base {
            return components[base.count]
        }
        return nil
    }
}
