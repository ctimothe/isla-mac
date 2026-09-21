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
        XCTAssertTrue(ShelfStore.isGone(trashed), "it exists, and it is still gone")

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
    func testRefreshFromDiskEvictsACardWhoseFileWasDeleted() throws {
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
        store.refreshFromDisk()

        XCTAssertTrue(store.items.isEmpty)
    }

    /// A card whose file exists but can no longer be read — its containing
    /// directory's traversal permission revoked, the way a "Don't Allow" on a
    /// protected folder leaves things — must not be evicted alongside a card
    /// that is genuinely gone (#10-adjacent regression covered by isGone()).
    func testRefreshFromDiskKeepsACardWhoseFileExistsButIsUnreadable() throws {
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

        store.refreshFromDisk()

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
}
