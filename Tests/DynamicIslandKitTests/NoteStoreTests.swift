import XCTest
@testable import DynamicIslandKit

@MainActor
final class NoteStoreTests: XCTestCase {
    func testBlankNotesLeaveTheStoreOnLeave() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = NoteStore(fileURL: file)
        store.add()
        let id = store.notes[0].id
        store.update(id, text: "Heading\nBody")

        store.add()
        store.leave()
        XCTAssertEqual(store.notes.count, 1)
    }

    func testMissingNotesFileDoesNotSetFileBroken() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = NoteStore(fileURL: file)

        XCTAssertFalse(store.fileBroken)
    }

    func testAddRefusesToOverwriteAMalformedNotesFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.json")
        try Data("{broken".utf8).write(to: file)
        let store = NoteStore(fileURL: file)

        store.add()
        store.flush()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{broken")
        XCTAssertTrue(store.fileBroken)
    }
}
