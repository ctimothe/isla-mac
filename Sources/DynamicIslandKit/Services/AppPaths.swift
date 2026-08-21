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
            NSLog("Dynamic Island: cannot create support directory: \(error.localizedDescription)")
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
            NSLog("Dynamic Island: cannot create drop inbox: \(error.localizedDescription)")
            return nil
        }
        return inbox
    }

    /// Trashes drop folders older than a week, so the inbox does not grow for
    /// the life of the install. Called on launch, off the main thread.
    static func pruneDropInbox(using fm: FileManager = .default) {
        let root = live.supportDirectory.appendingPathComponent("Dropped", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if modified < cutoff { try? fm.trashItem(at: entry, resultingItemURL: nil) }
        }
    }
}
