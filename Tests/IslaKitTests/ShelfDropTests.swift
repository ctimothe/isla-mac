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
}
