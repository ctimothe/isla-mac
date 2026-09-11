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

    /// Movie bytes on the pasteboard — a captured recording copied as data —
    /// arrive with their container type and leave with it: the vault names the
    /// file from the extension, so dropping it would save every recording as
    /// one format regardless of what was copied.
    func testMovieDataIsDeliveredWithItsContainerExtension() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        var received: (data: Data, ext: String)?
        store.onMovieData = { received = ($0, $1) }

        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .init("public.mpeg-4"))
        store.pollNow()

        XCTAssertEqual(received?.data, Data([1, 2, 3]))
        XCTAssertEqual(received?.ext, "mp4")
        // Data captures live on the shelf, not in history — like screenshots.
        XCTAssertTrue(store.items.isEmpty)
    }

    /// The screenshot-saving switch guards every clipboard capture that
    /// writes a file. A recording is megabytes, not bytes; with the switch
    /// off it must not be encoded, written, or kept.
    func testMovieDataRespectsTheCaptureSwitch() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        store.wantsImages = { false }
        var received: (data: Data, ext: String)?
        store.onMovieData = { received = ($0, $1) }

        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .init("public.mpeg-4"))
        store.pollNow()

        XCTAssertNil(received)
    }

    /// A recording copied as a file in Finder is already on disk, so there is
    /// nothing for the vault to write — but it still belongs on the shelf, and
    /// it still belongs in history like every other copied file.
    func testCopiedMovieFileIsRecordedAndHandedToTheShelf() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        var handed: URL?
        store.onMovieFile = { handed = $0 }

        let url = URL(fileURLWithPath: "/tmp/ClipboardStoreTests-capture.mov")
        board.clearContents()
        board.writeObjects([url as NSURL])
        store.pollNow()

        XCTAssertEqual(handed, url)
        XCTAssertEqual(store.items.count, 1)
    }

    /// A copied document is history only: the shelf is for captures, not for
    /// every file that passes through the pasteboard.
    func testCopiedNonMovieFileIsNotHandedToTheShelf() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        var handed: URL?
        store.onMovieFile = { handed = $0 }

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/notes.pdf") as NSURL])
        store.pollNow()

        XCTAssertNil(handed)
        XCTAssertEqual(store.items.count, 1)
    }
}
