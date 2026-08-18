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
}
