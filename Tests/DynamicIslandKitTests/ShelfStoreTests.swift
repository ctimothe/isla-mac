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
}
