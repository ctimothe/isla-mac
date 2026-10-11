import XCTest
@testable import IslaKit

@MainActor
final class ShelfStoreTests: XCTestCase {
    func testLoadUsesStoredPathsWithoutRemovingInaccessibleEntries() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/protected/example.txt"], forKey: "shelf.urls")

        let store = ShelfStore(defaults: defaults)
        store.load()

        XCTAssertEqual(store.items.map(\.url.path), ["/protected/example.txt"])
    }

    /// A capture belongs where it was taken, not where it was found. Filmed
    /// on 2026-09-21: a recording made at 14:47 but first seen at 16:40 sat
    /// above the one made at 16:37.
    func testCapturesReadNewestFirstByWhenTheyWereTaken() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        let late = URL(fileURLWithPath: "/tmp/Screen Recording at 16.37.40.mov")
        let early = URL(fileURLWithPath: "/tmp/Screen Recording at 14.47.45.mov")

        store.add([late], dates: [late: Date(timeIntervalSinceNow: -180)])
        store.add([early], dates: [early: Date(timeIntervalSinceNow: -6500)])

        XCTAssertEqual(store.items.map(\.url), [late, early])
    }

    /// A drop is dated when it was dropped, so it reads above older captures.
    func testADropIsDatedWhenItWasDropped() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        let capture = URL(fileURLWithPath: "/tmp/Screenshot at 09.00.00.png")
        let dropped = URL(fileURLWithPath: "/tmp/notes.txt")
        store.add([capture], dates: [capture: Date(timeIntervalSinceNow: -3600)])
        store.add([dropped])

        XCTAssertEqual(store.items.first?.url, dropped)
        XCTAssertEqual(store.items.first?.date?.timeIntervalSinceNow ?? -99, 0, accuracy: 5)
    }

    /// Each card is bookmarked once, when it arrives — not on every save.
    /// `persist` runs on every change, and it used to bookmark the whole shelf
    /// each time: up to sixty reads of file and volume metadata on the main
    /// thread for one copied screenshot, with the panel shut.
    func testEachCardIsBookmarkedOnceNotOnEverySave() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        var made: [String] = []
        store.makeBookmark = { url in
            made.append(url.lastPathComponent)
            return Data(url.path.utf8)
        }
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.png")

        store.add([first])
        store.add([second])
        if let card = store.items.first(where: { $0.url == second }) { store.remove(card) }

        XCTAssertEqual(made, ["first.png", "second.png"], "one bookmark per card, however often the shelf is saved")
        XCTAssertEqual(
            defaults.array(forKey: "shelf.urls.bookmarks") as? [Data], [Data(first.path.utf8)],
            "the saved list still holds one bookmark per card, in order"
        )
    }

    /// A card that could not be bookmarked is asked again at the next save,
    /// as before — a failure is not remembered as an answer.
    func testAFailedBookmarkIsTriedAgain() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        var attempts = 0
        store.makeBookmark = { _ in
            attempts += 1
            return nil
        }
        store.add([URL(fileURLWithPath: "/tmp/unbookmarkable.png")])
        store.add([URL(fileURLWithPath: "/tmp/other.png")])

        XCTAssertEqual(attempts, 3, "the failed card is tried again on the second save")
        XCTAssertEqual(defaults.array(forKey: "shelf.urls.bookmarks") as? [Data], [Data(), Data()])
    }

    /// A reloaded shelf reuses the bookmarks it saved rather than making them
    /// all again on its first save.
    func testAReloadedShelfReusesItsBookmarks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID()).png")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ShelfStore(defaults: defaults).add([file])

        let reloaded = ShelfStore(defaults: defaults)
        reloaded.load()
        var made: [String] = []
        reloaded.makeBookmark = { url in
            made.append(url.lastPathComponent)
            return Data(url.path.utf8)
        }
        reloaded.add([URL(fileURLWithPath: "/tmp/new.png")])

        XCTAssertEqual(made, ["new.png"], "the card that came back from disk keeps its bookmark")
    }

    /// Dates survive a relaunch, and with them the order.
    func testDatesSurviveAReload() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let taken = Date(timeIntervalSince1970: 1_790_000_000)
        let url = URL(fileURLWithPath: "/tmp/Screenshot.png")
        ShelfStore(defaults: defaults).add([url], dates: [url: taken])

        let reloaded = ShelfStore(defaults: defaults)
        reloaded.load()
        XCTAssertEqual(reloaded.items.first?.date, taken)
    }

    /// A file in the Trash is gone, as far as a person is concerned. The shelf
    /// followed trashed recordings into ~/.Trash and kept offering them.
    func testAFileInTheTrashIsGoneAndIsNotReloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfTrash-\(UUID())")
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trashed = trash.appendingPathComponent("Screen Recording.mov")
        try Data([1]).write(to: trashed)
        XCTAssertEqual(ShelfStore.verdict(for: trashed, mounted: []), .gone, "it exists, and it is still gone")

        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([trashed.path], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.load()
        XCTAssertTrue(store.items.isEmpty)
    }

    /// How long ago, the way a person says it.
    func testTheAgeReadsTheWayAPersonSaysIt() {
        let now = Date()
        XCTAssertEqual(ShelfItem.age(of: now.addingTimeInterval(-20), now: now), localized("Just now"))
        let minutes = ShelfItem.age(of: now.addingTimeInterval(-300), now: now)
        XCTAssertTrue(minutes.contains("5"), minutes)
        let hours = ShelfItem.age(of: now.addingTimeInterval(-7200), now: now)
        XCTAssertTrue(hours.contains("2"), hours)
    }

    func testClearPersistsOnlyToTheInjectedDefaults() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/tmp/example.txt"], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.load()

        store.clear()

        XCTAssertEqual(defaults.stringArray(forKey: "shelf.urls"), [])
    }

    /// A plain click on item 0 sets the anchor; a Finder-style shift-click on
    /// item 3 should then select the whole contiguous run 0...3, not just
    /// toggle item 3 the way Cmd-click does.
    func testShiftClickSelectsTheContiguousRangeFromTheAnchor() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt", "/tmp/d.txt"],
            forKey: "shelf.urls"
        )
        let store = ShelfStore(defaults: defaults)
        store.load()

        store.select(store.items[0], modifiers: [])
        store.select(store.items[3], modifiers: .shift)

        XCTAssertTrue(store.items[0...3].allSatisfy { store.isSelected($0) })
    }

    /// Cmd-click keeps toggling exactly the clicked item, unaffected by the fix
    /// to Shift's behavior above.
    func testCommandClickStillTogglesOnlyTheClickedItem() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt", "/tmp/d.txt"],
            forKey: "shelf.urls"
        )
        let store = ShelfStore(defaults: defaults)
        store.load()

        store.select(store.items[0], modifiers: [])
        store.select(store.items[3], modifiers: .command)

        XCTAssertTrue(store.isSelected(store.items[0]))
        XCTAssertTrue(store.isSelected(store.items[3]))
        XCTAssertFalse(store.isSelected(store.items[1]))
        XCTAssertFalse(store.isSelected(store.items[2]))
    }

    /// A card whose file has actually been deleted is evicted the next time
    /// the shelf is refreshed from disk.
    func testRefreshFromDiskEvictsACardWhoseFileWasDeleted() async throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defaults.set([file.path], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.load()
        XCTAssertEqual(store.items.count, 1)

        try FileManager.default.removeItem(at: file)
        await store.refreshFromDisk().value

        XCTAssertTrue(store.items.isEmpty)
    }

    /// A card whose file exists but can no longer be read — its containing
    /// directory's traversal permission revoked, the way a "Don't Allow" on a
    /// protected folder leaves things — must not be evicted alongside a card
    /// that is genuinely gone (#10-adjacent regression covered by `verdict`).
    func testRefreshFromDiskKeepsACardWhoseFileExistsButIsUnreadable() async throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("secret.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defaults.set([file.path], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.load()
        XCTAssertEqual(store.items.count, 1)

        // Revoking traversal on the directory (not the file's own bits, which
        // `stat` does not consult) is what actually reproduces "present but
        // denied" rather than "missing".
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        await store.refreshFromDisk().value

        XCTAssertEqual(store.items.count, 1)
    }

    /// A finished recording is imported on the next scan, exactly once: the
    /// second scan finds nothing new, so the shelf does not duplicate what it
    /// already holds.
    func testFreshRecordingIsImportedOnce() throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date.distantPast, forKey: RecordingPickup.sinceKey)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("rec.mov"))

        let store = ShelfStore(defaults: defaults)
        store.importNewRecordings(from: dir)
        XCTAssertEqual(store.items.map(\.url.lastPathComponent), ["rec.mov"])

        store.importNewRecordings(from: dir)
        XCTAssertEqual(store.items.count, 1)
    }

    /// Throwing a recording off the shelf is a decision: the scan remembers
    /// what it met, so the next open does not resurrect it.
    func testRemovedRecordingStaysRemoved() throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date.distantPast, forKey: RecordingPickup.sinceKey)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("rec.mov"))

        let store = ShelfStore(defaults: defaults)
        store.importNewRecordings(from: dir)
        XCTAssertEqual(store.items.count, 1)

        store.remove(store.items[0])
        store.importNewRecordings(from: dir)
        XCTAssertTrue(store.items.isEmpty)
    }

    /// Off means off: with the toggle down the captures folder is never
    /// touched — which is also what keeps the system prompt from ever
    /// appearing for someone who declined the feature.
    func testDisabledToggleNeverScans() throws {
        let standard = UserDefaults.standard
        let had = standard.object(forKey: NotchViewModel.importRecordingsKey)
        defer {
            if let had { standard.set(had, forKey: NotchViewModel.importRecordingsKey) }
            else { standard.removeObject(forKey: NotchViewModel.importRecordingsKey) }
        }
        standard.set(false, forKey: NotchViewModel.importRecordingsKey)

        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date.distantPast, forKey: RecordingPickup.sinceKey)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("rec.mov"))

        let store = ShelfStore(defaults: defaults)
        store.importNewRecordings(from: dir)
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Disks that come and go (F-001)

    /// Ejecting a disk is not deleting its files. A path under an unmounted
    /// `/Volumes` root answers "no such file", exactly like a deleted one, and
    /// the shelf used to read that as gone: every card on an ejected USB stick
    /// or SMB share left the shelf on the next open, and the save after it made
    /// the loss permanent.
    func testACardOnAnUnmountedVolumeStaysOffline() async {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = "/Volumes/Isla-Test-\(UUID())/report.pdf"
        defaults.set([path], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.mountedVolumes = { [] }
        store.requestThumbnail = { _, _ in }
        store.load()

        await store.refreshFromDisk().value

        XCTAssertEqual(store.items.count, 1, "the card waits for its disk")
        XCTAssertTrue(store.items.first?.isOffline ?? false)
    }

    /// Plugging the disk back in brings the card back to life on the next
    /// open — nothing to re-add, nothing to find again.
    func testRemountingBringsTheCardBack() async throws {
        let volumes = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfVolumes-\(UUID())", isDirectory: true)
        let root = volumes.appendingPathComponent("Isla-Test", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volumes) }
        let file = root.appendingPathComponent("report.pdf")
        try Data([1]).write(to: file)
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([file.path], forKey: "shelf.urls")

        let store = ShelfStore(defaults: defaults)
        // The temporary folder stands in for /Volumes: a test cannot mount a
        // disk, but it can say which roots count as mounted.
        let volumesPath = volumes.path
        store.verdictFor = { url, mounted in
            ShelfStore.verdict(for: url, mounted: mounted, volumes: volumesPath)
        }
        store.requestThumbnail = { _, _ in }
        store.mountedVolumes = { [] }
        store.load()

        await store.refreshFromDisk().value
        XCTAssertEqual(store.items.map(\.isOffline), [true], "ejected: the card stays, offline")

        let rootPath = root.standardizedFileURL.path
        store.mountedVolumes = { [rootPath] }
        await store.refreshFromDisk().value
        XCTAssertEqual(store.items.map(\.isOffline), [false], "plugged back in: the card is live again")
    }

    /// An offline card keeps the bookmark it came with. Resolution is done
    /// without mounting, so it fails while the disk is away, and the loader
    /// used to drop the bytes on failure — the next save then wrote an empty
    /// Data in their place, and the one record that could follow the file
    /// once the disk returned under another name was gone.
    func testAnOfflineCardKeepsItsBookmark() async {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = "/Volumes/Isla-Test-\(UUID())/report.pdf"
        let original = Data("a bookmark to a disk that is not here".utf8)
        defaults.set([path], forKey: "shelf.urls")
        defaults.set([original], forKey: "shelf.urls.bookmarks")
        let store = ShelfStore(defaults: defaults)
        store.mountedVolumes = { [] }
        store.requestThumbnail = { _, _ in }
        store.makeBookmark = { Data($0.path.utf8) }
        store.load()
        await store.refreshFromDisk().value

        // Any change saves the whole shelf.
        store.add([URL(fileURLWithPath: "/tmp/other.png")])

        XCTAssertEqual(defaults.stringArray(forKey: "shelf.urls")?.last, path)
        XCTAssertEqual((defaults.array(forKey: "shelf.urls.bookmarks") as? [Data])?.last, original)
    }

    /// A card whose disk is away cannot be dragged anywhere: there is no file
    /// behind it to hand over.
    func testAnOfflineCardIsLeftOutOfADrag() async {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let offline = "/Volumes/Isla-Test-\(UUID())/report.pdf"
        defaults.set(["/tmp/here.txt", offline], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.mountedVolumes = { [] }
        store.verdictFor = { url, mounted in
            url.path.hasPrefix("/Volumes/") ? ShelfStore.verdict(for: url, mounted: mounted) : .present
        }
        store.requestThumbnail = { _, _ in }
        store.load()
        await store.refreshFromDisk().value
        guard let here = store.items.first(where: { !$0.isOffline }),
              let away = store.items.first(where: { $0.isOffline }) else {
            return XCTFail("one card each way")
        }

        XCTAssertEqual(store.dragURLs(startingAt: away), [])
        store.select(here, modifiers: [])
        store.select(away, modifiers: .command)
        XCTAssertEqual(store.dragURLs(startingAt: here), [here.url])
    }

    /// The verdict tells the four answers apart: a deleted file is gone, one
    /// on a disk that is not plugged in is offline, and a volume path that is
    /// really a link to a mounted disk — `/Volumes/Macintosh HD` is one — is
    /// asked like any other path rather than read as an ejected disk.
    func testTheVerdictTellsAnEjectedDiskFromADeletedFile() throws {
        let volumes = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfVolumes-\(UUID())", isDirectory: true)
        let boot = volumes.appendingPathComponent("Boot", isDirectory: true)
        try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volumes) }
        let link = volumes.appendingPathComponent("Macintosh HD")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: boot)
        let present = boot.appendingPathComponent("here.txt")
        try Data([1]).write(to: present)
        let v = volumes.path

        XCTAssertEqual(ShelfStore.verdict(for: volumes.appendingPathComponent("Away/x.pdf"), mounted: [], volumes: v), .offline)
        XCTAssertEqual(ShelfStore.verdict(for: link.appendingPathComponent("deleted.txt"), mounted: [], volumes: v), .gone)
        XCTAssertEqual(ShelfStore.verdict(for: link.appendingPathComponent("here.txt"), mounted: [], volumes: v), .present)
        XCTAssertEqual(
            ShelfStore.verdict(for: URL(fileURLWithPath: "/tmp/isla-\(UUID())-missing.txt"), mounted: []),
            .gone
        )
    }

    // MARK: - Opening the shelf (F-022)

    /// A shelf that has already drawn its previews does not ask QuickLook for
    /// them again. Every open used to re-request all sixty, and every answer
    /// landed as a redraw of the whole panel during the tab transition.
    func testASecondRefreshRequestsNoThumbnails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfThumbs-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try (0..<3).map { index -> URL in
            let file = dir.appendingPathComponent("card-\(index).png")
            try Data([1]).write(to: file)
            return file
        }
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(files.map(\.path), forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        var requested = 0
        store.requestThumbnail = { _, done in
            requested += 1
            done(NSImage(size: NSSize(width: 4, height: 4)))
        }
        store.load()

        await store.refreshFromDisk().value
        await drainMainQueue()
        XCTAssertEqual(requested, 3)

        await store.refreshFromDisk().value
        await drainMainQueue()
        XCTAssertEqual(requested, 3, "the second open asks QuickLook for nothing")
    }

    /// Previews that land together are one change to the shelf, not one each.
    func testABurstOfThumbnailsIsOneRedraw() async throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/tmp/a.png", "/tmp/b.png", "/tmp/c.png"], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        var pending: [(NSImage?) -> Void] = []
        store.requestThumbnail = { _, done in pending.append(done) }
        store.verdictFor = { _, _ in .present }
        store.load()
        await store.refreshFromDisk().value
        XCTAssertEqual(pending.count, 3)

        var changes = 0
        let watch = store.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        pending.forEach { $0(NSImage(size: NSSize(width: 4, height: 4))) }
        await drainMainQueue()

        XCTAssertEqual(changes, 1, "three previews, one redraw")
    }

    /// The reachability check runs off the main thread. A card on a sleeping
    /// disk or a half-dead network share held the main thread for as long as
    /// the check took, with the shelf mid-transition.
    func testReachabilityIsNotAskedOnTheMainThread() async {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/tmp/a.txt", "/tmp/b.txt"], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        let log = ThreadLog()
        store.verdictFor = { _, _ in
            log.record(Thread.isMainThread)
            return .present
        }
        store.requestThumbnail = { _, _ in }
        store.load()

        await store.refreshFromDisk().value

        XCTAssertEqual(log.onMain, [false, false])
    }

    /// Lets the main queue run what is already on it, twice over: a preview's
    /// answer hops to main once, and the batch it joins is flushed one hop
    /// later.
    private func drainMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Where each verdict was asked, recorded from whichever thread asked it.
private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ onMain: Bool) {
        lock.lock()
        values.append(onMain)
        lock.unlock()
    }
    var onMain: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
