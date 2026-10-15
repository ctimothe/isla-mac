import AppKit
import XCTest
@testable import IslaKit

/// Pictures in the history (redesign spec §9.1, §9.4): at most 12, the original
/// pasteboard bytes up to 25 MB else a 2048 px PNG, a 176 × 132 thumbnail, copied
/// back as the picture — and Save Clipboard Screenshots and the Ask-mode read
/// rules exactly as they were.
@MainActor
final class ClipboardImageTests: XCTestCase {
    private var board: NSPasteboard!
    private var store: ClipboardStore!

    override func setUp() async throws {
        board = NSPasteboard(name: .init("ClipboardImageTests.\(UUID())"))
        store = ClipboardStore(pasteboard: board)
        store.accessBehavior = { .allowed }
        store.recordsHistory = { true }
        store.wantsImages = { false }
        store.keepsImages = { true }
        store.sourceApp = { "Photos" }
    }

    override func tearDown() async throws {
        board.releaseGlobally()
    }

    private func png(_ width: Int = 300, _ height: Int = 200, noise: Bool = false) -> Data {
        ClipboardPinsTests.png(width: width, height: height, noise: noise)
    }

    /// Waits for the background encode to land.
    private func settle(until condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let done = expectation(description: "settled")
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() || Date() > deadline { done.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
            }
        }
        check()
        wait(for: [done], timeout: timeout + 1)
    }

    // MARK: The entry

    func testASmallPictureKeepsItsOriginalBytesAndGetsAThumbnail() throws {
        let original = png(300, 200)
        let image = try XCTUnwrap(ClipImage.make(data: original, type: .png, sourceApp: "Photos"))
        XCTAssertEqual(image.data, original, "the pasteboard's own bytes, under the limit")
        XCTAssertEqual(image.type, .png)
        XCTAssertEqual(image.pixelSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(image.thumbnail.width, 176)
        XCTAssertEqual(image.thumbnail.height, 132)
        XCTAssertEqual(image.dimensionsText, "300 × 200")
        XCTAssertEqual(ClipImageText.detail(image), "300 × 200 · Photos")
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: original)?.tiffRepresentation)
        let kept = try XCTUnwrap(ClipImage.make(data: tiff, type: .tiff, sourceApp: nil))
        XCTAssertEqual(kept.type, .tiff, "a TIFF stays a TIFF")
        XCTAssertEqual(ClipImageText.detail(kept), "300 × 200")
    }

    func testThePicturePastTheByteLimitIsKeptAsAScaledPNG() throws {
        let original = png(400, 300, noise: true)
        XCTAssertGreaterThan(original.count, 1_000)
        // The 25 MB line, crossed with a few kilobytes: injected.
        let image = try XCTUnwrap(ClipImage.make(
            data: original, type: .tiff, sourceApp: nil, byteLimit: 1_000, maximumPixels: 100
        ))
        XCTAssertEqual(image.type, .png, "past the limit it is a PNG")
        XCTAssertNotEqual(image.data, original)
        let kept = try XCTUnwrap(image.keptPixelSize)
        XCTAssertEqual(max(kept.width, kept.height), 100, "its long side is the cap")
        XCTAssertEqual(kept.width / kept.height, 400.0 / 300, accuracy: 0.05, "the shape is kept")
        XCTAssertEqual(image.pixelSize, CGSize(width: 400, height: 300), "the row still says what was copied")
        XCTAssertEqual(image.thumbnail.width, 176)
        // Never enlarged: a picture smaller than the cap keeps its own size.
        let small = try XCTUnwrap(ClipImage.make(
            data: png(50, 40, noise: true), type: .png, sourceApp: nil, byteLimit: 10, maximumPixels: 2048
        ))
        XCTAssertEqual(small.keptPixelSize, CGSize(width: 50, height: 40))
    }

    func testTheLimitsAreTheSpecs() {
        XCTAssertEqual(ClipImage.maximumEntries, 12)
        XCTAssertEqual(ClipImage.byteLimit, 25 * 1024 * 1024)
        XCTAssertEqual(ClipImage.maximumPixels, 2048)
        XCTAssertEqual(ClipImage.thumbnailSize, CGSize(width: 176, height: 132))
        XCTAssertEqual(store.imageByteLimit, 25 * 1024 * 1024)
        XCTAssertEqual(store.imageMaximumPixels, 2048)
    }

    func testBytesThatAreNotAPictureAreNotAnEntry() {
        XCTAssertNil(ClipImage.make(data: Data("hello".utf8), type: .png, sourceApp: nil))
        XCTAssertNil(ClipImage.make(data: Data(), type: .tiff, sourceApp: nil))
    }

    func testTheSamePictureCopiedTwiceIsOneEntry() throws {
        let data = png()
        let first = try XCTUnwrap(ClipImage.make(data: data, type: .png, sourceApp: "Photos"))
        let again = try XCTUnwrap(ClipImage.make(data: data, type: .png, sourceApp: "Safari"))
        XCTAssertEqual(first, again, "who copied it is not what makes it a different picture")
        store.record(ClipItem(payload: .image(first), date: Date()))
        store.record(ClipItem(payload: .image(again), date: Date()))
        XCTAssertEqual(store.items.count, 1)
    }

    // MARK: Twelve

    func testAThirteenthPictureDropsTheOldest() throws {
        var firsts: [ClipItem] = []
        for index in 0..<13 {
            let image = try XCTUnwrap(ClipImage.make(data: png(40 + index, 30), type: .png, sourceApp: nil))
            let item = ClipItem(payload: .image(image), date: Date(timeIntervalSince1970: Double(index)))
            firsts.append(item)
            store.record(item)
            if index == 5 { store.record(ClipItem(payload: .text("between"), date: Date())) }
        }
        let pictures = store.items.filter { $0.kind == .image }
        XCTAssertEqual(pictures.count, 12)
        XCTAssertFalse(pictures.contains { $0.id == firsts[0].id }, "the oldest picture went")
        XCTAssertTrue(pictures.contains { $0.id == firsts[12].id })
        XCTAssertTrue(store.items.contains { $0.preview == "between" }, "text is not what the cap drops")
    }

    func testAPinnedPictureOutlivesTheCapWhileAnUnpinnedOneCanBeDropped() throws {
        var made: [ClipItem] = []
        for index in 0..<12 {
            let image = try XCTUnwrap(ClipImage.make(data: png(40 + index, 30), type: .png, sourceApp: nil))
            let item = ClipItem(payload: .image(image), date: Date(timeIntervalSince1970: Double(index)))
            made.append(item)
            store.record(item)
        }
        store.setPinned(store.items.first { $0.id == made[0].id }!, true)
        let extra = try XCTUnwrap(ClipImage.make(data: png(99, 30), type: .png, sourceApp: nil))
        store.record(ClipItem(payload: .image(extra), date: Date()))
        let pictures = store.items.filter { $0.kind == .image }
        XCTAssertEqual(pictures.count, 12)
        XCTAssertTrue(pictures.contains { $0.id == made[0].id }, "the pinned one stayed")
        XCTAssertFalse(pictures.contains { $0.id == made[1].id }, "the oldest unpinned one went")
    }

    func testTurningIncludeImagesOffDropsThePicturesAndKeepsTheRest() throws {
        store.record(ClipItem(payload: .text("note"), date: Date()))
        let image = try XCTUnwrap(ClipImage.make(data: png(), type: .png, sourceApp: nil))
        store.record(ClipItem(payload: .image(image), date: Date()))
        store.removeImages()
        XCTAssertEqual(store.items.map(\.preview), ["note"])
    }

    // MARK: Reading them, once

    func testACopiedPictureBecomesAnEntryAndCopiesBackAsThePicture() throws {
        let original = png(120, 80)
        board.clearContents()
        board.setData(original, forType: .png)
        store.pollNow()
        settle { !self.store.items.isEmpty }

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.kind, .image)
        guard case .image(let image) = item.payload else { return XCTFail("not a picture entry") }
        XCTAssertEqual(image.pixelSize, CGSize(width: 120, height: 80))
        XCTAssertEqual(image.sourceApp, "Photos")
        XCTAssertEqual(item.preview, "Image")
        XCTAssertEqual(store.contentReadCount, 1, "one read for the picture")

        board.clearContents()
        store.copy(item)
        XCTAssertEqual(board.data(forType: .png), original, "the original bytes go back")
        store.pollNow()
        settle(until: { false }, timeout: 0.4)
        XCTAssertEqual(store.items.count, 1, "copying it back is not copying it again")
    }

    func testATIFFIsKeptAsItWasCopied() throws {
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: png(60, 40))?.tiffRepresentation)
        board.clearContents()
        board.setData(tiff, forType: .tiff)
        store.pollNow()
        settle { !self.store.items.isEmpty }
        guard case .image(let image)? = store.items.first?.payload else { return XCTFail("no picture entry") }
        XCTAssertEqual(image.type, .tiff)
        XCTAssertEqual(image.data, tiff)
    }

    func testThePasteboardPathAppliesTheByteLimit() throws {
        store.imageByteLimit = 1_000
        store.imageMaximumPixels = 64
        board.clearContents()
        board.setData(png(300, 200, noise: true), forType: .png)
        store.pollNow()
        settle { !self.store.items.isEmpty }
        guard case .image(let image)? = store.items.first?.payload else { return XCTFail("no picture entry") }
        XCTAssertEqual(image.type, .png)
        let kept = try XCTUnwrap(image.keptPixelSize)
        XCTAssertEqual(max(kept.width, kept.height), 64)
    }

    func testIncludeImagesOffKeepsNoPictureAndReadsNone() {
        store.keepsImages = { false }
        board.clearContents()
        board.setData(png(), forType: .png)
        store.pollNow()
        settle(until: { false }, timeout: 0.5)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.contentReadCount, 0, "no switch wanted the picture, so it was not read")
    }

    func testHistoryOffKeepsNoPictureEvenWithIncludeImagesOn() {
        store.recordsHistory = { false }
        board.clearContents()
        board.setData(png(), forType: .png)
        store.pollNow()
        settle(until: { false }, timeout: 0.5)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.contentReadCount, 0)
    }

    /// Save Clipboard Screenshots is a switch of its own, and keeps working the
    /// way it did: with Include Images off it still reaches the vault, and with
    /// both on one read serves both.
    func testSaveClipboardScreenshotsIsIndependentOfIncludeImages() throws {
        var delivered: [Data] = []
        store.onImage = { delivered.append($0) }
        let data = png(80, 60)

        // Screenshots on, images off: the vault gets it, history does not.
        store.wantsImages = { true }
        store.keepsImages = { false }
        board.clearContents()
        board.setData(data, forType: .png)
        store.pollNow()
        settle { !delivered.isEmpty }
        XCTAssertEqual(delivered, [data])
        XCTAssertTrue(store.items.isEmpty)

        // Both on: the same single read feeds both.
        store.keepsImages = { true }
        let before = store.contentReadCount
        board.clearContents()
        board.setData(png(81, 60), forType: .png)
        store.pollNow()
        settle { !self.store.items.isEmpty }
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.contentReadCount - before, 1, "two switches, one read")

        // Screenshots off, images on: history gets it, the vault does not.
        store.wantsImages = { false }
        board.clearContents()
        board.setData(png(82, 60), forType: .png)
        store.pollNow()
        settle { self.store.items.count == 2 }
        XCTAssertEqual(delivered.count, 2, "the vault was not asked")
        XCTAssertEqual(store.items.count, 2)
    }

    /// Under Ask an empty read is a refusal. With Include Images wanting the
    /// picture too, it is still read once and never retried.
    func testAskModeNeverRetriesAnImageReadForHistoryEither() {
        store.accessBehavior = { .ask }
        store.wantsImages = { false }
        board.declareTypes([.png], owner: nil)
        store.pollNow()
        settle(until: { false }, timeout: 1.5)
        XCTAssertEqual(store.contentReadCount, 1)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testTextBesideAPictureStillGoesToHistoryAsText() throws {
        let item = NSPasteboardItem()
        item.setString("A1\tB1", forType: .string)
        item.setData(png(), forType: .png)
        board.clearContents()
        board.writeObjects([item])
        store.pollNow()
        settle(until: { false }, timeout: 0.5)
        XCTAssertEqual(store.items.map(\.payload), [.text("A1\tB1")])
    }

    func testReadPlanReadsAPictureForEitherSwitchAndAFilmForOneOnly() {
        let picture: [NSPasteboard.PasteboardType] = [.png, .tiff]
        let film: [NSPasteboard.PasteboardType] = [.init("public.mpeg-4")]
        typealias Store = ClipboardStore
        XCTAssertEqual(Store.readPlan(types: picture, history: true, images: false, keepImages: true), .image)
        XCTAssertEqual(Store.readPlan(types: picture, history: true, images: false, keepImages: false), .nothing)
        XCTAssertEqual(Store.readPlan(types: picture, history: false, images: false, keepImages: true), .nothing, "history off")
        XCTAssertEqual(Store.readPlan(types: picture, history: true, images: true, keepImages: true), .image)
        XCTAssertEqual(Store.readPlan(types: picture, history: false, images: true, keepImages: true), .image)
        XCTAssertEqual(Store.readPlan(types: picture + [.string], history: true, images: false, keepImages: true), .text)
        XCTAssertEqual(Store.readPlan(types: film, history: true, images: false, keepImages: true), .nothing, "Include Images keeps pictures, not films")
        XCTAssertEqual(Store.readPlan(types: film, history: true, images: true, keepImages: true), .movieData)
    }
}
