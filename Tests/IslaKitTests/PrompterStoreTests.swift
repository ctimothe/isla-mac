import Foundation
import XCTest
@testable import IslaKit

// MARK: - Fakes
//
// Nothing here touches Application Support, a real timer or UserDefaults. The
// three tests at the bottom that exercise `FilePrompterFileIO` do so against a
// directory they create under $TMPDIR and remove again.

/// An in-memory stand-in for the library file. A failed write leaves `data`
/// exactly as it was, which is the contract the real atomic write is tested
/// for separately below.
private final class FakeFileIO: PrompterFileIO {
    var data: Data?
    var readError: Error?
    var writeError: Error?
    var copyError: Error?
    private(set) var writes: [Data] = []
    private(set) var reads = 0
    private(set) var existsCalls = 0
    private(set) var copies: [(name: String, data: Data)] = []

    init(data: Data? = nil) { self.data = data }

    func exists() -> Bool {
        existsCalls += 1
        return data != nil
    }

    func read() throws -> Data {
        reads += 1
        if let readError { throw readError }
        guard let data else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    func writeAtomically(_ newData: Data) throws {
        if let writeError { throw writeError }
        data = newData
        writes.append(newData)
    }

    func copyAside(as name: String) throws -> String {
        if let copyError { throw copyError }
        guard let data else { throw CocoaError(.fileReadNoSuchFile) }
        copies.append((name, data))
        return name
    }

    var touched: Bool { reads + existsCalls + writes.count + copies.count > 0 }
}

/// Fires only when the test advances time.
@MainActor
private final class StoreScheduler: PrompterScheduling {
    final class Entry: PrompterCancellable {
        var isCancelled = false
        let due: TimeInterval
        let action: @MainActor () -> Void
        init(due: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.action = action
        }
        func cancel() { isCancelled = true }
    }

    var now: TimeInterval = 0
    private(set) var scheduled = 0
    private var entries: [Entry] = []

    func every(_ interval: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable {
        XCTFail("the library never asks for a repeating timer")
        return Entry(due: now + interval, action: action)
    }

    func after(_ delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable {
        scheduled += 1
        let entry = Entry(due: now + delay, action: action)
        entries.append(entry)
        return entry
    }

    var live: Int { entries.filter { !$0.isCancelled }.count }

    func advance(by dt: TimeInterval) {
        now += dt
        for entry in entries where !entry.isCancelled && entry.due <= now {
            entry.isCancelled = true
            entry.action()
        }
    }
}

private struct Boom: Error {}

// MARK: - Fixtures

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private let scriptID = "11111111-2222-3333-4444-555555555555"

private func version1File(scripts: [[String: Any]]? = nil, current: String? = scriptID) -> Data {
    let scripts = scripts ?? [[
        "id": scriptID, "title": "Launch talk",
        "updatedAt": "2027-01-15T08:00:00Z", "pages": ["Hello [smile] world", "Second page"],
    ]]
    var object: [String: Any] = ["version": 1, "scripts": scripts]
    if let current { object["currentScriptID"] = current }
    return json(object)
}

@MainActor
final class PrompterStoreTests: XCTestCase {
    private var io = FakeFileIO()
    private var scheduler = StoreScheduler()
    private var library: PrompterLibrary!

    override func setUp() {
        super.setUp()
        io = FakeFileIO()
        scheduler = StoreScheduler()
        library = makeLibrary()
    }

    private func makeLibrary() -> PrompterLibrary {
        PrompterLibrary(io: io, scheduler: scheduler, now: { fixedNow })
    }

    private func lastWritten() throws -> [String: Any] {
        let data = try XCTUnwrap(io.writes.last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Absence

    func testConstructingTheLibraryPerformsNoIO() {
        _ = makeLibrary()
        XCTAssertFalse(io.touched, "the file is not read, created or touched until something asks")
        XCTAssertEqual(library.status, .notLoaded)
        XCTAssertTrue(library.scripts.isEmpty)
        XCTAssertEqual(scheduler.scheduled, 0)
    }

    func testFlushAndQuitBeforeLoadWriteNothing() {
        library.flush()
        XCTAssertFalse(io.touched, "quitting with the switch off must not create the file")
    }

    func testMutatingBeforeLoadIsRefusedAndTouchesNothing() {
        XCTAssertThrowsError(try library.addScript(title: "x")) {
            XCTAssertEqual($0 as? PrompterLibraryError, .notLoaded)
        }
        XCTAssertFalse(io.touched)
    }

    // MARK: Loading

    func testMissingFileLoadsEmptyAndWritableWithoutWriting() {
        library.load()
        XCTAssertEqual(library.status, .ready)
        XCTAssertTrue(library.isFirstRun, "the tab seeds its sample script only when the file never existed")
        XCTAssertTrue(library.scripts.isEmpty)
        XCTAssertTrue(io.writes.isEmpty, "E-53: created on first write, not on load")
        XCTAssertTrue(library.canWrite)
    }

    func testEmptiedLibraryIsNotFirstRun() throws {
        io.data = version1File(scripts: [], current: nil)
        library.load()
        XCTAssertFalse(library.isFirstRun, "an emptied library is not re-seeded")
    }

    func testLoadIsIdempotent() throws {
        io.data = version1File()
        library.load()
        let reads = io.reads
        library.load()
        XCTAssertEqual(io.reads, reads)
    }

    func testVersion1FileDecodes() throws {
        io.data = version1File()
        library.load()
        XCTAssertEqual(library.status, .ready)
        let script = try XCTUnwrap(library.scripts.first)
        XCTAssertEqual(script.id, UUID(uuidString: scriptID))
        XCTAssertEqual(script.title, "Launch talk")
        XCTAssertEqual(script.pages, ["Hello [smile] world", "Second page"])
        XCTAssertEqual(script.updatedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(library.currentScriptID, UUID(uuidString: scriptID))
        XCTAssertTrue(io.writes.isEmpty, "loading never rewrites")
    }

    func testCurrentScriptIDThatPointsNowhereLoadsAsNil() {
        io.data = version1File(current: "99999999-2222-3333-4444-555555555555")
        library.load()
        XCTAssertNil(library.currentScriptID)
    }

    // MARK: Schema and round trip

    func testWrittenFileMatchesTheVersion1Schema() throws {
        library.load()
        let id = try library.addScript(title: "Talk", pages: ["a", "b"])
        library.setCurrentScript(id)
        library.flush()
        let object = try lastWritten()
        XCTAssertEqual(Set(object.keys), ["version", "currentScriptID", "scripts"])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["currentScriptID"] as? String, id.uuidString)
        let scripts = try XCTUnwrap(object["scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(Set(scripts[0].keys), ["id", "title", "updatedAt", "pages"])
        XCTAssertEqual(scripts[0]["id"] as? String, id.uuidString)
        XCTAssertEqual(scripts[0]["title"] as? String, "Talk")
        XCTAssertEqual(scripts[0]["updatedAt"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(scripts[0]["pages"] as? [String], ["a", "b"])
    }

    func testRoundTripPreservesEverythingIncludingUnicodeAndCues() throws {
        library.load()
        let id = try library.addScript(title: "Привет 👩‍👩‍👧 [] [smile]", pages: ["Привет [pause] мир", "", "👩‍👩‍👧 \u{202E}x"])
        library.setCurrentScript(id)
        library.flush()
        let reopened = PrompterLibrary(io: io, scheduler: StoreScheduler(), now: { fixedNow })
        reopened.load()
        XCTAssertEqual(reopened.status, .ready)
        XCTAssertEqual(reopened.scripts, library.scripts)
        XCTAssertEqual(reopened.currentScriptID, id)
    }

    // MARK: Debounce

    func testManyMutationsInTheWindowMakeOneWrite() throws {
        library.load()
        let id = try library.addScript(title: "Talk")
        for index in 0..<50 {
            try library.setPage(scriptID: id, index: 0, text: "draft \(index)")
            scheduler.advance(by: 0.1)
        }
        XCTAssertTrue(io.writes.isEmpty, "each edit restarts the 0.5 s window")
        scheduler.advance(by: 0.5)
        XCTAssertEqual(io.writes.count, 1)
        XCTAssertEqual(scheduler.live, 0)
        let pages = ((try lastWritten()["scripts"] as? [[String: Any]])?.first?["pages"]) as? [String]
        XCTAssertEqual(pages, ["draft 49"])
    }

    func testTheWriteLandsHalfASecondAfterTheLastEditNotBefore() throws {
        library.load()
        _ = try library.addScript(title: "Talk")
        scheduler.advance(by: 0.49)
        XCTAssertTrue(io.writes.isEmpty)
        scheduler.advance(by: 0.02)
        XCTAssertEqual(io.writes.count, 1)
    }

    func testExplicitFlushWritesImmediatelyAndCancelsTheTimer() throws {
        library.load()
        _ = try library.addScript(title: "Talk")
        library.flush()
        XCTAssertEqual(io.writes.count, 1)
        XCTAssertEqual(scheduler.live, 0)
        scheduler.advance(by: 5)
        XCTAssertEqual(io.writes.count, 1, "the cancelled timer does not write a second time")
    }

    func testFlushWithNothingPendingWritesNothing() throws {
        io.data = version1File()
        library.load()
        library.flush()
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testQuitPathFlushPersistsAPendingEdit() throws {
        library.load()
        let id = try library.addScript(title: "Talk")
        try library.setPage(scriptID: id, index: 0, text: "typed a moment before quit")
        library.flush() // what applicationWillTerminate and session start call
        let reopened = PrompterLibrary(io: io, scheduler: StoreScheduler(), now: { fixedNow })
        reopened.load()
        XCTAssertEqual(reopened.scripts.first?.pages, ["typed a moment before quit"])
    }

    func testDebouncedWriterAloneCoalescesFlushesAndCancels() {
        let scheduler = StoreScheduler()
        var runs = 0
        let writer = DebouncedWriter(delay: 0.5, scheduler: scheduler) { runs += 1 }
        writer.schedule()
        writer.schedule()
        XCTAssertTrue(writer.isPending)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(writer.isPending)
        writer.schedule()
        writer.flush()
        XCTAssertEqual(runs, 2)
        writer.flush()
        XCTAssertEqual(runs, 2, "a flush with nothing pending does nothing")
        writer.schedule()
        writer.cancel()
        scheduler.advance(by: 5)
        XCTAssertEqual(runs, 2)
    }

    // MARK: Higher version

    func testHigherVersionOpensReadOnlyAndIsNeverRewritten() throws {
        let original = json(["version": 2, "scripts": [["shape": "unknown"]], "future": true])
        io.data = original
        library.load()
        XCTAssertEqual(library.status, .newerVersion(2))
        XCTAssertFalse(library.canWrite)
        XCTAssertThrowsError(try library.addScript(title: "x")) {
            XCTAssertEqual($0 as? PrompterLibraryError, .readOnly)
        }
        library.flush()
        scheduler.advance(by: 10)
        XCTAssertTrue(io.writes.isEmpty)
        XCTAssertEqual(io.data, original)
        XCTAssertTrue(io.copies.isEmpty, "a valid newer file is not corrupt; no copy is made")
        XCTAssertThrowsError(try library.startFreshLibrary(), "a newer file is never replaced from inside this version") {
            XCTAssertEqual($0 as? PrompterLibraryError, .readOnly)
        }
        XCTAssertEqual(io.data, original)
    }

    // MARK: Unreadable / undecodable

    private func assertUnreadableIsPreserved(_ bytes: Data?, readError: Error? = nil, file: StaticString = #filePath, line: UInt = #line) {
        io.data = bytes
        io.readError = readError
        library.load()
        guard case .unreadable = library.status else {
            return XCTFail("expected unreadable, got \(library.status)", file: file, line: line)
        }
        XCTAssertFalse(library.canWrite, file: file, line: line)
        XCTAssertThrowsError(try library.addScript(title: "x"), file: file, line: line) {
            XCTAssertEqual($0 as? PrompterLibraryError, .writingDisabled, file: file, line: line)
        }
        library.flush()
        scheduler.advance(by: 10)
        XCTAssertTrue(io.writes.isEmpty, "never overwritten", file: file, line: line)
        XCTAssertEqual(io.data, bytes, file: file, line: line)
    }

    func testGarbageIsCopiedAsideAndNeverOverwritten() throws {
        let garbage = Data("this is not json {{{".utf8)
        assertUnreadableIsPreserved(garbage)
        let copy = try XCTUnwrap(io.copies.first)
        XCTAssertEqual(copy.name, "library.corrupt-20270115T080000Z.json")
        XCTAssertEqual(copy.data, garbage)
        XCTAssertEqual(library.status, .unreadable(corruptCopy: "library.corrupt-20270115T080000Z.json"))
    }

    func testEveryUndecodableShapeIsTreatedAsUnreadable() {
        let shapes: [Data] = [
            Data(),                                                   // a zero-byte file
            Data([0xFF, 0xFE, 0x00, 0xD8]),                           // not UTF-8
            json(["scripts": []]),                                    // no version
            json(["version": "1", "scripts": []]),                    // wrong type
            json(["version": 0, "scripts": []]),                      // below 1
            json(["version": 1]),                                     // no scripts
            json(["version": 1, "scripts": [["id": "not-a-uuid", "title": "t", "updatedAt": "2027-01-15T08:00:00Z", "pages": []]]]),
            json(["version": 1, "scripts": [["id": scriptID, "title": 5, "updatedAt": "2027-01-15T08:00:00Z", "pages": []]]]),
            Data("[1,2,3]".utf8),
        ]
        for shape in shapes {
            let local = FakeFileIO(data: shape)
            let lib = PrompterLibrary(io: local, scheduler: StoreScheduler(), now: { fixedNow })
            lib.load()
            guard case .unreadable = lib.status else {
                XCTFail("expected unreadable for \(String(decoding: shape, as: UTF8.self))")
                continue
            }
            XCTAssertTrue(local.writes.isEmpty)
            XCTAssertEqual(local.copies.count, 1)
            XCTAssertEqual(local.data, shape)
        }
    }

    func testAFileThatCannotBeReadIsUnreadableNotMissing() {
        assertUnreadableIsPreserved(Data("{}".utf8), readError: CocoaError(.fileReadNoPermission))
        XCTAssertFalse(library.isFirstRun)
    }

    func testFailedCopyAsideStillDisablesWriting() {
        io.copyError = Boom()
        assertUnreadableIsPreserved(Data("garbage".utf8))
        XCTAssertEqual(library.status, .unreadable(corruptCopy: nil))
    }

    func testStartingAFreshLibraryReplacesTheBrokenFileOnlyAfterTheCopyExists() throws {
        let garbage = Data("garbage".utf8)
        io.data = garbage
        library.load()
        XCTAssertEqual(io.copies.count, 1)
        try library.startFreshLibrary()
        XCTAssertEqual(library.status, .ready)
        XCTAssertTrue(library.canWrite)
        XCTAssertEqual(io.writes.count, 1, "the fresh library is written at once so the next launch reads it")
        XCTAssertEqual(io.copies.first?.data, garbage)
        let id = try library.addScript(title: "New")
        library.flush()
        let reopened = PrompterLibrary(io: io, scheduler: StoreScheduler(), now: { fixedNow })
        reopened.load()
        XCTAssertEqual(reopened.scripts.map(\.id), [id])
    }

    func testStartingFreshWhenNothingIsBrokenIsRefused() {
        library.load()
        XCTAssertThrowsError(try library.startFreshLibrary())
        XCTAssertTrue(io.writes.isEmpty)
    }

    // MARK: Read-only destination

    func testWriteFailureKeepsEditsAndSurfacesOnceWithoutCrashing() throws {
        io.writeError = CocoaError(.fileWriteNoPermission)
        library.load()
        let id = try library.addScript(title: "Talk")
        scheduler.advance(by: 0.5)
        XCTAssertEqual(library.writeFailure, .writeFailed)
        XCTAssertEqual(library.scripts.map(\.id), [id], "E-55: in-memory edits are kept")
        XCTAssertEqual(library.status, .ready)
        XCTAssertNil(io.data)
        try library.setPage(scriptID: id, index: 0, text: "still typing")
        scheduler.advance(by: 0.5)
        XCTAssertEqual(library.writeFailure, .writeFailed)
    }

    func testWritingResumesAndTheFailureClearsOnceTheDestinationRecovers() throws {
        io.writeError = Boom()
        library.load()
        let id = try library.addScript(title: "Talk")
        library.flush()
        XCTAssertEqual(library.writeFailure, .writeFailed)
        io.writeError = nil
        try library.setPage(scriptID: id, index: 0, text: "later")
        library.flush()
        XCTAssertNil(library.writeFailure)
        XCTAssertEqual(io.writes.count, 1)
    }

    func testAFailedWriteIsRetriedByTheNextFlushEvenWithoutANewEdit() throws {
        io.writeError = Boom()
        library.load()
        _ = try library.addScript(title: "Talk")
        library.flush()
        io.writeError = nil
        library.flush() // quit
        XCTAssertEqual(io.writes.count, 1, "unsaved edits are not forgotten after one failure")
    }

    // MARK: Limits

    func testPageLimitIs200AndRefusesTheNext() throws {
        library.load()
        let id = try library.addScript(title: "Long", pages: Array(repeating: "", count: 200))
        XCTAssertThrowsError(try library.addPage(scriptID: id)) {
            XCTAssertEqual($0 as? PrompterLibraryError, .tooManyPages(limit: 200))
        }
        XCTAssertEqual(library.script(id)?.pages.count, 200, "nothing truncated")
        XCTAssertThrowsError(try library.addScript(title: "x", pages: Array(repeating: "", count: 201))) {
            XCTAssertEqual($0 as? PrompterLibraryError, .tooManyPages(limit: 200))
        }
        XCTAssertNoThrow(try library.duplicateScript(id, title: "copy"), "a duplicate of a 200-page script is also 200 pages")
    }

    func testCharacterLimitIs1000000PerScriptAcrossPages() throws {
        library.load()
        let id = try library.addScript(title: "Big", pages: [String(repeating: "a", count: 999_990), ""])
        try library.setPage(scriptID: id, index: 1, text: String(repeating: "b", count: 10))
        XCTAssertEqual(library.script(id)?.pages[1].count, 10, "exactly at the limit is allowed")
        XCTAssertThrowsError(try library.setPage(scriptID: id, index: 1, text: String(repeating: "b", count: 11))) {
            XCTAssertEqual($0 as? PrompterLibraryError, .scriptTooLong(limit: 1_000_000))
        }
        XCTAssertEqual(library.script(id)?.pages[1].count, 10, "the refused edit changed nothing")
        XCTAssertThrowsError(try library.addScript(title: "x", pages: [String(repeating: "a", count: 1_000_001)])) {
            XCTAssertEqual($0 as? PrompterLibraryError, .scriptTooLong(limit: 1_000_000))
        }
    }

    func testCharactersAreCountedAsCharactersNotUTF16Units() throws {
        library.load()
        // 400,000 family emoji are 400,000 characters, 2.8 million UTF-16 units.
        let family = String(repeating: "👩‍👩‍👧", count: 400_000)
        XCTAssertNoThrow(try library.addScript(title: "emoji", pages: [family]))
    }

    func testShrinkingAnOverLimitScriptLoadedFromDiskIsAllowedButGrowingIsNot() throws {
        let big = String(repeating: "a", count: 1_000_050)
        io.data = version1File(scripts: [[
            "id": scriptID, "title": "Hand edited", "updatedAt": "2027-01-15T08:00:00Z", "pages": [big],
        ]])
        library.load()
        XCTAssertEqual(library.status, .ready, "an over-limit file is not truncated or rejected on load")
        let id = UUID(uuidString: scriptID)!
        XCTAssertThrowsError(try library.setPage(scriptID: id, index: 0, text: big + "b")) {
            XCTAssertEqual($0 as? PrompterLibraryError, .scriptTooLong(limit: 1_000_000))
        }
        XCTAssertNoThrow(try library.setPage(scriptID: id, index: 0, text: String(repeating: "a", count: 10)))
    }

    func testScriptLimitIs500() throws {
        library.load()
        for index in 0..<500 { try library.addScript(title: "s\(index)") }
        XCTAssertThrowsError(try library.addScript(title: "one more")) {
            XCTAssertEqual($0 as? PrompterLibraryError, .tooManyScripts(limit: 500))
        }
        XCTAssertThrowsError(try library.duplicateScript(library.scripts[0].id, title: "dup")) {
            XCTAssertEqual($0 as? PrompterLibraryError, .tooManyScripts(limit: 500))
        }
        XCTAssertEqual(library.scripts.count, 500)
    }

    // MARK: Editing

    func testDuplicateTitlesAreAllowedAndIdentityIsTheID() throws {
        library.load()
        let first = try library.addScript(title: "Same")
        let second = try library.addScript(title: "Same")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(library.scripts.map(\.title), ["Same", "Same"])
        try library.renameScript(second, title: "Same")
        library.flush()
        let reopened = PrompterLibrary(io: io, scheduler: StoreScheduler(), now: { fixedNow })
        reopened.load()
        XCTAssertEqual(reopened.scripts.map(\.id), [first, second])
    }

    func testPageOperationsAndUpdatedAt() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let lib = PrompterLibrary(io: io, scheduler: scheduler, now: { clock })
        lib.load()
        let id = try lib.addScript(title: "Talk", pages: ["a", "b", "c"])
        clock = Date(timeIntervalSince1970: 1_800_000_100)
        try lib.setPage(scriptID: id, index: 0, text: "A")
        XCTAssertEqual(lib.script(id)?.updatedAt, clock)
        let added = try lib.addPage(scriptID: id, text: "d")
        XCTAssertEqual(added, 3)
        try lib.movePage(scriptID: id, from: 3, to: 0)
        XCTAssertEqual(lib.script(id)?.pages, ["d", "A", "b", "c"])
        try lib.deletePage(scriptID: id, index: 1)
        XCTAssertEqual(lib.script(id)?.pages, ["d", "b", "c"])
        XCTAssertThrowsError(try lib.setPage(scriptID: id, index: 9, text: "x")) {
            XCTAssertEqual($0 as? PrompterLibraryError, .noSuchPage)
        }
        XCTAssertThrowsError(try lib.renameScript(UUID(), title: "x")) {
            XCTAssertEqual($0 as? PrompterLibraryError, .noSuchScript)
        }
    }

    func testDuplicateDeleteAndCurrentScript() throws {
        library.load()
        let id = try library.addScript(title: "Talk", pages: ["a", "b"])
        library.setCurrentScript(id)
        let copy = try library.duplicateScript(id, title: "Talk copy")
        XCTAssertNotEqual(copy, id)
        XCTAssertEqual(library.script(copy)?.pages, ["a", "b"])
        XCTAssertEqual(library.script(copy)?.title, "Talk copy")
        try library.deleteScript(id)
        XCTAssertNil(library.currentScriptID, "deleting the current script clears the pointer")
        library.setCurrentScript(UUID())
        XCTAssertNil(library.currentScriptID, "an unknown id is ignored")
        library.flush()
        XCTAssertEqual(try lastWritten()["currentScriptID"] as? String, nil)
    }

    func testChangingTheCurrentScriptIsDebouncedLikeAnyEdit() throws {
        library.load()
        let id = try library.addScript(title: "Talk")
        library.flush()
        let writes = io.writes.count
        library.setCurrentScript(nil)
        library.setCurrentScript(id)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(io.writes.count, writes + 1)
    }

    // MARK: Real file IO (under $TMPDIR only)

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PrompterStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testRealIOReadDoesNotCreateAnythingAndWriteCreatesTheDirectory() throws {
        let directory = tempDirectory().appendingPathComponent("Prompter", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let real = FilePrompterFileIO(directory: directory)
        XCTAssertFalse(real.exists())
        XCTAssertThrowsError(try real.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "reading never creates the folder")
        try real.writeAtomically(Data("one".utf8))
        XCTAssertTrue(real.exists())
        XCTAssertEqual(try real.read(), Data("one".utf8))
        XCTAssertEqual(directory.appendingPathComponent("library.json").lastPathComponent, "library.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json").path))
    }

    func testRealIOFailedWriteLeavesTheOldFileWholeAndNoTemporaryFiles() throws {
        let directory = tempDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let real = FilePrompterFileIO(directory: directory)
        let old = Data(String(repeating: "old", count: 10_000).utf8)
        try real.writeAtomically(old)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        if FileManager.default.isWritableFile(atPath: directory.path) {
            throw XCTSkip("running as a user that ignores directory permissions")
        }
        XCTAssertThrowsError(try real.writeAtomically(Data("new".utf8)))
        XCTAssertEqual(try real.read(), old, "the old library is whole after a failed write")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["library.json"], "no partial or temporary file left behind")
    }

    func testRealIOCopyAsideKeepsBytesAndNeverOverwritesAnEarlierCopy() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = FilePrompterFileIO(directory: directory)
        try real.writeAtomically(Data("broken".utf8))
        let first = try real.copyAside(as: "library.corrupt-20270115T080000Z.json")
        try real.writeAtomically(Data("broken again".utf8))
        let second = try real.copyAside(as: "library.corrupt-20270115T080000Z.json")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(first)), Data("broken".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(second)), Data("broken again".utf8))
        XCTAssertEqual(try real.read(), Data("broken again".utf8), "the original stays in place")
    }
}
