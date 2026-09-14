import XCTest
@testable import IslaKit

@MainActor
final class SettingsPaneTests: XCTestCase {
    func testNotchStoresOwnOneLocalLibraryForTheSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let stores = NotchStores(localLyricsDirectory: root)

        XCTAssertTrue(stores.localLyricsLibrary === stores.lyricsCoordinator.library)
    }

    func testSettingsCopyPromisesLocalOnlyLyrics() {
        XCTAssertEqual(SettingsPane.localLyricsPrivacyCopyKey, "Lyrics stay on this Mac.")
    }
}
