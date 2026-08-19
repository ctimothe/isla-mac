import AppKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class SnippetStoreTests: XCTestCase {
    func testSearchMatchesLabelAndTextCaseInsensitively() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let board = NSPasteboard(name: .init("SnippetStoreTests.\(UUID())"))
        let store = SnippetStore(fileURL: file, pasteboard: board, log: { _ in })
        store.add(label: "Office Address", text: "42 Example Road")

        store.query = "example"

        XCTAssertEqual(store.filtered.map(\.label), ["Office Address"])
        store.query = "OFFICE"
        XCTAssertEqual(store.filtered.map(\.text), ["42 Example Road"])
    }

    func testCopyUsesInjectedPasteboard() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let board = NSPasteboard(name: .init("SnippetStoreTests.\(UUID())"))
        let store = SnippetStore(fileURL: file, pasteboard: board, log: { _ in })
        let snippet = Snippet(label: "Address", text: "42 Example Road")

        store.copy(snippet)

        XCTAssertEqual(board.string(forType: .string), "42 Example Road")
    }

    func testRemoveRefusesToOverwriteAMalformedSnippetsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("snippets.json")
        let snippet = Snippet(label: "Office Address", text: "42 Example Road")
        try JSONEncoder().encode([snippet]).write(to: file)
        let pasteboard = NSPasteboard(name: .init("SnippetStoreTests.\(UUID())"))
        let store = SnippetStore(fileURL: file, pasteboard: pasteboard, log: { _ in })
        store.reload()
        XCTAssertEqual(store.items, [snippet])

        // The file is edited by hand into something unreadable in between the
        // load that put the snippet in memory and the removal below.
        try Data("{broken".utf8).write(to: file)

        store.remove(snippet)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{broken")
        XCTAssertTrue(store.fileBroken)
    }
}
