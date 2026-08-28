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
    /// Files to drag: the whole selection if this card is part of it, else
    /// just this card.
    var urls: () -> [URL]
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
        var onDoubleClick: () -> Void = {}

        private var mouseDownPoint: NSPoint?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start = mouseDownPoint else { return }
            let delta = hypot(
                event.locationInWindow.x - start.x,
                event.locationInWindow.y - start.y
            )
            guard delta > 3 else { return }

            let files = urls()
            guard !files.isEmpty else { return }
            dragging = true
            ShelfDragSource.beginDragOut()

            let items = files.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                // Fan the icons out slightly so a group reads as a stack.
                let offset = CGFloat(index) * 9
                item.setDraggingFrame(
                    NSRect(x: offset, y: -offset, width: 48, height: 48),
                    contents: icon
                )
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownPoint = nil
                dragging = false
                ShelfDragSource.endDragOut()
            }
            guard !dragging else { return }
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onClick(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            dragging = false
            ShelfDragSource.endDragOut()
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
