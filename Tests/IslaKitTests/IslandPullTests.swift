import XCTest
@testable import IslaKit

/// The vertical two-finger swipe that opens and closes the panel (owner,
/// 2026-10-25; spec §19.16 amendment), held on the pure engine: what the
/// first 10 pt decide, which way is down under either scrolling direction,
/// where a pull may start, what commits, and the momentum that never acts.
final class IslandPullTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    /// One event. `down` is the fingers' travel toward the bottom of the
    /// trackpad; the delta AppKit reports is derived from it and from the
    /// scrolling direction, so a test states the hand, not the sign.
    private func scroll(
        down: CGFloat = 0, sideways dx: CGFloat = 0, _ phase: ScrollSample.Phase = .changed,
        momentum: ScrollSample.Phase = .none, natural: Bool = true, precise: Bool = true,
        at time: TimeInterval = 0
    ) -> PageScroll {
        PageScroll(
            deltaX: dx, deltaY: natural ? down : -down, phase: phase, momentumPhase: momentum,
            precise: precise, time: time, invertedFromDevice: natural
        )
    }

    private let shut = IslandPull.Context(isOpen: false, region: .island)

    private func open(on surface: Surface = .player, region: IslandPull.Region = .header) -> IslandPull.Context {
        IslandPull.Context(isOpen: true, region: region, surface: surface)
    }

    /// A gesture from its began to its release: `steps` events of `each`
    /// points down, 10 ms apart, then the lift `lift` seconds after the last.
    private func play(
        _ context: IslandPull.Context, each: CGFloat, steps: Int, natural: Bool = true,
        lift: TimeInterval = 0.01, phase end: ScrollSample.Phase = .ended
    ) -> (pull: IslandPull, outcomes: [IslandPull.Outcome]) {
        var pull = IslandPull()
        var outcomes = [pull.handle(scroll(.began, natural: natural, at: 0), context)]
        for step in 1...steps {
            outcomes.append(pull.handle(scroll(down: each, natural: natural, at: Double(step) * 0.01), context))
        }
        outcomes.append(pull.handle(scroll(end, natural: natural, at: Double(steps) * 0.01 + lift), context))
        return (pull, outcomes)
    }

    // MARK: Opening

    func testADownSwipeOverTheShutIslandOpensWhatAClickWould() {
        let (_, outcomes) = play(shut, each: 6, steps: 8)
        XCTAssertEqual(outcomes.first, .pass, "the began decides nothing")
        XCTAssertEqual(outcomes[1], .pass, "6 pt is under the 10 pt lock: still the page's")
        guard case .stretch(let first) = outcomes[2] else { return XCTFail("past the lock the pull tracks: \(outcomes[2])") }
        XCTAssertGreaterThan(first, 0, "pulled down, the island grows")
        XCTAssertLessThan(first, IslandPull.stretchLimit)
        XCTAssertEqual(outcomes.last, .open(nil), "nil is what a click on the island opens: `openTarget`")
    }

    func testTheBubbleOpensTheTray() {
        let (_, outcomes) = play(IslandPull.Context(isOpen: false, region: .bubble), each: 6, steps: 8)
        XCTAssertEqual(outcomes.last, .open(.tray), "the bubble's click opens the tray, and so does its swipe")
    }

    func testDownIsTheFingersUnderEitherScrollingDirection() {
        XCTAssertEqual(play(shut, each: 6, steps: 8, natural: true).outcomes.last, .open(nil))
        XCTAssertEqual(play(shut, each: 6, steps: 8, natural: false).outcomes.last, .open(nil),
                       "natural scrolling off flips the delta, not the hand")
        // And up over the shut island is not a way to open it, either way round.
        XCTAssertEqual(play(shut, each: -6, steps: 8, natural: true).outcomes.last, .pass)
        XCTAssertEqual(play(shut, each: -6, steps: 8, natural: false).outcomes.last, .pass)
        XCTAssertEqual(IslandPull.fingersDown(scroll(down: 4, natural: true)), 4)
        XCTAssertEqual(IslandPull.fingersDown(scroll(down: 4, natural: false)), 4)
    }

    func testAShortSlowPullSettlesBackAndAFlickCommits() {
        // 12 pt, held still for a quarter of a second before lifting: no speed
        // left, and short of the commit distance.
        XCTAssertEqual(play(shut, each: 6, steps: 2, lift: 0.25).outcomes.last, .settle)
        // The same 12 pt thrown: the projection carries it past.
        XCTAssertEqual(play(shut, each: 6, steps: 2, lift: 0.005).outcomes.last, .open(nil))
        // Fingers that lift as a cancel never commit, however far they went.
        XCTAssertEqual(play(shut, each: 10, steps: 6, phase: .cancelled).outcomes.last, .settle)
    }

    func testPullingBackBeforeLiftingCancels() {
        var pull = IslandPull()
        _ = pull.handle(scroll(.began, at: 0), shut)
        for step in 1...6 { _ = pull.handle(scroll(down: 8, at: Double(step) * 0.01), shut) }
        // Back up past where it began, quickly.
        for step in 7...14 { _ = pull.handle(scroll(down: -8, at: Double(step) * 0.01), shut) }
        XCTAssertEqual(pull.handle(scroll(.ended, at: 0.15), shut), .settle)
    }

    func testTheStretchIsARubberBandThatNeverReachesItsLimit() {
        var pull = IslandPull()
        _ = pull.handle(scroll(.began), shut)
        var last: CGFloat = 0
        for step in 1...40 {
            guard case .stretch(let points) = pull.handle(scroll(down: 10, at: Double(step) * 0.01), shut) else {
                return XCTFail("tracking at step \(step)")
            }
            XCTAssertGreaterThanOrEqual(points, last)
            XCTAssertLessThan(points, IslandPull.stretchLimit)
            last = points
        }
    }

    func testASidewaysLockNeverOpens() {
        var pull = IslandPull()
        XCTAssertEqual(pull.handle(scroll(.began), shut), .pass)
        XCTAssertEqual(pull.handle(scroll(down: 3, sideways: 11), shut), .pass, "more sideways: the pages' or nobody's")
        // However far down the rest of it goes.
        for step in 1...10 { XCTAssertEqual(pull.handle(scroll(down: 20, at: Double(step) * 0.01), shut), .pass) }
        XCTAssertEqual(pull.handle(scroll(.ended, at: 0.11), shut), .pass)
        XCTAssertEqual(pull.stage, .idle)
    }

    func testAGestureThatBeganOffTheIslandNeverOpens() {
        let outside = IslandPull.Context(isOpen: false, region: .outside)
        XCTAssertEqual(play(outside, each: 10, steps: 6).outcomes, Array(repeating: .pass, count: 8))
    }

    func testAWheelNeverPulls() {
        var pull = IslandPull()
        for _ in 0..<10 {
            XCTAssertEqual(pull.handle(scroll(down: 30, .none, precise: false), shut), .pass)
        }
    }

    func testTheLockScreenRefusesAsAClickDoes() {
        let locked = IslandPull.Context(isOpen: false, locked: true, region: .island)
        let (_, outcomes) = play(locked, each: 6, steps: 8)
        XCTAssertEqual(outcomes.last, .refuse, "the shake a click gets over the shield")
        for outcome in outcomes {
            if case .stretch(let points) = outcome { XCTAssertEqual(points, 0, "nothing stretches toward an open that cannot happen") }
        }
    }

    func testTheSettingOffIgnoresEverything() {
        var off = shut
        off.enabled = false
        XCTAssertEqual(play(off, each: 10, steps: 6).outcomes, Array(repeating: .pass, count: 8))
        var openOff = open()
        openOff.enabled = false
        XCTAssertEqual(play(openOff, each: -10, steps: 6).outcomes, Array(repeating: .pass, count: 8))
    }

    // MARK: Closing

    func testAnUpSwipeOnTheHeaderClosesFromEverySurface() {
        for surface in Surface.allCases {
            let (_, outcomes) = play(open(on: surface), each: -6, steps: 8)
            XCTAssertEqual(outcomes.last, .close, "\(surface)")
            guard case .stretch(let points) = outcomes[2] else { return XCTFail("\(surface) tracks") }
            XCTAssertLessThan(points, 0, "pushed up, the panel draws in")
        }
    }

    func testAnUpSwipeOnThePlayerClosesFromAnywhereOnIt() {
        XCTAssertEqual(play(open(on: .player, region: .body), each: -6, steps: 8).outcomes.last, .close,
                       "nothing on the player scrolls up or down")
    }

    func testAnUpSwipeOverContentThatScrollsIsTheContents() {
        // The Shelf's grid, Clipboard's list, the lyric stage, Settings' form,
        // Translate's text: a vertical scroll there is the reader's, always.
        for surface in [Surface.tray, .clipboard, .stage, .settings, .translate, .drop, .welcome] {
            XCTAssertEqual(play(open(on: surface, region: .body), each: -6, steps: 8).outcomes.last, .pass, "\(surface)")
            XCTAssertFalse(IslandPull.closesFromBody(surface), "\(surface)")
        }
        XCTAssertTrue(IslandPull.closesFromBody(.player))
    }

    func testDownOnTheOpenPanelDoesNothing() {
        XCTAssertEqual(play(open(), each: 6, steps: 8).outcomes.last, .pass, "open is open: down asks nothing")
    }

    func testNothingStartsWhileThePagesTravel() {
        var travelling = open(region: .header)
        travelling.travelling = true
        XCTAssertEqual(play(travelling, each: -10, steps: 6).outcomes.last, .pass)
    }

    // MARK: Momentum

    func testMomentumNeverActsAndAfterAPullIsSwallowed() {
        // The glide of a scroll that began on Clipboard's list, arriving over
        // the header: momentum alone never closes.
        var pull = IslandPull()
        for step in 0..<10 {
            XCTAssertEqual(pull.handle(scroll(down: -30, momentum: step == 0 ? .began : .changed), open()), .pass)
        }
        // And the glide after a pull that opened the panel is the pull's: it
        // must not scroll the page that just opened under it.
        let played = play(shut, each: 8, steps: 6)
        var opened = played.pull
        XCTAssertEqual(played.outcomes.last, .open(nil))
        XCTAssertEqual(opened.handle(scroll(down: 12, momentum: .began), open(on: .tray, region: .body)), .swallow)
        XCTAssertEqual(opened.handle(scroll(down: 6, momentum: .changed), open(on: .tray, region: .body)), .swallow)
        XCTAssertEqual(opened.handle(scroll(momentum: .ended), open(on: .tray, region: .body)), .swallow)
        // Until the next gesture lands.
        XCTAssertEqual(opened.handle(scroll(.mayBegin), open()), .pass)
        XCTAssertEqual(opened.stage, .idle)
    }

    func testAPullAfterAPageTurnStartsFresh() {
        // A sideways swipe locked on the header, then an up-swipe there.
        var pull = IslandPull()
        _ = pull.handle(scroll(.began), open())
        _ = pull.handle(scroll(sideways: -12), open())
        _ = pull.handle(scroll(.ended), open())
        _ = pull.handle(scroll(sideways: -20, momentum: .began), open())
        for step in 1...8 { _ = pull.handle(scroll(down: -6, at: Double(step) * 0.01), open()) }
        XCTAssertEqual(pull.handle(scroll(.ended, at: 0.09), open()), .pass, "changed events with no began are nobody's")
        // A fresh gesture does close.
        _ = pull.handle(scroll(.began, at: 1), open())
        for step in 1...8 { _ = pull.handle(scroll(down: -6, at: 1 + Double(step) * 0.01), open()) }
        XCTAssertEqual(pull.handle(scroll(.ended, at: 1.09), open()), .close)
    }
}

/// What the controller does with a pull's verdict: the click's own open and
/// close, played out with no trackpad, no panel and no pointer.
@MainActor
final class IslandPullControllerTests: XCTestCase {
    private func harness() throws -> (vm: NotchViewModel, controller: NotchController) {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.pointer.buttonsHeld = { false }
        controller.attachForTesting(viewModel: vm, rootView: root)
        controller.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        controller.updateMomentsQuiet = { false }
        controller.updateScreenLocked = { false }
        controller.availableUpdate = { nil }
        controller.installerState = { (.idle, nil) }
        controller.quitApp = { XCTFail("a test never quits") }
        return (vm, controller)
    }

    /// The close folds one run-loop pass after it is asked for (`setOpen`).
    private func spin(until condition: () -> Bool, within seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testTheKeyIsStable() {
        XCTAssertEqual(NotchViewModel.swipeToOpenKey, "island.swipeToOpen")
        XCTAssertEqual(SettingsRowID.swipeToOpen.key, NotchViewModel.swipeToOpenKey)
        XCTAssertEqual(SettingsRowID.swipeToOpen.kind, .toggle)
        XCTAssertTrue(SettingsTable.rows(for: .general).contains(.swipeToOpen), "in General, beside Open on Hover")
    }

    func testAPullOpensWhatAClickWouldAndAPushClosesItPinnedOrNot() throws {
        let (vm, controller) = try harness()
        controller.islandPulledOpen()
        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(vm.surface, vm.openTarget)
        controller.islandPulledShut()
        spin(until: { !vm.isOpen })
        XCTAssertFalse(vm.isOpen)

        controller.islandPulledOpen(opening: .tray)
        XCTAssertEqual(vm.surface, .tray, "the bubble's pull opens the tray")
        vm.isPinnedOpen = true
        controller.islandPulledShut()
        XCTAssertFalse(vm.isPinnedOpen, "the pin goes at once")
        spin(until: { !vm.isOpen })
        XCTAssertFalse(vm.isOpen, "the gesture is explicit: a pinned panel closes too")
    }

    func testOverTheShieldAPullShakesAndOpensNothing() throws {
        let (vm, controller) = try harness()
        vm.isLockedPresentation = true
        let before = vm.lockedHoverNudges
        controller.islandPulledOpen()
        XCTAssertFalse(vm.isOpen)
        XCTAssertEqual(vm.lockedHoverNudges, before + 1)
    }
}
