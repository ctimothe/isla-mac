import Foundation
import XCTest
@testable import IslaKit

final class AppPathsTests: XCTestCase {
    func testLivePathsUseOnlyIslaDirectories() {
        XCTAssertEqual(AppPaths.live.supportDirectory.lastPathComponent, "Isla")
        XCTAssertEqual(AppPaths.live.screenshotDirectory.lastPathComponent, "Isla")
        XCTAssertFalse(AppPaths.live.supportDirectory.path.contains("/Cyclop"))
        XCTAssertFalse(AppPaths.live.screenshotDirectory.path.contains("/Cyclop"))
    }

    func testSupportFileCreatesOnlyTheInjectedSupportDirectory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            screenshotDirectory: root.appendingPathComponent("pictures")
        )

        let file = paths.supportFile("notes.json")

        XCTAssertEqual(file, root.appendingPathComponent("support/notes.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("support").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pictures").path))
    }
}
