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
        let watcher = PointerWatcher.withNoButtonHeld()
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
        let watcher = PointerWatcher.withNoButtonHeld()
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
        let watcher = PointerWatcher.withNoButtonHeld()
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

    /// With Open on Hover switched on, dragging a window by its title bar to
    /// the top edge to tile it — or dragging a text selection across the top
    /// of the screen — carried the pointer through the notch, and 50 ms later
    /// the panel unfolded over the very thing being dragged (J-020). The
    /// watcher only ever read where the pointer was, never whether a button
    /// was down, so a press that began in another app counted as a hover.
    func testAHeldButtonDoesNotCountAsArriving() {
        let watcher = PointerWatcher.withNoButtonHeld()
        var changes: [Bool] = []
        watcher.openRect = Self.everywhere
        watcher.closeRect = Self.everywhere
        watcher.openDelay = 0
        watcher.isPanelOpen = { false }
        var held = true
        watcher.buttonsHeld = { held }
        watcher.onChange = { changes.append($0) }
        defer { watcher.stop() }

        sample(watcher, times: 3)
        XCTAssertFalse(changes.contains(true), "a press from another app passing through the notch is not a hover")

        // Released with the pointer resting on the island: that is a hover
        // like any other, and it arrives.
        held = false
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [true], "once the button is up, the pointer standing there is asking")
    }

    /// Overshooting the scrubber or the Panel Width slider past the panel's
    /// edge used to make the window click-through mid-drag — interactivity was
    /// `isDragging() || interactiveRect.contains(point)`, and `isDragging`
    /// knew about file drags and menus only — and 0.32 s later the panel
    /// folded, taking the slider and its uncommitted change with it (F-028).
    /// A press that began on the panel now holds it, interactive and open,
    /// until the button comes up.
    func testAPressStartedInThePanelKeepsItInteractive() throws {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        var buttonDown = true
        panel.primaryButtonIsDown = { buttonDown }

        panel.sendEvent(try Self.mouse(.leftMouseDown, in: panel))
        XCTAssertTrue(panel.isPressLatched)
        XCTAssertTrue(panel.pressIsHeld())

        let watcher = PointerWatcher.withNoButtonHeld()
        var interactive: [Bool] = []
        var changes: [Bool] = []
        // Open, with the pointer dragged off it and nothing else holding it.
        watcher.interactiveRect = Self.nowhere
        watcher.openRect = Self.nowhere
        watcher.closeRect = Self.nowhere
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        watcher.isDragging = { panel.pressIsHeld() }
        watcher.onInteractiveChange = { interactive.append($0) }
        watcher.onChange = { changes.append($0) }
        watcher.setInside(true)
        defer { watcher.stop() }

        sample(watcher, times: 4)
        XCTAssertEqual(interactive, [true], "the panel keeps taking the drag it started")
        XCTAssertEqual(changes, [], "and does not fold under it")

        // Released outside the panel: the pointer being away means what it
        // always means again.
        buttonDown = false
        panel.sendEvent(try Self.mouse(.leftMouseUp, in: panel))
        XCTAssertFalse(panel.isPressLatched)
        sample(watcher, times: 2)
        XCTAssertEqual(interactive, [true, false])
        XCTAssertEqual(changes, [false])
    }

    /// The latch must not outlive the press when the release never reaches
    /// `sendEvent` — a control's own tracking loop dequeues the mouse-up
    /// itself. Left standing, the next press *anywhere* would read as one that
    /// began on the panel: the window would go interactive under a drag in
    /// another app, and a title bar dragged through the notch would be let in
    /// again by the very check that keeps it out.
    func testALostMouseUpDoesNotLeaveThePressLatched() throws {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        var buttonDown = true
        panel.primaryButtonIsDown = { buttonDown }

        panel.sendEvent(try Self.mouse(.leftMouseDown, in: panel))
        XCTAssertTrue(panel.pressIsHeld())

        // The button comes up, and the panel never hears of it.
        buttonDown = false
        XCTAssertFalse(panel.pressIsHeld())
        XCTAssertFalse(panel.isPressLatched, "a press that is over is forgotten, not merely masked")

        // A later press that began somewhere else is not this panel's.
        buttonDown = true
        XCTAssertFalse(panel.pressIsHeld())
    }

    // MARK: - Harness

    private static func mouse(_ type: NSEvent.EventType, in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

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
    /// A resting sampler ticks every 125 ms, and only a tick lets the panel
    /// take the mouse, so a pointer flicked from rest onto the island and
    /// clicked inside that window clicked the menu bar behind it (review
    /// 2026-10-18). A move into the band is now a tick of its own — the
    /// panel answers on the move, not on the next beat — and the monitor
    /// that reports it stands only while the sampler idles.
    func testAMoveTowardTheNotchIsAnsweredAtOnce() {
        let watcher = PointerWatcher.withNoButtonHeld()
        var installs = 0, removals = 0
        var moved: (@Sendable () -> Void)?
        watcher.watchMovement = { handler in
            installs += 1
            moved = handler
            return NSObject()
        }
        watcher.stopWatchingMovement = { _ in removals += 1 }
        watcher.warmZone = CGRect(x: 0, y: 700, width: 1_000, height: 200)
        watcher.coolZone = CGRect(x: 0, y: 650, width: 1_000, height: 250)
        watcher.interactiveRect = CGRect(x: 400, y: 850, width: 200, height: 50)
        var interactive: [Bool] = []
        watcher.onInteractiveChange = { interactive.append($0) }
        var point = CGPoint(x: 500, y: 100)
        watcher.location = { point }

        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(installs, 1, "idle, so the monitor stands")
        XCTAssertEqual(interactive, [false])

        // Elsewhere on the screen: no tick, however much the pointer moves.
        point = CGPoint(x: 900, y: 300)
        moved?()
        XCTAssertEqual(interactive, [false])
        XCTAssertEqual(removals, 0)

        // Onto the island: interactive on the move itself, and the sampler is
        // warm, so the monitor has nothing left to do.
        point = CGPoint(x: 500, y: 880)
        moved?()
        XCTAssertEqual(interactive, [false, true], "no wait for the timer")
        XCTAssertEqual(removals, 1, "warm, so the monitor goes")

        watcher.stop()
        XCTAssertEqual(removals, 1, "nothing left to remove")
        watcher.start()
        XCTAssertEqual(installs, 2, "idle again after a restart")
        watcher.stop()
        XCTAssertEqual(removals, 2, "and gone with the sampler")
    }

    private func sample(_ watcher: PointerWatcher, times: Int) {
        for _ in 0..<times { watcher.start() }
    }
}

extension PointerWatcher {
    /// A watcher that reads no real mouse button. The default asks
    /// `NSEvent.pressedMouseButtons`, and a button held anywhere on the Mac
    /// running the suite turns every arrival a test makes into a drag passing
    /// through: nineteen arrival tests failed together on 2026-10-18 while the
    /// owner was clicking, and passed on the rerun.
    static func withNoButtonHeld() -> PointerWatcher {
        let watcher = PointerWatcher()
        watcher.buttonsHeld = { false }
        return watcher
    }
}
