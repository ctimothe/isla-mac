import AppKit
import XCTest
@testable import IslaKit

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

    /// Simulates a Continuity photo: the type lands on the pasteboard before
    /// its bytes do, so `pollNow()` starts the retry wait. Turning off image
    /// saving mid-wait — the moment the bytes actually arrive — must not save
    /// the picture anyway.
    func testTurningOffImageSavingMidWaitAbortsTheAwaitedImage() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        var wantsImages = true
        store.wantsImages = { wantsImages }
        var receivedImage: Data?
        store.onImage = { receivedImage = $0 }

        board.clearContents()
        // Declares the type without providing data yet, the same way a phone
        // copy's picture arrives after the type has already been announced.
        board.declareTypes([.tiff], owner: nil)
        store.pollNow()

        // Off, mid-wait — before the retry that would have found the bytes.
        wantsImages = false

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        // Providing the data now does not move the change count: it is the
        // same pasteboard generation as the `declareTypes` call above, exactly
        // as it plays out for a real Continuity photo.
        board.setData(rep.tiffRepresentation!, forType: .tiff)

        let tick = expectation(description: "awaitImage retry tick elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { tick.fulfill() }
        wait(for: [tick], timeout: 2)

        XCTAssertNil(receivedImage)
        XCTAssertTrue(store.items.isEmpty)
    }
}
