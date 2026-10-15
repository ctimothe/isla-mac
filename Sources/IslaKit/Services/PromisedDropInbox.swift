import Foundation

/// Where files that a drag only promised come to rest.
///
/// Mail attachments, Photos items and images dragged out of a browser offer a
/// promise, not a file, and the source writes it when it is ready: seconds
/// later for an iCloud Photos original that has to be downloaded first. This
/// lived in `NotchRootView`, and its receivers held that view weakly. The view
/// is rebuilt whenever a display changes, so a monitor plugged in mid-transfer
/// dropped the file on the floor and the dropInbox sweep trashed it seven days
/// later (G-025). It also called straight into the open-the-panel path, so a
/// promise that landed after the Mac was locked opened the panel over the
/// shield. The inbox is owned by `NotchStores` and so outlives every panel; the
/// controller decides, per batch, whether the arrival may be shown.
@MainActor
final class PromisedDropInbox {
    private let shelf: ShelfStore

    /// A coalesced batch of files that landed. Wired once by the controller.
    var onBatch: (([URL]) -> Void)?
    /// A batch whose drop was aimed at the Shelf's AirDrop well (spec §8.3):
    /// sent, not kept. A promise cannot be sent until its source has written
    /// the file, which is when it reaches the inbox, so the aim is latched at
    /// the release (`sendNextBatchWithAirDrop`) and honoured here.
    var onAirDropBatch: (([URL]) -> Void)?

    /// Set by the controller at the release of a drop over AirDrop's well; read
    /// and cleared when the batch it names is delivered. One batch, never the
    /// next drop's: a later drop to the Shelf's other well must not be sent to
    /// a stranger's phone because an earlier one was.
    private var airDropNext = false

    func sendNextBatchWithAirDrop(_ send: Bool) {
        airDropNext = send
    }

    init(shelf: ShelfStore) {
        self.shelf = shelf
    }

    /// Where a promised file lands, called by `NSFilePromiseReceiver` on the
    /// queue handed to it by `NotchRootView` — never on the main queue.
    ///
    /// This used to be `MainActor.assumeIsolated`, which is an assertion, not a
    /// hop: it traps when it is wrong, and here it was wrong every single time.
    /// Dragging a Mail attachment or a Photos item — the two sources the whole
    /// promise path exists for — killed the process the moment the first file
    /// was written. `Task { @MainActor }` is the hop the code always meant.
    ///
    /// `nonisolated` on purpose: the inbox is main-actor isolated, and the
    /// compiler has to be told this one entry point is not.
    nonisolated func arrived(url: URL?, error: Error?) {
        if let error {
            Log.shelf.error("promised file failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            // A cancel is the user's own doing (the drag was abandoned or the
            // source app was told to stop); anything else used to leave a drop
            // that looked accepted and then produced nothing (F-035).
            let cancelled = (error as NSError).domain == NSCocoaErrorDomain
                && (error as NSError).code == CocoaError.userCancelled.rawValue
            if !cancelled {
                Task { @MainActor [weak self] in self?.shelf.show(.promiseFailed) }
            }
            return
        }
        guard let url else { return }
        Task { @MainActor [weak self] in
            self?.enqueue(url)
        }
    }

    /// Files received so far that have not been handed over yet.
    private var pending: [URL] = []
    private var delivery: DispatchWorkItem?
    private var firstPendingAt: Date?

    /// However slowly files trickle in, a batch is handed over by now.
    private static let maximumWait: TimeInterval = 3

    /// Long enough that the files of one drop arrive together, short enough
    /// that the shelf does not feel slow.
    private static let coalesceWindow: TimeInterval = 0.4

    private func enqueue(_ url: URL) {
        pending.append(url)
        // A ceiling on the sliding window: files arriving slower than the
        // debounce would otherwise push delivery back indefinitely.
        if firstPendingAt == nil { firstPendingAt = Date() }
        if let start = firstPendingAt, Date().timeIntervalSince(start) > Self.maximumWait {
            delivery?.cancel()
            deliver()
            return
        }
        delivery?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.deliver() }
        }
        delivery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow, execute: work)
    }

    private func deliver() {
        let batch = pending
        pending.removeAll()
        delivery = nil
        firstPendingAt = nil
        let toAirDrop = airDropNext
        airDropNext = false
        guard !batch.isEmpty else { return }
        if toAirDrop, let onAirDropBatch {
            onAirDropBatch(batch)
        } else {
            onBatch?(batch)
        }
    }
}
