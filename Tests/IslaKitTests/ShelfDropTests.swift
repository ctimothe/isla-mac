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
