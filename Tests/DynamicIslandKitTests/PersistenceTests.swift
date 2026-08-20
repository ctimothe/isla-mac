import AppKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class PersistenceTests: XCTestCase {
    func testBlankNotesAreRemovedAndFlushPersistsAnEmptyList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: file)

        store.add()
        store.leave()
        store.flush()

        XCTAssertTrue(store.notes.isEmpty)
        let stored = try JSONDecoder().decode([Note].self, from: Data(contentsOf: file))
        XCTAssertEqual(stored, [])
    }
}
