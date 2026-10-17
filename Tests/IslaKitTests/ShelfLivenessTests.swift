import AppKit
import XCTest
@testable import IslaKit

/// What keeps the Shelf on the island (spec §19.1, amended 2026-10-17): a file
/// a person put there, never one Isla collected by itself. Show Screen
/// Captures is on by default, so on the owner's Mac the Shelf filled to its
/// limit of 60 with screenshots and the island never went back into the notch
/// — "60" beside every song, and on the bare notch with nothing playing. A
/// collected file now shows the Shelf for a moment and the island rests.
@MainActor
final class ShelfLivenessTests: XCTestCase {

    private func geometry() throws -> NotchGeometry {
        let onscreen = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        return NotchGeometry(
            screen: onscreen.screen,
            notchSize: CGSize(width: 185, height: 38),
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

    /// Files in the probe's own folder, on a Shelf with no QuickLook and no
    /// bookmarks, so nothing reaches past it.
    private func files(_ count: Int, _ prefix: String, in isolated: ProbeStores) -> [URL] {
        let shelf = isolated.stores.shelf
        shelf.requestThumbnail = { _, done in done(nil) }
        shelf.makeBookmark = { _ in nil }
        let urls = (0..<count).map { isolated.temp.appendingPathComponent("\(prefix)-\($0).png") }
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
        return urls
    }

    private func store() -> (ShelfStore, UserDefaults, () -> Void) {
        let suite = "ShelfLivenessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ShelfStore(defaults: defaults)
        store.makeBookmark = { _ in nil }
        store.requestThumbnail = { _, done in done(nil) }
        return (store, defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Who put a card there

    /// A drop is a person's; a capture is Isla's. Kept per card, and across a
    /// relaunch, or the island would come back out of the notch for every
    /// screenshot the moment the app restarted.
    func testWhoPutACardThereSurvivesAReload() {
        let (shelf, defaults, release) = store()
        defer { release() }
        let dropped = URL(fileURLWithPath: "/tmp/notes.txt")
        let collected = URL(fileURLWithPath: "/tmp/Screenshot at 09.00.00.png")
        shelf.add([dropped])
        shelf.add([collected], origin: .collected)
        XCTAssertEqual(shelf.items.first { $0.url == dropped }?.origin, .placed, "a drop is a person's by default")
        XCTAssertEqual(shelf.items.first { $0.url == collected }?.origin, .collected)

        let reloaded = ShelfStore(defaults: defaults)
        reloaded.load()
        XCTAssertEqual(reloaded.items.first { $0.url == dropped }?.origin, .placed)
        XCTAssertEqual(reloaded.items.first { $0.url == collected }?.origin, .collected)
    }

    /// A Shelf saved before the origin was kept says nothing about who put
    /// each card there. Read as collected: one stray card left out of the
    /// island costs nothing, sixty screenshots kept on it was the bug.
    func testCardsSavedBeforeOriginsWereKeptLoadAsCollected() {
        let (_, defaults, release) = store()
        defer { release() }
        defaults.set(["/tmp/a.png", "/tmp/b.png"], forKey: "shelf.urls")

        let shelf = ShelfStore(defaults: defaults)
        shelf.load()
        XCTAssertEqual(shelf.items.map(\.origin), [.collected, .collected])
    }

    /// Dropping a collected screenshot on the notch is a person keeping it:
    /// the card becomes theirs. The reverse never happens — a capture that
    /// lands on a file a person already put there leaves it theirs.
    func testADropMakesACollectedCardAPersonsAndACaptureNeverTakesOneBack() {
        let (shelf, defaults, release) = store()
        defer { release() }
        let shot = URL(fileURLWithPath: "/tmp/Screenshot at 10.00.00.png")
        let notes = URL(fileURLWithPath: "/tmp/notes.txt")
        shelf.add([shot], origin: .collected)
        shelf.add([notes])

        shelf.add([shot])
        shelf.add([notes], origin: .collected)
        XCTAssertEqual(shelf.items.first { $0.url == shot }?.origin, .placed, "kept by hand")
        XCTAssertEqual(shelf.items.first { $0.url == notes }?.origin, .placed, "still the person's")

        let reloaded = ShelfStore(defaults: defaults)
        reloaded.load()
        XCTAssertEqual(reloaded.items.map(\.origin), [.placed, .placed], "and saved that way")
    }

    /// A recording picked up from the capture folder is Isla's doing.
    func testAPickedUpRecordingIsCollected() throws {
        let (shelf, defaults, release) = store()
        defer { release() }
        defaults.set(Date.distantPast, forKey: RecordingPickup.sinceKey)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("rec.mov"))

        shelf.importNewRecordings(from: dir)
        try XCTSkipIf(shelf.items.isEmpty, "Import Screen Recordings is off in this defaults domain")
        XCTAssertEqual(shelf.items.map(\.origin), [.collected])
    }

    /// The clipboard's screenshots and recordings reach the Shelf through one
    /// door, which marks them collected and tells the island.
    func testACopiedCaptureLandsCollectedAndIsAnnounced() {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let url = files(1, "copied", in: isolated)[0]
        var announced: [URL] = []
        isolated.stores.onScreenshot = { announced.append($0) }

        isolated.stores.collect(url)
        XCTAssertEqual(isolated.stores.shelf.items.map(\.origin), [.collected])
        XCTAssertEqual(announced, [url])
    }

    // MARK: The island

    /// Collected files alone leave the island in the notch, with or without a
    /// song: no compact Shelf, no bubble.
    func testCollectedFilesAloneLeaveTheIslandInTheNotch() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        isolated.stores.shelf.add(files(60, "shot", in: isolated), origin: .collected)

        XCTAssertEqual(vm.activity, .none, "sixty screenshots and the island rests")
        isolated.stores.media.apply(playing())
        XCTAssertEqual(vm.activity, .music)
        XCTAssertNil(vm.bubbleCount, "and no bubble beside the song")
    }

    /// One file a person put there makes the Shelf live, and the count is
    /// still everything on it — what the tray will show when it opens.
    func testAPlacedFileKeepsTheShelfLiveAndTheCountIsEverything() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        let shelf = isolated.stores.shelf
        shelf.add(files(3, "shot", in: isolated), origin: .collected)
        shelf.add(files(1, "kept", in: isolated))

        XCTAssertEqual(vm.activity, .shelf(count: 4))
        isolated.stores.media.apply(playing())
        XCTAssertEqual(vm.bubbleCount, 4)

        let kept = try XCTUnwrap(shelf.items.first { $0.origin == .placed })
        shelf.remove(kept)
        XCTAssertNil(vm.bubbleCount, "the person's file gone, the screenshots alone keep nothing")
    }

    /// A collected file shows the Shelf for a moment — compact on the bare
    /// notch, the bubble beside a song — and then the island rests.
    func testACaptureShowsTheShelfForAMomentThenTheIslandRests() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        XCTAssertEqual(NotchViewModel.collectedMoment, .seconds(2), "spec §19.1, amended 2026-10-17")
        vm.collectedMomentLifetime = .milliseconds(150)
        let urls = files(2, "shot", in: isolated)

        isolated.stores.shelf.add([urls[0]], origin: .collected)
        vm.receivedScreenshot(at: urls[0])
        XCTAssertEqual(vm.activity, .shelf(count: 1), "the tray and the count, at once")
        settle(0.5)
        XCTAssertEqual(vm.activity, .none, "then the notch")

        isolated.stores.media.apply(playing())
        isolated.stores.shelf.add([urls[1]], origin: .collected)
        vm.receivedScreenshot(at: urls[1])
        XCTAssertEqual(vm.bubbleCount, 2, "beside a song the moment is the bubble")
        settle(0.5)
        XCTAssertNil(vm.bubbleCount)
    }

    /// Each capture holds the moment from itself, so a burst of screenshots
    /// keeps the Shelf up until the last one's moment is over.
    func testEachCaptureRestartsTheMoment() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        // Wide margins: the check falls 0.2 s after the first moment would
        // have ended and 0.4 s before the second does, so a loaded runner
        // that oversleeps cannot fail it.
        vm.collectedMomentLifetime = .seconds(1)
        let urls = files(2, "shot", in: isolated)

        isolated.stores.shelf.add([urls[0]], origin: .collected)
        vm.receivedScreenshot(at: urls[0])
        settle(0.6)
        isolated.stores.shelf.add([urls[1]], origin: .collected)
        vm.receivedScreenshot(at: urls[1])
        settle(0.6)
        XCTAssertEqual(vm.activity, .shelf(count: 2), "the first moment would be over; the second holds")
        settle(1.0)
        XCTAssertEqual(vm.activity, .none)
    }

    /// Nothing is shown for a capture that lands while a surface is open —
    /// the island is not on screen — and opening ends one in progress, as it
    /// ends a peek or an alert, so closing never uncovers a stale moment.
    func testAnOpenSurfaceTakesNoMomentAndEndsOne() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        let url = files(1, "shot", in: isolated)[0]
        isolated.stores.shelf.add([url], origin: .collected)

        vm.isOpen = true
        vm.receivedScreenshot(at: url)
        vm.isOpen = false
        XCTAssertEqual(vm.activity, .none, "nothing waited behind the open surface")

        vm.receivedScreenshot(at: url)
        XCTAssertEqual(vm.activity, .shelf(count: 1))
        vm.isOpen = true
        vm.isOpen = false
        XCTAssertEqual(vm.activity, .none, "opening ended it")
    }

    /// The shield going up ends a moment in progress, as opening does: the
    /// compact Shelf over the lock screen, folding there a second later with
    /// nobody asking, is the island talking to an empty room.
    func testLockingEndsAMoment() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        let url = files(1, "shot", in: isolated)[0]
        isolated.stores.shelf.add([url], origin: .collected)

        vm.receivedScreenshot(at: url)
        XCTAssertTrue(vm.isShowingCollected)
        vm.isLockedPresentation = true
        XCTAssertFalse(vm.isShowingCollected, "the lock ended it")
        vm.isLockedPresentation = false
        XCTAssertEqual(vm.activity, .none, "and unlocking does not bring it back")
    }

    /// A card dragged out of the Shelf and let go over the panel is the
    /// Shelf's own card coming back, not a person keeping a file. Taken as a
    /// drop, it made a collected screenshot a person's, and one cancelled drag
    /// kept the island out of the notch for good (R7 review).
    func testACardLetGoOverThePanelIsNotKept() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        let url = files(1, "shot", in: isolated)[0]
        isolated.stores.shelf.add([url], origin: .collected)

        ShelfDragSource.beginDragOut()
        defer { ShelfDragSource.endDragOut() }
        XCTAssertFalse(vm.acceptDrop(urls: [url]), "refused, so the card slides back where it came from")
        XCTAssertEqual(isolated.stores.shelf.items.map(\.origin), [.collected])
        XCTAssertEqual(vm.activity, .none)
    }

    /// The Shelf's limit takes collected cards first, oldest first, and a
    /// person's only when nothing collected is left: sixty screenshots copied
    /// with the panel shut used to push out the one PDF somebody kept, with
    /// the notice saying so in a footer nobody saw.
    func testAFullShelfLetsCollectedCardsGoFirst() {
        let (shelf, _, release) = store()
        defer { release() }
        let kept = URL(fileURLWithPath: "/tmp/kept.pdf")
        shelf.add([kept], dates: [kept: Date(timeIntervalSinceNow: -86_400)])
        let shots = (0..<ShelfStore.limit).map { URL(fileURLWithPath: "/tmp/shot-\($0).png") }
        for (index, shot) in shots.enumerated() {
            shelf.add([shot], dates: [shot: Date(timeIntervalSinceNow: -Double(ShelfStore.limit - index))], origin: .collected)
        }

        XCTAssertEqual(shelf.items.count, ShelfStore.limit)
        XCTAssertTrue(shelf.items.contains { $0.url == kept }, "the person's file stays")
        XCTAssertFalse(shelf.items.contains { $0.url == shots[0] }, "the oldest screenshot went instead")

        let placed = (0..<ShelfStore.limit).map { URL(fileURLWithPath: "/tmp/placed-\($0).txt") }
        shelf.add(placed)
        XCTAssertEqual(shelf.items.count, ShelfStore.limit)
        XCTAssertTrue(shelf.items.allSatisfy { $0.origin == .placed }, "every screenshot went before any person's file")
        XCTAssertFalse(shelf.items.contains { $0.url == kept }, "then the oldest person's file, as before")
    }

    /// Who put each card there is kept by path, not by position, so a build
    /// from before this — which rewrites the list and leaves this key alone —
    /// cannot shift the origins onto other cards.
    func testOriginsFollowTheirFilesWhenAnOlderBuildReordersTheList() {
        let (shelf, defaults, release) = store()
        defer { release() }
        let notes = URL(fileURLWithPath: "/tmp/notes.txt")
        let shot = URL(fileURLWithPath: "/tmp/Screenshot.png")
        shelf.add([notes], dates: [notes: Date(timeIntervalSinceNow: -60)])
        shelf.add([shot], dates: [shot: Date()], origin: .collected)

        // What an older build leaves behind after its own save: the same two
        // cards in another order, and no bookmarks it did not make.
        defaults.set([notes.path, shot.path], forKey: "shelf.urls")
        defaults.removeObject(forKey: "shelf.urls.bookmarks")
        defaults.removeObject(forKey: "shelf.urls.dates")

        let reloaded = ShelfStore(defaults: defaults)
        reloaded.load()
        XCTAssertEqual(reloaded.items.first { $0.url == notes }?.origin, .placed)
        XCTAssertEqual(reloaded.items.first { $0.url == shot }?.origin, .collected)
    }

    // MARK: The cut

    /// The window's clickable regions follow the Shelf: the bubble's rect
    /// comes with a capture's moment and goes when it ends, and is as wide as
    /// the count's digits. A region left behind takes the menu bar's clicks
    /// over nothing; one cut short drops clicks on the bubble's edge.
    func testTheCutFollowsTheMomentAndTheCountsDigits() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        vm.collectedMomentLifetime = .milliseconds(300)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        isolated.stores.media.apply(playing())
        settle(0.05)

        let urls = files(10, "shot", in: isolated)
        isolated.stores.shelf.add(Array(urls[0..<9]), origin: .collected)
        settle(0.05)
        XCTAssertEqual(root.bubbleRect, .zero, "collected files alone: no bubble, no region")

        isolated.stores.shelf.add([urls[9]], origin: .collected)
        vm.receivedScreenshot(at: urls[9])
        settle(0.1)
        XCTAssertEqual(
            root.bubbleRect.width, IslandBubbleLayout.width(count: 10), accuracy: 0.001,
            "the moment's bubble, two digits wide"
        )
        settle(0.6)
        XCTAssertEqual(root.bubbleRect, .zero, "gone with the moment")
    }
}
