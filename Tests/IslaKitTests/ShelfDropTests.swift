import XCTest
@testable import IslaKit

/// The promised-file path, driven the way `NSFilePromiseReceiver` drives it.
///
/// It hands its reader to the operation queue the caller supplied, which is
/// deliberately not the main queue. Asserting main-actor isolation inside that
/// reader is not a check that fails loudly in the wrong case — it is a trap
/// that takes the process down every time a Mail attachment or a Photos item
/// lands on the shelf.
@MainActor
final class ShelfDropTests: XCTestCase {

    func testAPromisedFileArrivingOffTheMainQueueIsDelivered() {
        let view = NotchRootView(frame: .zero)
        let delivered = expectation(description: "the coalesced batch reaches onDrop")
        var received: [URL] = []
        view.onDrop = { urls in
            received = urls
            delivered.fulfill()
            return true
        }

        let url = URL(fileURLWithPath: "/tmp/isla-promise-test.txt")
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.addOperation { view.promisedFileArrived(url, error: nil) }

        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(received, [url])
    }

    /// A cancelled or failed promise still calls the reader, with an error.
    /// It must be logged and dropped, never delivered as a file.
    func testAFailedPromiseDeliversNothing() {
        let view = NotchRootView(frame: .zero)
        view.onDrop = { _ in
            XCTFail("a failed promise must not reach the shelf")
            return false
        }

        let queue = OperationQueue()
        queue.addOperation {
            view.promisedFileArrived(nil, error: CocoaError(.userCancelled))
        }

        let settled = expectation(description: "the coalesce window closes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }

    /// A drag over the island asks what it carries once, not on every move.
    /// `draggingUpdated` arrives on every move of the pointer, and each call
    /// used to read the dragged items back off the drag pasteboard.
    func testADragReadsWhatItCarriesOnceNotOnEveryMove() {
        let view = NotchRootView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let pasteboard = NSPasteboard(name: .init("ShelfDropTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/isla-drag-test.txt") as NSURL])
        let drag = CountingDrag(pasteboard: pasteboard, sequence: 41)

        XCTAssertEqual(view.draggingEntered(drag), .copy)
        let afterEntering = drag.pasteboardReads
        for _ in 0..<20 { XCTAssertEqual(view.draggingUpdated(drag), .copy) }
        XCTAssertEqual(drag.pasteboardReads, afterEntering, "twenty moves of one drag read nothing more")

        let next = CountingDrag(pasteboard: pasteboard, sequence: 42)
        XCTAssertEqual(view.draggingUpdated(next), .copy)
        XCTAssertGreaterThan(next.pasteboardReads, 0, "a new drag is asked afresh")
    }

    // MARK: - Dragging a card out (F-020, F-038)

    /// A card dragged into a Finder folder on the same disk used to move the
    /// user's original, because Move was on offer and Finder prefers it
    /// there. Copy is the default now; ⌘, Finder's own way to ask for a move,
    /// puts Move (and the Trash) back. Nothing is offered inside the app.
    func testDragOutCopiesUnlessCommandIsHeld() {
        typealias Drag = ShelfDragSource.DragView
        XCTAssertEqual(Drag.operationMask(context: .outsideApplication, modifiers: []), [.copy, .link])
        XCTAssertEqual(Drag.operationMask(context: .outsideApplication, modifiers: [.shift]), [.copy, .link])
        let held = Drag.operationMask(context: .outsideApplication, modifiers: [.command])
        XCTAssertTrue(held.contains(.move))
        XCTAssertTrue(held.contains(.generic), "AppKit narrows a ⌘-drag to Generic at the destination")
        XCTAssertTrue(held.contains(.delete), "⌘-dragging onto the Trash still works")
        XCTAssertEqual(Drag.operationMask(context: .withinApplication, modifiers: []), [])
        XCTAssertEqual(Drag.operationMask(context: .withinApplication, modifiers: [.command]), [])
    }

    /// The drag lifts the card's own thumbnail from where it sits on the card,
    /// so a grab in the middle of the picture keeps the pointer in the middle
    /// of it. It used to be a 48 pt file icon pinned to the card's corner.
    /// The box is the thumbnail's frame in the card, top-left origin as
    /// SwiftUI measures it; the answer is in the drag view's own, unflipped
    /// coordinates.
    func testDragFrameSitsOverTheThumbnail() {
        typealias Drag = ShelfDragSource.DragView
        let bounds = NSRect(x: 0, y: 0, width: 86, height: 92)
        let box = CGRect(x: 9, y: 8, width: 68, height: 40)

        XCTAssertEqual(
            Drag.dragFrame(index: 0, thumbnail: box, imageSize: NSSize(width: 68, height: 40), bounds: bounds),
            NSRect(x: 9, y: 44, width: 68, height: 40)
        )
        XCTAssertEqual(
            Drag.dragFrame(index: 1, thumbnail: box, imageSize: NSSize(width: 68, height: 40), bounds: bounds),
            NSRect(x: 18, y: 35, width: 68, height: 40),
            "a group still fans out by the same step"
        )
        XCTAssertEqual(
            Drag.dragFrame(index: 0, thumbnail: box, imageSize: NSSize(width: 64, height: 64), bounds: bounds),
            NSRect(x: 23, y: 44, width: 40, height: 40),
            "a square icon is fitted the way the card fits it, centred in the box"
        )
        XCTAssertEqual(
            Drag.dragFrame(index: 0, thumbnail: .zero, imageSize: NSSize(width: 86, height: 92), bounds: bounds),
            bounds,
            "before the card has been measured, the card itself"
        )
    }

    /// Only a drop that may have taken the file away is followed up. A copy
    /// leaves the original where it was, and the card with it.
    func testOnlyADropThatMayHaveMovedTheFileIsFollowed() {
        let view = ShelfDragSource.DragView()
        let url = URL(fileURLWithPath: "/tmp/isla-moved.png")
        var moved: [[URL]] = []
        var presses: [Bool] = []
        view.onMoved = { moved.append($0) }
        view.onPress = { presses.append($0) }

        view.draggedURLs = [url]
        view.ended(with: .copy)
        XCTAssertEqual(moved, [])
        XCTAssertEqual(presses, [false], "the press ends with the drag either way")

        for operation: NSDragOperation in [.move, .generic, .delete] {
            view.draggedURLs = [url]
            view.ended(with: operation)
        }
        XCTAssertEqual(moved, [[url], [url], [url]])
        XCTAssertTrue(view.draggedURLs.isEmpty, "nothing is followed twice")
    }
}

/// A drag that counts how often its pasteboard is asked for.
@MainActor
private final class CountingDrag: NSObject, @preconcurrency NSDraggingInfo {
    private let pasteboard: NSPasteboard
    let draggingSequenceNumber: Int
    private(set) var pasteboardReads = 0

    init(pasteboard: NSPasteboard, sequence: Int) {
        self.pasteboard = pasteboard
        self.draggingSequenceNumber = sequence
    }

    var draggingPasteboard: NSPasteboard {
        pasteboardReads += 1
        return pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
