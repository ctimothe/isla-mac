import XCTest
@testable import DynamicIslandKit

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
}
