import XCTest
@testable import DynamicIslandKit

@MainActor
final class TeleprompterStoreTests: XCTestCase {
    func testPreferencesClampAndRunningStateSuspends() throws {
        let suite = "TeleprompterStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(99.0, forKey: "teleprompter.speed")
        defaults.set(2.0, forKey: "teleprompter.fontSize")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "Read me".write(to: file, atomically: true, encoding: .utf8)

        let store = TeleprompterStore(fileURL: file, defaults: defaults)

        XCTAssertEqual(store.speed, 3.0)
        XCTAssertEqual(store.fontSize, 18.0)
        XCTAssertEqual(store.script, "Read me")
        store.contentHeight = 500
        store.viewportHeight = 100
        store.start()
        XCTAssertTrue(store.isRunning)
        store.suspend()
        XCTAssertFalse(store.isRunning)
    }
}
