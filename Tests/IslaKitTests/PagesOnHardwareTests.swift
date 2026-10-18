import AppKit
import XCTest
@testable import IslaKit

/// What the owner found on the first use of the pages on hardware
/// (2026-10-18, spec §19.16's last amendment): a dot to a shorter page folded
/// the panel under the pointer that pressed it, a quick sideways swipe on a
/// full Shelf scrolled its strip instead of turning the page, the three tools
/// changed size as they turned, and Settings had no way out but the gear lit.
@MainActor
final class PagesOnHardwareTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    override func tearDown() {
        LabLocalization.use("en")
        super.tearDown()
    }

    /// Two samples make a verdict; see `PointerWatcherTests.sample`.
    private func sample(_ watcher: PointerWatcher, times: Int) {
        for _ in 0..<times { watcher.start() }
    }

    // MARK: - A panel that shrinks under the pointer

    /// The body shrinks out from under a pointer resting on it. The body it
    /// left holds the panel while the pointer stays in it; once the pointer
    /// reaches the new body, the old one holds nothing.
    func testABodyThatShrinksUnderTheRestingPointerKeepsThePanel() {
        let watcher = PointerWatcher()
        defer { watcher.stop() }
        var changes: [Bool] = []
        var point = CGPoint(x: 0, y: -300)
        watcher.location = { point }
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        watcher.onChange = { changes.append($0) }
        let tall = CGRect(x: -300, y: -330, width: 600, height: 340)
        let short = CGRect(x: -200, y: -230, width: 400, height: 240)
        watcher.closeRect = tall
        watcher.setInside(true)
        sample(watcher, times: 3)
        XCTAssertEqual(changes, [], "on the body")

        watcher.closeRect = short
        XCTAssertFalse(short.contains(point), "the case at hand: the new body ends above the pointer")
        sample(watcher, times: 3)
        XCTAssertEqual(changes, [], "the pointer has not moved, and the panel stays")

        point = CGPoint(x: 0, y: -200)
        sample(watcher, times: 2)
        point = CGPoint(x: 0, y: -300)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "once on the new body, the old one holds nothing")
    }

    /// Leaving the body it shrank from is leaving.
    func testLeavingTheBodyItShrankFromCloses() {
        let watcher = PointerWatcher()
        defer { watcher.stop() }
        var changes: [Bool] = []
        var point = CGPoint(x: 0, y: -300)
        watcher.location = { point }
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        watcher.onChange = { changes.append($0) }
        watcher.closeRect = CGRect(x: -300, y: -330, width: 600, height: 340)
        watcher.setInside(true)
        watcher.closeRect = CGRect(x: -200, y: -230, width: 400, height: 240)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [])

        point = CGPoint(x: 0, y: -1_000)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false])
    }

    /// A pointer that was not on the old body is not held by it: a shrink is
    /// not a way of reaching the panel.
    func testAShrinkHoldsOnlyAPointerThatWasOnTheBody() {
        let watcher = PointerWatcher()
        defer { watcher.stop() }
        var changes: [Bool] = []
        let point = CGPoint(x: 0, y: -1_000)
        watcher.location = { point }
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        watcher.onChange = { changes.append($0) }
        watcher.closeRect = CGRect(x: -300, y: -330, width: 600, height: 340)
        watcher.setInside(true)
        watcher.closeRect = CGRect(x: -200, y: -230, width: 400, height: 240)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false])
    }

    /// The whole route at the controller: on Clipboard, the pointer presses
    /// Music's dot, 306 pt down; Music's body ends at 214. The panel used to
    /// fold `closeDelay` after the press.
    func testADotToAShorterPageLeavesThePanelOpenUnderThePointer() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isOpen = true
        vm.turnPage(to: .clipboard)
        controller.refreshOpenRects(bodySettled: true, animated: false)

        let body = vm.openBodySize
        let dot = PageDotsLayout.centres(bodySize: body)[0]
        let content = vm.geometry.contentScreenRect(for: body)
        let point = CGPoint(x: content.minX + dot.x, y: content.maxY - dot.y)
        controller.pointer.location = { point }
        controller.pointerLocation = { point }
        var changes: [Bool] = []
        controller.pointer.onChange = { changes.append($0) }
        controller.pointer.openDelay = 0
        controller.pointer.closeDelay = 0
        defer { controller.pointer.stop() }
        controller.pointer.setInside(true)
        for _ in 0..<2 { controller.pointer.start() }
        XCTAssertEqual(changes, [], "the pointer is on Music's dot")

        vm.travel(to: .player, reduceMotion: true)
        controller.refreshOpenRects(bodySettled: true, animated: false)
        XCTAssertFalse(
            vm.geometry.hoverRect(for: vm.openBodySize).contains(point),
            "the case at hand: Music ends above the dots it was turned from"
        )
        for _ in 0..<3 { controller.pointer.start() }
        XCTAssertEqual(changes, [], "the panel stays open under the pointer that pressed the dot")
        XCTAssertTrue(vm.isOpen)
    }

    /// A watcher holding the shrink for rects away from the screen's origin,
    /// where real ones are: the built-in display's notch sits at its top, and
    /// (0, 0) is the bottom-left corner.
    private func heldWatcher(
        at start: CGPoint, changes: @escaping (Bool) -> Void
    ) -> (PointerWatcher, (CGPoint) -> Void) {
        let watcher = PointerWatcher()
        var point = start
        watcher.location = { point }
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        watcher.onChange = changes
        watcher.closeRect = Self.tallBody
        watcher.interactiveRect = Self.tallBody
        watcher.setInside(true)
        watcher.closeRect = Self.shortBody
        watcher.interactiveRect = Self.shortBody
        return (watcher, { point = $0 })
    }

    private static let tallBody = CGRect(x: 500, y: 600, width: 600, height: 340)
    private static let shortBody = CGRect(x: 600, y: 700, width: 400, height: 240)

    /// The hold is the body the panel shrank from and nothing more. It began
    /// as `.zero`, and a union with `.zero` reaches out to the screen's
    /// origin: on the built-in display the panel then held a pointer anywhere
    /// left of and below the old body (review 5, S1). Here the pointer leaves
    /// the old body down and to the left while coming no farther from the new
    /// one, and the panel folds.
    func testTheHoldReachesNoFurtherThanTheBodyItShrankFrom() {
        var changes: [Bool] = []
        let (watcher, move) = heldWatcher(at: CGPoint(x: 510, y: 610)) { changes.append($0) }
        defer { watcher.stop() }
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [], "held in the old body's far corner")

        let outside = CGPoint(x: 495, y: 700)
        XCTAssertFalse(Self.tallBody.contains(outside))
        move(outside)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "off the old body is off the panel")
    }

    /// The hold is for a pointer that has not gone anywhere. One that moves
    /// away from the new body has: inside the old body is now click-through,
    /// and from Settings back to Music the person could work in the browser
    /// under it while Music stood open over them (review 5, S3).
    func testTheHoldEndsWhenThePointerHeadsAway() {
        var changes: [Bool] = []
        let (watcher, move) = heldWatcher(at: CGPoint(x: 800, y: 650)) { changes.append($0) }
        defer { watcher.stop() }
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [])

        let away = CGPoint(x: 560, y: 610)
        XCTAssertTrue(Self.tallBody.contains(away), "still inside the old body")
        move(away)
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "going away is leaving")
    }

    /// A pointer on its way up to the new body is held all the way, with 6 pt
    /// of slack for a hand that trembles, and the new body takes it from
    /// there.
    func testThePointerMayHeadForTheNewBody() {
        var changes: [Bool] = []
        let (watcher, move) = heldWatcher(at: CGPoint(x: 800, y: 650)) { changes.append($0) }
        defer { watcher.stop() }
        for point in [CGPoint(x: 800, y: 680), CGPoint(x: 790, y: 690), CGPoint(x: 800, y: 686)] {
            move(point)
            sample(watcher, times: 2)
        }
        XCTAssertEqual(changes, [], "closer, closer, and 4 pt back: still on its way")

        move(CGPoint(x: 800, y: 720))
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [], "on the new body")
        move(CGPoint(x: 800, y: 650))
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false], "and the old body holds nothing after that")
    }

    /// A press where the old body was is a click in whatever app is under it,
    /// since that area no longer takes clicks: the person is working there.
    func testAPressOffThePanelEndsTheHold() {
        var changes: [Bool] = []
        let (watcher, _) = heldWatcher(at: CGPoint(x: 800, y: 650)) { changes.append($0) }
        defer { watcher.stop() }
        var held = false
        watcher.buttonsHeld = { held }
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [])

        held = true
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false])
    }

    /// A click or a scroll in the app under where the old body was is seen
    /// by a monitor that stands only while a hold does, not by the sampler
    /// catching a button down: resting, it samples every 125 ms, and a tap to
    /// click is shorter than that (re-review 6, F1).
    func testAPressElsewhereSeenByTheMonitorEndsTheHold() {
        var changes: [Bool] = []
        var installs = 0
        var removals = 0
        var pressed: (@Sendable () -> Void)?
        let watcher = PointerWatcher()
        watcher.watchPressesElsewhere = { handler in
            installs += 1
            pressed = handler
            return NSObject()
        }
        watcher.stopWatchingPresses = { _ in removals += 1 }
        let point = CGPoint(x: 800, y: 650)
        watcher.location = { point }
        watcher.openDelay = 0
        watcher.closeDelay = 0
        watcher.isPanelOpen = { true }
        watcher.onChange = { changes.append($0) }
        watcher.closeRect = Self.tallBody
        watcher.setInside(true)
        XCTAssertEqual(installs, 0, "no hold, no monitor")
        watcher.closeRect = Self.shortBody
        watcher.closeRect = CGRect(x: 650, y: 750, width: 300, height: 190)
        XCTAssertEqual(installs, 1, "one monitor however many shrinks")
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [])

        // From another thread, which is not promised either way: the hold
        // ends on the main thread a pass later.
        let handler = pressed
        let delivered = expectation(description: "delivered off the main thread")
        DispatchQueue.global().async {
            handler?()
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(removals, 1, "the monitor goes with the hold")
        sample(watcher, times: 2)
        XCTAssertEqual(changes, [false])
        watcher.stop()
        XCTAssertEqual(removals, 1)
    }

    /// Reaching the new body, or the watcher stopping, takes the monitor away.
    func testTheMonitorStandsOnlyWhileTheHoldDoes() {
        var removals = 0
        let watcher = PointerWatcher()
        watcher.watchPressesElsewhere = { _ in NSObject() }
        watcher.stopWatchingPresses = { _ in removals += 1 }
        var point = CGPoint(x: 800, y: 650)
        watcher.location = { point }
        watcher.isPanelOpen = { true }
        watcher.closeRect = Self.tallBody
        watcher.setInside(true)
        watcher.closeRect = Self.shortBody
        point = CGPoint(x: 800, y: 720)
        sample(watcher, times: 1)
        XCTAssertEqual(removals, 1, "on the new body")

        point = CGPoint(x: 800, y: 650)
        watcher.closeRect = Self.tallBody
        watcher.closeRect = Self.shortBody
        watcher.stop()
        XCTAssertEqual(removals, 2, "stopped")
    }

    /// What the monitor counts as working elsewhere: any press, and a scroll
    /// the person starts. Not the momentum of a page swipe made on the panel,
    /// which can still be arriving under the pointer as the body shrinks.
    func testOnlyAScrollThePersonStartsEndsTheHold() {
        XCTAssertTrue(PointerWatcher.startsAScroll(phase: [], momentum: []), "a mouse wheel")
        XCTAssertTrue(PointerWatcher.startsAScroll(phase: .began, momentum: []), "fingers down in another app")
        XCTAssertFalse(PointerWatcher.startsAScroll(phase: .changed, momentum: []))
        XCTAssertFalse(PointerWatcher.startsAScroll(phase: [], momentum: .changed), "momentum")
        XCTAssertFalse(PointerWatcher.startsAScroll(phase: [], momentum: .began))
    }

    /// The controller's own check — the one a dropped keyboard runs 0.6 s
    /// later — counts the hold too. On Clipboard with the search field
    /// claimed, Music's dot drops the keyboard; the check found the pointer
    /// below Music's body and folded the island, the owner's bug by another
    /// door (review 5, S2).
    func testADotThatDropsTheKeyboardLeavesThePanelOpen() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isOpen = true
        vm.turnPage(to: .clipboard)
        controller.refreshOpenRects(bodySettled: true, animated: false)
        let content = vm.geometry.contentScreenRect(for: vm.openBodySize)
        let dot = PageDotsLayout.centres(bodySize: vm.openBodySize)[0]
        let point = CGPoint(x: content.minX + dot.x, y: content.maxY - dot.y)
        controller.pointer.location = { point }
        controller.pointerLocation = { point }
        controller.pointer.closeDelay = 0
        defer { controller.pointer.stop() }
        controller.pointer.setInside(true)
        controller.pointer.start()

        vm.travel(to: .player, reduceMotion: true)
        controller.refreshOpenRects(bodySettled: true, animated: false)
        controller.setKeyboard(false)
        let settled = expectation(description: "the check has run")
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.pointerAwayCollapseDelay + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3)

        XCTAssertTrue(vm.isOpen, "the panel stays open under the pointer that pressed the dot")
        XCTAssertTrue(controller.pointer.isInside)
    }

    /// And leaving after the dot still folds it, wherever the panel sits on
    /// the screen.
    func testLeavingAfterADotFoldsThePanel() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isOpen = true
        vm.turnPage(to: .clipboard)
        controller.refreshOpenRects(bodySettled: true, animated: false)
        let content = vm.geometry.contentScreenRect(for: vm.openBodySize)
        let dot = PageDotsLayout.centres(bodySize: vm.openBodySize)[0]
        var point = CGPoint(x: content.minX + dot.x, y: content.maxY - dot.y)
        controller.pointer.location = { point }
        controller.pointerLocation = { point }
        controller.pointer.openDelay = 0
        controller.pointer.closeDelay = 0
        var changes: [Bool] = []
        controller.pointer.onChange = { changes.append($0) }
        defer { controller.pointer.stop() }
        controller.pointer.setInside(true)
        controller.pointer.start()
        vm.travel(to: .player, reduceMotion: true)
        controller.refreshOpenRects(bodySettled: true, animated: false)
        for _ in 0..<2 { controller.pointer.start() }
        XCTAssertEqual(changes, [])

        point = CGPoint(x: content.minX - 200, y: content.minY - 200)
        for _ in 0..<2 { controller.pointer.start() }
        XCTAssertEqual(changes, [false])
    }

    // MARK: - One size for the three tools

    /// Shelf, Clipboard and Translate share one body at every width and
    /// notch: the panel's width and Clipboard's height. Music keeps its own;
    /// the stage and Settings stay 400.
    func testTheThreeToolsShareOneSize() {
        for bodyWidth in [CGFloat(480), 560, 620] {
            for notchWidth in [CGFloat(180), 185, 200, 220, 240] {
                for notchHeight in [CGFloat(24), 32, 38] {
                    let notch = CGSize(width: notchWidth, height: notchHeight)
                    func size(_ surface: Surface) -> CGSize {
                        SurfaceLayout.bodySize(for: surface, bodyWidth: bodyWidth, notch: notch)
                    }
                    let at = "\(bodyWidth), notch \(notchWidth) × \(notchHeight)"
                    let shared = CGSize(width: bodyWidth, height: SurfaceLayout.y(316, notchHeight: notchHeight))
                    XCTAssertEqual(size(.tray), shared, at)
                    XCTAssertEqual(size(.clipboard), shared, at)
                    XCTAssertEqual(size(.translate), shared, at)
                    XCTAssertEqual(size(.player).height, SurfaceLayout.y(214, notchHeight: notchHeight), at)
                    XCTAssertEqual(size(.settings).height, SurfaceLayout.y(400, notchHeight: notchHeight), at)
                    // In English the tray's header fits beside every notch at
                    // the narrowest panel (Russian's one exception is held in
                    // `HeaderNotchBandTests.testTheTrayIsThePanelsWidth`).
                    XCTAssertGreaterThanOrEqual(bodyWidth, ShelfLayout.bodyWidth(notchWidth: notchWidth), at)
                }
            }
        }
    }

    /// Translate's two cards grow to fill the taller body, keeping the 24 pt
    /// under them they had.
    func testTranslatesCardsFillTheSharedHeight() {
        XCTAssertEqual(TranslateLayout.contentHeight, 262)
        XCTAssertEqual(TranslateLayout.cardHeight, 192)
        XCTAssertEqual(TranslateLayout.contentHeight - TranslateLayout.cardTop - TranslateLayout.cardHeight, 24)
    }

    // MARK: - Sideways always turns the page

    /// A full Shelf no longer scrolls sideways first: a sideways swipe over it
    /// turns the page from the first event that decides.
    func testASidewaysSwipeOnAFullShelfTurnsThePage() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.pageTravel.clock = ManualPageClock()
        vm.isOpen = true
        vm.open(.tray)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = isolated.stores.shelf
        shelf.requestThumbnail = { _, done in done(nil) }
        shelf.makeBookmark = { _ in nil }
        let files = (0..<12).map { folder.appendingPathComponent("capture-\($0).png") }
        for file in files { FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)) }
        shelf.add(files)
        XCTAssertEqual(shelf.items.count, 12, "the case at hand: more than a row")
        func scroll(_ dx: CGFloat, _ phase: ScrollSample.Phase, at time: TimeInterval) -> PageScroll {
            PageScroll(deltaX: dx, deltaY: 0, phase: phase, time: time)
        }
        XCTAssertFalse(vm.pageScroll(scroll(-6, .began, at: 0), over: true), "the first 6 pt decide nothing yet")
        XCTAssertTrue(vm.pageScroll(scroll(-6, .changed, at: 0.01), over: true), "toward Clipboard: the pages take it")
        XCTAssertNotNil(vm.pageTravel.leg)
    }

    // MARK: - The gear and its way back

    /// On a page the gear is Settings; on Settings it is a close button that
    /// goes back, unlit and without the update badge Settings shows itself.
    func testOnSettingsTheGearIsACloseButton() {
        let page = HeaderGear(onSettings: false, hasUpdate: true)
        XCTAssertEqual(page.symbol, "gearshape")
        XCTAssertEqual(page.label, "Settings")
        XCTAssertTrue(page.badge)

        let settings = HeaderGear(onSettings: true, hasUpdate: true)
        XCTAssertEqual(settings.symbol, "xmark")
        XCTAssertEqual(settings.label, "Close Settings")
        XCTAssertFalse(settings.badge, "Settings shows the update itself")

        LabLocalization.use("ru")
        XCTAssertEqual(HeaderGear(onSettings: true, hasUpdate: false).label, "Закрыть настройки")
        XCTAssertEqual(HeaderGear(onSettings: false, hasUpdate: false).label, "Настройки")
    }
}
