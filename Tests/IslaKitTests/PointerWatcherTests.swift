import AppKit
import XCTest
@testable import IslaKit

@MainActor
final class PointerWatcherTests: XCTestCase {
    /// `start()` used to only schedule a Timer at the idle interval
    /// (125 ms), which does not fire until its first interval has elapsed —
    /// leaving `onInteractiveChange` uncalled, and the panel it drives
    /// click-through, for that whole stretch right after every build or
    /// rebuild. `start()` must sample the pointer synchronously so
    /// interactivity is correct from the first frame.
    func testStartReportsInteractivityImmediatelyWithoutWaitingForTheTimer() {
        let watcher = PointerWatcher()
        var receivedValues: [Bool] = []
        // Large enough to contain the pointer wherever the test runner's
        // cursor actually sits, so the assertion does not depend on real
        // screen geometry.
        watcher.interactiveRect = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
        watcher.onInteractiveChange = { receivedValues.append($0) }

        watcher.start()
        defer { watcher.stop() }

        XCTAssertEqual(receivedValues, [true])
    }
}
