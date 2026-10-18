import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Shelf's behaviour around the tray (spec §8, §19.7): what the controller
/// does with the Delete key, how a drop that was already kept looks, how Remove
/// All asks, what a tile's thumbnail is, where an AirDrop-aimed promise goes,
/// and how the tray lays its row out.
///
/// Nothing here opens a file, shows Quick Look, starts AirDrop, writes the
/// general pasteboard or reserves a real key: stores are isolated, files live
/// in a temporary folder, and the Delete key goes through a recording
/// registrar.
@MainActor
final class ShelfPaneTests: XCTestCase {
    private var spoken: [String] = []
    private var savedSink: ((String) -> Void)?

    override func setUp() {
        super.setUp()
        spoken = []
        savedSink = Announcer.shared.sink
        Announcer.shared.sink = { [unowned self] in spoken.append($0) }
        Announcer.shared.forget()
        _ = ArmedConfirmations.shared.disarmAll()
    }

    override func tearDown() {
        _ = ArmedConfirmations.shared.disarmAll()
        if let savedSink { Announcer.shared.sink = savedSink }
        Announcer.shared.forget()
        super.tearDown()
    }

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let folder: URL
        let shelf: ShelfStore
        let files: [URL]

        @MainActor
        init(names: [String]) throws {
            suiteName = "ShelfPaneTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("isla-shelf-pane-\(UUID().uuidString)", isDirectory: true)
            self.folder = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            shelf = ShelfStore(defaults: defaults)
            shelf.requestThumbnail = { _, done in done(nil) }
            shelf.makeBookmark = { _ in nil }
            let made = names.map { folder.appendingPathComponent($0) }
            for file in made { FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)) }
            if !made.isEmpty { shelf.add(made) }
            files = made
        }

        func release() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Already kept (§8.4)

    /// A drop of what the shelf already holds adds nothing, lights the tile it
    /// matched — and only that one — and says so under the row, for 1.2 s.
    func testADropOfWhatIsKeptLightsItsTileAndAddsNothing() throws {
        let fixture = try Fixture(names: ["a.txt", "b.txt", "c.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        XCTAssertTrue(shelf.alreadyKept.isEmpty)
        let target = try XCTUnwrap(shelf.items.first { $0.url == fixture.files[1] })

        let result = shelf.add([fixture.files[1]])

        XCTAssertEqual(result, ShelfStore.AddResult(added: 0, duplicates: 1, evicted: 0))
        XCTAssertEqual(shelf.items.count, 3, "no duplicate")
        XCTAssertEqual(shelf.alreadyKept, [target.id], "the existing tile, and no other")
        XCTAssertEqual(shelf.notice, .alreadyOnShelf)
        XCTAssertEqual(ShelfStore.Notice.alreadyOnShelf.text, "Already on the Shelf")
        XCTAssertTrue(shelf.selection.isEmpty, "the flash is drawing: it never selects")
        XCTAssertEqual(
            ShelfWell.state(isSelected: false, isHovered: false, isAlreadyKept: shelf.alreadyKept.contains(target.id)),
            .alreadyKept
        )
        XCTAssertNil(ShelfWell.state(
            isSelected: false, isHovered: false,
            isAlreadyKept: shelf.alreadyKept.contains(try XCTUnwrap(shelf.items.first { $0.url == fixture.files[0] }).id)
        ))
    }

    func testTheFlashAndTheLineLastOnePointTwoSeconds() async throws {
        XCTAssertEqual(ShelfStore.alreadyKeptLifetime, .milliseconds(1200))
        let fixture = try Fixture(names: ["a.txt", "b.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        shelf.noticeLifetime = .milliseconds(200)  // the one seam shortens both, never lengthens
        shelf.add([fixture.files[0]])
        XCTAssertFalse(shelf.alreadyKept.isEmpty)
        XCTAssertEqual(shelf.notice, .alreadyOnShelf)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(shelf.alreadyKept.isEmpty, "the tile stops lighting")
        XCTAssertNil(shelf.notice, "and the bar stops saying so")
    }

    /// Another sentence — the eviction line — keeps `noticeLifetime`, which is
    /// four seconds (spec §8.4, `Shelf-Full`).
    func testOnlyTheNodIsShort() {
        let shelf = ShelfStore(defaults: UserDefaults(suiteName: "ShelfPaneTests.\(UUID())")!)
        XCTAssertEqual(shelf.noticeLifetime, .seconds(4))
    }

    func testRemovingATileTakesItsFlashWithIt() throws {
        let fixture = try Fixture(names: ["a.txt", "b.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        shelf.add([fixture.files[0]])
        let lit = try XCTUnwrap(shelf.items.first { shelf.alreadyKept.contains($0.id) })
        shelf.remove(lit)
        XCTAssertTrue(shelf.alreadyKept.isEmpty)
        shelf.add([fixture.files[1]])
        shelf.clear()
        XCTAssertTrue(shelf.alreadyKept.isEmpty)
    }

    // MARK: - Clear asks once (§8.4)

    func testClearAsksOnceAndCancelKeepsEverything() throws {
        let fixture = try Fixture(names: ["a.txt", "b.txt", "c.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        let clear = ShelfClearConfirmation()
        shelf.select(shelf.items[0], modifiers: [])

        clear.ask(count: shelf.items.count)
        XCTAssertTrue(clear.isAsking)
        XCTAssertEqual(spoken, ["Remove all 3 items? Files are untouched."], "a person who cannot see the tray change is told")

        clear.cancel()
        XCTAssertFalse(clear.isAsking)
        XCTAssertEqual(shelf.items.count, 3, "Cancel keeps every tile")
        XCTAssertEqual(shelf.selection.count, 1, "and the selection")
        for file in fixture.files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testRemoveAllEmptiesTheShelfButNotTheFiles() throws {
        let fixture = try Fixture(names: ["a.txt", "b.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        let clear = ShelfClearConfirmation()
        var cleared = 0
        clear.confirm { cleared += 1 }
        XCTAssertEqual(cleared, 0, "nothing was asked, so there is nothing to confirm")

        clear.ask(count: 2)
        clear.confirm { shelf.clear() }
        XCTAssertFalse(clear.isAsking)
        XCTAssertTrue(shelf.items.isEmpty)
        for file in fixture.files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "files are untouched") }
    }

    /// Escape answers "no" before it folds the panel, as it did the arming:
    /// the first Escape cancels, and only the second, with nothing left asked,
    /// is the fold's.
    func testEscapeCancelsTheQuestion() {
        let clear = ShelfClearConfirmation()
        clear.ask(count: 5)
        XCTAssertTrue(ArmedConfirmations.shared.disarmAll(), "the question is the Escape's to answer")
        XCTAssertFalse(clear.isAsking)
        XCTAssertFalse(ArmedConfirmations.shared.disarmAll(), "the second Escape finds nothing asked")
    }

    func testAskingTwiceOrOfNothingDoesNothingMore() {
        let clear = ShelfClearConfirmation()
        clear.ask(count: 0)
        XCTAssertFalse(clear.isAsking, "an empty shelf has nothing to ask about")
        clear.ask(count: 4)
        clear.ask(count: 4)
        XCTAssertEqual(spoken.count, 1, "said once")
        clear.cancel()
        XCTAssertFalse(ArmedConfirmations.shared.disarmAll(), "cancelling withdraws it from the registry")
    }

    // MARK: - Tiles

    /// Only images earn a Quick Look thumbnail; everything else keeps its
    /// type's icon, as Finder's icon view draws it.
    func testOnlyImagesAreAskedForAPreview() {
        for name in ["a.png", "b.jpg", "c.JPEG", "d.heic", "e.gif", "f.tiff"] {
            XCTAssertTrue(ShelfStore.wantsPreview(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.pdf", "b.txt", "c.mov", "d.zip", "e.key", "folder", "f.docx", "g.mp3"] {
            XCTAssertFalse(ShelfStore.wantsPreview(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testAnImageGetsAPreviewAndTheRestKeepTheirIcons() async throws {
        let fixture = try Fixture(names: [])
        defer { fixture.release() }
        let shelf = fixture.shelf
        var asked: [String] = []
        shelf.requestThumbnail = { url, done in
            asked.append(url.lastPathComponent)
            done(NSImage(size: NSSize(width: 8, height: 4)))
        }
        let urls = ["shot.png", "report.pdf", "notes.txt"].map { fixture.folder.appendingPathComponent($0) }
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
        shelf.add(urls)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(asked, ["shot.png"], "QuickLook is asked about the image alone")
        XCTAssertEqual(shelf.items.filter(\.isPreview).map(\.name), ["shot.png"])
        XCTAssertTrue(shelf.items.filter { !$0.isPreview }.allSatisfy { $0.name != "shot.png" })
    }

    // MARK: - Open With

    func testOpenWithListsTheDefaultFirstThenTheRestByNameEachOnce() {
        func app(_ name: String) -> URL { URL(fileURLWithPath: "/Applications/\(name).app") }
        let nameOf: (URL) -> String = { $0.deletingPathExtension().lastPathComponent }
        let apps = ShelfOpenWith.ordered(
            default: app("Preview"),
            all: [app("TextEdit"), app("Preview"), app("Acrobat"), app("textedit"), app("Safari")],
            name: nameOf
        )
        XCTAssertEqual(apps.map(\.name), ["Preview", "Acrobat", "Safari", "TextEdit", "textedit"],
                       "the default first, then by name; the default is not listed twice")
        XCTAssertEqual(ShelfOpenWith.ordered(default: nil, all: [app("B"), app("A")], name: nameOf).map(\.name), ["A", "B"])
        XCTAssertTrue(ShelfOpenWith.ordered(default: nil, all: [], name: nameOf).isEmpty)
        let many = (0..<30).map { app("App\($0)") }
        XCTAssertEqual(ShelfOpenWith.ordered(default: nil, all: many, name: nameOf).count, ShelfOpenWith.limit)
    }

    // MARK: - A drop aimed at AirDrop

    /// A promise cannot be sent until its source has written the file, so the
    /// aim travels with the drop's own receiver callbacks and is honoured when
    /// that file lands — and only for that drop's files.
    func testAPromisedDropAimedAtAirDropIsSentNotKept() {
        let fixture = try! Fixture(names: [])
        defer { fixture.release() }
        let inbox = PromisedDropInbox(shelf: fixture.shelf)
        var kept: [[URL]] = []
        var sent: [[URL]] = []
        let delivered = expectation(description: "two batches")
        delivered.expectedFulfillmentCount = 2
        inbox.onBatch = { kept.append($0); delivered.fulfill() }
        inbox.onAirDropBatch = { sent.append($0); delivered.fulfill() }

        let first = URL(fileURLWithPath: "/tmp/isla-airdrop-promise-1.txt")
        let second = URL(fileURLWithPath: "/tmp/isla-airdrop-promise-2.txt")
        let queue = OperationQueue()
        queue.addOperation { inbox.arrived(url: first, error: nil, toAirDrop: true) }
        // The first batch is delivered before the second drop is made.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            queue.addOperation { inbox.arrived(url: second, error: nil, toAirDrop: false) }
        }
        wait(for: [delivered], timeout: 4)
        XCTAssertEqual(sent, [[first]], "the AirDrop-aimed drop is sent")
        XCTAssertEqual(kept, [[second]], "the next one is kept: the aim was for that drop")
    }

    /// Review 2026-10-15: one shared flag meant a second promised drop made
    /// before the first batch landed overwrote the first's destination, and a
    /// Keep drop still downloading could be sent with AirDrop. Both orders, two
    /// drops whose files arrive inside the same coalescing window.
    func testOverlappingPromisedDropsEachKeepTheirOwnDestination() {
        for firstToAirDrop in [false, true] {
            let fixture = try! Fixture(names: [])
            defer { fixture.release() }
            let inbox = PromisedDropInbox(shelf: fixture.shelf)
            var kept: [[URL]] = []
            var sent: [[URL]] = []
            let delivered = expectation(description: "both destinations, first to AirDrop \(firstToAirDrop)")
            delivered.expectedFulfillmentCount = 2
            inbox.onBatch = { kept.append($0); delivered.fulfill() }
            inbox.onAirDropBatch = { sent.append($0); delivered.fulfill() }

            let first = URL(fileURLWithPath: "/tmp/isla-overlap-first.txt")
            let second = URL(fileURLWithPath: "/tmp/isla-overlap-second.txt")
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            // Drop one is released, drop two is released, and only then do
            // either's files land.
            queue.addOperation { inbox.arrived(url: first, error: nil, toAirDrop: firstToAirDrop) }
            queue.addOperation { inbox.arrived(url: second, error: nil, toAirDrop: !firstToAirDrop) }
            wait(for: [delivered], timeout: 4)
            XCTAssertEqual(sent, [[firstToAirDrop ? first : second]], "first to AirDrop: \(firstToAirDrop)")
            XCTAssertEqual(kept, [[firstToAirDrop ? second : first]], "first to AirDrop: \(firstToAirDrop)")
        }
    }

    /// Re-review 2026-10-15: an AirDrop-aimed promise that lands long after the
    /// release is kept, not sent. Injected clock: 3 s sends, 30 s keeps.
    func testALateAirDropAimedPromiseIsKeptNotSent() {
        for (elapsed, expectSent) in [(3.0, true), (30.0, false)] {
            let fixture = try! Fixture(names: [])
            defer { fixture.release() }
            let inbox = PromisedDropInbox(shelf: fixture.shelf)
            let released = Date(timeIntervalSince1970: 1_000_000)
            inbox.now = { released.addingTimeInterval(elapsed) }
            var kept: [[URL]] = []
            var sent: [[URL]] = []
            let delivered = expectation(description: "one batch at \(elapsed) s")
            inbox.onBatch = { kept.append($0); delivered.fulfill() }
            inbox.onAirDropBatch = { sent.append($0); delivered.fulfill() }
            let file = URL(fileURLWithPath: "/tmp/isla-late-airdrop-\(elapsed).txt")
            OperationQueue().addOperation { inbox.arrived(url: file, error: nil, toAirDrop: true, releasedAt: released) }
            wait(for: [delivered], timeout: 4)
            XCTAssertEqual(sent, expectSent ? [[file]] : [], "at \(elapsed) s")
            XCTAssertEqual(kept, expectSent ? [] : [[file]], "at \(elapsed) s")
        }
    }

    // MARK: - The controller's Delete key

    private func rig(center: NotificationCenter = NotificationCenter()) throws -> (NotchController, NotchViewModel, ProbeStores, ShelfDeleteKeyTests.FakeRegistrar) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let controller = NotchController()
        let fake = ShelfDeleteKeyTests.FakeRegistrar()
        controller.deleteKeyRegistrar = fake.registrar
        controller.appIsActive = { false }
        controller.activationCenter = center
        controller.attachForTesting(viewModel: vm, rootView: NotchRootView(frame: .zero))
        return (controller, vm, isolated, fake)
    }

    /// The whole claim at the controller, through the real wiring — `isOpen`,
    /// the tab, the pointer, the lock and the selection are only ever assigned
    /// (review 2026-10-15: the test used to call `refreshDeleteKey()` after each
    /// step, so the sink `build` installs was never what it exercised). Open on
    /// the Shelf, pointer on it, a tile picked: held. Each way it ends gives
    /// the keys back at once, and a selection that did not survive the way out
    /// is not brought back by the way in.
    func testTheControllerHoldsTheKeyOnlyWhileTheClaimHolds() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release(); controller.teardown() }
        let urls = ["a.txt", "b.txt"].map { URL(fileURLWithPath: "/tmp/isla-delete-\($0)") }
        vm.shelf.add(urls)

        vm.isOpen = true
        vm.surface = .tray
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertFalse(controller.holdsDeleteKey, "the pointer is not on the Shelf yet")
        vm.isPointerOnShelf = true
        XCTAssertTrue(controller.holdsDeleteKey, "pointer on the Shelf, a selection made this opening: held")
        XCTAssertEqual(fake.live.count, 2)

        vm.isPointerOnShelf = false
        XCTAssertFalse(controller.holdsDeleteKey, "the pointer left")
        vm.isPointerOnShelf = true
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.surface = .clipboard
        XCTAssertFalse(controller.holdsDeleteKey, "the tab changed")
        XCTAssertTrue(vm.shelf.selection.isEmpty, "and the selection did not wait for the Shelf's return")
        vm.surface = .tray
        XCTAssertFalse(controller.holdsDeleteKey, "coming back finds nothing picked, so nothing held")
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.isLockedPresentation = true
        XCTAssertFalse(controller.holdsDeleteKey, "the screen locked")
        vm.isLockedPresentation = false
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.isOpen = false
        XCTAssertFalse(controller.holdsDeleteKey, "the panel closed")
        XCTAssertTrue(vm.shelf.selection.isEmpty, "a selection belongs to one opening")
        vm.isOpen = true
        XCTAssertFalse(controller.holdsDeleteKey, "reopened: the old selection is gone, not revived")
        vm.shelf.select(vm.shelf.items[1], modifiers: [])
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.shelf.clearSelection()
        XCTAssertFalse(controller.holdsDeleteKey, "the selection emptied")

        XCTAssertTrue(fake.live.isEmpty, "nothing left registered")
        XCTAssertLessThanOrEqual(fake.peak, 2, "never registered twice")
    }

    /// Review 2026-10-15, the scenario: a tile picked on Monday, the panel
    /// closed, and on Tuesday the pointer rests on the grid while the person
    /// types in Mail. The Delete key must still be Mail's.
    func testAStaleSelectionNeverHoldsTheKeyAcrossAnOpening() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release(); controller.teardown() }
        vm.shelf.add(["a", "b"].map { URL(fileURLWithPath: "/tmp/isla-delete-stale-\($0).txt") })

        vm.isOpen = true
        vm.surface = .tray
        vm.isPointerOnShelf = true
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertTrue(controller.holdsDeleteKey, "Monday")
        let generation = vm.openingGeneration
        vm.isOpen = false
        XCTAssertFalse(controller.holdsDeleteKey)

        // Tuesday: the panel opens on the Shelf with the pointer already resting on it.
        vm.isOpen = true
        XCTAssertGreaterThan(vm.openingGeneration, generation, "a new opening has its own stamp")
        XCTAssertTrue(vm.isPointerOnShelf)
        XCTAssertFalse(controller.holdsDeleteKey, "nothing was picked on this opening")
        controller.deleteKeyPressed()
        XCTAssertEqual(vm.shelf.items.count, 2, "a Delete pressed now removes nothing")

        // Even a selection that reached the store without passing through a
        // close (made while the panel was shut) carries Monday's stamp, not Tuesday's.
        vm.isOpen = false
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertFalse(vm.shelfSelectionIsCurrent, "made while shut")
        vm.isOpen = true
        XCTAssertFalse(vm.shelfSelectionIsCurrent, "and not made during the opening that follows")
        XCTAssertFalse(controller.holdsDeleteKey)
        XCTAssertTrue(fake.live.isEmpty)
    }

    func testAppActivationGivesTheKeyBack() throws {
        let center = NotificationCenter()
        let (controller, vm, isolated, fake) = try rig(center: center)
        defer { isolated.release(); controller.teardown() }
        vm.shelf.add([URL(fileURLWithPath: "/tmp/isla-delete-active.txt")])
        vm.isOpen = true
        vm.surface = .tray
        vm.isPointerOnShelf = true
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertTrue(controller.holdsDeleteKey)
        // Activation is the one input that is not the model's: the controller
        // hears it from the two notifications and calls this.
        controller.appIsActive = { true }  // Quick Look activated Isla
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(controller.holdsDeleteKey)
        XCTAssertTrue(fake.live.isEmpty)
    }

    /// Codex P1, re-review 2026-10-15: the sink read the old value of a
    /// `@Published`, so the first selection did not install the watch.
    func testTheFirstSelectionInstallsTheOutsideClickWatchAndClearingRemovesIt() throws {
        let (controller, vm, isolated, _) = try rig()
        defer { isolated.release(); controller.teardown() }
        var installed = 0, removed = 0
        controller.installOutsideClickMonitor = { _ in installed += 1; return NSObject() }
        controller.removeOutsideClickMonitor = { _ in removed += 1 }
        vm.shelf.add([URL(fileURLWithPath: "/tmp/isla-watch.txt")])
        vm.isOpen = true
        vm.surface = .tray
        XCTAssertEqual(installed, 0)
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertEqual(installed, 1, "first selection installs the watch")
        vm.shelf.clearSelection()
        XCTAssertEqual(removed, 1, "no selection, no watch")
    }

    /// Re-review 2026-10-15: with the panel never activating, clicking into
    /// Mail fires no activation notification; the mouse-down outside is what
    /// releases Delete.
    func testAnOutsideMouseDownClearsTheSelectionAndReleasesDelete() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release(); controller.teardown() }
        vm.shelf.add([URL(fileURLWithPath: "/tmp/isla-delete-outside.txt")])
        vm.isOpen = true
        vm.surface = .tray
        vm.isPointerOnShelf = true
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertTrue(controller.holdsDeleteKey)
        controller.outsideMouseDown()
        XCTAssertTrue(vm.shelf.selection.isEmpty)
        XCTAssertFalse(controller.holdsDeleteKey)
        XCTAssertTrue(fake.live.isEmpty)
    }

    /// A press removes the selection through the controller, and a press that
    /// arrives with no claim — queued behind the event that ended it — removes
    /// nothing and gives the keys back instead.
    func testAPressRemovesTheSelectionOnlyWhileTheClaimHolds() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release(); controller.teardown() }
        vm.shelf.add(["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/isla-delete-press-\($0).txt") })
        vm.isOpen = true
        vm.surface = .tray
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        vm.shelf.select(vm.shelf.items[1], modifiers: .command)
        vm.isPointerOnShelf = true
        XCTAssertEqual(fake.live.count, 2)

        // The pointer left, but a press was already queued behind the event.
        // The registration follows the model at once, so put one back to stand
        // in for the queued press.
        vm.isPointerOnShelf = false
        XCTAssertTrue(fake.live.isEmpty)
        controller.deleteKeyPressed()
        XCTAssertEqual(vm.shelf.items.count, 3, "no claim, no removal")
        XCTAssertFalse(controller.holdsDeleteKey, "and the keys stay handed back")

        vm.isPointerOnShelf = true
        XCTAssertTrue(controller.holdsDeleteKey)
        controller.deleteKeyPressed()
        XCTAssertEqual(vm.shelf.items.count, 1, "the two picked tiles went")
        XCTAssertTrue(vm.shelf.selection.isEmpty)
        XCTAssertFalse(controller.holdsDeleteKey, "nothing left to remove: the keys go back")
    }

    /// Teardown, a rebuild's first act, gives the keys back whatever the claim.
    func testTeardownGivesTheKeyBack() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release() }
        vm.shelf.add([URL(fileURLWithPath: "/tmp/isla-delete-teardown.txt")])
        vm.isOpen = true
        vm.surface = .tray
        vm.isPointerOnShelf = true
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        XCTAssertTrue(controller.holdsDeleteKey)
        controller.teardown()
        XCTAssertFalse(controller.holdsDeleteKey)
        XCTAssertTrue(fake.live.isEmpty)
    }

    // MARK: - The tray's grid

    /// The tray's content, `ShelfLayout.viewport`: the panel's width at its
    /// default, 560, and 262 under the header row — the three tools' shared
    /// page (§19.16, amended 2026-10-18).
    private static let trayWidth: CGFloat = 560
    private var traySize: CGSize { ShelfLayout.viewport(bodyWidth: Self.trayWidth).size }

    private func tray(_ shelf: ShelfStore, clear: ShelfClearConfirmation = ShelfClearConfirmation()) -> ShelfPane {
        ShelfPane(shelf: shelf, clear: clear, bodyWidth: Self.trayWidth)
    }

    private func names(_ count: Int) -> [String] { (0..<count).map { String(format: "file-%02d.txt", $0) } }

    /// Rows of 80 × 94 tiles on a 90 pitch across and 104 down, six to a row
    /// at 560, centred: two rows in view and part of a third, which is what
    /// the grid scrolls down for (owner, 2026-10-18).
    func testTheGridFillsRowsAndScrollsDown() async throws {
        let fixture = try Fixture(names: names(16))
        defer { fixture.release() }
        let size = traySize
        let root = await AXProbe.tree(of: tray(fixture.shelf), size: size)
        let tiles = root.all(role: "AXButton").filter { $0.label.hasPrefix("file-") }
        let frames = tiles.compactMap(\.frame).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        XCTAssertEqual(frames.count, tiles.count, root.dump)
        XCTAssertGreaterThanOrEqual(frames.count, 13, "the third row is built, past the foot\n\(root.dump)")
        let first = ShelfLayout.tileFrame(index: 0, bodyWidth: Self.trayWidth)
        XCTAssertEqual(frames[0].minX, first.minX, accuracy: 1, "the grid's leading edge")
        XCTAssertEqual(frames[0].minY, first.minY, accuracy: 1, "on the board's y")
        XCTAssertEqual(frames[0].width, 80, accuracy: 1)
        XCTAssertEqual(frames[0].height, 94, accuracy: 1)
        let rows = Dictionary(grouping: frames) { ($0.minY * 2).rounded() }.sorted { $0.key < $1.key }
        XCTAssertEqual(rows.first?.value.count, 6, "six to a row at 560\n\(root.dump)")
        for row in rows {
            let xs = row.value.map(\.minX).sorted()
            for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertEqual(b - a, 90, accuracy: 1, "90 pt apart across") }
        }
        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertEqual((b.key - a.key) / 2, 104, accuracy: 1, "104 pt apart down")
        }
        XCTAssertLessThanOrEqual(rows[1].value[0].maxY, size.height + 1, "two rows inside the tray")
        XCTAssertGreaterThan(rows[2].value[0].maxY, size.height, "and the third runs past its foot")
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, -1, "nothing runs off sideways")
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 1)
        }
    }

    /// Two rows or fewer do not scroll.
    func testTwoRowsNeedNoScrolling() async throws {
        let fixture = try Fixture(names: names(12))
        defer { fixture.release() }
        let size = traySize
        let root = await AXProbe.tree(of: tray(fixture.shelf), size: size)
        let frames = root.all(role: "AXButton").filter { $0.label.hasPrefix("file-") }.compactMap(\.frame)
        XCTAssertEqual(frames.count, 12, root.dump)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minY, -1)
            XCTAssertLessThanOrEqual(frame.maxY, size.height + 1)
        }
        XCTAssertFalse(ShelfLayout.scrolls(count: frames.count, bodyWidth: Self.trayWidth))
    }

    /// Pressing Remove All (the header's, which asks the model's confirmation)
    /// puts the question where the row was, with its two answers; Cancel takes
    /// it away and everything is where it was.
    func testRemoveAllAsksInPlaceAndCancelPutsItAway() async throws {
        let fixture = try Fixture(names: names(3))
        defer { fixture.release() }
        let ask = ShelfClearConfirmation()
        let root = await AXProbe.tree(of: tray(fixture.shelf, clear: ask), size: traySize)
        XCTAssertFalse(words(root).contains("Remove all 3 items? Files are untouched."), root.dump)
        ask.ask(count: fixture.shelf.items.count)
        defer { ask.cancel() }
        let asking = await AXProbe.tree(of: tray(fixture.shelf, clear: ask), size: traySize)
        XCTAssertTrue(words(asking).contains("Remove all 3 items? Files are untouched."), asking.dump)
        XCTAssertTrue(asking.all(role: "AXButton").contains { $0.label == "Cancel" || $0.title == "Cancel" }, asking.dump)
        XCTAssertTrue(asking.all(role: "AXButton").contains { $0.label == "Remove All" || $0.title == "Remove All" }, asking.dump)
        XCTAssertEqual(fixture.shelf.items.count, 3, "asking removes nothing")

        guard let cancel = asking.all(role: "AXButton").first(where: { $0.label == "Cancel" || $0.title == "Cancel" }) else {
            return XCTFail(asking.dump)
        }
        XCTAssertTrue(cancel.press(), asking.dump)
        XCTAssertFalse(ask.isAsking)
        let after = await asking.reread()
        XCTAssertFalse(words(after).contains("Remove all 3 items? Files are untouched."), after.dump)
        XCTAssertEqual(fixture.shelf.items.count, 3, "Cancel keeps every tile")
    }

    /// The header's Remove All asks the view model's question — the one the
    /// tray draws in place of its row — and Escape or leaving the tray takes
    /// it back with nothing removed (§19.7, amended 2026-10-18).
    func testTheHeaderAsksTheTraysQuestionAndEscapeOrLeavingTakesItBack() throws {
        let (controller, vm, isolated, _) = try rig()
        defer { isolated.release(); controller.teardown() }
        let fixture = try Fixture(names: names(2))
        defer { fixture.release() }
        vm.shelf.requestThumbnail = { _, done in done(nil) }
        vm.shelf.makeBookmark = { _ in nil }
        vm.shelf.add(fixture.files)
        XCTAssertEqual(vm.shelf.items.count, 2)
        vm.open(.tray)

        vm.askToRemoveAll()
        XCTAssertTrue(vm.shelfClear.isAsking, "the header's button asks the tray's question")
        XCTAssertTrue(vm.consumeEscape(), "Escape is the question's before it is the panel's")
        XCTAssertFalse(vm.shelfClear.isAsking)

        vm.askToRemoveAll()
        vm.open(.settings)
        XCTAssertFalse(vm.shelfClear.isAsking, "leaving the tray takes the question back")
        vm.open(.tray)
        XCTAssertFalse(vm.shelfClear.isAsking, "and coming back does not find it waiting")
        XCTAssertEqual(vm.shelf.items.count, 2, "nothing was removed")
    }

    func testRemoveAllClearsTheShelf() async throws {
        let fixture = try Fixture(names: names(3))
        defer { fixture.release() }
        let ask = ShelfClearConfirmation()
        ask.ask(count: 3)
        let asking = await AXProbe.tree(of: tray(fixture.shelf, clear: ask), size: traySize)
        guard let removeAll = asking.all(role: "AXButton").first(where: { $0.label == "Remove All" || $0.title == "Remove All" }) else {
            return XCTFail(asking.dump)
        }
        XCTAssertTrue(removeAll.press(), asking.dump)
        XCTAssertTrue(fixture.shelf.items.isEmpty)
        for file in fixture.files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "files are untouched") }
    }

    /// A disk that is not plugged in: the tile stays, and says why in its
    /// accessibility value.
    func testAnOfflineTileSaysWhy() async throws {
        let fixture = try Fixture(names: [])
        defer { fixture.release() }
        fixture.shelf.verdictFor = { _, _ in .offline }
        fixture.shelf.mountedVolumes = { [] }
        let url = URL(fileURLWithPath: "/Volumes/Backup Disk/q3.pdf")
        fixture.shelf.add([url])
        await fixture.shelf.refreshFromDisk().value
        XCTAssertEqual(fixture.shelf.items.first?.isOffline, true)

        let root = await AXProbe.tree(of: tray(fixture.shelf), size: traySize)
        let tile = root.all(role: "AXButton").first { $0.label == "q3.pdf" }
        XCTAssertNotNil(tile, root.dump)
        XCTAssertTrue(tile?.value.contains("Disk not connected") ?? false, root.dump)
    }

    private func words(_ root: AXNode) -> [String] {
        root.all(role: "AXStaticText").map { $0.label.isEmpty ? $0.value : $0.label }
    }
}
