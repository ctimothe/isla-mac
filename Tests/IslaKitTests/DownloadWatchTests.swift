import XCTest
@testable import IslaKit

/// The Downloads watch played out over time, over an in-memory folder and a
/// clock the test moves. No test reads a real folder: the sequencing is what
/// needs holding — a rename that lands after the delete, Firefox's
/// placeholder beside its `.part`, a listing the system refused — and none of
/// it can be reached with a real browser.
@MainActor
final class DownloadWatchTests: XCTestCase {
    typealias Entry = DownloadWatch.Entry

    /// The folder and the clock as the test scripts them.
    @MainActor final class Rig {
        struct File {
            var entry = Entry(size: 0, isDirectory: false, created: nil)
            var safari: (soFar: Int64?, total: Int64?)?
            var agent: String?
        }

        let folder = URL(fileURLWithPath: "/fake/Downloads", isDirectory: true)
        var files: [String: File] = [:]
        var listFails = false
        var now = Date(timeIntervalSince1970: 1_000_000)
        var listCalls = 0
        var observing = false
        var stopCalls = 0
        private var changed: (@Sendable () -> Void)?
        private var timers: [(at: Date, work: @MainActor @Sendable () -> Void)] = []
        private var tickOrder = 0

        var events: [DownloadEvent] = []
        var reports: [[DownloadProgress]] = []

        lazy var watch: DownloadWatch = {
            let watch = DownloadWatch(environment: DownloadWatch.Environment(
                folder: folder,
                list: { [unowned self] _ in
                    MainActor.assumeIsolated {
                        self.listCalls += 1
                        return self.listFails ? nil : self.files.keys.sorted().map { self.folder.appendingPathComponent($0) }
                    }
                },
                attributes: { [unowned self] url in
                    MainActor.assumeIsolated { self.files[url.lastPathComponent]?.entry }
                },
                readSafariInfo: { [unowned self] url in
                    MainActor.assumeIsolated { self.files[url.lastPathComponent]?.safari }
                },
                quarantineAgent: { [unowned self] url in
                    MainActor.assumeIsolated { self.files[url.lastPathComponent]?.agent }
                },
                observe: { [unowned self] _, changed in
                    self.observing = true
                    self.changed = changed
                    return { [unowned self] in
                        self.observing = false
                        self.stopCalls += 1
                        self.changed = nil
                    }
                },
                // Every read runs in place, on the main thread, so the table is
                // read where it lives.
                offMain: { $0() },
                onMain: { work in MainActor.assumeIsolated { work() } },
                after: { [unowned self] delay, work in self.timers.append((self.now.addingTimeInterval(delay), work)) },
                now: { [unowned self] in self.now }
            ))
            watch.onActiveChange = { [unowned self] in self.reports.append($0) }
            watch.onEvent = { [unowned self] in self.events.append($0) }
            return watch
        }()

        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

        /// Moves the clock and runs every timer that came due, in order.
        func advance(_ seconds: TimeInterval) {
            let end = now.addingTimeInterval(seconds)
            while let next = timers.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
                timers.remove(at: next.offset)
                now = next.element.at
                next.element.work()
            }
            now = end
        }

        /// The folder changed, as the kernel would say.
        func touch() { changed?() }

        func add(_ name: String, size: Int64 = 0, directory: Bool = false, created: TimeInterval = 0,
                 agent: String? = nil, safari: (soFar: Int64?, total: Int64?)? = nil) {
            files[name] = File(
                entry: Entry(size: size, isDirectory: directory, created: Date(timeIntervalSince1970: 1_000_000 + created)),
                safari: safari, agent: agent
            )
            touch()
        }

        func grow(_ name: String, to size: Int64) {
            files[name]?.entry.size = size
        }

        func remove(_ name: String) {
            files[name] = nil
            touch()
        }

        var pendingTimers: Int { timers.count }
    }

    private func rig(_ configure: (Rig) -> Void = { _ in }) -> Rig {
        let rig = Rig()
        configure(rig)
        rig.watch.start()
        return rig
    }

    // MARK: - Progress

    func testASafariBundleReportsItsBytesAndItsTotal() {
        let rig = rig()
        rig.add("report.pdf.download", size: 900, directory: true, safari: (soFar: 250, total: 1000))
        XCTAssertEqual(rig.watch.active, [DownloadProgress(name: "report.pdf", bytesSoFar: 250, totalBytes: 1000)])
        XCTAssertEqual(rig.watch.active.first?.fraction, 0.25)
        XCTAssertEqual(rig.reports.count, 1)
    }

    func testASafariBundleWithoutItsPlistFallsBackToTheSummedSize() {
        let rig = rig()
        rig.add("a.zip.download", size: 4096, directory: true)
        XCTAssertEqual(rig.watch.active, [DownloadProgress(name: "a.zip", bytesSoFar: 4096, totalBytes: nil)])
        XCTAssertNil(rig.watch.active.first?.fraction)
    }

    func testChromeSaysHowMuchButNotHowBig() {
        let rig = rig()
        rig.add("video.mp4.crdownload", size: 777)
        XCTAssertEqual(rig.watch.active, [DownloadProgress(name: "video.mp4", bytesSoFar: 777, totalBytes: nil)])
        XCTAssertNil(rig.watch.active[0].fraction)
    }

    func testAFractionNeverPassesFullOrDividesByZero() {
        XCTAssertEqual(DownloadProgress(name: "a", bytesSoFar: 12, totalBytes: 10).fraction, 1)
        XCTAssertNil(DownloadProgress(name: "a", bytesSoFar: 12, totalBytes: 0).fraction)
    }

    /// A download's size grows without a write to the folder, so the watch
    /// looks again on its own while one is in progress.
    func testGrowthIsReportedOnTheTick() {
        let rig = rig()
        rig.add("big.iso.crdownload", size: 100)
        XCTAssertEqual(rig.watch.active.first?.bytesSoFar, 100)

        rig.grow("big.iso.crdownload", to: 300)
        rig.advance(DownloadWatch.tick)
        XCTAssertEqual(rig.watch.active.first?.bytesSoFar, 300)
        rig.grow("big.iso.crdownload", to: 450)
        rig.advance(DownloadWatch.tick)
        XCTAssertEqual(rig.watch.active.first?.bytesSoFar, 450)
        XCTAssertEqual(rig.reports.map { $0.first?.bytesSoFar }, [100, 300, 450])
    }

    func testAnUnchangedListingIsNotReportedAgain() {
        let rig = rig()
        rig.add("x.part", size: 10)
        rig.advance(DownloadWatch.tick)
        rig.advance(DownloadWatch.tick)
        XCTAssertEqual(rig.reports.count, 1)
    }

    /// Nothing is polled outside a download: no download, no listing.
    func testTheTickStopsWhenNothingIsInProgress() {
        let rig = rig()
        rig.add("a.bin.crdownload", size: 1)
        rig.add("a.bin", size: 1)
        rig.remove("a.bin.crdownload")
        XCTAssertEqual(rig.watch.active, [])

        rig.advance(10)
        let calls = rig.listCalls
        rig.advance(60)
        XCTAssertEqual(rig.listCalls, calls, "no polling while idle")
        XCTAssertEqual(rig.pendingTimers, 0)
    }

    func testTheOldestDownloadComesFirst() {
        let rig = rig()
        rig.add("new.zip.crdownload", size: 1, created: 20)
        rig.add("old.zip.part", size: 1, created: 5)
        XCTAssertEqual(rig.watch.active.map(\.name), ["old.zip", "new.zip"])
    }

    // MARK: - Names

    func testTheFinalNameIsDerivedFromEachExtension() {
        XCTAssertEqual(DownloadWatch.finalName(of: "report.pdf.download"), "report.pdf")
        XCTAssertEqual(DownloadWatch.finalName(of: "report.pdf.crdownload"), "report.pdf")
        XCTAssertEqual(DownloadWatch.finalName(of: "Unconfirmed 123.crdownload"), "Unconfirmed 123")
        XCTAssertEqual(DownloadWatch.finalName(of: "report.pdf.part"), "report.pdf")
        XCTAssertEqual(DownloadWatch.finalName(of: "clip.mp4.opdownload"), "clip.mp4")
        XCTAssertEqual(DownloadWatch.finalName(of: "Report.PDF.CRDOWNLOAD"), "Report.PDF")
        XCTAssertNil(DownloadWatch.finalName(of: "report.pdf"))
        XCTAssertNil(DownloadWatch.finalName(of: "notes.part.txt"))
        XCTAssertNil(DownloadWatch.finalName(of: ".crdownload"))
        XCTAssertNil(DownloadWatch.finalName(of: ".hidden.crdownload"))
    }

    func testEveryKindOfDownloadIsFollowed() {
        let rig = rig()
        rig.add("a.download", size: 1, directory: true, created: 1)
        rig.add("b.crdownload", size: 1, created: 2)
        rig.add("Unconfirmed 9.crdownload", size: 1, created: 3)
        rig.add("c.part", size: 1, created: 4)
        rig.add("d.opdownload", size: 1, created: 5)
        XCTAssertEqual(rig.watch.active.map(\.name), ["a", "b", "Unconfirmed 9", "c", "d"])
    }

    func testHiddenFilesAreIgnored() {
        let rig = rig()
        rig.add(".com.google.Chrome.abc123", size: 5)
        rig.add(".x.crdownload", size: 5)
        rig.add(".DS_Store", size: 5, agent: "sharingd")
        XCTAssertEqual(rig.watch.active, [])
        XCTAssertEqual(rig.events, [])
    }

    // MARK: - Finishing

    func testAFinishedDownloadIsAnnouncedOnce() {
        let rig = rig()
        rig.add("report.pdf.crdownload", size: 500)
        rig.add("report.pdf", size: 500)
        rig.remove("report.pdf.crdownload")
        XCTAssertEqual(rig.events, [.finished(rig.url("report.pdf"))])
        XCTAssertEqual(rig.watch.active, [])
        XCTAssertEqual(rig.reports.last, [])

        rig.touch()
        rig.advance(5)
        XCTAssertEqual(rig.events.count, 1, "not again on a later look")
    }

    /// Safari moves the file out and deletes the bundle; the final file can
    /// appear after the delete the folder reported.
    func testARenameThatLandsAfterTheDeleteStillFinishes() {
        let rig = rig()
        rig.add("report.pdf.download", size: 500, directory: true, safari: (500, 1000))
        rig.remove("report.pdf.download")
        XCTAssertEqual(rig.events, [], "nothing to point at yet")
        XCTAssertEqual(rig.watch.active, [])

        rig.advance(0.4)
        rig.add("report.pdf", size: 1000)
        XCTAssertEqual(rig.events, [.finished(rig.url("report.pdf"))])
        rig.advance(5)
        XCTAssertEqual(rig.events.count, 1)
    }

    /// The file appears after the delete and with no folder event at all: the
    /// look a second later finds it.
    func testTheFileFoundOnTheSecondLookStillFinishes() {
        let rig = rig()
        rig.add("report.pdf.part", size: 500)
        rig.remove("report.pdf.part")
        rig.files["report.pdf"] = Rig.File(entry: Entry(size: 1000, isDirectory: false, created: nil))
        rig.advance(DownloadWatch.finishGrace)
        XCTAssertEqual(rig.events, [.finished(rig.url("report.pdf"))])
        XCTAssertEqual(rig.events.count, 1)
    }

    func testACancelledDownloadIsSilent() {
        let rig = rig()
        rig.add("movie.mkv.crdownload", size: 500)
        rig.remove("movie.mkv.crdownload")
        rig.advance(5)
        XCTAssertEqual(rig.events, [])
        XCTAssertEqual(rig.watch.active, [])
        XCTAssertEqual(rig.pendingTimers, 0)
    }

    /// A file of that name arriving long after a cancel is not that download.
    func testAFileThatAppearsAfterTheGraceIsNotAFinish() {
        let rig = rig()
        rig.add("movie.mkv.crdownload", size: 500)
        rig.remove("movie.mkv.crdownload")
        rig.advance(2)
        rig.add("movie.mkv", size: 500)
        XCTAssertEqual(rig.events, [])
    }

    // MARK: - Firefox

    /// Firefox creates an empty file under the final name beside its `.part`:
    /// that is neither a finished download nor something that arrived.
    func testFirefoxPlaceholderIsNeitherFinishedNorAnArrival() {
        let rig = rig()
        rig.add("report.pdf.part", size: 100)
        rig.add("report.pdf", size: 0, agent: "sharingd")
        XCTAssertEqual(rig.events, [])
        XCTAssertEqual(rig.watch.active.map(\.name), ["report.pdf"])

        rig.advance(3)
        XCTAssertEqual(rig.events, [], "still downloading")

        rig.grow("report.pdf.part", to: 900)
        rig.remove("report.pdf.part")
        XCTAssertEqual(rig.events, [.finished(rig.url("report.pdf"))])
    }

    func testAPlaceholderThatArrivesBeforeItsPartIsLeftAlone() {
        let rig = rig()
        rig.add("a.zip", size: 0)
        rig.add("a.zip.part", size: 10)
        rig.remove("a.zip.part")
        XCTAssertEqual(rig.events, [.finished(rig.url("a.zip"))])
    }

    // MARK: - AirDrop

    func testAFileSentByAirDropIsAnnouncedOnce() {
        let rig = rig()
        rig.add("IMG_0042.HEIC", size: 9000, agent: "sharingd")
        XCTAssertEqual(rig.events, [.airDropReceived(rig.url("IMG_0042.HEIC"))])
        rig.touch()
        rig.advance(5)
        XCTAssertEqual(rig.events.count, 1)
    }

    func testAFolderSentByAirDropIsAnnounced() {
        let rig = rig()
        rig.add("Photos", directory: true, agent: "AirDrop")
        XCTAssertEqual(rig.events, [.airDropReceived(rig.url("Photos"))])
    }

    func testTheAgentIsMatchedWithoutRegardToCase() {
        XCTAssertTrue(DownloadWatch.isAirDrop("SharingD"))
        XCTAssertTrue(DownloadWatch.isAirDrop("com.apple.airdrop"))
        XCTAssertFalse(DownloadWatch.isAirDrop("Google Chrome"))
        XCTAssertFalse(DownloadWatch.isAirDrop(""))
    }

    func testAFileFromAnotherAgentIsNotAnAirDrop() {
        let rig = rig()
        rig.add("photo.jpg", size: 5, agent: "Safari")
        rig.add("copied.txt", size: 5)
        rig.advance(5)
        XCTAssertEqual(rig.events, [])
    }

    /// AirDrop writes the file and then marks it: the first read can find no
    /// mark, and the second look does.
    func testAMarkWrittenAfterTheFileIsStillFound() {
        let rig = rig()
        rig.add("late.pdf", size: 5)
        XCTAssertEqual(rig.events, [])
        rig.files["late.pdf"]?.agent = "sharingd"
        rig.advance(DownloadWatch.finishGrace)
        XCTAssertEqual(rig.events, [.airDropReceived(rig.url("late.pdf"))])
    }

    func testAFileWithNoMarkIsLeftAloneAfterTheSecondLook() {
        let rig = rig()
        rig.add("plain.txt", size: 5)
        rig.advance(DownloadWatch.finishGrace)
        let calls = rig.listCalls
        rig.advance(30)
        XCTAssertEqual(rig.listCalls, calls)
        XCTAssertEqual(rig.events, [])
    }

    /// A download's own file is the browser's, whatever mark it carries.
    func testAFinishedDownloadIsNotAlsoAnAirDrop() {
        let rig = rig()
        rig.add("a.pdf.crdownload", size: 5)
        rig.add("a.pdf", size: 5, agent: "sharingd")
        rig.remove("a.pdf.crdownload")
        XCTAssertEqual(rig.events, [.finished(rig.url("a.pdf"))])
    }

    // MARK: - What was already there

    func testFilesPresentAtStartProduceNothing() {
        let rig = rig {
            $0.files["old.pdf"] = Rig.File(agent: "sharingd")
            $0.files["IMG.HEIC"] = Rig.File(agent: "sharingd")
        }
        rig.touch()
        rig.advance(5)
        XCTAssertEqual(rig.events, [])
        XCTAssertEqual(rig.reports, [])
    }

    func testADownloadAlreadyRunningAtStartIsFollowed() {
        let rig = rig {
            $0.files["a.zip.crdownload"] = Rig.File(entry: Entry(size: 40, isDirectory: false, created: nil))
        }
        XCTAssertEqual(rig.watch.active, [DownloadProgress(name: "a.zip", bytesSoFar: 40, totalBytes: nil)])
        rig.add("a.zip", size: 40)
        rig.remove("a.zip.crdownload")
        XCTAssertEqual(rig.events, [.finished(rig.url("a.zip"))])
    }

    // MARK: - Failure, start and stop

    /// Permission denied is not an error: the watch keeps what it knew and
    /// tries again on the next change.
    func testAListingFailureKeepsTheLastState() {
        let rig = rig()
        rig.add("a.bin.crdownload", size: 10)
        let before = rig.reports
        rig.listFails = true
        rig.touch()
        rig.advance(DownloadWatch.tick)
        XCTAssertEqual(rig.watch.active.map(\.name), ["a.bin"])
        XCTAssertEqual(rig.reports, before)
        XCTAssertEqual(rig.events, [])

        rig.listFails = false
        rig.grow("a.bin.crdownload", to: 20)
        rig.advance(DownloadWatch.tick)
        XCTAssertEqual(rig.watch.active.first?.bytesSoFar, 20)
    }

    /// A folder the system would not show at the start has no first listing
    /// yet: what the first good one finds is still not news.
    func testTheFirstListingThatSucceedsIsTheOneThatSeeds() {
        let rig = Rig()
        rig.listFails = true
        rig.files["old.pdf"] = Rig.File(agent: "sharingd")
        rig.watch.start()
        rig.listFails = false
        rig.touch()
        XCTAssertEqual(rig.events, [])
        rig.add("new.pdf", agent: "sharingd")
        XCTAssertEqual(rig.events, [.airDropReceived(rig.url("new.pdf"))])
    }

    func testStopClearsAndReports() {
        let rig = rig()
        rig.add("a.bin.part", size: 10)
        rig.watch.stop()
        XCTAssertEqual(rig.watch.active, [])
        XCTAssertEqual(rig.reports.last, [])
        XCTAssertFalse(rig.observing)

        rig.touch()
        rig.advance(10)
        XCTAssertEqual(rig.reports.count, 2, "silent once stopped")
    }

    func testStopWithNothingActiveReportsNothing() {
        let rig = rig()
        rig.watch.stop()
        XCTAssertEqual(rig.reports, [])
    }

    func testStartAndStopAreIdempotent() {
        let rig = rig()
        rig.watch.start()
        rig.watch.start()
        rig.add("a.bin.part", size: 10)
        XCTAssertEqual(rig.reports.count, 1)
        rig.watch.stop()
        rig.watch.stop()
        XCTAssertEqual(rig.stopCalls, 1)
        XCTAssertEqual(rig.reports.count, 2)
    }

    /// A start after a stop is a first listing again: what is there is not
    /// news, and the old session's timers do nothing.
    func testARestartSeedsAgainAndIgnoresTheOldTimers() {
        let rig = rig()
        rig.add("a.bin.part", size: 10)
        rig.watch.stop()
        rig.add("while-off.pdf", agent: "sharingd")
        rig.watch.start()
        XCTAssertEqual(rig.events, [])
        XCTAssertEqual(rig.watch.active.map(\.name), ["a.bin"])
        rig.advance(DownloadWatch.tick)
        XCTAssertEqual(rig.events, [])
    }
}
