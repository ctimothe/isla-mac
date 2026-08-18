import AppKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class ClipboardStoreTests: XCTestCase {
    func testKeepsFortyNewestUniqueEntries() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)

        for index in 0..<45 {
            board.clearContents()
            board.setString("entry-\(index)", forType: .string)
            store.pollNow()
        }

        XCTAssertEqual(store.items.count, 40)
        XCTAssertEqual(store.items.first?.preview, "entry-44")
        XCTAssertEqual(store.items.last?.preview, "entry-5")
    }

    func testConcealedPasteboardTypeIsIgnored() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        board.clearContents()
        board.setString("secret", forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))

        store.pollNow()

        XCTAssertTrue(store.items.isEmpty)
    }

    func testCopyUsesTheInjectedPasteboardWithoutRecordingItsOwnWrite() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        board.clearContents()
        board.setString("remember me", forType: .string)
        store.pollNow()
        let item = store.items[0]

        board.clearContents()
        store.copy(item)
        store.pollNow()

        XCTAssertEqual(board.string(forType: .string), "remember me")
        XCTAssertEqual(store.items.count, 1)
    }
}
