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

    /// Clicking the island a second time shuts the panel, and it stays shut —
    /// even with Open on Hover switched on, which is the configuration where it
    /// did not.
    ///
    /// The close tells the watcher the pointer is outside while `openRect` is
    /// still cut for the *open* body: it only shrinks back to the collapsed
    /// strip `collapseRectShrinkDelay` later, in `applyActiveRect`. The pointer
    /// that just clicked is inside that rect, so the next sample read an
    /// outside→inside transition, waited `openDelay`, and reopened the panel
    /// roughly 50 ms after the click that closed it — a visible fold and
    /// unfold, and no way to close the island by clicking it.
    func testAPanelClosedByHandIsNotReopenedByThePointerThatClosedIt() {
        let watcher = PointerWatcher()
        var changes: [Bool] = []
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.everywhere
        watcher.openDelay = 0
        watcher.closeDelay = 0
        // Already shut by the click; only the pointer's opinion is left.
        watcher.isPanelOpen = { false }
        watcher.onChange = { changes.append($0) }
        watcher.setInside(true)
        defer { watcher.stop() }

        watcher.closedByHand()
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [], "the click that shut the panel cannot reopen it")

        // The pointer walks off. Nothing to report: the panel is already shut.
        watcher.openRect = Self.nowhere
        watcher.closeRect = Self.nowhere
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [])

        // And comes back. That is a real arrival, and it opens again.
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.everywhere
        sample(watcher, times: 2)
        XCTAssertEqual(
            changes, [true],
            "a pointer that left and returned is asking for the panel again"
        )
    }

    /// Dragging a card out of the Shelf must not fold the panel it came from.
    ///
    /// The pointer leaves `closeRect` with the card, and until 2026-09-10 only
    /// the watcher's already-outside close path asked whether a drag was in
    /// flight. The departure itself did not, so 0.32 s after the pointer left,
    /// the panel folded and took the view the drag session was running from with
    /// it. It was masked while every click pinned the panel — `holdsOpen` refused
    /// the close — and a click leaves the panel unpinned now.
    func testADragOutOfThePanelKeepsItOpenUntilTheDragEnds() {
        let watcher = PointerWatcher()
        var changes: [Bool] = []
        // Open, with the pointer already off it: the card is on its way to the
        // Desktop.
        watcher.openRect = Self.nowhere
        watcher.closeRect = Self.nowhere
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        var dragging = true
        watcher.isDragging = { dragging }
        watcher.onChange = { changes.append($0) }
        watcher.setInside(true)
        defer { watcher.stop() }

        sample(watcher, times: 4)
        XCTAssertEqual(changes, [], "a drag in flight keeps the panel it came out of")

        // The card is dropped. Now the pointer being away means what it always
        // means.
        dragging = false
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "the drag ended with the pointer still away")
    }

    // MARK: - Harness

    /// Large enough to hold the pointer wherever the test runner's cursor
    /// actually sits, so no assertion here depends on real screen geometry.
    private static let everywhere = CGRect(
        x: -100_000, y: -100_000, width: 200_000, height: 200_000
    )
    /// And far enough off any display that the pointer is never in it.
    private static let nowhere = CGRect(x: -1_000_000, y: -1_000_000, width: 10, height: 10)

    /// Takes `times` synchronous samples.
    ///
    /// `tick()` is private and `start()` is the door the type already has to
    /// it — it re-arms the timer and then samples once, in line, which is what
    /// `testStartReportsInteractivityImmediatelyWithoutWaitingForTheTimer`
    /// exists to hold. Two samples make a verdict: the first records that the
    /// pointer is somewhere new, the second finds the dwell elapsed.
    private func sample(_ watcher: PointerWatcher, times: Int) {
        for _ in 0..<times { watcher.start() }
    }
}
