import Foundation

/// Watches the local feed's folder and says when it changed, so a build
/// published there reaches the island within a second or two instead of at the
/// next daily check — the point of the feed is that the owner sees each change
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
@MainActor
final class UpdateFeedWatcher {
    private let folder: URL
    private let coalesce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// A publish's burst of writes, gathered into one check.
    nonisolated static let defaultCoalesce: TimeInterval = 0.5

    init(folder: URL, coalesce: TimeInterval = UpdateFeedWatcher.defaultCoalesce, onChange: @escaping @MainActor () -> Void) {
        self.folder = folder
        self.coalesce = coalesce
        self.onChange = onChange
    }

    /// Starts watching; false when the folder cannot be opened, which leaves
    /// the launch check and Check for Updates as the ways to find a build.
    @discardableResult
    func start() -> Bool {
        stop()
        // O_EVTONLY: a descriptor for events only, which does not keep the
        // volume from unmounting or the folder from being removed.
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.updates.error("update feed: could not watch the folder")
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    var isWatching: Bool { source != nil }

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
