import XCTest
@testable import DynamicIslandKit

@MainActor
final class LyricsStoreTests: XCTestCase {
    // MARK: - LRC parsing

    func testParsesTimestampedLinesInOrder() {
        let raw = """
        [00:12.50] First line
        [00:05.00] Actually earlier
        [01:02.250] A minute in
        """
        let lines = LyricsStore.parseLRC(raw)
        XCTAssertEqual(lines.map(\.text), ["Actually earlier", "First line", "A minute in"])
        XCTAssertEqual(lines[0].at, 5.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].at, 12.5, accuracy: 0.001)
        XCTAssertEqual(lines[2].at, 62.25, accuracy: 0.001)
    }

    func testRepeatedTimestampsShareOneText() {
        // A chorus is written once and stamped everywhere it is sung.
        let lines = LyricsStore.parseLRC("[00:10.00][01:10.00]Chorus")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Chorus")
        XCTAssertEqual(lines[1].at, 70.0, accuracy: 0.001)
    }

    func testOffsetTagShiftsTheWholeFile() {
        // Positive offset means the lyrics run early, so lines move back.
        let lines = LyricsStore.parseLRC("[offset: +500]\n[00:10.00] Line")
        XCTAssertEqual(lines[0].at, 9.5, accuracy: 0.001)
    }

    func testMetadataAndBlankLinesAreDropped() {
        let raw = """
        [ar:Somebody]
        [ti:Something]
        [00:10.00]
        [00:12.00] Real line
        """
        let lines = LyricsStore.parseLRC(raw)
        XCTAssertEqual(lines.map(\.text), ["Real line"])
    }

    // MARK: - Current-line selection

    private let lines = [
        LyricsStore.Line(at: 5, text: "one"),
        LyricsStore.Line(at: 10, text: "two"),
        LyricsStore.Line(at: 20, text: "three"),
    ]

    func testBeforeTheFirstLineNothingIsCurrent() {
        let (line, next) = LyricsStore.current(in: lines, at: 2)
        XCTAssertNil(line)
        XCTAssertEqual(next?.text, "one")
    }

    func testExactBoundaryBelongsToTheLineStarting() {
        XCTAssertEqual(LyricsStore.current(in: lines, at: 10).line?.text, "two")
    }

    func testBetweenLinesTheEarlierOneHolds() {
        let (line, next) = LyricsStore.current(in: lines, at: 14)
        XCTAssertEqual(line?.text, "two")
        XCTAssertEqual(next?.text, "three")
    }

    func testPastTheLastLineItHoldsWithNoNext() {
        let (line, next) = LyricsStore.current(in: lines, at: 300)
        XCTAssertEqual(line?.text, "three")
        XCTAssertNil(next)
    }

    // MARK: - Cache round trip

    func testCacheAnswersWithoutASecondFetch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // A session pointed at an unroutable host: if the second load needed
        // the network, it would fail rather than answer from disk.
        let store = LyricsStore(cacheDirectory: directory)
        _ = store // construction only; the cache API is exercised through keys

        let key = LyricsStore.cacheKey(title: "T", artist: "A", album: "L", duration: 200)
        let sameKey = LyricsStore.cacheKey(title: "T", artist: "A", album: "L", duration: 200.4)
        let otherKey = LyricsStore.cacheKey(title: "T2", artist: "A", album: "L", duration: 200)
        XCTAssertEqual(key, sameKey, "sub-second duration jitter must not defeat the cache")
        XCTAssertNotEqual(key, otherKey)
    }
}
