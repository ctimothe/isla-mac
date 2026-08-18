import XCTest
@testable import DynamicIslandKit

@MainActor
final class NoteStoreTests: XCTestCase {
    func testFirstLineIsTitleAndBlankNotesLeaveTheStore() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = NoteStore(fileURL: file)
        store.add()
        let id = store.notes[0].id
        store.update(id, text: "Heading\nBody")

        XCTAssertEqual(store.notes[0].title, "Heading")

        store.add()
        store.leave()
        XCTAssertEqual(store.notes.count, 1)
    }
}
