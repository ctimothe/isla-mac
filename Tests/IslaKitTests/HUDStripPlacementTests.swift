import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Where the level capsule sits under the open panel, at every moment it is
/// up (owner, 2026-10-26: "sometimes the HUD sound control bar opens in the
/// whole middle of the screen … once you try again it works properly").
///
/// The capsule's layer is a hosting view of its own (`NotchStage`), so it
/// redraws only on what it observes. It used to place the capsule under
/// `openBodySize` — while the pages travel that is every page the leg can
/// reach, together, the clickable region rather than the drawn outline — and
/// it observed the view model alone, which says nothing when a leg ends. A
/// capsule standing through a dot or a swipe to a shorter page stayed under
/// the tallest page of the leg until it folded; the next press, a fresh
/// arrival, read the right body again.
@MainActor
final class HUDStripPlacementTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    private var isolated: ProbeStores!
    private var clock: ManualPageClock!

    override func setUp() async throws {
        isolated = ProbeFixtures.isolatedStores()
        clock = ManualPageClock()
    }

    override func tearDown() async throws {
        isolated.release()
    }

    private func openModel(on surface: Surface) throws -> NotchViewModel {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.pageTravel.clock = clock
        vm.surface = surface
        vm.isOpen = true
        return vm
    }

    private func press(_ vm: NotchViewModel, _ level: Float = 0.5) {
        vm.hudStrip = HUDMoment(HUDReading(kind: .volume, level: level, muted: false, deviceSymbol: nil))
    }

    /// Where the drawn outline's bottom edge is, plus the gap: what the
    /// shell draws the open island at (`NotchContentView.size` is
    /// `vm.bodySize`, which is `drawnOpenBodySize` while open).
    private func underTheOutline(_ vm: NotchViewModel) -> CGFloat {
        vm.bodySize.height + HUDStripLayout.gap
    }

    private func scroll(_ dx: CGFloat, _ phase: ScrollSample.Phase = .changed, at time: TimeInterval = 0) -> PageScroll {
        PageScroll(deltaX: dx, deltaY: 0, phase: phase, momentumPhase: .none, precise: true, time: time)
    }

    /// Two fingers moving the content left by `distance` points, slowly: the
    /// pages under the fingers, Music toward the Shelf.
    private func drag(_ vm: NotchViewModel, by distance: CGFloat) {
        _ = vm.pageScroll(scroll(0, .began), over: true)
        _ = vm.pageScroll(scroll(-10), over: true)
        _ = vm.pageScroll(scroll(-distance), over: true)
    }

    private func runUntilAtRest(_ vm: NotchViewModel) {
        for _ in 0..<400 where vm.pageTravel.leg != nil { clock.advance(1.0 / 120) }
        XCTAssertNil(vm.pageTravel.leg, "the leg ended")
    }

    // MARK: The layer, hosted as the app hosts it

    /// The layer in a never-ordered window, drawn with `cacheDisplay` after
    /// every curve has had time to land: where the capsule's top edge is, in
    /// points from the window's top, down the notch's axis.
    @MainActor
    private final class Host {
        let window: NSWindow
        let hosting: NSHostingView<HUDStripLayer>

        init(vm: NotchViewModel) {
            let size = vm.geometry.windowSize
            hosting = NSHostingView(rootView: HUDStripLayer(vm: vm))
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: size)
            window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Closed by the test and still owned by it: AppKit's default
            // release on close is a second release under ARC.
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
        }

        func settle(_ seconds: TimeInterval = 1.2) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            hosting.layoutSubtreeIfNeeded()
        }

        func capsuleTop() -> CGFloat? {
            let size = hosting.bounds.size
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            rep.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let x = Int(size.width / 2)
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                return CGFloat(y)
            }
            return nil
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    // MARK: Suspect 1 — the clickable region is not the outline

    /// Mid-swipe from Music toward the Shelf, the leg reaches Music and the
    /// Shelf, and the clickable region is cut for the Shelf's 300-odd points;
    /// the outline is still mostly Music's 200. The capsule goes under the
    /// outline.
    func testMidSwipeTheCapsuleSitsUnderTheDrawnOutlineNotTheClickableRegion() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 40)
        let leg = try XCTUnwrap(vm.pageTravel.leg, "the precondition: the fingers have the pages")
        XCTAssertTrue(leg.reachable.contains(.tray))
        XCTAssertGreaterThan(vm.openBodySize.height, vm.bodySize.height + 50, "the region is cut far below the outline")
        press(vm)
        XCTAssertEqual(
            HUDStripLayer.capsuleFrame(for: vm).minY, underTheOutline(vm), accuracy: 0.5,
            "6 pt under the outline as drawn, not under the clickable region"
        )
    }

    /// The radius it narrows by is the outline's, mixed as the pages are.
    func testMidSwipeTheCapsuleIsNoWiderThanTheDrawnOutlineAllows() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 120)
        XCTAssertNotNil(vm.pageTravel.leg)
        let frame = HUDStripLayer.capsuleFrame(for: vm)
        XCTAssertEqual(
            frame.width,
            HUDStripLayout.width(bodyWidth: vm.drawnOpenBodySize.width, bottomRadius: vm.openBottomRadius)
        )
        XCTAssertEqual(frame.midX, vm.geometry.windowSize.width / 2, accuracy: 0.001)
    }

    // MARK: Suspect 1 — and nothing redrew the layer when the leg ended

    /// The owner's case: the capsule up on Clipboard, a dot (or ⌃Tab) to
    /// Music. The page turns at the start of the leg — one publish of the
    /// view model, with the leg reaching both pages — and the leg ends with
    /// no publish at all. The capsule has to land under Music's outline.
    func testACapsuleStandingThroughADotTurnLandsUnderTheShorterPage() throws {
        let vm = try openModel(on: .clipboard)
        let host = Host(vm: vm)
        defer { host.close() }
        press(vm)
        host.settle()
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2, "under Clipboard")

        vm.travel(to: .player, reduceMotion: false)
        clock.advance(1.0 / 120)
        host.settle(0.05)
        runUntilAtRest(vm)
        host.settle()
        XCTAssertEqual(vm.presented, .player)
        XCTAssertEqual(
            try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2,
            "under Music's outline once the pages are at rest, not Clipboard's"
        )
    }

    /// The charger, headphones and confirmations share the capsule (spec
    /// §19.5 d, amended 2026-10-26): drawn in the same place, and moved by a
    /// page turn exactly as the level is.
    func testANoticeInTheCapsuleSitsUnderTheOutlineAndFollowsADotTurn() throws {
        let vm = try openModel(on: .clipboard)
        let host = Host(vm: vm)
        defer { host.close() }
        vm.stripNotice = .ambient(.charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold))
        host.settle()
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop(), "the notice is drawn"), underTheOutline(vm), accuracy: 2)

        vm.travel(to: .player, reduceMotion: false)
        clock.advance(1.0 / 120)
        host.settle(0.05)
        runUntilAtRest(vm)
        host.settle()
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2, "under Music's outline")

        vm.stripNotice = .confirmation(IslandConfirmation(.copied))
        host.settle()
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2, "a confirmation the same")
        vm.stripNotice = nil
        host.settle()
        XCTAssertNil(host.capsuleTop(), "and gone when it folds")
    }

    /// A press during a swipe that springs back to Music: nothing turns, so
    /// nothing publishes on the view model when the leg ends.
    func testAPressDuringASwipeThatSpringsBackLandsUnderThePage() throws {
        let vm = try openModel(on: .player)
        let host = Host(vm: vm)
        defer { host.close() }
        host.settle(0.1)
        drag(vm, by: 40)
        XCTAssertNotNil(vm.pageTravel.leg)
        press(vm)
        host.settle(0.1)
        XCTAssertTrue(vm.pageScroll(scroll(0, .ended, at: 5), over: true))
        runUntilAtRest(vm)
        host.settle()
        XCTAssertEqual(vm.presented, .player, "the swipe turned nothing")
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2, "under Music")
    }

    /// The layer redraws per page-travel frame only while the capsule is up:
    /// with it folded, a whole leg re-runs nothing of it.
    func testAFoldedCapsuleDoesNotWatchThePages() throws {
        let vm = try openModel(on: .clipboard)
        let host = Host(vm: vm)
        defer { host.close() }
        host.settle(0.1)
        XCTAssertNil(host.capsuleTop(), "nothing drawn with the capsule folded")
        let before = HUDStripPlaced.bodies
        vm.travel(to: .player, reduceMotion: false)
        for _ in 0..<30 {
            clock.advance(1.0 / 120)
            host.settle(0.005)
        }
        XCTAssertEqual(HUDStripPlaced.bodies, before, "no frame of the leg reached the capsule's placement")
        runUntilAtRest(vm)

        // Up, it does follow the frames: the count above is not deaf.
        press(vm)
        host.settle(0.1)
        let shown = HUDStripPlaced.bodies
        XCTAssertGreaterThan(shown, before, "the arrival drew it")
        vm.travel(to: .clipboard, reduceMotion: false)
        for _ in 0..<10 {
            clock.advance(1.0 / 120)
            host.settle(0.005)
        }
        XCTAssertGreaterThan(HUDStripPlaced.bodies, shown + 5, "a frame of the leg, a frame of the capsule")
    }

    // MARK: Suspect 2 — the stage with no song

    /// `presented` reads `media.track`, which the view model does not
    /// forward; the presenter, which it does, changes in the same report. A
    /// song leaving the stage and coming back moves the capsule with the body.
    func testTheStageLosingAndRegainingItsSongMovesTheCapsuleWithTheBody() throws {
        let vm = try openModel(on: .stage)
        XCTAssertEqual(vm.presented, .player, "no song: the stage is drawn as the empty player")
        let host = Host(vm: vm)
        defer { host.close() }
        press(vm)
        host.settle()
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2)

        var published = 0
        let watch = vm.objectWillChange.sink { published += 1 }
        isolated.stores.media.apply(playing())
        XCTAssertGreaterThan(published, 0, "a song arriving is heard by what watches the view model")
        XCTAssertEqual(vm.presented, .stage)
        host.settle()
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2, "under the stage's 400")

        published = 0
        isolated.stores.media.apply(NowPlayingFeed.Snapshot())
        XCTAssertNil(isolated.stores.media.track)
        XCTAssertGreaterThan(published, 0, "and so is it leaving")
        XCTAssertEqual(vm.presented, .player)
        host.settle()
        XCTAssertEqual(try XCTUnwrap(host.capsuleTop()), underTheOutline(vm), accuracy: 2, "back under the player")
        withExtendedLifetime(watch) {}
    }

    // MARK: The tall surfaces

    /// On the stage and on Settings the capsule is where it always was: 6 pt
    /// under a 400 pt body, a little over 440 pt from the top of the screen.
    func testOnTheTallSurfacesTheCapsuleIsUnderTheirBody() throws {
        for surface in [Surface.settings, .stage] {
            let vm = try openModel(on: surface)
            if surface == .stage { isolated.stores.media.apply(playing()) }
            XCTAssertEqual(vm.presented, surface)
            press(vm)
            let frame = HUDStripLayer.capsuleFrame(for: vm)
            XCTAssertEqual(frame.minY, underTheOutline(vm), accuracy: 0.5, "\(surface)")
            XCTAssertEqual(frame.minY, vm.geometry.notchSize.height + 362 + HUDStripLayout.gap, "\(surface)")
        }
    }

    private func playing() -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.duration = 180
        snapshot.elapsed = 9.2
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        return snapshot
    }
}
