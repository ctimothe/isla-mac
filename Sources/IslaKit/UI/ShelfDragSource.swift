import AppKit
import SwiftUI

/// Drag handle for shelf cards.
///
/// SwiftUI's `onDrag` hands back a single `NSItemProvider`, so it can never
/// carry more than one file. Dragging a selection needs an AppKit dragging
/// session with one `NSDraggingItem` per URL, which is what this overlay
/// starts. It also owns the click handling, because selection and dragging
/// come from the same mouse-down.
struct ShelfDragSource: NSViewRepresentable {
    /// Files to drag, each with the picture its card already shows: the whole
    /// selection if this card is part of it, else just this card. The grabbed
    /// card comes first, so it is the one under the pointer.
    var items: () -> [(url: URL, image: NSImage)]
    /// Where the card draws its thumbnail, in the card's own coordinates with
    /// a top-left origin, as SwiftUI measured it. `.zero` until measured.
    var thumbnail: CGRect
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void
    /// True on mouse-down, false on mouse-up or when a drag ends.
    var onPress: (Bool) -> Void
    /// The files of a drag that ended in a move or in the Trash.
    var onMoved: ([URL]) -> Void
    /// The card's tool tip. It has to live here: this view covers the whole
    /// card and owns the mouse, so AppKit asks it, and only it, what to show,
    /// and a SwiftUI `.help` on anything drawn beneath it never appeared.
    var toolTip: String? = nil

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        if view.toolTip != toolTip { view.toolTip = toolTip }
        view.items = items
        view.thumbnail = thumbnail
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onPress = onPress
        view.onMoved = onMoved
    }

    final class DragView: NSView, NSDraggingSource {
        var items: () -> [(url: URL, image: NSImage)] = { [] }
        var thumbnail: CGRect = .zero
        var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
        var onDoubleClick: () -> Void = {}
        var onPress: (Bool) -> Void = { _ in }
        var onMoved: ([URL]) -> Void = { _ in }

        /// The files of the drag in flight, kept for `ended(with:)`. Internal
        /// so `ShelfDropTests` can stand in for a session AppKit never made.
        var draggedURLs: [URL] = []

        private var mouseDown: NSEvent?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDown = event
            dragging = false
            // Feedback on the way down, not on release (F-038). Not for a
            // ⌃-click: that is the context menu's, whose tracking can keep
            // the mouse-up from ever reaching this view, and a card would
            // then sit pressed until its next click.
            if !event.modifierFlags.contains(.control) { onPress(true) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start = mouseDown else { return }
            let delta = hypot(
                event.locationInWindow.x - start.locationInWindow.x,
                event.locationInWindow.y - start.locationInWindow.y
            )
            guard delta > 3 else { return }

            let files = items()
            guard !files.isEmpty else { return }
            dragging = true
            draggedURLs = files.map(\.url)
            ShelfDragSource.beginDragOut()

            let draggingItems = files.enumerated().map { index, file -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                // The card's own cached picture — a screenshot's preview, or
                // the icon it is still showing — never a new QuickLook request
                // in the middle of the gesture. It used to be a generic 48 pt
                // file icon pinned to the card's corner.
                item.setDraggingFrame(
                    Self.dragFrame(index: index, thumbnail: thumbnail, imageSize: file.image.size, bounds: bounds),
                    contents: file.image
                )
                return item
            }
            // Started from the mouse-down, not from this event: AppKit places
            // the image where the frame says and then moves it by the
            // pointer's travel from the event it was given. Given the drag
            // event, the image lagged the 3 pt of hysteresis behind the point
            // that was grabbed for the whole of the drag.
            beginDraggingSession(with: draggingItems, event: start, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDown = nil
                dragging = false
                ShelfDragSource.endDragOut()
                onPress(false)
            }
            guard !dragging else { return }
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onClick(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            }
        }

        /// Copy unless ⌘ is held, and nothing inside the app.
        ///
        /// Move used to be on offer always, and Finder takes Move for a drop
        /// on the same disk: dragging a screenshot into a folder took the
        /// user's original out of where macOS saved it, and the card stayed
        /// behind on a dead path (F-020). The Shelf holds references, so the
        /// safe reading of a plain drag is a copy. ⌘ is Finder's own way to
        /// ask for a move — AppKit narrows a ⌘-drag to Generic at the
        /// destination, which Finder performs as a move — and it brings the
        /// Trash (Delete) back with it; a card that moved follows its file.
        ///
        /// AppKit asks again whenever the modifiers change mid-drag, so
        /// pressing ⌘ partway over a folder turns the copy into a move, as it
        /// does for a drag that starts in Finder.
        static func operationMask(
            context: NSDraggingContext, modifiers: NSEvent.ModifierFlags
        ) -> NSDragOperation {
            guard context == .outsideApplication else { return [] }
            return modifiers.contains(.command) ? [.copy, .move, .link, .generic, .delete] : [.copy, .link]
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            Self.operationMask(context: context, modifiers: NSEvent.modifierFlags)
        }

        /// Where one dragged card's picture starts: over the thumbnail it
        /// came from, fitted the way the card fits it, so a grab in the
        /// middle of a screenshot keeps the pointer on the same point of it
        /// for the whole drag. A group fans out behind the grabbed card by
        /// the same 9 pt step it always had, so it still reads as a stack.
        ///
        /// - Parameter thumbnail: the thumbnail's box in the card, top-left
        ///   origin as SwiftUI measures it; `.zero` before it has been
        ///   measured, and then the whole card stands in.
        /// - Returns: a frame in this view's coordinates, which are not
        ///   flipped.
        static func dragFrame(index: Int, thumbnail: CGRect, imageSize: NSSize, bounds: NSRect) -> NSRect {
            let box = thumbnail.isEmpty ? CGRect(origin: .zero, size: bounds.size) : thumbnail
            var size = box.size
            if imageSize.width > 0, imageSize.height > 0 {
                let scale = min(box.width / imageSize.width, box.height / imageSize.height)
                size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            }
            let topLeft = CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
            let offset = CGFloat(index) * 9
            return NSRect(
                x: topLeft.x + offset,
                y: bounds.height - topLeft.y - size.height - offset,
                width: size.width,
                height: size.height
            )
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            ended(with: operation)
        }

        /// The end of a drag, whatever became of it.
        ///
        /// A drop that may have taken the file away — a move, a Generic drop
        /// (which Finder performs as one), the Trash — is handed to the card
        /// to follow. This has to happen here and now: AppKit does not retain
        /// a dragging source, so nothing later can be counted on to hear about
        /// it. A plain copy leaves the original, and the card, where they were.
        func ended(with operation: NSDragOperation) {
            let urls = draggedURLs
            draggedURLs = []
            dragging = false
            mouseDown = nil
            ShelfDragSource.endDragOut()
            onPress(false)
            if !urls.isEmpty, !operation.isDisjoint(with: [.move, .generic, .delete]) {
                onMoved(urls)
            }
        }
    }

    /// True while a card is being dragged out of the shelf.
    ///
    /// The panel's own drag flag only tracks drags coming *in*, so an outgoing
    /// one left the pointer watcher free to decide the cursor had wandered off
    /// the panel — which folded the panel 0.32 s into the drag and tore down
    /// the very view the session was running from.
    @MainActor private(set) static var isDraggingOut = false

    /// Fail-safe for the latch above.
    ///
    /// AppKit does not retain a dragging source, so a view torn down mid-session
    /// never receives `draggingSession(_:endedAt:)` — and a latch stuck true
    /// leaves an invisible, permanently click-eating rectangle at the top of the
    /// screen and a panel that never auto-collapses. No drag outlives this.
    @MainActor private static var dragOutExpiry: DispatchWorkItem?
    @MainActor private static let maximumDragDuration: TimeInterval = 120

    @MainActor static func beginDragOut() {
        isDraggingOut = true
        dragOutExpiry?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { endDragOut() } }
        dragOutExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumDragDuration, execute: work)
    }

    @MainActor static func endDragOut() {
        isDraggingOut = false
        dragOutExpiry?.cancel()
        dragOutExpiry = nil
    }
}
