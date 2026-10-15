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

    /// Finder's anchor moves with a ⌘-click that picks a card, so ⌘-click A
    /// then ⇧-click D is the run A…D. It used to move only on a plain click:
    /// with no anchor, the ⇧-click fell through to a toggle and picked D
    /// alone beside A (J-022).
    func testCommandClickThenShiftClickSelectsTheRange() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt", "/tmp/d.txt"],
            forKey: "shelf.urls"
        )
        let store = ShelfStore(defaults: defaults)
        store.load()

        store.select(store.items[0], modifiers: .command)
        store.select(store.items[3], modifiers: .shift)

        XCTAssertEqual(store.selection, Set(store.items.map(\.id)), "the whole run from the ⌘-clicked card")
    }

    /// A card trimmed past the cap leaves the selection with it. It used to
    /// stay there, and the footer read "3 selected" over two visible
    /// cards (J-022).
    func testATrimDropsTrimmedCardsFromTheSelection() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = quietStore(defaults)
        let base = Date(timeIntervalSinceNow: -100_000)
        let full = (0..<ShelfStore.limit).map { URL(fileURLWithPath: "/tmp/full-\($0).png") }
        store.add(full, dates: Dictionary(uniqueKeysWithValues: full.enumerated().map {
            ($0.element, base.addingTimeInterval(Double($0.offset)))
        }))
        guard let oldest = store.items.last else { return XCTFail("a full shelf") }
        store.select(oldest, modifiers: [])

        store.add([URL(fileURLWithPath: "/tmp/newer.png")])

        XCTAssertFalse(store.items.contains(oldest), "the oldest card left past the cap")
        XCTAssertTrue(store.selection.isEmpty, "and took its place in the selection with it")
    }

    /// A drop says what became of it. `add` used to return nothing, so a
    /// file already on the shelf vanished from the drop without a word, and
    /// a drop onto a full shelf pushed the oldest cards off it the same way
    /// (F-035).
    func testAddReportsDuplicatesAndEvictions() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = quietStore(defaults)
        let base = Date(timeIntervalSinceNow: -100_000)
        let full = (0..<ShelfStore.limit).map { URL(fileURLWithPath: "/tmp/full-\($0).png") }
        let first = store.add(full, dates: Dictionary(uniqueKeysWithValues: full.enumerated().map {
            ($0.element, base.addingTimeInterval(Double($0.offset)))
        }))
        XCTAssertEqual(first, ShelfStore.AddResult(added: ShelfStore.limit, duplicates: 0, evicted: 0))
        XCTAssertNil(store.notice, "filling the shelf exactly is nothing to report")

        let again = store.add([full[7]])
        XCTAssertEqual(again, ShelfStore.AddResult(added: 0, duplicates: 1, evicted: 0))
        XCTAssertEqual(store.notice, .alreadyOnShelf)

        let more = (0..<3).map { URL(fileURLWithPath: "/tmp/more-\($0).png") }
        let past = store.add(more)
        XCTAssertEqual(past, ShelfStore.AddResult(added: 3, duplicates: 0, evicted: 3))
        XCTAssertEqual(store.notice, .evicted(3))
        XCTAssertEqual(store.items.count, ShelfStore.limit)
        XCTAssertFalse(store.items.contains { full[0...2].contains($0.url) }, "the three oldest left")
    }

    /// The footer's notice is a moment, not a state: it goes by itself, and
    /// a newer one restarts the clock rather than being cut short by the
    /// older one's timer.
    func testTheDropNoticeClearsItself() async throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = quietStore(defaults)
        store.noticeLifetime = .milliseconds(200)
        let url = URL(fileURLWithPath: "/tmp/twice.png")
        store.add([url])

        store.add([url])
        try await Task.sleep(for: .milliseconds(120))
        store.add([url])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.notice, .alreadyOnShelf, "the second notice runs its own full lifetime")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(store.notice)
    }

    /// An AirDrop that cannot happen says why, in words. It used to be
    /// `NSSound.beep()` alone, silent at zero alert volume and nothing at
    /// all to VoiceOver (F-049). The two causes read differently because
    /// they mean different things to do: a Mac without AirDrop will never
    /// send, a refused batch of files might go another way.
    func testAirDropRefusalsAreWorded() {
        XCTAssertEqual(
            ShelfSharing.airDropRefusal(serviceAvailable: false, canPerform: false)?.text,
            "AirDrop is not available on this Mac."
        )
        XCTAssertEqual(
            ShelfSharing.airDropRefusal(serviceAvailable: true, canPerform: false)?.text,
            "AirDrop cannot send these files."
        )
        XCTAssertNil(ShelfSharing.airDropRefusal(serviceAvailable: true, canPerform: true))
    }

    /// The refusal goes through the same footer notice as a drop's result,
    /// and lapses the same way: a moment, not a state.
    func testANoticeClearsItself() async throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = quietStore(defaults)
        store.noticeLifetime = .milliseconds(150)

        store.show(.airDropCannotSend)
        XCTAssertEqual(store.notice, .airDropCannotSend)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.notice)
    }

    /// An AirDrop refusal answers a press on the selection's own verb, so
    /// it is shown over the selection count; a drop's result is not, and
    /// keeps waiting for the selection to be gone, as it did.
    func testOnlyARefusalIsShownOverASelection() {
        XCTAssertTrue(ShelfStore.Notice.airDropUnavailable.showsOverSelection)
        XCTAssertTrue(ShelfStore.Notice.airDropCannotSend.showsOverSelection)
        XCTAssertFalse(ShelfStore.Notice.alreadyOnShelf.showsOverSelection)
        XCTAssertFalse(ShelfStore.Notice.evicted(2).showsOverSelection)
    }

    /// With cards picked, the footer's destructive verb is "Remove 2" and
    /// acts on those two only. Beside a selection it used to be Clear, which
    /// emptied the whole shelf (H-015).
    func testRemoveSelectedLeavesTheRest() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt", "/tmp/d.txt"],
            forKey: "shelf.urls"
        )
        let store = quietStore(defaults)
        store.load()
        let kept = [store.items[0].url, store.items[2].url]

        store.select(store.items[1], modifiers: .command)
        store.select(store.items[3], modifiers: .command)
        store.removeSelected()

        XCTAssertEqual(store.items.map(\.url), kept)
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "shelf.urls"), kept.map(\.path), "and the shorter shelf is saved")
    }

    /// A store that never asks QuickLook or the disk for a bookmark: sixty
    /// fixture cards should cost nothing but the test.
    private func quietStore(_ defaults: UserDefaults) -> ShelfStore {
        let store = ShelfStore(defaults: defaults)
        store.requestThumbnail = { _, _ in }
        store.makeBookmark = { Data($0.path.utf8) }
        return store
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

    /// A `since` the clock stamped in the future is rewritten to the present
    /// the first time the shelf reads it, so a capture taken after that
    /// reaches the shelf. Unclamped, a first launch with the clock a year
    /// ahead kept every capture off the shelf for a year (G-037).
    func testAFutureSinceIsRewrittenSoTheNextCaptureArrives() throws {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date().addingTimeInterval(365 * 86400), forKey: RecordingPickup.sinceKey)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ShelfStore(defaults: defaults)
        store.importNewRecordings(from: dir)
        let stored = try XCTUnwrap(defaults.object(forKey: RecordingPickup.sinceKey) as? Date)
        XCTAssertLessThanOrEqual(stored, Date(), "the stamp in the future is written back as now")

        // A capture finished after that open, dated a minute on so the test
        // does not race the stamp it was just given.
        let capture = dir.appendingPathComponent("rec.mov")
        try Data([1]).write(to: capture)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: capture.path
        )
        store.importNewRecordings(from: dir)
        XCTAssertEqual(store.items.map(\.url.lastPathComponent), ["rec.mov"])
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

    // MARK: - A dragged-out file that moved (F-020)

    /// A temporary folder with a file in it, for the move tests. The file is
    /// real: following a move means resolving a real bookmark, and the
    /// default `makeBookmark` is what made it.
    private func movableFile(named name: String = "Screenshot.png") throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfMove-\(UUID())")
        let from = root.appendingPathComponent("from", isDirectory: true)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        let file = from.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: file)
        return (root, file)
    }

    /// A ⌘-drag into a Finder folder moves the file. The card used to keep
    /// the old path: double-click, Quick Look and a second drag all failed
    /// without a word, and the next open erased the card as deleted with the
    /// file sitting one folder over. Now it follows the file through its
    /// bookmark, keeping its id, so the selection it was part of holds.
    func testAMovedFileKeepsItsCard() throws {
        let (root, a) = try movableFile()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        store.requestThumbnail = { _, _ in }
        store.add([a])
        let card = store.items[0]
        store.select(card, modifiers: [])

        let to = root.appendingPathComponent("to", isDirectory: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let b = to.appendingPathComponent("Screenshot moved.png")
        try FileManager.default.moveItem(at: a, to: b)
        store.followMove([a])

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].url.resolvingSymlinksInPath(), b.resolvingSymlinksInPath())
        XCTAssertEqual(store.items[0].id, card.id, "the same card, not a new one")
        XCTAssertTrue(store.isSelected(store.items[0]), "still selected")
        XCTAssertEqual(
            (defaults.stringArray(forKey: "shelf.urls") ?? []).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() },
            [b.resolvingSymlinksInPath()],
            "the new place is saved, so a relaunch finds it too"
        )
    }

    /// Dragged onto the Trash in the Dock, or moved into it: the file is gone
    /// as far as a person is concerned, and so is the card.
    func testAFileDraggedToTheTrashLeavesTheShelf() throws {
        let (root, a) = try movableFile()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        store.requestThumbnail = { _, _ in }
        store.add([a])
        store.select(store.items[0], modifiers: [])

        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: trash.appendingPathComponent(a.lastPathComponent))
        store.followMove([a])

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "shelf.urls"), [])
    }

    /// A move to another disk is a copy and a delete, and a bookmark cannot
    /// follow a file across disks: nothing is left to point at, so the card
    /// leaves rather than sitting there dead.
    func testAFileThatCannotBeFollowedLeavesTheShelf() throws {
        let (root, a) = try movableFile()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        store.requestThumbnail = { _, _ in }
        let other = URL(fileURLWithPath: "/tmp/stays-\(UUID()).txt")
        store.add([other])
        store.add([a])

        try FileManager.default.removeItem(at: a)
        store.followMove([a])

        XCTAssertEqual(store.items.map(\.url), [other], "only the card that went away leaves")
    }

    /// Finder's file operations run on their own after the drop is accepted,
    /// so when the drag ends the file may not have moved yet. A card whose
    /// file is still where it was is asked again shortly, not given up on.
    func testAMoveThatLandsAfterTheDragEndsIsStillFollowed() async throws {
        let (root, a) = try movableFile()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        store.requestThumbnail = { _, _ in }
        store.moveSettleDelays = [.milliseconds(20), .milliseconds(20)]
        store.add([a])

        let followUp = store.followMove([a])
        XCTAssertEqual(store.items.map(\.url), [a], "nothing moved yet, so nothing changes")
        XCTAssertNotNil(followUp, "and it will look again")

        let b = root.appendingPathComponent("Screenshot moved.png")
        try FileManager.default.moveItem(at: a, to: b)
        await followUp?.value

        XCTAssertEqual(store.items.map { $0.url.resolvingSymlinksInPath() }, [b.resolvingSymlinksInPath()])
    }

    /// A group drag lifts the grabbed card first, so it is the one that sits
    /// under the pointer; the rest fan out behind it in shelf order.
    func testAGroupDragLiftsTheGrabbedCardFirst() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults)
        store.requestThumbnail = { _, _ in }
        store.makeBookmark = { Data($0.path.utf8) }
        let urls = ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/\($0).png") }
        store.add(urls)
        for card in store.items { store.select(card, modifiers: .command) }
        let grabbed = store.items[1]

        XCTAssertEqual(store.dragCards(startingAt: grabbed).map(\.url), [urls[1], urls[0], urls[2]])
        XCTAssertEqual(store.dragURLs(startingAt: grabbed), urls, "Quick Look and AirDrop keep shelf order")
    }

    // The tile's name — middle truncation over two lines, keeping the
    // extension (redesign 2026-10-15, spec §8.1) — is `ShelfTileName`, held by
    // `ShelfLayoutTests`. It replaced `ShelfItem.compactName`, which kept the
    // last word and dropped the start (H-025); Finder's rule keeps both ends.

    // MARK: The card menu's header (M-23)

    /// The menu opens on what the card is: its kind, its size and the folder
    /// it is in, so a person can tell which of two same-named files they
    /// right-clicked before acting on it.
    func testTheMenuHeaderSaysKindSizeAndFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shelf Header \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data(repeating: 65, count: 2_048).write(to: file)
        let item = ShelfItem(url: file, icon: NSImage())

        let header = item.menuHeader()
        let parts = header.components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 3, header)
        XCTAssertFalse(parts[0].isEmpty, "the kind")
        XCTAssertTrue(parts[1].contains("2"), "the size, \(parts[1])")
        XCTAssertEqual(parts.last, "in " + folder.lastPathComponent)
    }

    /// An offline card has no kind or size to read — its disk is away — so
    /// the header names the disk, which is what brings it back.
    func testAnOfflineCardsMenuHeaderNamesItsDisk() {
        let item = ShelfItem(url: URL(fileURLWithPath: "/Volumes/Backup Disk/Reports/q3.pdf"), icon: NSImage(), isOffline: true)
        XCTAssertEqual(item.menuHeader(), "Backup Disk")
    }

    // MARK: The action bar (F-037)

    /// The bar acts on the cards that can be acted on: the selection, in
    /// shelf order, without a card whose disk is away.
    func testTheActionBarActsOnTheReachableSelectionInShelfOrder() async {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let offline = "/Volumes/Isla-Test-\(UUID())/report.pdf"
        defaults.set(["/tmp/a.txt", offline, "/tmp/b.txt", "/tmp/c.txt"], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.mountedVolumes = { [] }
        store.verdictFor = { url, mounted in
            url.path.hasPrefix("/Volumes/") ? ShelfStore.verdict(for: url, mounted: mounted) : .present
        }
        store.requestThumbnail = { _, _ in }
        store.load()
        await store.refreshFromDisk().value
        XCTAssertEqual(store.selectedCards, [])

        // Picked last-to-first, read back first-to-last.
        for card in store.items.reversed() where card.url.lastPathComponent != "b.txt" {
            store.select(card, modifiers: .command)
        }
        XCTAssertEqual(store.selectedCards.map(\.url.lastPathComponent),
                       store.items.map(\.url.lastPathComponent).filter { $0 == "a.txt" || $0 == "c.txt" })
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
