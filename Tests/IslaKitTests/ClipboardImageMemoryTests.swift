import AppKit
import XCTest
@testable import IslaKit

/// Pictures in the history stay out of memory (2026-10-18). Measured on the
/// owner's Mac: a 10 MB screenshot took the footprint from 148 to 521 MB within
/// seconds, because the history kept the original bytes of up to twelve
/// pictures of up to 25 MB as heap `Data`. Now the bytes are in session files,
/// a budget bounds what stays resident, and `==` compares a digest.
///
/// Nothing here writes the general pasteboard, the real temporary directory or
/// the vault: the board is named, the spool's root is a folder of the test's own.
@MainActor
final class ClipboardImageMemoryTests: XCTestCase {
    private var board: NSPasteboard!
    private var store: ClipboardStore!
    private var root: URL!
    private var spool: ClipImageSpool!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardImageMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        spool = ClipImageSpool(root: root)
        board = NSPasteboard(name: .init("ClipboardImageMemoryTests.\(UUID())"))
        store = ClipboardStore(pasteboard: board)
        store.accessBehavior = { .allowed }
        store.recordsHistory = { true }
        store.wantsImages = { false }
        store.keepsImages = { true }
        store.sourceApp = { "Photos" }
        store.imageSpool = spool
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    /// An uncompressed TIFF of about `megabytes` MB that ImageIO decodes, whose
    /// pixels are all `fill` — so two with different fills are different pictures.
    private func tiff(megabytes: Int, fill: UInt8) throws -> Data {
        let side = Int((Double(megabytes * 1024 * 1024) / 4).squareRoot())
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        memset(try XCTUnwrap(rep.bitmapData), Int32(fill), rep.bytesPerRow * side)
        return try XCTUnwrap(rep.tiffRepresentation(using: .none, factor: 0))
    }

    private func png(_ width: Int = 120, _ height: Int = 80, noise: Bool = false) -> Data {
        ClipboardPinsTests.png(width: width, height: height, noise: noise)
    }

    private func settle(until condition: @escaping () -> Bool, timeout: TimeInterval = 10) {
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

    private func filesOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: spool.directory.path)) ?? []).sorted()
    }

    private func entry(_ data: Data, type: NSPasteboard.PasteboardType = .png) throws -> ClipItem {
        let image = try XCTUnwrap(ClipImage.make(data: data, type: type, sourceApp: nil, spool: spool))
        return ClipItem(payload: .image(image), date: Date())
    }

    // MARK: Twelve large pictures

    func testTwelveTwentyMegabytePicturesHoldNoMoreThanTheBudgetInMemory() throws {
        for index in 0..<12 {
            store.record(try entry(try tiff(megabytes: 20, fill: UInt8(index + 1)), type: .tiff))
        }
        XCTAssertEqual(store.items.count, 12)
        XCTAssertLessThanOrEqual(store.residentPictureBytes, ClipImage.residentBudget)
        XCTAssertEqual(store.residentPictureBytes, 0, "20 MB pictures are past the per-picture limit: files only")
        XCTAssertEqual(filesOnDisk().count, 12, "and every one has its file")
        // The pictures are all still there to paste.
        for item in store.items {
            guard case .image(let image) = item.payload else { return XCTFail("not a picture") }
            XCTAssertGreaterThan(image.data.count, 19 * 1024 * 1024)
        }
    }

    func testTheSpoolIsPrivateToTheOwner() throws {
        store.record(try entry(png()))
        let fm = FileManager.default
        let directory = try fm.attributesOfItem(atPath: spool.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(directory, 0o700)
        let file = try XCTUnwrap(filesOnDisk().first)
        let mode = try fm.attributesOfItem(atPath: spool.directory.appendingPathComponent(file).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testNothingIsCreatedUntilAPictureIsKept() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.directory.path))
    }

    // MARK: The budget

    /// Small pictures stay in memory — pasting one back touches no disk — until
    /// the total passes the budget; then the oldest give theirs up and are read
    /// from their files, and every entry stays.
    func testThePicturesTogetherAreHeldToTheBudgetOldestFirst() throws {
        store.imageResidentBudget = 12_000
        var items: [ClipItem] = []
        for index in 0..<8 {
            let item = try entry(png(40 + index, 30, noise: true))
            items.append(item)
            store.record(item)
        }
        XCTAssertEqual(store.items.count, 8, "demoted, not dropped")
        XCTAssertLessThanOrEqual(store.residentPictureBytes, 12_000)
        guard case .image(let oldest) = items[0].payload, case .image(let newest) = items[7].payload else {
            return XCTFail("not pictures")
        }
        XCTAssertEqual(oldest.bytes.residentByteCount, 0, "the oldest gave up its memory")
        XCTAssertGreaterThan(newest.bytes.residentByteCount, 0, "the newest kept it")
        XCTAssertNotNil(oldest.pasteboardData, "and is read from its file")
    }

    /// With no file to fall back on a picture cannot be demoted, so the budget
    /// is kept by dropping the oldest entries instead.
    func testWithoutASpoolTheBudgetDropsTheOldestPictures() throws {
        store.imageSpool = nil
        store.imageResidentBudget = 12_000
        var made: [ClipItem] = []
        for index in 0..<8 {
            let image = try XCTUnwrap(ClipImage.make(data: png(40 + index, 30, noise: true), type: .png, sourceApp: nil))
            let item = ClipItem(payload: .image(image), date: Date())
            made.append(item)
            store.record(item)
        }
        XCTAssertLessThanOrEqual(store.residentPictureBytes, 12_000)
        XCTAssertLessThan(store.items.count, 8)
        XCTAssertTrue(store.items.contains { $0.id == made[7].id }, "the newest stays")
        XCTAssertFalse(store.items.contains { $0.id == made[0].id })
    }

    // MARK: Files go with their entries

    func testEvictedRemovedAndClearedPicturesDeleteTheirFiles() throws {
        var made: [ClipItem] = []
        for index in 0..<13 {
            let item = try entry(png(40 + index, 30))
            made.append(item)
            store.record(item)
        }
        XCTAssertEqual(store.items.count, 12, "the thirteenth dropped the oldest")
        XCTAssertEqual(filesOnDisk().count, 12, "and took its file")

        store.remove(try XCTUnwrap(store.items.first))
        XCTAssertEqual(filesOnDisk().count, 11, "Remove")

        let pinned = try XCTUnwrap(store.items.last)
        store.setPinned(pinned, true)
        store.clear()
        XCTAssertEqual(filesOnDisk().count, 1, "Clear History keeps the pin and its file")

        store.clearAll()
        XCTAssertEqual(filesOnDisk().count, 0, "history off clears everything")

        store.record(try entry(png(70, 30)))
        store.record(ClipItem(payload: .text("note"), date: Date()))
        store.removeImages()
        XCTAssertEqual(filesOnDisk().count, 0, "Include Images off")
        XCTAssertEqual(store.items.map(\.preview), ["note"])
    }

    func testTheSameBytesRecordedTwiceKeepTheirFile() throws {
        let item = try entry(png(), type: .png)
        store.record(item)
        store.record(item)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(filesOnDisk().count, 1, "replacing an entry by itself does not delete its file")
        guard case .image(let image) = item.payload else { return XCTFail("not a picture") }
        XCTAssertNotNil(image.pasteboardData)
    }

    func testAnEntryWhoseFileIsGoneLeavesThePasteboardAlone() throws {
        let item = try entry(try tiff(megabytes: 6, fill: 9), type: .tiff)
        store.record(item)
        board.clearContents()
        board.setString("kept", forType: .string)
        try FileManager.default.removeItem(at: spool.directory)
        store.copy(item)
        XCTAssertEqual(board.string(forType: .string), "kept")
    }

    // MARK: Stale directories

    func testStaleDirectoriesAreSweptAndLiveOnesAreNot() throws {
        let fm = FileManager.default
        func make(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("file"))
            return url
        }
        let dead = try make("isla-clipboard-111-AAAA")
        let alive = try make("isla-clipboard-222-BBBB")
        let legacy = try make("isla-clipboard-CCCC")
        let own = try make("isla-clipboard-333-DDDD")
        let unrelated = try make("something-else-111")

        let removed = ClipImageSpool.sweepStale(in: root, keeping: own, isAlive: { $0 == 222 || $0 == 333 })
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(fm.fileExists(atPath: dead.path), "its process is gone")
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "a name without a process id is stale")
        XCTAssertTrue(fm.fileExists(atPath: alive.path), "another running Isla's pictures are not ours to delete")
        XCTAssertTrue(fm.fileExists(atPath: own.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    func testQuitRemovesTheSessionDirectory() throws {
        store.record(try entry(png()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.directory.path))
        spool.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.directory.path))
    }

    // MARK: Equality

    /// `==` runs whenever SwiftUI diffs the list. It compared up to 25 MB of
    /// bytes; with the file deleted and nothing resident there are no bytes to
    /// compare at all, and it still answers.
    func testEqualityNeverTouchesTheBytes() throws {
        let data = try tiff(megabytes: 6, fill: 5)
        let first = try XCTUnwrap(ClipImage.make(data: data, type: .tiff, sourceApp: "A", spool: spool, residentLimit: 0))
        let again = try XCTUnwrap(ClipImage.make(data: data, type: .tiff, sourceApp: "B", spool: spool, residentLimit: 0))
        let other = try XCTUnwrap(ClipImage.make(data: try tiff(megabytes: 6, fill: 6), type: .tiff, sourceApp: "A", spool: spool, residentLimit: 0))
        first.bytes.discard()
        again.bytes.discard()
        other.bytes.discard()
        XCTAssertEqual(first.data.count, 0, "the bytes are unreachable")
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
    }

    // MARK: Copying the same picture twice

    func testAnIdenticalConsecutivePictureIsNotAddedOrSavedTwice() throws {
        var delivered: [Data] = []
        store.onImage = { delivered.append($0) }
        store.wantsImages = { true }
        let data = png(200, 150, noise: true)

        board.clearContents()
        board.setData(data, forType: .png)
        store.pollNow()
        settle { !delivered.isEmpty && !self.store.items.isEmpty }
        XCTAssertEqual(delivered, [data])
        XCTAssertEqual(store.items.count, 1)
        let firstID = store.items[0].id

        store.record(ClipItem(payload: .text("between"), date: Date()))
        board.clearContents()
        board.setData(data, forType: .png)
        store.pollNow()
        settle(until: { false }, timeout: 0.6)
        XCTAssertEqual(delivered.count, 1, "the vault was not handed the same bytes again")
        XCTAssertEqual(store.items.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(store.items.first?.id, firstID, "the entry already there came back to the top")
        XCTAssertEqual(filesOnDisk().count, 1, "and no second file was written")

        board.clearContents()
        board.setData(png(201, 150, noise: true), forType: .png)
        store.pollNow()
        settle { delivered.count == 2 }
        XCTAssertEqual(delivered.count, 2, "a different picture is saved")
    }

    // MARK: Paste-back through the pipeline

    func testALargeCopiedPictureIsFileBackedAndPastesBackAsTheOriginal() throws {
        let original = try tiff(megabytes: 20, fill: 42)
        board.clearContents()
        board.setData(original, forType: .tiff)
        store.pollNow()
        settle { !self.store.items.isEmpty }

        let item = try XCTUnwrap(store.items.first)
        guard case .image(let image) = item.payload else { return XCTFail("not a picture entry") }
        XCTAssertEqual(image.type, .tiff)
        XCTAssertEqual(image.bytes.residentByteCount, 0, "nothing of it stays in memory")
        XCTAssertEqual(store.residentPictureBytes, 0)
        XCTAssertNotNil(image.bytes.fileURL)
        XCTAssertEqual(filesOnDisk().count, 1)

        board.clearContents()
        store.copy(item)
        XCTAssertEqual(board.data(forType: .tiff), original, "the original bytes and type go back")
    }
}
