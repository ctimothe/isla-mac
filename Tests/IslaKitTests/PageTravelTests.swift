import XCTest
@testable import IslaKit

/// A clock a test turns by hand: the pages settle exactly as far as the test
/// says, and nothing ticks behind its back.
@MainActor
final class ManualPageClock: PageClock {
    var now: TimeInterval = 100
    private(set) var tick: (() -> Void)?
    var isRunning: Bool { tick != nil }

    func start(_ tick: @escaping () -> Void) { self.tick = tick }
    func stop() { tick = nil }

    /// Moves the time on and draws one frame.
    func advance(_ seconds: TimeInterval) {
        now += seconds
        tick?()
    }
}

/// The swipe as the island lives it (spec §19.16): the view model fed scroll
/// events turns its pages, never takes the keyboard for it, draws the outline
/// between two pages and keeps the clickable region over all it can reach.
@MainActor
final class PageTravelTests: XCTestCase {
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

    private func openModel(on page: Surface) throws -> NotchViewModel {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.pageTravel.clock = clock
        vm.surface = page
        vm.isOpen = true
        return vm
    }

    private func scroll(
        _ dx: CGFloat, _ dy: CGFloat = 0, _ phase: ScrollSample.Phase = .changed, at time: TimeInterval = 0
    ) -> PageScroll {
        PageScroll(deltaX: dx, deltaY: dy, phase: phase, momentumPhase: .none, precise: true, time: time)
    }

    /// Two fingers moving the content left by `distance` points, slowly.
    @discardableResult
    private func drag(_ vm: NotchViewModel, by distance: CGFloat) -> [Bool] {
        var consumed = [vm.pageScroll(scroll(0, 0, .began), over: true)]
        consumed.append(vm.pageScroll(scroll(distance < 0 ? 10 : -10, 0), over: true))
        consumed.append(vm.pageScroll(scroll(-distance, 0), over: true))
        return consumed
    }

    private func release(_ vm: NotchViewModel) -> Bool {
        vm.pageScroll(scroll(0, 0, .ended, at: 5), over: true)
    }

    private func playing() -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.album = ""
        snapshot.duration = 180
        snapshot.elapsed = 9.2
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        return snapshot
    }

    private func settle() {
        for _ in 0..<600 where clock.isRunning { clock.advance(1.0 / 120) }
    }

    private func size(_ surface: Surface, _ vm: NotchViewModel) -> CGSize {
        SurfaceLayout.bodySize(for: surface, bodyWidth: vm.geometry.expandedSize.width, notch: vm.geometry.notchSize)
    }

    // MARK: Turning

    func testASwipeTurnsToTheNextPageAndSettles() throws {
        let vm = try openModel(on: .player)
        let distance = (size(.player, vm).width + size(.tray, vm).width) / 2
        XCTAssertEqual(drag(vm, by: distance * 0.7), [false, true, true], "the began is the page's until 10 pt decide")
        XCTAssertEqual(vm.surface, .player, "nothing turns under the fingers")
        XCTAssertEqual(vm.pageTravel.leg?.position ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertTrue(release(vm))
        XCTAssertEqual(vm.surface, .tray, "the release turns the page")
        XCTAssertTrue(clock.isRunning, "and it settles")
        settle()
        XCTAssertNil(vm.pageTravel.leg, "at rest")
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(vm.presented, .tray)
    }

    func testAShortSwipeGoesBack() throws {
        let vm = try openModel(on: .clipboard)
        drag(vm, by: -40)
        XCTAssertTrue(release(vm))
        XCTAssertEqual(vm.surface, .clipboard)
        settle()
        XCTAssertNil(vm.pageTravel.leg)
    }

    /// Looking through the pages never takes typing from the app in front,
    /// and a swipe that goes back to where it began leaves the keyboard where
    /// it was.
    func testASwipeNeverTakesTheKeyboard() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 2000)
        _ = release(vm)
        settle()
        drag(vm, by: 2000)
        _ = release(vm)
        settle()
        XCTAssertEqual(vm.surface, .clipboard)
        XCTAssertFalse(vm.wantsKeyboard, "a swipe to Clipboard leaves the keyboard alone")

        vm.open(.clipboard)
        XCTAssertTrue(vm.wantsKeyboard)
        drag(vm, by: 30)
        _ = release(vm)
        settle()
        XCTAssertEqual(vm.surface, .clipboard)
        XCTAssertTrue(vm.wantsKeyboard, "a swipe that went back keeps it")

        drag(vm, by: 2000)
        _ = release(vm)
        XCTAssertEqual(vm.surface, .translate)
        XCTAssertFalse(vm.wantsKeyboard, "leaving the page gives it back")
    }

    func testAVerticalGestureIsThePagesOwn() throws {
        let vm = try openModel(on: .clipboard)
        XCTAssertFalse(vm.pageScroll(scroll(0, 0, .began), over: true))
        XCTAssertFalse(vm.pageScroll(scroll(-2, 14), over: true))
        XCTAssertFalse(vm.pageScroll(scroll(-80, 0), over: true))
        XCTAssertFalse(vm.pageScroll(scroll(0, 0, .ended), over: true))
        XCTAssertNil(vm.pageTravel.leg)
        XCTAssertEqual(vm.surface, .clipboard)
    }

    /// Settings is a level below the pages and does not page; neither does a
    /// shut island. (The stage with no song is drawn as the empty player,
    /// which is Music's page and pages like it.)
    func testOnlyAnOpenPagePages() throws {
        let settings = try openModel(on: .settings)
        XCTAssertEqual(drag(settings, by: 300), [false, false, false])
        XCTAssertNil(settings.pageTravel.leg)
        let shut = try openModel(on: .tray)
        shut.isOpen = false
        XCTAssertEqual(drag(shut, by: 300), [false, false, false])
    }

    /// Only the page on screen holds the keyboard or starts work: the page
    /// beside it for a swipe's length neither takes focus as it appears nor
    /// translates anything for nobody.
    func testOnlyThePageOnScreenIsLive() throws {
        let vm = try openModel(on: .clipboard)
        drag(vm, by: 100)
        XCTAssertEqual(vm.travellingLeg?.mounted, [.clipboard, .translate])
        XCTAssertTrue(NotchContentView.paneIsLive(.clipboard, presented: vm.presented))
        XCTAssertFalse(NotchContentView.paneIsLive(.translate, presented: vm.presented))
    }

    // MARK: The outline

    /// Between two pages the drawn outline is their mix, and the clickable
    /// region covers every page the gesture can reach.
    func testTheOutlineIsDrawnBetweenThePagesAndCutOverAllItCanReach() throws {
        let vm = try openModel(on: .tray)
        let player = size(.player, vm), tray = size(.tray, vm), clipboard = size(.clipboard, vm)
        let distance = (tray.width + clipboard.width) / 2
        drag(vm, by: distance / 2)
        XCTAssertEqual(vm.bodySize.width, (tray.width + clipboard.width) / 2, accuracy: 0.001)
        XCTAssertEqual(vm.bodySize.height, (tray.height + clipboard.height) / 2, accuracy: 0.001)
        XCTAssertEqual(vm.openBodySize.width, max(player.width, tray.width, clipboard.width), accuracy: 0.001)
        XCTAssertEqual(vm.openBodySize.height, max(player.height, tray.height, clipboard.height), accuracy: 0.001)
        XCTAssertEqual(vm.openTopRadius, (Surface.tray.topRadius + Surface.clipboard.topRadius) / 2, accuracy: 0.001)
        XCTAssertEqual(
            vm.openBottomRadius, (Surface.tray.bottomRadius + Surface.clipboard.bottomRadius) / 2, accuracy: 0.001
        )
        _ = release(vm)
        settle()
        XCTAssertEqual(vm.openBodySize, clipboard, "at rest, the page's own")
        XCTAssertEqual(vm.bodySize, clipboard)
    }

    /// Past the page next to the one it began on the content rubber-bands,
    /// but the outline stays the size of that neighbour: it never grows
    /// toward a page the gesture cannot reach, outside the clickable region
    /// cut for the ones it can (R8b review F4).
    func testTheOutlineNeverOutgrowsWhatTheGestureCanReach() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 2000)
        let position = try XCTUnwrap(vm.pageTravel.leg?.position)
        XCTAssertGreaterThan(position, 1, "the rubber band is past the Shelf")
        XCTAssertEqual(vm.bodySize, size(.tray, vm), "the Shelf's outline, not one mixed with Clipboard's")
        XCTAssertEqual(vm.openTopRadius, Surface.tray.topRadius, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(vm.bodySize.width, vm.openBodySize.width)
        XCTAssertLessThanOrEqual(vm.bodySize.height, vm.openBodySize.height)
    }

    // MARK: Interruption

    /// Files dragged to the notch, or the welcome, laid over the pages while
    /// the fingers have them end the gesture: the pages go to rest under the
    /// overlay rather than waiting half way, with the clickable region still
    /// cut over them, for a release that will never come (R8b review F6).
    func testAnOverlayEndsTheGestureUnderIt() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 100)
        XCTAssertNotNil(vm.pageTravel.leg)
        vm.isDropTargeted = true
        XCTAssertNil(vm.pageTravel.leg)
        vm.isDropTargeted = false
        XCTAssertNil(vm.travellingLeg)
        XCTAssertFalse(vm.pageScroll(scroll(-30, 0), over: true), "the rest of that gesture is not the pages'")
        XCTAssertEqual(vm.surface, .player)
    }

    /// On the stage with no song, drawn as Music's page, a swipe that comes
    /// back to where it began turns nothing: the surface stays the stage, so
    /// a song starting shows its lyrics, as ⌃⌥⌘L asked. It compared the
    /// released page with the surface alone and turned to Music (R8b
    /// re-review N6).
    func testASwipeBackOnTheEmptyStageLeavesTheStage() throws {
        let vm = try openModel(on: .stage)
        drag(vm, by: 40)
        _ = release(vm)
        settle()
        XCTAssertEqual(vm.surface, .stage)
    }

    /// A song arriving under a swipe on the stage with no song — drawn as
    /// Music's page — takes the page from under the fingers: the stage is not
    /// a page. The pages go to rest, as they do under the drop surface or the
    /// welcome. Left there, the empty player came back half turned when the
    /// song stopped, with the clickable region still cut wide (R8b re-review R3).
    func testASongArrivingUnderASwipeOnTheEmptyStageEndsIt() throws {
        let vm = try openModel(on: .stage)
        XCTAssertEqual(vm.presented, .player)
        drag(vm, by: 100)
        XCTAssertNotNil(vm.pageTravel.leg)
        isolated.stores.media.apply(playing())
        XCTAssertEqual(vm.presented, .stage)
        XCTAssertNil(vm.pageTravel.leg)
        XCTAssertEqual(vm.pageTravel.reachable, [], "nothing left cut wide")
        XCTAssertFalse(vm.pageScroll(scroll(-30, 0), over: true), "the rest of that gesture is not the pages'")
    }

    /// A dot or ⌃Tab pressed while two fingers have the pages takes them: the
    /// rest of the gesture and its glide are swallowed instead of fighting
    /// the travel frame by frame, and its release turns nothing (R8b review F7).
    func testADotTakesThePagesFromTheFingers() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 100)
        vm.travel(to: .clipboard, reduceMotion: false)
        clock.advance(0.05)
        let settling = try XCTUnwrap(vm.pageTravel.leg?.position)
        XCTAssertTrue(vm.pageScroll(scroll(-80, 0), over: true), "swallowed")
        XCTAssertEqual(try XCTUnwrap(vm.pageTravel.leg?.position), settling, accuracy: 0.0001, "the fingers no longer move it")
        XCTAssertTrue(clock.isRunning, "the dot's travel goes on")
        XCTAssertTrue(release(vm))
        XCTAssertEqual(vm.surface, .clipboard, "the release turns nothing")
        XCTAssertTrue(vm.pageScroll(PageScroll(deltaX: -20, deltaY: 0, phase: .none, momentumPhase: .changed, precise: true, time: 6), over: true))
    }

    /// A swipe that lands while a page settles picks it up where it is on
    /// screen.
    func testASwipeDuringASettlePicksThePageUp() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 300)
        _ = release(vm)
        clock.advance(0.05)
        let onScreen = try XCTUnwrap(vm.pageTravel.leg?.position)
        XCTAssertNotEqual(onScreen, 1)
        XCTAssertFalse(vm.pageScroll(scroll(0, 0, .began, at: 6), over: true), "the first 10 pt decide")
        XCTAssertTrue(vm.pageScroll(scroll(-10, 0, at: 6), over: true))
        XCTAssertFalse(clock.isRunning, "the settle stops under the fingers")
        XCTAssertEqual(try XCTUnwrap(vm.pageTravel.leg?.position), onScreen, accuracy: 0.0001)
    }

    /// Anything other than a page turn that changes the surface puts the
    /// pages at rest at once: the gear, the stage, the panel closing.
    func testSettingsOrClosingEndsTheTravel() throws {
        let vm = try openModel(on: .player)
        drag(vm, by: 300)
        _ = release(vm)
        clock.advance(0.05)
        vm.pressGear()
        XCTAssertEqual(vm.surface, .settings)
        XCTAssertNil(vm.pageTravel.leg)
        XCTAssertFalse(clock.isRunning)

        let closing = try openModel(on: .tray)
        drag(closing, by: 100)
        closing.isOpen = false
        XCTAssertNil(closing.pageTravel.leg)
    }

    // MARK: A rebuild

    /// A display change builds a new view model; where the person was goes
    /// with it. The bare notch opens the page last shown since launch, and the
    /// lit gear goes back to where Settings was opened from — both were lost to
    /// a monitor plugged in (R8b review F9).
    func testWhereThePagesWereSurvivesARebuild() throws {
        let old = try openModel(on: .translate)
        old.pressGear()
        XCTAssertEqual(old.surface, .settings)
        let fresh = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        // In `build(restoring:)`'s order: the surface, then the place, which
        // the surface's own setting would otherwise write over.
        fresh.surface = old.surface
        fresh.restorePlace(old.place)
        XCTAssertEqual(fresh.lastPage, .translate)
        fresh.pressGear()
        XCTAssertEqual(fresh.surface, .translate)
    }

    /// The tray's size is read many times on every frame of a swipe: what it
    /// measures in text is kept, and kept per language, so the answer is the
    /// one measured afresh in English and in Russian (R8b review P2).
    func testTheTraysMeasuredRoomFollowsTheLanguage() {
        defer { LabLocalization.use("en") }
        for language in ["en", "ru", "en"] {
            LabLocalization.use(language)
            XCTAssertEqual(ShelfLayout.headerSideRoom(), ShelfLayout.measuredHeaderSideRoom(), language)
            XCTAssertEqual(ShelfLayout.headerSideRoom(), ShelfLayout.measuredHeaderSideRoom(), "\(language), kept")
        }
    }
}
