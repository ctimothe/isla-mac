import AppKit
import XCTest
@testable import IslaKit

/// Pins (redesign spec §9.2, §9.4): they sort first, do not count against the
/// 40-entry cap, survive Clear History, and — only with Keep Pinned Items on —
/// are saved to one 0600 file that a test injects and the real Application
/// Support never sees.
@MainActor
final class ClipboardPinsTests: XCTestCase {
    private var board: NSPasteboard!
    private var store: ClipboardStore!
    private var folder: URL!

    override func setUp() async throws {
        board = NSPasteboard(name: .init("ClipboardPinsTests.\(UUID())"))
        store = ClipboardStore(pasteboard: board)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-pins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private func text(_ string: String, minutesAgo: Double = 0) -> ClipItem {
        ClipItem(payload: .text(string), date: Date(timeIntervalSince1970: 1_792_065_600 - minutesAgo * 60))
    }

    /// A file URL as a Keep Pinned file would hold it.
    private var pinFile: PinnedClipboardFile {
        PinnedClipboardFile(url: folder.appendingPathComponent("Isla/pinned-clipboard.plist"))
    }

    private func attach(on: Bool = true) {
        store.pinnedFile = pinFile
        store.keepsPinned = { on }
    }

    // MARK: Order and caps

    func testPinnedRowsSortFirstEachGroupNewestFirst() {
        for name in ["a", "b", "c", "d"] { store.record(text(name)) }
        // items, newest first: d c b a
        store.setPinned(store.items[3], true)   // a
        store.setPinned(store.items[1], true)   // c
        XCTAssertEqual(store.listed.map(\.preview), ["c", "a", "d", "b"])
        XCTAssertEqual(store.items.map(\.preview), ["d", "c", "b", "a"], "storage order is when it was last used")
    }

    func testPinsDoNotCountAgainstTheFortyEntryCap() {
        for index in 0..<3 { store.record(text("pin-\(index)")) }
        for item in store.items { store.setPinned(item, true) }
        for index in 0..<45 { store.record(text("entry-\(index)")) }
        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 40)
        XCTAssertEqual(store.items.filter(\.isPinned).count, 3, "no pin was trimmed to make room")
        XCTAssertEqual(store.items.count, 43)
        XCTAssertEqual(store.listed.prefix(3).map(\.isPinned), [true, true, true])
        XCTAssertEqual(store.items.first?.preview, "entry-44")
        XCTAssertFalse(store.items.contains { $0.preview == "entry-4" }, "the oldest unpinned went")
    }

    func testCopyingAPinnedNoteAgainKeepsItPinned() {
        store.record(text("keep"))
        store.setPinned(store.items[0], true)
        store.record(text("other"))
        store.record(text("keep"))
        XCTAssertEqual(store.items.filter { $0.preview == "keep" }.count, 1, "one entry")
        XCTAssertTrue(store.items.first { $0.preview == "keep" }?.isPinned == true)
    }

    func testUnpinReturnsAnEntryToTheOrdinaryList() {
        store.record(text("a"))
        store.record(text("b"))
        // items, newest first: b a. Pinning the older one lifts it over the newer.
        store.togglePin(store.items.first { $0.preview == "a" }!)
        XCTAssertEqual(store.listed.map(\.preview), ["a", "b"])
        store.togglePin(store.items.first { $0.preview == "a" }!)
        XCTAssertEqual(store.listed.map(\.preview), ["b", "a"], "unpinned, it is where it was used")
    }

    // MARK: Clear

    func testClearHistoryKeepsThePins() {
        for name in ["a", "b", "c"] { store.record(text(name)) }
        store.setPinned(store.items.first { $0.preview == "b" }!, true)
        store.clear()
        XCTAssertEqual(store.items.map(\.preview), ["b"], "pins survive a clear")
        store.clearAll()
        XCTAssertTrue(store.items.isEmpty, "history switched off keeps nothing")
    }

    func testAPinnedEntryIsRemovedByRemovingIt() {
        store.record(text("a"))
        store.setPinned(store.items[0], true)
        store.remove(store.items[0])
        XCTAssertTrue(store.items.isEmpty)
    }

    func testTheClearQuestionNamesWhatWillGoAndEscapeAnswersIt() {
        let ask = ClipboardClearConfirmation()
        var cleared = 0
        ask.confirm { cleared += 1 }
        XCTAssertEqual(cleared, 0, "nothing was asked, so nothing is confirmed")
        ask.ask(count: 0)
        XCTAssertFalse(ask.isAsking, "nothing to clear, nothing to ask")
        ask.ask(count: 13)
        XCTAssertTrue(ask.isAsking)
        XCTAssertEqual(ask.count, 13)
        // Escape is how macOS says no, and it is answered before the panel folds.
        XCTAssertTrue(ArmedConfirmations.shared.disarmAll())
        XCTAssertFalse(ask.isAsking)
        ask.ask(count: 2)
        ask.cancel()
        XCTAssertFalse(ask.isAsking)
        XCTAssertFalse(ArmedConfirmations.shared.disarmAll(), "cancelling withdrew its claim on Escape")
        ask.ask(count: 2)
        ask.confirm { cleared += 1 }
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(ask.isAsking)
        ask.confirm { cleared += 1 }
        XCTAssertEqual(cleared, 1, "a second yes is nothing")
    }

    // MARK: Keep Pinned Items

    func testNothingIsWrittenWhileTheSwitchIsOff() {
        attach(on: false)
        store.record(text("secret"))
        store.setPinned(store.items[0], true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinFile.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinFile.url.deletingLastPathComponent().path))
    }

    func testPinsRoundTripThroughTheFile() throws {
        attach()
        store.record(text("a note", minutesAgo: 5))
        store.record(text("https://example.com/x", minutesAgo: 3))
        let file = ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/Q3 Report.pdf")), date: Date(timeIntervalSince1970: 1_792_000_000))
        store.record(file)
        let several = ClipItem(
            payload: .files([URL(fileURLWithPath: "/tmp/a.key"), URL(fileURLWithPath: "/tmp/b.key")]),
            date: Date(timeIntervalSince1970: 1_792_000_100)
        )
        store.record(several)
        store.record(text("not pinned"))
        for item in store.items where item.preview != "not pinned" { store.setPinned(item, true) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: pinFile.url.path))

        let fresh = ClipboardStore(pasteboard: NSPasteboard(name: .init("ClipboardPinsTests.fresh.\(UUID())")))
        fresh.pinnedFile = pinFile
        fresh.keepsPinned = { true }
        fresh.pinnedFileExists = { _ in true }  // the fixtures' /tmp files are not real
        fresh.loadPinned()
        XCTAssertEqual(fresh.items.count, 4, "only the pins came back")
        XCTAssertTrue(fresh.items.allSatisfy(\.isPinned))
        XCTAssertEqual(Set(fresh.items.map(\.payload.debugKey)), Set(store.items.filter(\.isPinned).map(\.payload.debugKey)))
        XCTAssertEqual(fresh.items.first { $0.preview == "a note" }?.date, Date(timeIntervalSince1970: 1_792_065_600 - 300))
        // A restored link is still a link: the kind is decided again from the text.
        XCTAssertEqual(fresh.items.first { $0.preview.hasPrefix("https://") }?.kind, .link)
        XCTAssertEqual(fresh.items.first { $0.preview == "a.key + 1" }?.kind, .files)
    }

    func testTheFileIsReadableByTheUserAloneInAPrivateFolder() throws {
        attach()
        store.record(text("private"))
        store.setPinned(store.items[0], true)
        let mode = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: pinFile.url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let directory = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: pinFile.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directory.intValue & 0o777, 0o700)
        // A rewrite keeps the mode: the temporary is made 0600 and renamed over.
        store.record(text("another"))
        store.setPinned(store.items[0], true)
        let after = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: pinFile.url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(after.intValue & 0o777, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: pinFile.url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["pinned-clipboard.plist"], "no temporary file is left behind")
    }

    func testUnpinningRewritesTheFileAndTheLastOneRemovesIt() throws {
        attach()
        store.record(text("a"))
        store.record(text("b"))
        for item in store.items { store.setPinned(item, true) }
        XCTAssertEqual(pinFile.load().count, 2)
        store.togglePin(store.items.first { $0.preview == "a" }!)
        XCTAssertEqual(pinFile.load().map(\.payload), [.text("b")])
        store.togglePin(store.items.first { $0.preview == "b" }!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinFile.url.path), "no pins, no file")
    }

    func testTurningTheSwitchOffDeletesTheFileAndOnWritesWhatIsPinned() {
        var on = true
        store.pinnedFile = pinFile
        store.keepsPinned = { on }
        store.record(text("kept"))
        store.setPinned(store.items[0], true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinFile.url.path))

        on = false
        store.keepPinnedChanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinFile.url.path), "off deletes the file")
        // And stays off: a later pin writes nothing.
        store.record(text("later"))
        store.setPinned(store.items[0], true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinFile.url.path))

        on = true
        store.keepPinnedChanged()
        XCTAssertEqual(Set(pinFile.load().map(\.payload.debugKey)), ["text:kept", "text:later"], "on saves the pins held now")
    }

    func testImagesAreNeverWritten() throws {
        attach()
        let image = try XCTUnwrap(ClipImage.make(data: Self.png(width: 40, height: 30), type: .png, sourceApp: nil))
        store.record(ClipItem(payload: .image(image), date: Date()))
        store.setPinned(store.items[0], true)
        XCTAssertTrue(store.items[0].isPinned, "a picture can be pinned for the session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinFile.url.path), "and is not saved")

        store.record(text("a note"))
        store.setPinned(store.items[0], true)
        let saved = pinFile.load()
        XCTAssertEqual(saved.map(\.payload), [.text("a note")])
        let raw = try String(contentsOf: pinFile.url, encoding: .utf8)
        XCTAssertFalse(raw.contains("image"), "nothing of the picture is in the file")
    }

    func testAFileThatIsNotPinsIsIgnoredWithoutCrashing() throws {
        attach()
        try FileManager.default.createDirectory(at: pinFile.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hostile: [Data] = [
            Data(), Data("not a plist".utf8), Data([0, 1, 2, 3, 255, 254]),
            try PropertyListSerialization.data(fromPropertyList: ["version": 99, "items": []], format: .xml, options: 0),
            try PropertyListSerialization.data(fromPropertyList: ["version": 1], format: .xml, options: 0),
            try PropertyListSerialization.data(fromPropertyList: ["version": 1, "items": "nope"], format: .xml, options: 0),
            try PropertyListSerialization.data(fromPropertyList: ["version": 1, "items": [["kind": "text"], ["kind": "bogus", "date": Date()], ["kind": "file", "path": "relative", "date": Date()]]] as [String: Any], format: .xml, options: 0),
            try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .xml, options: 0),
        ]
        for data in hostile {
            try data.write(to: pinFile.url)
            let fresh = ClipboardStore(pasteboard: NSPasteboard(name: .init("ClipboardPinsTests.bad.\(UUID())")))
            fresh.pinnedFile = pinFile
            fresh.keepsPinned = { true }
            fresh.loadPinned()
            XCTAssertTrue(fresh.items.isEmpty, "\(data.count) bytes")
            // And the next pin replaces the damaged file with a good one.
            fresh.record(text("fresh"))
            fresh.setPinned(fresh.items[0], true)
            XCTAssertEqual(pinFile.load().map(\.payload), [.text("fresh")])
        }
    }

    func testAnUnreadableFileIsIgnored() throws {
        attach()
        store.record(text("a"))
        store.setPinned(store.items[0], true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: pinFile.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pinFile.url.path) }
        let fresh = ClipboardStore(pasteboard: NSPasteboard(name: .init("ClipboardPinsTests.locked.\(UUID())")))
        fresh.pinnedFile = pinFile
        fresh.keepsPinned = { true }
        fresh.loadPinned()
        XCTAssertTrue(fresh.items.isEmpty)
    }

    func testALeftoverFileIsRemovedAtLaunchWhenTheSwitchIsOff() throws {
        attach()
        store.record(text("a"))
        store.setPinned(store.items[0], true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinFile.url.path))
        let fresh = ClipboardStore(pasteboard: NSPasteboard(name: .init("ClipboardPinsTests.off.\(UUID())")))
        fresh.pinnedFile = pinFile
        fresh.keepsPinned = { false }
        fresh.loadPinned()
        XCTAssertTrue(fresh.items.isEmpty, "off means the pins are not restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinFile.url.path))
    }

    func testTheStoreNeverReachesTheRealApplicationSupportUnlessWired() {
        let bare = ClipboardStore(pasteboard: NSPasteboard(name: .init("ClipboardPinsTests.bare.\(UUID())")))
        XCTAssertNil(bare.pinnedFile)
        XCTAssertFalse(bare.keepsPinned())
        XCTAssertFalse(bare.keepsImages())
        bare.loadPinned()
        bare.keepPinnedChanged()
        // And the app's default is the spec's: off.
        XCTAssertEqual(NotchViewModel.clipboardKeepPinnedKey, "clipboard.keepPinned")
        XCTAssertEqual(NotchViewModel.clipboardIncludeImagesKey, "clipboard.includeImages")
    }

    func testTheFileHoldsWhatItSaysAndNothingElse() throws {
        let records = [
            PinnedClipboardFile.Record(payload: .text("hello"), date: Date(timeIntervalSince1970: 100)),
            PinnedClipboardFile.Record(payload: .file(URL(fileURLWithPath: "/tmp/a b.txt")), date: Date(timeIntervalSince1970: 200)),
        ]
        try pinFile.save(records)
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: pinFile.url), options: [], format: nil)
        let root = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["version", "items"])
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(pinFile.load(exists: { _ in true }), records)
    }

    // MARK: Pinned files come back only if local and present (review 2026-10-15)

    /// `ClipItem.init` reads a file's size on the main thread at launch, and a
    /// stale network mount can hang that read. Load keeps a file pin only if its
    /// path is local and there; a path under /Volumes or /Network is dropped
    /// without the filesystem being asked about it.
    func testLoadDropsFilePinsThatAreMissingOrOnAMountWithoutTouchingThem() throws {
        let present = folder.appendingPathComponent("here.txt")
        try Data("x".utf8).write(to: present)
        let missing = folder.appendingPathComponent("gone.txt")
        let mounted = URL(fileURLWithPath: "/Volumes/Backup/report.pdf")
        let network = URL(fileURLWithPath: "/Network/Servers/share/a.txt")
        let date = Date(timeIntervalSince1970: 100)
        try pinFile.save([
            .init(payload: .text("a note"), date: date),
            .init(payload: .file(present), date: date),
            .init(payload: .file(missing), date: date),
            .init(payload: .file(mounted), date: date),
            .init(payload: .file(network), date: date),
        ])

        var asked: [String] = []
        let loaded = pinFile.load(exists: { path in
            asked.append(path)
            return FileManager.default.fileExists(atPath: path)
        })
        XCTAssertEqual(loaded.map(\.payload), [.text("a note"), .file(present)], "text, and the one file that is there")
        XCTAssertEqual(Set(asked), [present.path, missing.path], "a mount's path is never asked about")
        XCTAssertFalse(asked.contains { $0.hasPrefix("/Volumes/") || $0.hasPrefix("/Network/") })
    }

    func testAStackKeepsTheFilesThatQualifyAndCollapsesToOneOrNone() throws {
        let one = folder.appendingPathComponent("one.key")
        let two = folder.appendingPathComponent("two.key")
        let three = folder.appendingPathComponent("three.key")
        for url in [one, two, three] { try Data("x".utf8).write(to: url) }
        let mounted = URL(fileURLWithPath: "/Volumes/Backup/a.key")
        let date = Date(timeIntervalSince1970: 100)
        try pinFile.save([
            .init(payload: .files([one, two, mounted]), date: date),
            .init(payload: .files([three, mounted]), date: date),
            .init(payload: .files([mounted, URL(fileURLWithPath: "/Volumes/Backup/b.key")]), date: date),
        ])
        let loaded = pinFile.load(exists: { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(loaded.map(\.payload), [.files([one, two]), .file(three)], "a stack with nothing local left is gone")
    }

    /// Through the store: a missing pin does not come back as a row.
    func testTheStoreDoesNotRestoreAMissingFilePin() throws {
        let present = folder.appendingPathComponent("here.txt")
        try Data("x".utf8).write(to: present)
        try pinFile.save([
            .init(payload: .file(present), date: Date(timeIntervalSince1970: 100)),
            .init(payload: .file(folder.appendingPathComponent("gone.txt")), date: Date(timeIntervalSince1970: 90)),
        ])
        let freshBoard = NSPasteboard(name: .init("ClipboardPinsTests.drop.\(UUID())"))
        defer { freshBoard.releaseGlobally() }
        let fresh = ClipboardStore(pasteboard: freshBoard)
        fresh.pinnedFile = pinFile
        fresh.keepsPinned = { true }
        fresh.loadPinned()
        XCTAssertEqual(fresh.items.map(\.preview), ["here.txt"])
    }

    // MARK: Fixtures

    static func png(width: Int, height: Int, noise: Bool = false) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        if let data = rep.bitmapData {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for index in 0..<(rep.bytesPerRow * height) {
                if noise {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    data[index] = UInt8(truncatingIfNeeded: seed >> 33)
                } else {
                    data[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: index % 251)
                }
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }
}

private extension ClipItem.Payload {
    /// A comparable stand-in for a payload, for a set.
    var debugKey: String {
        switch self {
        case .text(let string): return "text:\(string)"
        case .file(let url): return "file:\(url.path)"
        case .files(let urls): return "files:\(urls.map(\.path).joined(separator: ","))"
        case .image: return "image"
        }
    }
}
