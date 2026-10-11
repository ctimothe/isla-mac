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

    // MARK: - Reads only what a switch wants (J-001, F-050, G-029)

    /// Isla's own write is recognised from the type list alone. The marker
    /// used to be detected by asking for its bytes, which is a content read:
    /// under Paste from Other Apps set to Ask, every Shelf copy would have
    /// raised an alert for Isla's own data.
    func testOwnMarkerIsDetectedWithoutReadingContent() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        let provider = CountingProvider { type, _ in
            type == .string ? Data("shelf copy".utf8) : Data()
        }

        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string, .islaInternal])
        board.clearContents()
        board.writeObjects([item])
        store.pollNow()

        XCTAssertEqual(provider.calls[.string, default: 0], 0)
        XCTAssertEqual(provider.calls[.islaInternal, default: 0], 0)
        XCTAssertEqual(store.contentReadCount, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    /// The read macOS refused while the user was still answering its alert
    /// is tried again once the answer is Allow. The change count used to be
    /// spent before any read, so the copy that raised the alert was never
    /// recorded, even after the user allowed it.
    ///
    /// Simulated on a real pasteboard: the type is declared with no bytes, so
    /// the first read answers nil, as a refused read does. The answer to the
    /// alert then lands as the bytes, in the same pasteboard generation. A
    /// lazy data provider cannot stand in for the refusal: AppKit asks a
    /// provider once and keeps its nil.
    func testARefusedTextReadIsNotSpentWhenAccessIsGranted() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        board.declareTypes([.string], owner: nil)
        var answered = false
        store.accessBehavior = {
            guard store.contentReadCount >= 1 else { return .ask }
            if !answered {
                answered = true
                board.setString("allowed copy", forType: .string)
            }
            return .allowed
        }

        store.pollNow()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.preview, "allowed copy")
        XCTAssertEqual(store.contentReadCount, 2)
    }

    /// Don't Allow means the poll has nothing it may read: it stops, says so,
    /// and touches no content on the way out.
    func testDeniedAccessStopsPollingAndSaysSo() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        var answer = ClipboardAccess.allowed
        store.accessBehavior = { answer }
        let provider = CountingProvider { _, _ in Data("refused".utf8) }
        store.start()
        defer { store.stop() }
        XCTAssertTrue(store.isPolling)
        // The user picks Don't Allow in System Settings while Isla runs.
        answer = .denied

        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        board.writeObjects([item])
        store.pollNow()

        XCTAssertFalse(store.isPolling)
        XCTAssertEqual(store.access, .denied)
        XCTAssertEqual(provider.calls[.string, default: 0], 0)
        XCTAssertEqual(store.contentReadCount, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    /// A stopped poll cannot notice the user switching back to Allow, so the
    /// Clipboard tab asks. A wake does not restart it behind the user's back,
    /// and a recheck with both switches off starts nothing.
    func testRecheckAccessRestartsAPollThatDenialStopped() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        var answer = ClipboardAccess.denied
        store.accessBehavior = { answer }
        defer { store.stop() }

        store.start()
        XCTAssertFalse(store.isPolling)
        XCTAssertEqual(store.access, .denied)

        store.recheckAccess()
        XCTAssertFalse(store.isPolling, "still denied")

        answer = .allowed
        store.recordsHistory = { false }
        store.wantsImages = { false }
        store.recheckAccess()
        XCTAssertFalse(store.isPolling, "no switch wants the pasteboard")
        XCTAssertEqual(store.access, .allowed)

        store.stop()
        answer = .denied
        store.start()
        answer = .allowed
        store.recordsHistory = { true }
        store.recheckAccess()
        XCTAssertTrue(store.isPolling)
        XCTAssertEqual(store.access, .allowed)
    }

    /// The precedence, from the type list alone: nothing is read for a switch
    /// that is off, and text beside a picture is text while history is on.
    func testReadPlanReadsOnlyWhatASwitchWants() {
        let text: [NSPasteboard.PasteboardType] = [.string]
        let textAndImage: [NSPasteboard.PasteboardType] = [.string, .tiff]
        let image: [NSPasteboard.PasteboardType] = [.png, .tiff]
        let file: [NSPasteboard.PasteboardType] = [.fileURL, .string]
        let movie: [NSPasteboard.PasteboardType] = [.init("public.mpeg-4"), .string]

        XCTAssertEqual(ClipboardStore.readPlan(types: textAndImage, history: true, images: true), .text)
        XCTAssertEqual(ClipboardStore.readPlan(types: textAndImage, history: false, images: true), .image)
        XCTAssertEqual(ClipboardStore.readPlan(types: image, history: true, images: true), .image)
        XCTAssertEqual(ClipboardStore.readPlan(types: image, history: true, images: false), .nothing)
        XCTAssertEqual(ClipboardStore.readPlan(types: text, history: false, images: true), .nothing)
        XCTAssertEqual(ClipboardStore.readPlan(types: file, history: false, images: true), .files)
        XCTAssertEqual(ClipboardStore.readPlan(types: file, history: true, images: false), .files)
        XCTAssertEqual(ClipboardStore.readPlan(types: file, history: false, images: false), .nothing)
        XCTAssertEqual(ClipboardStore.readPlan(types: movie, history: true, images: true), .movieData)
        XCTAssertEqual(ClipboardStore.readPlan(types: movie, history: true, images: false), .text)
    }

    /// Under Ask an empty image read is a refusal, not a Continuity picture
    /// still in flight. The retry loop used to read again every half second,
    /// up to thirteen reads, and every one of them could raise another alert.
    func testAskModeNeverRetriesAnImageRead() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        store.wantsImages = { true }
        store.accessBehavior = { .ask }

        // Declared with no bytes: every read answers nil, as a refused one does.
        board.declareTypes([.png], owner: nil)
        store.pollNow()

        let settle = expectation(description: "retry window elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settle.fulfill() }
        wait(for: [settle], timeout: 3)

        XCTAssertEqual(store.contentReadCount, 1)
        XCTAssertTrue(store.items.isEmpty)
    }

    /// A Numbers range or a rich-text selection carries a picture of itself
    /// beside its text. It used to become a screenshot card, and the text the
    /// user actually copied never reached history.
    func testTextBesideAnImageGoesToHistory() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        store.wantsImages = { true }
        store.recordsHistory = { true }
        var images = 0
        store.onImage = { _ in images += 1 }

        let item = NSPasteboardItem()
        item.setString("A1\tB1", forType: .string)
        item.setData(Self.onePixelTIFF(), forType: .tiff)
        board.clearContents()
        board.writeObjects([item])
        store.pollNow()

        let settle = expectation(description: "an encode would have landed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.payload, .text("A1\tB1"))
        XCTAssertEqual(images, 0)
    }

    // The markers nspasteboard.org lists for tools that predate its universal
    // types, plus KeeWeb's. A password manager that sets only one of these
    // used to have its passwords recorded.

    func testLegacyOptOutMarkersAreHonouredForTextExpanderAndButler() {
        assertMarkerKeepsCopyOut("de.petermaurer.TransientPasteboardType")
    }

    func testLegacyOptOutMarkersAreHonouredForTypeIt4Me() {
        assertMarkerKeepsCopyOut("com.typeit4me.clipping")
    }

    func testLegacyOptOutMarkersAreHonouredForTypinator() {
        assertMarkerKeepsCopyOut("Pasteboard generator type")
    }

    func testLegacyOptOutMarkersAreHonouredForOnePassword() {
        assertMarkerKeepsCopyOut("com.agilebits.onepassword")
    }

    func testLegacyOptOutMarkersAreHonouredForKeeWeb() {
        assertMarkerKeepsCopyOut("net.antelle.keeweb")
    }

    // MARK: - Helpers

    private func assertMarkerKeepsCopyOut(_ marker: String, line: UInt = #line) {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        board.clearContents()
        board.setString("hunter2", forType: .string)
        board.setData(Data(), forType: .init(marker))

        store.pollNow()

        XCTAssertTrue(store.items.isEmpty, "\(marker) was recorded", line: line)
    }

    private static func onePixelTIFF() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.tiffRepresentation!
    }
}

/// A lazy pasteboard item that counts every time the pasteboard asks it for
/// bytes. On a real pasteboard that is exactly a content read, which is what
/// the privacy alert is raised for, so the count is the number of alerts a
/// user under Ask would have seen. `answer` gets the type and the 1-based call
/// number for that type, and nil provides nothing.
private final class CountingProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var calls: [NSPasteboard.PasteboardType: Int] = [:]
    private let answer: (NSPasteboard.PasteboardType, Int) -> Data?

    init(answer: @escaping (NSPasteboard.PasteboardType, Int) -> Data?) {
        self.answer = answer
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        calls[type, default: 0] += 1
        if let data = answer(type, calls[type]!) { item.setData(data, forType: type) }
    }
}
