import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Shelf waiting as a bubble beside the island (spec §19.7): its frame,
/// what it says, when it is absent, and that the window takes its clicks while
/// it shows and gives them back when it goes.
@MainActor
final class IslandBubbleTests: XCTestCase {

    private func geometry(notchWidth: CGFloat = 185, height: CGFloat = 38) throws -> NotchGeometry {
        let onscreen = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        return NotchGeometry(
            screen: onscreen.screen,
            notchSize: CGSize(width: notchWidth, height: height),
            notchCenterX: onscreen.screen.frame.midX,
            isPhysical: true
        )
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

    /// Files on the probe's Shelf, made in its own folder, with no QuickLook
    /// and no bookmarks so nothing reaches past it.
    private func keep(_ count: Int, on isolated: ProbeStores) {
        let shelf = isolated.stores.shelf
        shelf.requestThumbnail = { _, done in done(nil) }
        shelf.makeBookmark = { _ in nil }
        let urls = (0..<count).map { isolated.temp.appendingPathComponent("kept-\($0).txt") }
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
        shelf.add(urls)
    }

    // MARK: Frame

    /// 58 × `H`, shoulders 8.67, bottom corners 14, its left edge 16 right of
    /// the island's outline — the outline, not the body: the island's own
    /// shoulders lie between the two.
    func testTheBubbleIsFiftyEightWideSixteenRightOfTheIsland() throws {
        XCTAssertEqual(IslandBubbleLayout.width(count: 3), 58)
        XCTAssertEqual(IslandBubbleLayout.gap, 16)
        XCTAssertEqual(IslandBubbleLayout.topRadius, Theme.collapsedTopRadius)
        XCTAssertEqual(IslandBubbleLayout.bottomRadius, 14)

        for notch in [CGFloat(180), 185, 200, 220, 240] {
            for height in [CGFloat(24), 32, 38] {
                let geometry = try geometry(notchWidth: notch, height: height)
                let island = CGSize(width: notch + NotchMetrics.compactMediaExtension, height: height)
                let outline = geometry.contentRect(for: island).insetBy(dx: -Theme.collapsedTopRadius, dy: 0)
                let bubble = geometry.bubbleRect(islandWidth: island.width, height: height, count: 3)
                XCTAssertEqual(bubble.minX, outline.maxX + 16, accuracy: 0.001, "nw \(notch), H \(height)")
                XCTAssertEqual(bubble.width, 58, accuracy: 0.001)
                XCTAssertEqual(bubble.height, height, accuracy: 0.001, "the island's own height")
                XCTAssertEqual(bubble.maxY, geometry.windowSize.height, accuracy: 0.001, "hung from the top edge")
                XCTAssertTrue(
                    CGRect(origin: .zero, size: geometry.windowSize).contains(bubble),
                    "inside the window's single cut at nw \(notch)"
                )
            }
        }
    }

    /// The same bubble in the coordinates a SwiftUI gesture reports, the way
    /// `compactGestureRect` is the island's.
    func testTheGestureRectIsTheBubbleTheOtherWayUp() throws {
        let geometry = try geometry()
        let bubble = geometry.bubbleRect(islandWidth: 255, height: 38, count: 3)
        let gesture = geometry.bubbleGestureRect(islandWidth: 255, height: 38, count: 3)
        XCTAssertEqual(gesture.minX, bubble.minX, accuracy: 0.001)
        XCTAssertEqual(gesture.width, bubble.width, accuracy: 0.001)
        XCTAssertEqual(gesture.minY, 0, accuracy: 0.001, "SwiftUI counts from the top")
        XCTAssertEqual(gesture.height, 38, accuracy: 0.001)
        XCTAssertEqual(
            gesture.midX - geometry.windowSize.width / 2,
            IslandBubbleLayout.centreOffset(islandWidth: 255, count: 3), accuracy: 0.001,
            "where the view draws it: the island's centre plus the offset"
        )
    }

    /// 58 for one digit and 8 more for each further digit (spec §19.7,
    /// amended 2026-10-17): at a fixed 58, "60" touched the shoulders on the
    /// owner's Mac. It grows to the right; its left edge stays 16 from the
    /// island's outline.
    func testTheBubbleWidensADigitAtATime() throws {
        XCTAssertEqual(IslandBubbleLayout.width(count: 1), 58)
        XCTAssertEqual(IslandBubbleLayout.width(count: 9), 58)
        XCTAssertEqual(IslandBubbleLayout.width(count: 10), 66)
        XCTAssertEqual(IslandBubbleLayout.width(count: ShelfStore.limit), 66, "the Shelf's limit is two digits")

        let geometry = try geometry()
        let one = geometry.bubbleRect(islandWidth: 255, height: 38, count: 7)
        let two = geometry.bubbleRect(islandWidth: 255, height: 38, count: 60)
        XCTAssertEqual(two.minX, one.minX, accuracy: 0.001, "the gap to the island holds")
        XCTAssertEqual(two.width, 66, accuracy: 0.001)
        XCTAssertEqual(
            IslandBubbleLayout.centreOffset(islandWidth: 255, count: 60)
                - IslandBubbleLayout.centreOffset(islandWidth: 255, count: 7),
            4, accuracy: 0.001, "the centre moves by half the growth"
        )
    }

    /// Every count the Shelf can hold keeps the one-digit bubble's padding
    /// between the content and the shoulders — measured in the font the count
    /// is drawn in, not assumed from a digit's nominal width.
    func testEveryCountKeepsTheOneDigitPadding() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: IslandBubbleLayout.countSize, weight: .semibold)
        func padding(_ count: Int) -> CGFloat {
            let text = (String(count) as NSString).size(withAttributes: [.font: font]).width
            let content = IslandBubbleLayout.glyphSize.width + IslandBubbleLayout.spacing + text
            let body = IslandBubbleLayout.width(count: count) - 2 * IslandBubbleLayout.topRadius
            return (body - content) / 2
        }
        let reference = padding(8)
        XCTAssertGreaterThan(reference, 4, "the reference's one-digit bubble has about 5 pt a side")
        for count in 1...ShelfStore.limit {
            XCTAssertGreaterThanOrEqual(padding(count), reference - 0.5, "\(count) items")
        }
    }

    // MARK: Content

    /// Centred, 5 apart: `tray.full.fill` 18 × 14, white, and the count, 13
    /// semibold, tabular, blue. Its label is the Shelf activity's.
    func testTheBubbleHoldsTheTrayAndTheCount() {
        XCTAssertEqual(IslandBubbleLayout.glyphSize, CGSize(width: 18, height: 14))
        XCTAssertEqual(IslandBubbleLayout.spacing, 5)
        XCTAssertEqual(IslandBubbleLayout.countSize, 13)
        XCTAssertEqual(IslandBubbleLayout.countColor, Theme.SettingsTint.blue.color, "#0A84FF, the system blue")
        XCTAssertEqual(IslandBubble.label(count: 3), localized("Shelf, %d items", 3))
    }

    func testTheBubbleRenders() throws {
        let view = IslandBubble(count: 12, height: 38, increaseContrast: false, action: {})
            .padding(20)
            .background(Color(white: 0.55))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        XCTAssertNotNil(renderer.nsImage)
    }

    // MARK: When it shows

    /// Beside Music with files on the Shelf; never during an alert, while a
    /// surface is open or files are dragged over it, nor while locked.
    func testTheBubbleShowsOnlyBesideMusic() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        keep(3, on: isolated)
        XCTAssertEqual(vm.activity, .shelf(count: 3))
        XCTAssertNil(vm.bubbleCount, "with nothing playing the Shelf is the island itself")

        isolated.stores.media.apply(playing())
        XCTAssertEqual(vm.activity, .music)
        XCTAssertEqual(vm.bubbleCount, 3, "Music holds the island; the Shelf waits beside it")

        vm.hud = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        XCTAssertNil(vm.bubbleCount, "never during an alert")
        vm.hud = nil
        vm.ambient = .charging(level: 80, isCharging: true)
        XCTAssertNil(vm.bubbleCount, "nor the charger")
        vm.ambient = nil

        vm.isOpen = true
        XCTAssertNil(vm.bubbleCount, "nor beside an open surface")
        vm.isOpen = false
        vm.isDropTargeted = true
        XCTAssertNil(vm.bubbleCount, "nor while files are dragged over the notch")
        vm.isDropTargeted = false
        vm.isLockedPresentation = true
        XCTAssertNil(vm.bubbleCount, "nor over the lock screen")
        vm.isLockedPresentation = false

        XCTAssertEqual(vm.bubbleCount, 3)
    }

    // MARK: The click

    /// A click opens what was clicked (spec §19.1): the bubble, or the island
    /// showing the Shelf, opens the tray, and the island showing Music opens
    /// the player.
    func testAClickOnTheBubbleOrTheShelfActivityOpensTheShelf() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        keep(3, on: isolated)
        XCTAssertEqual(vm.openTarget, .tray, "the island shows the Shelf")
        isolated.stores.media.apply(playing())
        XCTAssertEqual(vm.openTarget, .player, "the island shows Music")

        vm.clickOpened(pointerIsOnPanel: true, opening: .tray)
        XCTAssertEqual(vm.surface, .tray, "the bubble's click")
        vm.clickOpened(pointerIsOnPanel: true)
        XCTAssertEqual(vm.surface, .player, "the island's click")
    }

    // MARK: Hit region

    /// The window takes the bubble's clicks while it shows, and only there —
    /// the 16 pt between it and the island stays the menu bar's — and gives
    /// them back the moment it goes.
    func testTheActiveRectsCoverTheBubbleWhileItShowsAndNotAfter() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)

        keep(2, on: isolated)
        isolated.stores.media.apply(playing())
        controller.refreshCollapsedRects()
        let bubble = vm.geometry.bubbleRect(islandWidth: vm.bodySize.width, height: vm.bodySize.height, count: 2)
        XCTAssertEqual(vm.bubbleCount, 2)
        XCTAssertTrue(root.bubbleRect.contains(CGPoint(x: bubble.midX, y: bubble.midY)))
        XCTAssertNotNil(root.hitTest(CGPoint(x: bubble.midX, y: bubble.midY)), "a click on the bubble reaches the panel")
        let gap = CGPoint(x: bubble.minX - IslandBubbleLayout.gap / 2, y: bubble.midY)
        XCTAssertNil(root.hitTest(gap), "the gap between the two is click-through")

        vm.hud = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        controller.refreshCollapsedRects()
        XCTAssertEqual(root.bubbleRect, .zero, "an alert takes the bubble away, and its rect with it")
        XCTAssertNil(root.hitTest(CGPoint(x: bubble.maxX - 2, y: bubble.midY)), "the pop-up ends short of it")
        vm.hud = nil

        vm.isLockedPresentation = true
        controller.refreshCollapsedRects()
        XCTAssertEqual(root.bubbleRect, .zero, "nothing on the shield answers but the pill")
    }
}
