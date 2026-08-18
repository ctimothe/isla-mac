import XCTest
@testable import DynamicIslandKit

final class ScreenshotVaultTests: XCTestCase {
    func testCollisionCreatesNumberedPNGWithoutDeletingEitherFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            screenshotDirectory: root.appendingPathComponent("pictures")
        )
        let vault = ScreenshotVault(paths: paths)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try XCTUnwrap(vault.save(Data([1]), at: date))
        let second = try XCTUnwrap(vault.save(Data([2]), at: date))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }
}
