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

    /// The 0.3–3.0 / 18–64 ranges belong to the model, not just to today's
    /// call sites (init's defaults read, the Slider, the increment buttons) —
    /// any caller that sets these directly must still land in range.
    func testSpeedAndFontSizeClampAtTheModelRegardlessOfCaller() throws {
        let suite = "TeleprompterStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TeleprompterStore(fileURL: file, defaults: defaults)

        store.speed = 10
        XCTAssertEqual(store.speed, 3.0)
        store.speed = 0
        XCTAssertEqual(store.speed, 0.3)

        store.fontSize = 200
        XCTAssertEqual(store.fontSize, 64)
        store.fontSize = 5
        XCTAssertEqual(store.fontSize, 18)
    }
}
