import Foundation

/// Watches the local feed's folder and says when it changed, so a build
/// published there reaches the island within a second or two instead of at the
/// next hourly check — the point of the feed is that the owner sees each change
/// as it is made (plan 2026-10-19).
///
/// A `DispatchSource` on the folder itself: the kernel reports a write to a
/// directory when an entry is added, removed or renamed in it, which is how
/// `Scripts/publish-dev-update.sh` lands `release.json` — written beside it and
/// renamed in, so a check never reads half of one. Rewriting a file in place
/// is not reported, and nothing here needs it to be.
///
/// A publish adds an image, a signature and the release in a burst, so the
/// events are coalesced: the callback runs once, `coalesce` seconds after the
/// last of them. On the main actor, with nothing to poll and no thread of its
/// own; with no feed it is never made.
///
/// The descriptor follows the folder it was opened on, not its path. When that
/// folder is removed or renamed — `rm -rf .dev-updates` and a publish that
/// makes it again — the watcher lets go, watches the folder above it, and
/// opens the path again when an entry there changes, checking once it has:
/// anything may be in the new folder. Before this the feed went unwatched
/// until Isla next launched (review, 2026-10-19). A timer, from `reopenDelay`
/// doubling to `reopenLimit`, is only the net for a folder above that cannot
/// be watched; at seconds it woke the Mac all night for a feed left gone.
@MainActor
final class UpdateFeedWatcher {
    private let folder: URL
    private let coalesce: TimeInterval
    private let firstReopenDelay: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var reopenWork: DispatchWorkItem?
    /// The folder above, watched while the feed is gone.
    private var parentSource: DispatchSourceFileSystemObject?

    /// A publish's burst of writes, gathered into one check.
    nonisolated static let defaultCoalesce: TimeInterval = 0.5
    /// The first wait before opening a lost folder's path again: a publish
    /// that removed it makes it again at once.
    nonisolated static let defaultReopenDelay: TimeInterval = 1
    /// The longest wait between the net's tries, for a feed that stays gone.
    nonisolated static let reopenLimit: TimeInterval = 300

    init(
        folder: URL, coalesce: TimeInterval = UpdateFeedWatcher.defaultCoalesce,
        reopenDelay: TimeInterval = UpdateFeedWatcher.defaultReopenDelay,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.folder = folder
        self.coalesce = coalesce
        self.firstReopenDelay = reopenDelay
        self.onChange = onChange
    }

    /// Starts watching; false when the folder cannot be opened, which leaves
    /// the launch check and Check for Updates as the ways to find a build.
    @discardableResult
    func start() -> Bool {
        stop()
        guard attach() else {
            Log.updates.error("update feed: could not watch the folder")
            return false
        }
        return true
    }

    func stop() {
        pending?.cancel()
        pending = nil
        reopenWork?.cancel()
        reopenWork = nil
        parentSource?.cancel()
        parentSource = nil
        source?.cancel()
        source = nil
    }

    var isWatching: Bool { source != nil }

    /// Opens the folder's path and watches what is there now.
    private func attach() -> Bool {
        // O_EVTONLY: a descriptor for events only, which does not keep the
        // volume from unmounting or the folder from being removed.
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source, source === self.source else { return }
                // On a folder, a write is an entry added, removed or renamed
                // inside it; a delete or a rename is the folder itself going.
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.lost()
                } else {
                    self.changed()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    /// The watched folder was removed or renamed: let it go and look for the
    /// path again.
    private func lost() {
        Log.updates.info("update feed: the folder went away; watching for it again")
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        watchParent()
        scheduleReopen(after: firstReopenDelay)
    }

    /// Watches the folder above the lost feed: an entry added, removed or
    /// renamed there is the moment to look for the feed again.
    private func watchParent() {
        parentSource?.cancel()
        parentSource = nil
        let descriptor = open(folder.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let parent = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        parent.setEventHandler { [weak self, weak parent] in
            MainActor.assumeIsolated {
                guard let self, let parent, parent === self.parentSource else { return }
                self.tryReopen()
            }
        }
        parent.setCancelHandler { close(descriptor) }
        parent.resume()
        parentSource = parent
    }

    /// Opens the feed's path if it is there again: stops looking, and checks.
    @discardableResult
    private func tryReopen() -> Bool {
        guard source == nil, attach() else { return false }
        reopenWork?.cancel()
        reopenWork = nil
        parentSource?.cancel()
        parentSource = nil
        onChange()
        return true
    }

    private func scheduleReopen(after delay: TimeInterval) {
        reopenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.reopenWork != nil else { return }
                self.reopenWork = nil
                if !self.tryReopen() {
                    self.scheduleReopen(after: min(delay * 2, Self.reopenLimit))
                }
            }
        }
        reopenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.source != nil else { return }
                self.pending = nil
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesce, execute: work)
    }
}
