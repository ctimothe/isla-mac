import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Shelf's behaviour around the grid (redesign 2026-10-15, spec §8): what
/// the controller does with the Delete key, how a drop that was already kept
/// looks, how Clear asks, what a tile's thumbnail is, where an AirDrop-aimed
/// promise goes, and how the pane lays itself out at the three widths.
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
    /// matched — and only that one — and says so in the bar, for 1.2 s.
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
        XCTAssertEqual(
            ShelfBar.make(
                itemCount: shelf.items.count, selectionCount: shelf.selection.count, notice: nil,
                isConfirmingClear: clear.isAsking, bodyWidth: 560
            ),
            ShelfBar(leading: .clearQuestion(count: 3), trailing: .confirmClear)
        )
        XCTAssertEqual(spoken, ["Remove all 3 items? Files are untouched."], "a person who cannot see the bar is told")

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
    /// aim is latched at the release and honoured when that batch lands — and
    /// only that one.
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
        inbox.sendNextBatchWithAirDrop(true)
        let queue = OperationQueue()
        queue.addOperation { inbox.arrived(url: first, error: nil) }
        // The first batch is delivered before the second drop is aimed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            inbox.sendNextBatchWithAirDrop(false)
            queue.addOperation { inbox.arrived(url: second, error: nil) }
        }
        wait(for: [delivered], timeout: 4)
        XCTAssertEqual(sent, [[first]], "the AirDrop-aimed drop is sent")
        XCTAssertEqual(kept, [[second]], "the next one is kept: the aim was for one batch")
    }

    // MARK: - The controller's Delete key

    private func rig() throws -> (NotchController, NotchViewModel, ProbeStores, ShelfDeleteKeyTests.FakeRegistrar) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let controller = NotchController()
        let fake = ShelfDeleteKeyTests.FakeRegistrar()
        controller.deleteKeyRegistrar = fake.registrar
        controller.appIsActive = { false }
        controller.attachForTesting(viewModel: vm, rootView: NotchRootView(frame: .zero))
        return (controller, vm, isolated, fake)
    }

    /// The whole claim at the controller: open on the Shelf, pointer on it, a
    /// tile picked — and each of the ways it ends gives the keys back at once.
    func testTheControllerHoldsTheKeyOnlyWhileTheClaimHolds() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release(); controller.teardown() }
        let urls = ["a.txt", "b.txt"].map { URL(fileURLWithPath: "/tmp/isla-delete-\($0)") }
        vm.shelf.add(urls)
        vm.shelf.select(vm.shelf.items[0], modifiers: [])

        vm.isOpen = true
        vm.tab = .shelf
        vm.isPointerOnShelf = true
        controller.refreshDeleteKey()
        XCTAssertTrue(controller.holdsDeleteKey, "pointer on the Shelf, a selection: held")
        XCTAssertEqual(fake.live.count, 2)

        vm.isPointerOnShelf = false
        controller.refreshDeleteKey()
        XCTAssertFalse(controller.holdsDeleteKey, "the pointer left")
        vm.isPointerOnShelf = true
        controller.refreshDeleteKey()
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.tab = .clipboard
        controller.refreshDeleteKey()
        XCTAssertFalse(controller.holdsDeleteKey, "the tab changed")
        vm.tab = .shelf
        controller.refreshDeleteKey()
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.isLockedPresentation = true
        controller.refreshDeleteKey()
        XCTAssertFalse(controller.holdsDeleteKey, "the screen locked")
        vm.isLockedPresentation = false
        controller.refreshDeleteKey()
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.isOpen = false
        controller.refreshDeleteKey()
        XCTAssertFalse(controller.holdsDeleteKey, "the panel closed")
        vm.isOpen = true
        controller.refreshDeleteKey()
        XCTAssertTrue(controller.holdsDeleteKey)

        vm.shelf.clearSelection()
        controller.refreshDeleteKey()
        XCTAssertFalse(controller.holdsDeleteKey, "the selection emptied")

        XCTAssertTrue(fake.live.isEmpty, "nothing left registered")
        XCTAssertLessThanOrEqual(fake.peak, 2, "never registered twice")
    }

    func testAppActivationGivesTheKeyBack() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release(); controller.teardown() }
        vm.shelf.add([URL(fileURLWithPath: "/tmp/isla-delete-active.txt")])
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        vm.isOpen = true
        vm.tab = .shelf
        vm.isPointerOnShelf = true
        controller.refreshDeleteKey()
        XCTAssertTrue(controller.holdsDeleteKey)
        controller.appIsActive = { true }  // Quick Look activated Isla
        controller.refreshDeleteKey()
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
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        vm.shelf.select(vm.shelf.items[1], modifiers: .command)
        vm.isOpen = true
        vm.tab = .shelf
        vm.isPointerOnShelf = true
        controller.refreshDeleteKey()
        XCTAssertEqual(fake.live.count, 2)

        // The pointer left, but the registration has not been told yet.
        vm.isPointerOnShelf = false
        controller.deleteKeyPressed()
        XCTAssertEqual(vm.shelf.items.count, 3, "no claim, no removal")
        XCTAssertFalse(controller.holdsDeleteKey, "and the keys are handed back")
        XCTAssertTrue(fake.live.isEmpty)

        vm.isPointerOnShelf = true
        controller.refreshDeleteKey()
        controller.deleteKeyPressed()
        XCTAssertEqual(vm.shelf.items.count, 1, "the two picked tiles went")
        XCTAssertTrue(vm.shelf.selection.isEmpty)
    }

    /// Teardown, a rebuild's first act, gives the keys back whatever the claim.
    func testTeardownGivesTheKeyBack() throws {
        let (controller, vm, isolated, fake) = try rig()
        defer { isolated.release() }
        vm.shelf.add([URL(fileURLWithPath: "/tmp/isla-delete-teardown.txt")])
        vm.shelf.select(vm.shelf.items[0], modifiers: [])
        vm.isOpen = true
        vm.tab = .shelf
        vm.isPointerOnShelf = true
        controller.refreshDeleteKey()
        XCTAssertTrue(controller.holdsDeleteKey)
        controller.teardown()
        XCTAssertFalse(controller.holdsDeleteKey)
        XCTAssertTrue(fake.live.isEmpty)
    }

    // MARK: - The pane at three widths

    private func paneSize(bodyWidth: CGFloat) -> CGSize {
        CGSize(width: PlayerLayout.paneWidth(bodyWidth: bodyWidth), height: 208 - 38 - NotchGeometry.bodyBottomPadding)
    }

    private func names(_ count: Int) -> [String] { (0..<count).map { String(format: "file-%02d.txt", $0) } }

    /// The first row holds as many tiles as the width allows, side by side from
    /// the pane's left edge, at 480, 560 and 620.
    func testTheGridFillsRowsByWidth() async throws {
        for (width, columns) in [(CGFloat(480), 5), (560, 6), (620, 6)] {
            let fixture = try Fixture(names: names(12))
            defer { fixture.release() }
            let size = paneSize(bodyWidth: width)
            let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: size)
            let tiles = root.all(role: "AXButton").filter { $0.label.hasPrefix("file-") }
            let frames = tiles.compactMap(\.frame)
            XCTAssertEqual(frames.count, tiles.count, root.dump)
            let top = frames.map(\.minY).min() ?? 0
            let firstRow = frames.filter { abs($0.minY - top) < 1 }.sorted { $0.minX < $1.minX }
            XCTAssertEqual(firstRow.count, columns, "columns at \(width)\n\(root.dump)")
            XCTAssertEqual(firstRow.first?.minX ?? -1, 0, accuracy: 1, "from the pane's left edge at \(width)")
            XCTAssertEqual(firstRow.first?.width ?? 0, 78, accuracy: 1)
            XCTAssertEqual(firstRow.first?.height ?? 0, 100, accuracy: 1)
            if firstRow.count > 1 {
                XCTAssertEqual(firstRow[1].minX - firstRow[0].minX, 82, accuracy: 1, "82 pt apart")
            }
            XCTAssertLessThanOrEqual(firstRow.last?.maxX ?? 0, size.width + 1, "inside the pane at \(width)")
        }
    }

    /// Below 540 the bar keeps Quick Look and Remove and carries the rest under
    /// "More"; from 540 up all five verbs show. Every control sits inside the
    /// pane, so none is clipped.
    func testTheSelectionBarAtEachWidth() async throws {
        for width in [CGFloat(480), 560, 620] {
            let fixture = try Fixture(names: names(4))
            defer { fixture.release() }
            fixture.shelf.select(fixture.shelf.items[0], modifiers: [])
            fixture.shelf.select(fixture.shelf.items[1], modifiers: .command)
            let size = paneSize(bodyWidth: width)
            let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: size)
            let buttons = root.all(role: "AXButton")
            func has(_ label: String) -> Bool { buttons.contains { $0.label == label || $0.title == label } }

            XCTAssertTrue(has("Quick Look"), "at \(width)\n\(root.dump)")
            XCTAssertTrue(has("Remove"), "at \(width)\n\(root.dump)")
            XCTAssertTrue(has("Deselect All"), "at \(width)\n\(root.dump)")
            let folded = !has("AirDrop")
            XCTAssertEqual(folded, width < 540, "folded below 540 only (\(width))\n\(root.dump)")
            XCTAssertEqual(has("More"), width < 540, "More carries the rest (\(width))\n\(root.dump)")
            XCTAssertEqual(has("Copy"), width >= 540, "\(width)")
            XCTAssertEqual(has("Show in Finder"), width >= 540, "\(width)")
            XCTAssertTrue(words(root).contains("2 selected"), root.dump)
            for label in ["Quick Look", "Remove", "Deselect All", "AirDrop", "More"] {
                guard let frame = buttons.first(where: { $0.label == label || $0.title == label })?.frame else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, -1, "\(label) at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 1, "\(label) at \(width)")
            }
        }
    }

    func testWithoutASelectionTheBarHintsAndOffersClear() async throws {
        let fixture = try Fixture(names: names(3))
        defer { fixture.release() }
        let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: paneSize(bodyWidth: 560))
        XCTAssertTrue(words(root).contains("Drag an item out to use it anywhere."), root.dump)
        XCTAssertTrue(root.all(role: "AXButton").contains { $0.label == "Clear" || $0.title == "Clear" }, root.dump)
        XCTAssertFalse(root.all(role: "AXButton").contains { $0.label == "Quick Look" || $0.title == "Quick Look" }, root.dump)
    }

    /// Pressing Clear puts the question in the bar, with its two answers; Cancel
    /// takes it away and everything is where it was.
    func testClearAsksInPlaceAndCancelPutsItAway() async throws {
        let fixture = try Fixture(names: names(3))
        defer { fixture.release() }
        let size = paneSize(bodyWidth: 560)
        let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: size)
        guard let clear = root.all(role: "AXButton").first(where: { $0.label == "Clear" || $0.title == "Clear" }) else {
            return XCTFail(root.dump)
        }
        XCTAssertTrue(clear.press(), root.dump)
        let asking = await clear.reread()
        XCTAssertTrue(words(asking).contains("Remove all 3 items? Files are untouched."), asking.dump)
        XCTAssertTrue(asking.all(role: "AXButton").contains { $0.label == "Cancel" || $0.title == "Cancel" }, asking.dump)
        XCTAssertTrue(asking.all(role: "AXButton").contains { $0.label == "Remove All" || $0.title == "Remove All" }, asking.dump)
        XCTAssertEqual(fixture.shelf.items.count, 3, "asking removes nothing")

        guard let cancel = asking.all(role: "AXButton").first(where: { $0.label == "Cancel" || $0.title == "Cancel" }) else {
            return XCTFail(asking.dump)
        }
        XCTAssertTrue(cancel.press(), asking.dump)
        let after = await cancel.reread()
        XCTAssertFalse(words(after).contains("Remove all 3 items? Files are untouched."), after.dump)
        XCTAssertEqual(fixture.shelf.items.count, 3, "Cancel keeps every tile")
    }

    func testRemoveAllClearsTheShelf() async throws {
        let fixture = try Fixture(names: names(3))
        defer { fixture.release() }
        let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: paneSize(bodyWidth: 560))
        guard let clear = root.all(role: "AXButton").first(where: { $0.label == "Clear" || $0.title == "Clear" }) else {
            return XCTFail(root.dump)
        }
        XCTAssertTrue(clear.press())
        let asking = await clear.reread()
        guard let removeAll = asking.all(role: "AXButton").first(where: { $0.label == "Remove All" || $0.title == "Remove All" }) else {
            return XCTFail(asking.dump)
        }
        XCTAssertTrue(removeAll.press(), asking.dump)
        XCTAssertTrue(fixture.shelf.items.isEmpty)
        for file in fixture.files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "files are untouched") }
    }

    /// A disk that is not plugged in: the tile stays, says why where its age
    /// would be, and the bar's verbs have no file to act on.
    func testAnOfflineTileSaysWhy() async throws {
        let fixture = try Fixture(names: [])
        defer { fixture.release() }
        fixture.shelf.verdictFor = { _, _ in .offline }
        fixture.shelf.mountedVolumes = { [] }
        let url = URL(fileURLWithPath: "/Volumes/Backup Disk/q3.pdf")
        fixture.shelf.add([url])
        await fixture.shelf.refreshFromDisk().value
        XCTAssertEqual(fixture.shelf.items.first?.isOffline, true)

        let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: paneSize(bodyWidth: 560))
        let tile = root.all(role: "AXButton").first { $0.label == "q3.pdf" }
        XCTAssertNotNil(tile, root.dump)
        XCTAssertTrue(tile?.value.contains("Disk not connected") ?? false, root.dump)
    }

    // MARK: - The header's Expand

    func testExpandHeaderToolIsTheSameButton() async {
        let size = CGSize(width: 560, height: 38)
        let collapsed = await AXProbe.tree(
            of: Text("Shelf").frame(width: size.width, height: size.height, alignment: .leading)
                .modifier(ExpandHeaderTool(isShown: true, bodyWidth: size.width, isExpanded: .constant(false))),
            size: size
        )
        XCTAssertNotNil(collapsed.first(label: "Expand"), collapsed.dump)
        let frame = collapsed.first(label: "Expand")?.frame
        XCTAssertEqual(frame?.minX ?? -1, 521, accuracy: 1, "bw − 39")
        XCTAssertEqual(frame?.minY ?? -1, 8, accuracy: 1)
        XCTAssertEqual(frame?.width ?? 0, 22, accuracy: 1)

        let expanded = await AXProbe.tree(
            of: Text("Shelf").frame(width: size.width, height: size.height, alignment: .leading)
                .modifier(ExpandHeaderTool(isShown: true, bodyWidth: size.width, isExpanded: .constant(true))),
            size: size
        )
        XCTAssertNotNil(expanded.first(label: "Collapse"), expanded.dump)

        let hidden = await AXProbe.tree(
            of: Text("Shelf").frame(width: size.width, height: size.height, alignment: .leading)
                .modifier(ExpandHeaderTool(isShown: false, bodyWidth: size.width, isExpanded: .constant(false))),
            size: size
        )
        XCTAssertNil(hidden.first(label: "Expand"), hidden.dump)
    }

    private func words(_ root: AXNode) -> [String] {
        root.all(role: "AXStaticText").map { $0.label.isEmpty ? $0.value : $0.label }
    }
}
