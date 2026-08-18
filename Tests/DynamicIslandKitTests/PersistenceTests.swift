import AppKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class PersistenceTests: XCTestCase {
    func testMalformedSnippetsAreReportedWithoutBeingOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("snippets.json")
        try Data("{broken".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: .init("PersistenceTests.\(UUID())"))
        let store = SnippetStore(fileURL: file, pasteboard: pasteboard, log: { _ in })

        store.reload()
        store.add(label: "Never", text: "overwrite")

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{broken")
        XCTAssertTrue(store.fileBroken)
        XCTAssertTrue(store.items.isEmpty)
    }

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
