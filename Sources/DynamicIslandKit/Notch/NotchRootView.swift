import AppKit
import UniformTypeIdentifiers

/// Content view of the panel. Everything outside `activeRect` is click-through,
/// so the window can stay at its full expanded size while the panel is collapsed.
final class NotchRootView: NSView {
    /// Interactive area, in window coordinates.
    var activeRect: CGRect = .zero {
        didSet {
            guard activeRect != oldValue else { return }
            refreshCursorArea()
        }
    }

    private var cursorArea: NSTrackingArea?

    /// Region that answers a hover with a nudge instead of opening.
    ///
    /// Used only while the Mac is locked, where the island is deliberately
    /// visible but deliberately inert — nothing may open over the shield. A
    /// hover there previously did nothing whatsoever, which reads as the app
    /// being broken rather than as a decision. A tracking area is the right
    /// instrument: it reports the pointer arriving without the panel having to
    /// poll for it, and the lock path stops the pointer sampler on purpose.
    var lockedHoverRect: CGRect = .zero {
        didSet {
            guard lockedHoverRect != oldValue else { return }
            refreshLockedHoverArea()
        }
    }
    /// Raised when the pointer enters that region.
    var onLockedHover: (() -> Void)?
    private var lockedHoverArea: NSTrackingArea?

    private func refreshLockedHoverArea() {
        if let lockedHoverArea {
            removeTrackingArea(lockedHoverArea)
            self.lockedHoverArea = nil
        }
        guard !lockedHoverRect.isEmpty else { return }
        // `.activeAlways` because this app is never active, and
        // `.mouseEnteredAndExited` only — the region must not claim clicks. It
        // does not: `hitTest` still returns nil outside `activeRect`, so the
        // password field keeps every press made here.
        let area = NSTrackingArea(
            rect: lockedHoverRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: ["locked": true]
        )
        addTrackingArea(area)
        lockedHoverArea = area
    }

    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?

    private(set) var isReceivingDrag = false

    /// Where a drag has to be to count as aimed at the panel: the visible
    /// island, generously grown, rather than the whole window. The window is
    /// 700×444 and almost entirely transparent, so accepting anywhere inside
    /// it made a drag merely passing across the top of the screen open the
    /// panel and switch it to the shelf.
    var dropRect: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // File promises as well as concrete URLs: Mail attachments, Photos
        // items, and images dragged out of a browser offer only a promise, so
        // registering for `.fileURL` alone silently refused all of them.
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The app never becomes active, so without this the first click on the
    /// panel would be spent activating instead of hitting the control.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While a drag is in flight the whole window must stay a valid target,
        // otherwise AppKit drops us as the destination mid-animation.
        guard isReceivingDrag || activeRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshCursorArea()
    }

    /// The cursor shape comes from the topmost window claiming a region under
    /// the pointer. Claiming nothing does not mean "leave the cursor alone", it
    /// means the panel is invisible to that lookup and the window underneath
    /// gets to decide — an I-beam over a text editor, say. So claim exactly the
    /// part of the panel that takes events and pin it to the arrow.
    ///
    /// A cursor rect would not do: AppKit disables those for non-key windows,
    /// and this panel is never key. `.activeAlways` keeps the tracking area
    /// live regardless of that and of the app being inactive.
    private func refreshCursorArea() {
        if let cursorArea {
            removeTrackingArea(cursorArea)
            self.cursorArea = nil
        }
        guard !activeRect.isEmpty else { return }
        let area = NSTrackingArea(
            rect: activeRect,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        cursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// The pointer can already be inside a freshly installed area — entering is
    /// then the first notification we get, and no cursor update precedes it.
    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["locked"] != nil {
            onLockedHover?()
            return
        }
        NSCursor.arrow.set()
    }

    // MARK: - Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard carriesFiles(sender), aimedAtPanel(sender) else { return [] }
        isReceivingDrag = true
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard carriesFiles(sender) else { return [] }
        // Once the panel is open the whole window is a valid target — that is
        // what it opened for. Until then the drag has to be over the island
        // itself, so passing across the top of the screen on the way somewhere
        // else neither opens the panel nor claims the drop.
        guard isReceivingDrag || aimedAtPanel(sender) else { return [] }
        if !isReceivingDrag {
            isReceivingDrag = true
            onDragEntered?()
        }
        return .copy
    }

    /// Whether the pointer is over the part of the window that is actually the
    /// panel. `hitTest` is not consulted for drags, so the check has to be made
    /// here explicitly.
    private func aimedAtPanel(_ sender: NSDraggingInfo) -> Bool {
        guard !dropRect.isEmpty else { return true }
        return dropRect.contains(convert(sender.draggingLocation, from: nil))
    }

    private func carriesFiles(_ sender: NSDraggingInfo) -> Bool {
        if !urls(from: sender).isEmpty { return true }
        return !promiseReceivers(from: sender).isEmpty
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
        onDragExited?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isReceivingDrag = false
        // The drag is over whatever became of it. Without this, a promise that
        // failed or was cancelled — the header is explicit that the reader is
        // still called, with an error — left `isDropTargeted` raised forever,
        // and that flag alone holds the panel open and refuses every collapse.
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        carriesFiles(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isReceivingDrag = false
        let files = urls(from: sender)
        if !files.isEmpty { return onDrop?(files) ?? false }

        // Nothing concrete on the pasteboard, but the source promised files:
        // ask for them. They arrive asynchronously, so the drop is accepted
        // now and the shelf gains its cards as each one is written.
        let receivers = promiseReceivers(from: sender)
        guard !receivers.isEmpty else { return false }
        let destination = AppPaths.dropInbox()
        guard let destination else { return false }
        // Not counted — coalesced.
        //
        // There is no reliable count to wait for: the reader is called once per
        // promised *file*, one receiver can carry several, and `fileNames` is
        // documented (and measured) to be empty until the promise has actually
        // been called in. Anything that decides up front how many callbacks to
        // expect therefore either delivers early and drops the rest, or waits
        // for arrivals that never come.
        //
        // So each file that lands is added to a pending batch and delivery is
        // pushed out a moment; a burst becomes one drop, a straggler an hour
        // later becomes its own. Nothing is ever discarded for arriving late.
        // Not the main queue: the reader call is wrapped in an
        // `NSFileCoordination` read, so it blocks until the source app has
        // finished writing — on the main thread that is the whole UI.
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                MainActor.assumeIsolated {
                    guard error == nil else {
                        NSLog("Dynamic Island: promised file failed: \(error?.localizedDescription ?? "")")
                        return
                    }
                    self.enqueuePromisedFile(url)
                }
            }
        }
        return true
    }

    /// Files received so far that have not been handed over yet.
    private var pendingPromised: [URL] = []
    private var promisedDelivery: DispatchWorkItem?
    private var firstPendingAt: Date?

    /// However slowly files trickle in, a batch is handed over by now.
    private static let promiseMaximumWait: TimeInterval = 3

    /// Long enough that the files of one drop arrive together, short enough
    /// that the shelf does not feel slow.
    private static let promiseCoalesceWindow: TimeInterval = 0.4

    private func enqueuePromisedFile(_ url: URL) {
        pendingPromised.append(url)
        // A ceiling on the sliding window: files arriving slower than the
        // debounce would otherwise push delivery back indefinitely.
        if firstPendingAt == nil { firstPendingAt = Date() }
        if let start = firstPendingAt, Date().timeIntervalSince(start) > Self.promiseMaximumWait {
            promisedDelivery?.cancel()
            deliverPromised()
            return
        }
        promisedDelivery?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.deliverPromised() }
        }
        promisedDelivery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.promiseCoalesceWindow, execute: work)
    }

    private func deliverPromised() {
        let batch = pendingPromised
        pendingPromised.removeAll()
        promisedDelivery = nil
        firstPendingAt = nil
        guard !batch.isEmpty else { return }
        _ = onDrop?(batch)
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    private func promiseReceivers(from sender: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
    }
}
