import Combine
import SwiftUI
import XCTest
@testable import IslaKit

/// The volume and brightness pop-up while the panel is open, and a held key
/// kept light (owner, 2026-10-25): the capsule under the panel
/// (`HUDStripLayout`, research `2026-10-25-hud-over-open-panel.md` option A),
/// the level kept out of the view model's publishes (`HUDLiveLevel`), and
/// readings coalesced to the latest (`LatestReadingMailbox`).
@MainActor
final class HUDStripTests: XCTestCase {

    private func reading(_ kind: HUDKind = .volume, _ level: Float = 0.5) -> HUDReading {
        HUDReading(kind: kind, level: level, muted: false, deviceSymbol: nil)
    }

    private func rig() throws -> (NotchController, NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        controller.hudFoldDelay = 0.15
        return (controller, vm, isolated)
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: Where it may show

    func testPlacementFollowsThePanelAndRefusesWhatItAlwaysRefused() {
        func place(
            open: Bool = false, drop: Bool = false, locked: Bool = false, asleep: Bool = false
        ) -> NotchController.HUDPlacement? {
            NotchController.hudPlacement(isOpen: open, isDropTargeted: drop, isLocked: locked, screensAsleep: asleep)
        }
        XCTAssertEqual(place(), .pill, "shut: the island's alert")
        XCTAssertEqual(place(open: true), .strip, "open: the capsule under the panel")
        XCTAssertNil(place(open: true, locked: true), "over the lock screen: nothing, as before")
        XCTAssertNil(place(locked: true))
        XCTAssertNil(place(open: true, asleep: true))
        XCTAssertNil(place(asleep: true))
        XCTAssertNil(place(open: true, drop: true), "a drag over the panel: the drop surface is the answer")
        XCTAssertNil(place(drop: true))
    }

    // MARK: Fit in the window

    /// The capsule is 6 pt under the body and 32 tall: 400 + 6 + 32 = 438 of
    /// the window's 444 on the tallest body at the reference notch.
    func testTheCapsuleFitsUnderTheTallestBodyInTheWindow() {
        let window = NotchMetrics.maximumWindow
        let tallest = NotchMetrics.tallestBody.height
        XCTAssertEqual(tallest + HUDStripLayout.gap + HUDStripLayout.height, 438)
        XCTAssertLessThanOrEqual(438, window.height)
        XCTAssertEqual(window.height - 438, 6, "six points to spare")
        XCTAssertEqual(HUDStripLayout.gap, 6)
        XCTAssertEqual(HUDStripLayout.height, 32)
    }

    /// Every surface, every panel width, every notch height the window can
    /// hold: the capsule is outside the body, inside the window, centred on
    /// the notch's axis, and no wider than the body less its two bottom
    /// corners.
    func testTheCapsuleFitsUnderEverySurfaceOnEveryNotch() {
        let window = NotchMetrics.maximumWindow
        // The synthetic notch is the menu bar's height (24 to 30); the physical
        // ones are 32 and 38 (14- and 16-inch at their scalings), and the window
        // has room for the capsule up to 44.
        XCTAssertEqual(HUDStripLayout.tallestNotchThatFits(windowHeight: window.height), 44)
        for notchHeight in stride(from: CGFloat(24), through: 44, by: 1) {
            for bodyWidth in [NotchMetrics.minimumBodyWidth, NotchMetrics.defaultBodyWidth, NotchMetrics.maximumBodyWidth] {
                let notch = CGSize(width: 185, height: notchHeight)
                for surface in NotchViewModel.Surface.allCases {
                    let body = SurfaceLayout.bodySize(for: surface, bodyWidth: bodyWidth, notch: notch)
                    let label = "\(surface) notch \(notchHeight) width \(bodyWidth)"
                    XCTAssertTrue(HUDStripLayout.fits(bodyHeight: body.height, windowHeight: window.height), label)
                    let frame = HUDStripLayout.frame(bodySize: body, bottomRadius: surface.bottomRadius, windowSize: window)
                    XCTAssertEqual(frame.minY, body.height + HUDStripLayout.gap, label)
                    XCTAssertLessThanOrEqual(frame.maxY, window.height, label)
                    XCTAssertEqual(frame.midX, window.width / 2, accuracy: 0.001, "on the notch's axis: \(label)")
                    XCTAssertEqual(frame.height, HUDStripLayout.height, label)
                    XCTAssertEqual(frame.width, HUDStripLayout.preferredWidth, label)
                    XCTAssertLessThanOrEqual(frame.width, body.width - 2 * surface.bottomRadius, "inside the corners: \(label)")
                }
            }
        }
        for notchHeight in [CGFloat(32), 38] {
            XCTAssertEqual(
                HUDStripLayout.tallestBody(notch: CGSize(width: 185, height: notchHeight), bodyWidth: 620),
                notchHeight + 362, "Settings and the stage are the tallest, 362 plus the notch"
            )
        }
    }

    /// Past the tallest notch that fits, the capsule stays inside the window
    /// rather than leaving it.
    func testAPastTheLimitNotchKeepsTheCapsuleInsideTheWindow() {
        let window = NotchMetrics.maximumWindow
        let body = SurfaceLayout.bodySize(for: .settings, bodyWidth: 620, notch: CGSize(width: 185, height: 50))
        XCTAssertFalse(HUDStripLayout.fits(bodyHeight: body.height, windowHeight: window.height))
        let frame = HUDStripLayout.frame(bodySize: body, bottomRadius: 44, windowSize: window)
        XCTAssertEqual(frame.maxY, window.height)
    }

    func testTheCapsuleNarrowsToStayInsideAShortBody() {
        XCTAssertEqual(HUDStripLayout.width(bodyWidth: 357, bottomRadius: 44), 220)
        XCTAssertEqual(HUDStripLayout.width(bodyWidth: 280, bottomRadius: 44), 192)
        XCTAssertEqual(HUDStripLayout.width(bodyWidth: 205, bottomRadius: 44), HUDStripLayout.minimumWidth)
    }

    func testTheWindowIsTheOneTheCapsuleWasCheckedAgainst() throws {
        let geometry = try LabGeometry.make()
        XCTAssertEqual(geometry.windowSize, NotchMetrics.maximumWindow, "never resized")
        XCTAssertEqual(NotchMetrics.maximumWindow.height, NotchGeometry.tallBodyHeight + 44)
    }

    // MARK: Showing, holding, folding

    func testAnOpenPanelShowsTheCapsuleAndNotThePill() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        controller.presentHUD(reading(.volume, 0.5))
        XCTAssertEqual(vm.hudStrip?.level, 0.5)
        XCTAssertNil(vm.hud, "never both")
        XCTAssertEqual(vm.activity, .none, "the capsule is not an island activity")
        XCTAssertEqual(vm.bodySize, vm.openBodySize, "and does not change the panel's size")
        controller.presentHUD(reading(.display, 0.25))
        XCTAssertEqual(vm.hudStrip?.symbol, HUDSymbol.display, "brightness the same")
        XCTAssertEqual(vm.hudStrip?.level, 0.25)
    }

    /// A press while it stands moves the bar and tells nobody else: the view
    /// model publishes on the arrival and the fold, and the level has its own
    /// store.
    func testRepeatedPressesMoveTheBarAndPublishNothingOnTheViewModel() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        controller.presentHUD(reading(.volume, 0.5))
        var viewModelChanges = 0
        var levelChanges = 0
        let watch = vm.objectWillChange.sink { viewModelChanges += 1 }
        let level = vm.hudLive.objectWillChange.sink { levelChanges += 1 }
        for step in 1...20 { controller.presentHUD(reading(.volume, 0.5 + Float(step) / 64)) }
        XCTAssertEqual(viewModelChanges, 0, "a held key re-runs nothing that watches the view model")
        XCTAssertEqual(levelChanges, 20, "the bar's own view hears each level")
        XCTAssertEqual(vm.hudStrip?.level, 0.5 + 20 / 64)
        controller.presentHUD(reading(.volume, 0.5 + 20 / 64))
        XCTAssertEqual(levelChanges, 20, "the same level again moves nothing")
        withExtendedLifetime((watch, level)) {}
    }

    func testThePillTooPublishesOnTheArrivalAndTheFoldOnly() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        var changes = 0
        let watch = vm.objectWillChange.sink { changes += 1 }
        controller.presentHUD(reading(.volume, 0.2))
        let arrival = changes
        XCTAssertGreaterThan(arrival, 0, "the arrival is heard")
        for step in 1...20 { controller.presentHUD(reading(.volume, 0.2 + Float(step) / 64)) }
        XCTAssertEqual(changes, arrival, "twenty presses, nothing more")
        XCTAssertEqual(vm.hud?.level, 0.2 + 20 / 64, "and the level is current")
        spin(until: { vm.hud == nil })
        XCTAssertNil(vm.hud)
        XCTAssertGreaterThan(changes, arrival, "the fold is heard")
        withExtendedLifetime(watch) {}
    }

    func testTheCapsuleFoldsAfterTheLastPressAndEachPressRestartsTheWait() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        let linger: TimeInterval = 0.5
        controller.hudFoldDelay = linger
        vm.isOpen = true
        controller.presentHUD(reading(.volume, 0.5))
        let first = Date()
        try await Task.sleep(for: .milliseconds(300))
        controller.presentHUD(reading(.volume, 0.5625))
        let last = Date()
        XCTAssertEqual(vm.hudStrip?.level, 0.5625)
        while Date().timeIntervalSince(first) < linger + 0.05 { try await Task.sleep(for: .milliseconds(10)) }
        if Date().timeIntervalSince(last) < linger - 0.05 {
            XCTAssertNotNil(vm.hudStrip, "past the first press's linger, inside the last one's")
        }
        let deadline = Date().addingTimeInterval(3)
        while vm.hudStrip != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(vm.hudStrip, "folded")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(last), linger - 0.02, "not before the last press's linger")
    }

    // MARK: Hand-offs

    func testClosingThePanelTakesTheCapsuleAndTheNextPressIsThePill() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.hudFoldDelay = 5
        vm.isOpen = true
        controller.presentHUD(reading(.volume, 0.5))
        XCTAssertNotNil(vm.hudStrip)
        vm.isOpen = false
        XCTAssertNil(vm.hudStrip, "folds with the panel")
        XCTAssertNil(vm.hud, "and does not reappear as the pill")
        controller.presentHUD(reading(.volume, 0.6))
        XCTAssertEqual(vm.hud?.level, 0.6, "the next press is the shut island's")
        XCTAssertNil(vm.hudStrip, "never both")
    }

    func testOpeningThePanelOverThePillDropsItAndTheNextPressIsTheCapsule() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.hudFoldDelay = 5
        controller.presentHUD(reading(.volume, 0.5))
        XCTAssertNotNil(vm.hud)
        vm.isOpen = true
        XCTAssertNil(vm.hud, "the pill goes as the panel opens")
        XCTAssertNil(vm.hudStrip, "and is not handed over mid-opening, which would show the level twice")
        controller.presentHUD(reading(.volume, 0.55))
        XCTAssertEqual(vm.hudStrip?.level, 0.55)
        XCTAssertNil(vm.hud)
    }

    func testADragOverThePanelTakesTheCapsuleAndRefusesANewOne() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.hudFoldDelay = 5
        vm.isOpen = true
        controller.presentHUD(reading())
        XCTAssertNotNil(vm.hudStrip)
        vm.isDropTargeted = true
        XCTAssertNil(vm.hudStrip, "the drop surface is the panel's whole answer")
        controller.presentHUD(reading())
        XCTAssertNil(vm.hudStrip)
        XCTAssertNil(vm.hud)
    }

    func testTurningVolumeAndBrightnessOffTakesEitherAway() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.hudFoldDelay = 5
        vm.isOpen = true
        controller.presentHUD(reading())
        vm.setVolumeAndBrightness(false)
        XCTAssertNil(vm.hudStrip)
        vm.isOpen = false
        controller.presentHUD(reading())
        XCTAssertNotNil(vm.hud)
        vm.setVolumeAndBrightness(false)
        XCTAssertNil(vm.hud)
    }

    /// The capsule is outside the panel's hit region: showing it changes
    /// `activeRect` by nothing, and no point of it is inside.
    func testTheCapsuleIsNotInTheClickableRegion() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.hudFoldDelay = 5
        vm.isOpen = true
        controller.refreshOpenRects(animated: false)
        let root = try XCTUnwrap(controller.rootView)
        let before = root.activeRect
        controller.presentHUD(reading())
        controller.refreshOpenRects(animated: false)
        XCTAssertEqual(root.activeRect, before, "the rect is the body's, with or without the capsule")
        let window = vm.geometry.windowSize
        let capsule = HUDStripLayout.frame(
            bodySize: vm.openBodySize, bottomRadius: vm.openBottomRadius, windowSize: window
        )
        // The root view's coordinates run up from the window's bottom.
        let appKitCapsule = CGRect(x: capsule.minX, y: window.height - capsule.maxY, width: capsule.width, height: capsule.height)
        XCTAssertFalse(before.intersects(appKitCapsule), "no point of the capsule is clickable")
        XCTAssertNil(root.hitTest(CGPoint(x: appKitCapsule.midX, y: appKitCapsule.midY)))
    }

    // MARK: A held key, coalesced

    func testTheMailboxKeepsTheLatestAndAsksForOneHop() {
        let mailbox = LatestReadingMailbox()
        XCTAssertNil(mailbox.take(), "empty")
        XCTAssertTrue(mailbox.post(reading(.volume, 0.1)), "the first of a burst schedules the hop")
        XCTAssertFalse(mailbox.post(reading(.volume, 0.2)), "the rest ride it")
        XCTAssertFalse(mailbox.post(reading(.display, 0.9)))
        XCTAssertEqual(mailbox.take(), reading(.display, 0.9), "latest wins")
        XCTAssertNil(mailbox.take(), "and is delivered once")
        XCTAssertTrue(mailbox.post(reading(.volume, 0.3)), "after a take, the next press hops again")
    }

    func testTheMailboxIsSafeFromTheApplierQueue() async {
        let mailbox = LatestReadingMailbox()
        let hops = HopCounter()
        await withTaskGroup(of: Void.self) { group in
            for step in 0..<8 {
                group.addTask {
                    for press in 0..<500 {
                        if mailbox.post(HUDReading(kind: .volume, level: Float(step * 500 + press) / 4000,
                                                   muted: false, deviceSymbol: nil)) {
                            hops.add()
                        }
                    }
                }
            }
        }
        XCTAssertEqual(hops.count, 1, "no hop was taken, so only the first asked for one")
        XCTAssertNotNil(mailbox.take())
        XCTAssertNil(mailbox.take())
    }

    // MARK: Drawn

    func testTheCapsuleRendersOnEverySurface() throws {
        let geometry = try LabGeometry.make()
        for surface in [NotchViewModel.Surface.player, .tray, .clipboard, .translate, .settings] {
            let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
            vm.isOpen = true
            vm.open(surface)
            vm.hudStrip = HUDMoment(reading(.volume, 0.62))
            let view = HUDStripLayer(vm: vm)
                .frame(width: geometry.windowSize.width, height: geometry.windowSize.height)
                .background(Color.gray)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            XCTAssertNotNil(renderer.nsImage, "\(surface)")
        }
    }

    /// No curve on the bar, anywhere: a held key retargeted one every few tens
    /// of milliseconds kept SwiftUI laying the bar out on every frame (about a
    /// quarter of the main thread's time in the hold, `hud-repeat`).
    func testTheBarHasNoCurve() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/HUDViews.swift"), encoding: .utf8)
        XCTAssertFalse(views.contains("value: hud.level"), "the level is never the value of an .animation")
        XCTAssertFalse(views.contains("numericText"), "nor does the number roll")
        let theme = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/Theme.swift"), encoding: .utf8)
        XCTAssertFalse(theme.contains("static let hudLevel"), "and Theme has no curve for it")
    }

    func testTheCapsuleContentWearsTheIslandsLine() throws {
        let live = HUDLiveLevel()
        live.update(HUDMoment(reading(.volume, 0.5)))
        let image = ImageRenderer(
            content: HUDStripContent(live: live, width: 220, increaseContrast: false)
                .frame(width: 220, height: 32)
        )
        image.scale = 2
        let rendered = try XCTUnwrap(image.nsImage)
        XCTAssertEqual(rendered.size.width, 220, accuracy: 0.5)
        XCTAssertEqual(rendered.size.height, 32, accuracy: 0.5, "32 points, the line inside them")
        XCTAssertEqual(Theme.islandStrokeWidth, 2)
    }
}

private final class HopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
