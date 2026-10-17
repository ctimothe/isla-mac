import XCTest
@testable import IslaKit

/// The row of dots under every page (spec §19.16): where it sits, what each
/// dot answers, how it reads to VoiceOver, and that a dot turns the page
/// without the keyboard.
@MainActor
final class PageDotsTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    /// Stores of the suite's own: the default ones read the owner's Shelf
    /// folder and general pasteboard, and a dot to the tray refreshes it.
    private var isolated: ProbeStores!

    override func setUp() {
        super.setUp()
        isolated = ProbeFixtures.isolatedStores()
    }

    override func tearDown() {
        isolated.release()
        isolated = nil
        LabLocalization.use("en")
        super.tearDown()
    }

    // MARK: Where it sits

    /// Four 6 pt dots on a 14 pt pitch, centred on the shape, their centre
    /// 10 above its bottom, on every page at every width and notch.
    func testTheRowSitsUnderEveryPage() {
        for bodyWidth in [CGFloat(480), 560, 620] {
            for notchWidth in [CGFloat(180), 185, 200, 220, 240] {
                for notchHeight in [CGFloat(24), 32, 38] {
                    for page in Surface.pages {
                        let notch = CGSize(width: notchWidth, height: notchHeight)
                        let body = SurfaceLayout.bodySize(for: page, bodyWidth: bodyWidth, notch: notch)
                        let at = "\(page) at \(bodyWidth), notch \(notchWidth) × \(notchHeight)"
                        let centres = PageDotsLayout.centres(bodySize: body)
                        XCTAssertEqual(centres.count, 4, at)
                        for centre in centres {
                            XCTAssertEqual(centre.y, body.height - 10, accuracy: 0.0001, at)
                        }
                        for (left, right) in zip(centres, centres.dropFirst()) {
                            XCTAssertEqual(right.x - left.x, 14, accuracy: 0.0001, at)
                        }
                        XCTAssertEqual((centres[0].x + centres[3].x) / 2, body.width / 2, accuracy: 0.0001, at)
                        // The dots lie in their own band: nothing of a page's
                        // content is under them.
                        let band = body.height - SurfaceLayout.pageDotsBand
                        for dot in PageDotsLayout.dotFrames(bodySize: body) {
                            XCTAssertEqual(dot.size, CGSize(width: 6, height: 6), at)
                            XCTAssertGreaterThanOrEqual(dot.minY, band, at)
                            XCTAssertLessThanOrEqual(dot.maxY, body.height, at)
                        }
                    }
                }
            }
        }
    }

    /// Each dot answers a 14 × 20 target centred on it; side by side the
    /// targets meet, and the row's stays inside the shape.
    func testEachDotAnswersAFourteenByTwentyTarget() {
        let body = SurfaceLayout.bodySize(for: .clipboard, bodyWidth: 560, notch: CGSize(width: 185, height: 38))
        let targets = PageDotsLayout.hitFrames(bodySize: body)
        let centres = PageDotsLayout.centres(bodySize: body)
        for (target, centre) in zip(targets, centres) {
            XCTAssertEqual(target.size, CGSize(width: 14, height: 20))
            XCTAssertEqual(target.midX, centre.x, accuracy: 0.0001)
            XCTAssertEqual(target.midY, centre.y, accuracy: 0.0001)
        }
        for (left, right) in zip(targets, targets.dropFirst()) {
            XCTAssertEqual(left.maxX, right.minX, accuracy: 0.0001, "no gap between two targets")
        }
        XCTAssertLessThanOrEqual(PageDotsLayout.rowFrame(bodySize: body).maxY, body.height)
    }

    /// The row is inside the clickable region on every page: the open rects
    /// are cut from the outline, and the row is in the outline.
    func testTheRowIsInsideTheClickableRegion() throws {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isOpen = true
        for page in Surface.pages {
            vm.turnPage(to: page)
            controller.refreshOpenRects(bodySettled: true)
            let body = vm.openBodySize
            let content = vm.geometry.contentRect(for: body)
            let row = PageDotsLayout.rowFrame(bodySize: body)
            // Body coordinates run down from the body's top; the window's run
            // up from its bottom.
            let inWindow = CGRect(
                x: content.minX + row.minX, y: content.maxY - row.maxY, width: row.width, height: row.height
            )
            XCTAssertTrue(root.activeRect.contains(inWindow), "\(page): \(inWindow) in \(root.activeRect)")
        }
    }

    // MARK: How it looks

    func testTheCurrentDotIsBrightestAndTheOthersBrightenUnderThePointer() {
        XCTAssertEqual(PageDots.opacity(index: 1, current: 1, hovering: false), 0.90)
        XCTAssertEqual(PageDots.opacity(index: 1, current: 1, hovering: true), 0.90)
        XCTAssertEqual(PageDots.opacity(index: 0, current: 1, hovering: false), 0.30)
        XCTAssertEqual(PageDots.opacity(index: 0, current: 1, hovering: true), 0.45)
    }

    /// The current dot is the page nearest where the pages are drawn: it
    /// changes half way through a swipe, not when the fingers lift.
    func testTheCurrentDotFollowsTheTravel() {
        let strip = PageStrip(pages: Surface.pages, widths: [492, 413, 560, 560])
        func leg(_ position: CGFloat) -> PageTravel.Leg { PageTravel.Leg(strip: strip, position: position, reach: 0...2) }
        XCTAssertEqual(PageDots.current(leg: nil, presented: .clipboard), 2)
        XCTAssertEqual(PageDots.current(leg: leg(1.4), presented: .player), 1)
        XCTAssertEqual(PageDots.current(leg: leg(1.6), presented: .player), 2)
        XCTAssertEqual(PageDots.current(leg: leg(-0.2), presented: .player), 0)
        let jump = PageTravel.Leg(
            strip: PageStrip(pages: [.player, .translate], widths: [492, 560]), position: 0.7, reach: 0...1
        )
        XCTAssertEqual(PageDots.current(leg: jump, presented: .translate), 3, "a jump's page, by its place in the row")
    }

    func testEachDotIsNamedForItsPage() {
        XCTAssertEqual(Surface.pages.map(PageDots.tooltip(for:)), ["Music", "Shelf", "Clipboard", "Translate"])
        LabLocalization.use("ru")
        XCTAssertEqual(Surface.pages.map(PageDots.tooltip(for:)), ["Музыка", "Полка", "Буфер обмена", "Перевод"])
    }

    // MARK: VoiceOver

    func testTheRowReadsAsOneAdjustableValue() {
        XCTAssertEqual(PageDots.accessibilityValue(current: 1), "Page 2 of 4, Shelf")
        XCTAssertEqual(PageDots.accessibilityLabel(), "Pages")
        LabLocalization.use("ru")
        XCTAssertEqual(PageDots.accessibilityValue(current: 3), "Страница 4 из 4, Перевод")
        XCTAssertEqual(PageDots.accessibilityLabel(), "Страницы")
    }

    /// VoiceOver finds the row after the page's own content, as one
    /// adjustable element, and its increment turns the page.
    func testVoiceOverReadsTheRowAfterThePageAndAdjustsIt() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.pageTravel.clock = ManualPageClock()
        vm.isOpen = true
        vm.open(.tray)
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm).defaultAppStorage(isolated.suite), size: size)
        let nodes = root.flattened
        let row = try XCTUnwrap(nodes.firstIndex { $0.label == "Pages" }, root.dump)
        XCTAssertEqual(nodes[row].role, "AXSlider", "what macOS knows as adjustable")
        // A slider's AXValue is its number; what VoiceOver says is the value's
        // description.
        let spoken = nodes[row].element.value(forKey: "accessibilityValueDescription") as? String
        XCTAssertEqual(spoken, "Page 2 of 4, Shelf", root.dump)
        XCTAssertTrue(nodes[row].actionNames.contains("AXIncrement"), root.dump)
        XCTAssertTrue(nodes[row].actionNames.contains("AXDecrement"), root.dump)
        let page = try XCTUnwrap(nodes.firstIndex { $0.label == "Shelf" }, root.dump)
        XCTAssertLessThan(page, row, "the page reads first")
        _ = nodes[row].element.perform(NSSelectorFromString("accessibilityPerformIncrement"))
        XCTAssertEqual(vm.surface, .clipboard)
        XCTAssertFalse(vm.wantsKeyboard)
    }

    // MARK: Turning by a dot

    private func openModel(on page: Surface, clock: ManualPageClock) throws -> NotchViewModel {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.pageTravel.clock = clock
        vm.isOpen = true
        vm.open(page)
        return vm
    }

    /// A dot turns the page at once, on the island's spring, and never takes
    /// the keyboard; leaving a page that had it gives it back.
    func testADotTurnsThePageWithoutTheKeyboard() throws {
        let clock = ManualPageClock()
        let vm = try openModel(on: .clipboard, clock: clock)
        XCTAssertTrue(vm.wantsKeyboard, "⌃⌥⌘V's Clipboard has it")
        vm.travel(to: .translate, reduceMotion: false)
        XCTAssertEqual(vm.surface, .translate)
        XCTAssertFalse(vm.wantsKeyboard)
        XCTAssertEqual(vm.travellingLeg?.mounted, [.clipboard], "it starts where it was")
        XCTAssertTrue(clock.isRunning)
        clock.advance(0.1)
        XCTAssertEqual(vm.travellingLeg?.mounted, [.clipboard, .translate])
        for _ in 0..<600 where clock.isRunning { clock.advance(1.0 / 120) }
        XCTAssertNil(vm.pageTravel.leg)
        XCTAssertEqual(vm.presented, .translate)
    }

    /// A dot two or three pages along travels straight there: only the page
    /// it leaves and the one it reaches are drawn on the way, and the outline
    /// moves between their two sizes alone.
    func testAFarDotTravelsStraightThere() throws {
        let clock = ManualPageClock()
        let vm = try openModel(on: .player, clock: clock)
        vm.travel(to: .translate, reduceMotion: false)
        clock.advance(0.1)
        XCTAssertEqual(vm.travellingLeg?.mounted, [.player, .translate])
        XCTAssertEqual(vm.travellingLeg?.reachable, [.player, .translate])
        let player = vm.openSize(of: .player), translate = vm.openSize(of: .translate)
        XCTAssertEqual(
            vm.openBodySize,
            CGSize(width: max(player.width, translate.width), height: max(player.height, translate.height))
        )
    }

    /// Under Reduce Motion nothing slides: the page is replaced in place, the
    /// crossfade every pane swap has.
    func testUnderReduceMotionADotCrossfades() throws {
        let clock = ManualPageClock()
        let vm = try openModel(on: .player, clock: clock)
        vm.travel(to: .tray, reduceMotion: true)
        XCTAssertEqual(vm.surface, .tray)
        XCTAssertNil(vm.pageTravel.leg)
        XCTAssertFalse(clock.isRunning)
    }

    /// The current page's own dot, and a dot pressed with nothing but a page
    /// under it, do nothing.
    func testTheCurrentDotAndAnythingButAPageDoNothing() throws {
        let clock = ManualPageClock()
        let vm = try openModel(on: .tray, clock: clock)
        vm.travel(to: .tray, reduceMotion: false)
        XCTAssertNil(vm.pageTravel.leg)
        vm.open(.settings)
        vm.travel(to: .player, reduceMotion: false)
        XCTAssertEqual(vm.surface, .settings, "Settings has no dots")
    }

    /// VoiceOver's increment and decrement turn one page, and stop at the ends.
    func testIncrementAndDecrementTurnOnePage() throws {
        let clock = ManualPageClock()
        let vm = try openModel(on: .player, clock: clock)
        vm.adjustPage(by: 1, reduceMotion: false)
        XCTAssertEqual(vm.surface, .tray)
        vm.adjustPage(by: -1, reduceMotion: false)
        XCTAssertEqual(vm.surface, .player)
        vm.adjustPage(by: -1, reduceMotion: false)
        XCTAssertEqual(vm.surface, .player, "nothing left of Music")
        XCTAssertFalse(vm.wantsKeyboard)
    }

    /// A dot pressed while a swipe's page is still settling re-aims it from
    /// where it is on screen, at the speed it had, rather than snapping.
    func testADotDuringASettleReAimsFromTheScreen() throws {
        let clock = ManualPageClock()
        let vm = try openModel(on: .player, clock: clock)
        vm.travel(to: .tray, reduceMotion: false)
        clock.advance(0.06)
        let onScreen = try XCTUnwrap(vm.pageTravel.leg?.position)
        vm.travel(to: .clipboard, reduceMotion: false)
        XCTAssertEqual(try XCTUnwrap(vm.pageTravel.leg?.position), onScreen, accuracy: 0.0001)
        XCTAssertEqual(vm.surface, .clipboard)
        for _ in 0..<600 where clock.isRunning { clock.advance(1.0 / 120) }
        XCTAssertNil(vm.pageTravel.leg)
    }
}
