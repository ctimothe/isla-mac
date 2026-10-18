import AppKit
import XCTest
@testable import IslaKit

/// What a test plays in place of the pasteboard's `data(forType:)`: it records
/// which thread each read ran on, can hold a read open until the test lets it
/// go, and answers with bytes it was given instead of touching the pasteboard,
/// so the test may move the board meanwhile without breaking the rule the
/// production code keeps (`PasteboardRead`).
private final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []
    private var finished = 0
    private var answers: [Data?]
    private let holds: Bool
    /// Signalled when a read has begun.
    let started = DispatchSemaphore(value: 0)
    /// Waited on by a read that holds; the test signals it.
    let release = DispatchSemaphore(value: 0)

    /// - Parameter answers: One per read, in order; the last repeats.
    init(holds: Bool, answers: [Data?]) {
        self.holds = holds
        self.answers = answers
    }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return onMain.count }
    var finishedReads: Int { lock.lock(); defer { lock.unlock() }; return finished }
    var anyReadRanOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain.contains(true) }

    var reader: @Sendable (NSPasteboard, NSPasteboard.PasteboardType) -> Data? {
        { @Sendable [self] _, _ in
            lock.lock()
            onMain.append(Thread.isMainThread)
            let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
            lock.unlock()
            started.signal()
            if holds { _ = release.wait(timeout: .now() + 5) }
            lock.lock(); finished += 1; lock.unlock()
            return answer
        }
    }
}

/// Where the pasteboard's bytes are read. A Retina screenshot is 10–21 MB, and
/// the read used to run on the main actor inside `pollNow`, so a screenshot
/// pasted into an agent hitched the pointer sampler and every animation for as
/// long as the pasteboard server took to hand the bytes over (spec §19.12).
@MainActor
final class ClipboardPasteboardReadTests: XCTestCase {
    private var board: NSPasteboard!
    private var store: ClipboardStore!
    private var readsStayOnMain: (() -> Bool)!

    override func setUp() async throws {
        // Another test may leave a window key, which would keep these reads on
        // the main thread: pin the answer to "no window has the keyboard".
        readsStayOnMain = PasteboardRead.readsStayOnMain
        PasteboardRead.readsStayOnMain = { false }
        board = NSPasteboard(name: .init("ClipboardPasteboardReadTests.\(UUID())"))
        store = ClipboardStore(pasteboard: board)
        store.accessBehavior = { .allowed }
        store.recordsHistory = { true }
        store.wantsImages = { false }
        store.keepsImages = { true }
        store.sourceApp = { "Photos" }
    }

    override func tearDown() async throws {
        PasteboardRead.readsStayOnMain = readsStayOnMain
        board.releaseGlobally()
    }

    private func png(_ width: Int = 300, _ height: Int = 200) -> Data {
        ClipboardPinsTests.png(width: width, height: height, noise: false)
    }

    /// Runs the main run loop until `condition` holds.
    private func settle(until condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let done = expectation(description: "settled")
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() || Date() > deadline { done.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() }
            }
        }
        check()
        wait(for: [done], timeout: timeout + 1)
    }

    private func waitForTheReadToBegin(_ probe: ReadProbe, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(probe.started.wait(timeout: .now() + 5), .success, "the read began", file: file, line: line)
    }

    /// An uncompressed Retina-sized TIFF, the shape a screenshot tool puts on
    /// the pasteboard: 2560 × 2048 RGBA is 20 MB.
    private func largeTIFF() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 2048,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.tiffRepresentation)
    }

    // MARK: Off the main thread

    func testThePictureIsReadOffTheMainThreadAndStillArrives() throws {
        let probe = ReadProbe(holds: false, answers: [png()])
        store.readPasteboardData = probe.reader
        board.clearContents()
        board.setData(png(), forType: .png)

        store.pollNow()
        settle { !self.store.items.isEmpty }

        XCTAssertEqual(probe.reads, 1)
        XCTAssertFalse(probe.anyReadRanOnMain, "the bytes are asked for on a background queue")
        XCTAssertEqual(store.items.first?.kind, .image, "and the picture still reaches the history")
        XCTAssertEqual(store.contentReadCount, 1)
    }

    /// The real read of a real 20 MB picture, no probe: it arrives whole, and
    /// the pasteboard is not left marked as being read.
    func testATwentyMegabytePictureArrivesWholeThroughTheRealRead() throws {
        let tiff = try largeTIFF()
        XCTAssertGreaterThan(tiff.count, 19_000_000)
        board.clearContents()
        board.setData(tiff, forType: .tiff)

        store.pollNow()
        settle(until: { !self.store.items.isEmpty }, timeout: 10)

        guard case .image(let image)? = store.items.first?.payload else { return XCTFail("no picture entry") }
        XCTAssertEqual(image.pixelSize, CGSize(width: 2560, height: 2048))
        XCTAssertFalse(PasteboardRead.isReading(board))
        XCTAssertEqual(store.contentReadCount, 1)
    }

    func testARecordingIsReadOffTheMainThreadAndStillArrives() {
        let probe = ReadProbe(holds: false, answers: [Data([1, 2, 3])])
        store.readPasteboardData = probe.reader
        store.wantsImages = { true }
        var received: (data: Data, ext: String)?
        store.onMovieData = { received = ($0, $1) }
        board.clearContents()
        board.setData(Data([9]), forType: .init("public.mpeg-4"))

        store.pollNow()
        settle { received != nil }

        XCTAssertFalse(probe.anyReadRanOnMain)
        XCTAssertEqual(received?.data, Data([1, 2, 3]))
        XCTAssertEqual(received?.ext, "mp4")
        XCTAssertEqual(store.contentReadCount, 1)
    }

    /// The structural form of "the poll costs the main actor nothing for the
    /// read": the read is held open by the test until the poll has returned,
    /// so a poll that waited for it would still be waiting when the read gave
    /// up, five seconds on.
    func testThePollReturnsWhileTheReadIsStillRunning() throws {
        let probe = ReadProbe(holds: true, answers: [png()])
        store.readPasteboardData = probe.reader
        board.clearContents()
        board.setData(try largeTIFF(), forType: .tiff)

        store.pollNow()

        XCTAssertEqual(probe.finishedReads, 0, "the poll came back before the read did")
        XCTAssertEqual(store.contentReadCount, 1, "the read is counted when it starts, on the main actor")
        waitForTheReadToBegin(probe)
        XCTAssertTrue(PasteboardRead.isReading(board))
        probe.release.signal()
        settle { !PasteboardRead.isReading(self.board) }
        XCTAssertFalse(PasteboardRead.isReading(board))
    }

    // MARK: A newer copy wins

    func testANewerCopyWhileTheReadRunsDropsThePicture() {
        let probe = ReadProbe(holds: true, answers: [png()])
        store.readPasteboardData = probe.reader
        store.wantsImages = { true }
        var vaulted: Data?
        store.onImage = { vaulted = $0 }
        board.clearContents()
        board.setData(png(), forType: .png)
        store.pollNow()
        waitForTheReadToBegin(probe)

        board.clearContents()
        board.setString("the newer copy", forType: .string)
        probe.release.signal()
        settle { !PasteboardRead.isReading(self.board) }

        XCTAssertNil(vaulted, "the stale picture is not handed to the vault")
        XCTAssertTrue(store.items.isEmpty, "nor kept in the history")

        store.pollNow()
        XCTAssertEqual(store.items.first?.preview, "the newer copy", "the next poll takes the newer copy")
        XCTAssertEqual(store.contentReadCount, 2, "the dropped read was still a read")
    }

    func testANewerCopyWhileTheReadRunsDropsTheRecording() {
        let probe = ReadProbe(holds: true, answers: [Data([1, 2, 3])])
        store.readPasteboardData = probe.reader
        store.wantsImages = { true }
        var received: Data?
        store.onMovieData = { data, _ in received = data }
        board.clearContents()
        board.setData(Data([9]), forType: .init("public.mpeg-4"))
        store.pollNow()
        waitForTheReadToBegin(probe)

        board.clearContents()
        board.setString("the newer copy", forType: .string)
        probe.release.signal()
        settle { !PasteboardRead.isReading(self.board) }

        XCTAssertNil(received)
    }

    // MARK: Nothing but the counter while a read runs

    func testAPollDuringAReadAsksNothingButTheCounterAndLeavesTheCopyUnspent() {
        let probe = ReadProbe(holds: true, answers: [png()])
        store.readPasteboardData = probe.reader
        var accessAsks = 0
        store.accessBehavior = { accessAsks += 1; return .allowed }
        board.clearContents()
        board.setData(png(), forType: .png)
        store.pollNow()
        waitForTheReadToBegin(probe)
        let asksBefore = accessAsks

        board.clearContents()
        board.setString("while it reads", forType: .string)
        store.pollNow()

        XCTAssertEqual(accessAsks, asksBefore, "no question beyond the change counter reached the pasteboard")
        XCTAssertEqual(store.contentReadCount, 1)
        XCTAssertTrue(store.items.isEmpty)

        probe.release.signal()
        settle { !PasteboardRead.isReading(self.board) }
        store.pollNow()
        XCTAssertEqual(store.items.first?.preview, "while it reads", "the copy was not spent: the next tick took it")
    }

    func testSettleWaitsForTheReadInFlight() {
        let probe = ReadProbe(holds: true, answers: [png()])
        store.readPasteboardData = probe.reader
        board.clearContents()
        board.setData(png(), forType: .png)
        store.pollNow()
        waitForTheReadToBegin(probe)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { probe.release.signal() }

        let begun = Date()
        PasteboardRead.settle(board)

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(begun), 0.1, "it waited for the read")
        XCTAssertEqual(probe.finishedReads, 1, "and the read had ended when it returned")
        settle { !PasteboardRead.isReading(self.board) }
    }

    /// The hazard is two threads in one `NSPasteboard`, so a read of one board
    /// holds up nobody who asks another. An unconditional wait on the queue
    /// would make this one wait for the read of the first.
    func testSettleWaitsOnlyForTheBoardThatIsBeingRead() {
        let other = NSPasteboard(name: .init("ClipboardPasteboardReadTests.other.\(UUID())"))
        defer { other.releaseGlobally() }
        let probe = ReadProbe(holds: true, answers: [png()])
        store.readPasteboardData = probe.reader
        board.clearContents()
        board.setData(png(), forType: .png)
        store.pollNow()
        waitForTheReadToBegin(probe)

        let begun = Date()
        PasteboardRead.settle(other)

        XCTAssertLessThan(Date().timeIntervalSince(begun), 0.1, "the other board was not held up")
        XCTAssertEqual(probe.finishedReads, 0, "and the read of this one is still running")
        probe.release.signal()
        settle { !PasteboardRead.isReading(self.board) }
    }

    // MARK: AppKit's own calls

    /// With a window holding the keyboard AppKit may ask the pasteboard on the
    /// main thread by itself (⌘V in the Translate field), which cannot be made
    /// to wait; the read is the main thread's then, and arrives at once.
    func testWhileAWindowHoldsTheKeyboardTheReadStaysOnTheMainThread() {
        PasteboardRead.readsStayOnMain = { true }
        let probe = ReadProbe(holds: false, answers: [png()])
        store.readPasteboardData = probe.reader
        board.clearContents()
        board.setData(png(), forType: .png)

        store.pollNow()
        settle { !self.store.items.isEmpty }

        XCTAssertEqual(probe.reads, 1)
        XCTAssertTrue(probe.anyReadRanOnMain)
        XCTAssertFalse(PasteboardRead.isReading(board), "nothing is marked as reading: the main thread did it")
        XCTAssertEqual(store.items.first?.kind, .image)
    }

    // MARK: The wait for a picture still on its way

    func testAPictureStillArrivingIsAskedForAgainOffTheMainThread() {
        let probe = ReadProbe(holds: false, answers: [nil, png()])
        store.readPasteboardData = probe.reader
        board.clearContents()
        board.setData(png(), forType: .png)

        store.pollNow()
        settle(until: { !self.store.items.isEmpty }, timeout: 4)

        XCTAssertEqual(probe.reads, 2, "the empty answer was followed by the retry half a second later")
        XCTAssertFalse(probe.anyReadRanOnMain)
        XCTAssertEqual(store.items.first?.kind, .image)
        XCTAssertEqual(store.contentReadCount, 2)
    }

    // MARK: The one thing the main actor may ask meanwhile

    /// The pattern the rule rests on, under load: a queue reading 1 MP TIFFs
    /// back to back while the main thread calls `changeCount` in bursts of
    /// thousands. This does not reproduce the hazard, which needs another
    /// process to land a copy mid-read; it holds the one call the rule allows.
    func testTheChangeCounterCanBeAskedInBurstsWhileReadsRun() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        board.clearContents()
        board.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)
        var completed = 0
        var asked = 0
        let deadline = Date().addingTimeInterval(1.5)
        func next() {
            guard Date() < deadline else { return }
            PasteboardRead.data(of: .tiff, from: board, using: { @Sendable board, type in board.data(forType: type) }) { data in
                XCTAssertNotNil(data)
                completed += 1
                next()
            }
        }
        next()
        settle(until: {
            for _ in 0..<5_000 { _ = self.board.changeCount }
            asked += 5_000
            return Date() > deadline && !PasteboardRead.isReading(self.board)
        }, timeout: 4)

        XCTAssertGreaterThan(completed, 10)
        XCTAssertGreaterThan(asked, 50_000)
    }
}

/// Every main-actor reach for the general pasteboard goes through
/// `PasteboardRead.general`, which waits out a read in flight. A new reach that
/// forgets would be the crash `PasteboardRead` describes, so this test is where
/// it is caught: adding one means choosing `PasteboardRead.general` or settling.
final class PasteboardAccessContractTests: XCTestCase {
    /// The two declarations that hold a pasteboard for later and settle it at
    /// each use (`ClipboardStore` and `Translator` call `PasteboardRead.settle`).
    private static let allowed: Set<String> = [
        "init(pasteboard: NSPasteboard = .general) {",
        "var pasteboard: NSPasteboard = .general",
    ]

    func testNoOneReachesForTheGeneralPasteboardOutsidePasteboardRead() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IslaKit")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        // `NSPasteboard.general`, and the shorthand where the type is inferred:
        // `of: .general`, `pasteboard: ... = .general`.
        let reaches = try NSRegularExpression(
            pattern: #"NSPasteboard\.general|of:\s*\.general\b|[Pp]asteboard\w*\s*[:=][^=\n]*(?<!PasteboardRead)\.general\b"#
        )
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "PasteboardRead.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("*") || code.hasPrefix("/*") || Self.allowed.contains(code) { continue }
                let range = NSRange(code.startIndex..., in: code)
                if reaches.firstMatch(in: code, range: range) != nil { offenders.append("\(url.lastPathComponent):\(index + 1)") }
            }
        }
        XCTAssertEqual(offenders, [], "use PasteboardRead.general, or call PasteboardRead.settle(_:) first")
    }
}
