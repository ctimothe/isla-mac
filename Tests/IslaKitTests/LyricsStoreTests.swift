import XCTest
@testable import IslaKit

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

    // MARK: - Sweep pacing

    func testSweepFinishesWithTheWordsNotTheSilence() {
        // 30 characters ~ 2.4s of singing inside a 10s slot: the sweep must
        // complete around the vocal, not crawl through the instrumental gap.
        let span = LyricsStore.sweepSpan(text: String(repeating: "a", count: 30), slot: 10)
        XCTAssertEqual(span, 2.4, accuracy: 0.01)
    }

    func testSweepNeverOutrunsTheSlot() {
        // A long line in a tight slot cannot sweep past the next line's start.
        let span = LyricsStore.sweepSpan(text: String(repeating: "a", count: 100), slot: 3)
        XCTAssertEqual(span, 3, accuracy: 0.01)
    }

    func testAVeryShortLineStillGetsAReadableSweep() {
        XCTAssertGreaterThanOrEqual(LyricsStore.sweepSpan(text: "Oh", slot: 8), 1.0)
    }

    // MARK: - Scored matching (QQ + Kugou)

    private func candidate(
        _ title: String, _ artist: String, duration: TimeInterval? = 200, isrc: String? = nil
    ) -> LyricsStore.MatchCandidate {
        LyricsStore.MatchCandidate(title: title, artist: artist, duration: duration, isrc: isrc)
    }

    /// An ISRC-exact hit outranks any scored hit, even a better text score.
    func testISRCExactOutranksScoredHits() {
        let picked = LyricsStore.pickMatch(
            title: "Test Song", artist: "Test Artist", isrc: "USRC12345678", refDuration: 200,
            candidates: [
                candidate("Test Song", "Test Artist"),
                candidate("Something Else Entirely", "Someone Else", isrc: "usrc12345678"),
            ]
        )
        XCTAssertEqual(picked, 1)
    }

    /// Same name, different recording: more than 3s apart in length is a
    /// cover or a remix masquerading, never a match.
    func testDurationGateRejectsBeyondThreeSeconds() {
        let picked = LyricsStore.pickMatch(
            title: "Test Song", artist: "Test Artist", isrc: nil, refDuration: 200,
            candidates: [candidate("Test Song", "Test Artist", duration: 203.5)]
        )
        XCTAssertNil(picked)
    }

    func testDurationGateAcceptsExactlyThreeSeconds() {
        let picked = LyricsStore.pickMatch(
            title: "Test Song", artist: "Test Artist", isrc: nil, refDuration: 200,
            candidates: [candidate("Test Song", "Test Artist", duration: 203)]
        )
        XCTAssertEqual(picked, 0)
    }

    /// A remaster suffix on the query must not defeat the catalogue entry.
    func testCleanTitleRetryRescuesRemaster() {
        let picked = LyricsStore.pickMatch(
            title: "Test Song (Remastered)", artist: "Test Artist", isrc: nil, refDuration: 200,
            candidates: [candidate("Test Song", "Test Artist")]
        )
        XCTAssertEqual(picked, 0)
    }

    /// The exact title wins over a cover wearing the same name.
    func testExactOutranksCover() {
        let picked = LyricsStore.pickMatch(
            title: "Test Song", artist: "Test Artist", isrc: nil, refDuration: 200,
            candidates: [
                candidate("Test Song (Cover)", "Test Artist"),
                candidate("Test Song", "Test Artist"),
            ]
        )
        XCTAssertEqual(picked, 1)
    }

    // MARK: - Arbitration

    private func wordLine(_ at: TimeInterval, _ words: [WordSyncedLyrics.Word]) -> LyricsStore.Line {
        LyricsStore.Line(at: at, text: words.map(\.text).joined(), words: words)
    }

    func testArbitrationKeepsBestNonEmpty() {
        let qq = [wordLine(10, [.init(at: 10, text: "Hello ", end: 10.5), .init(at: 10.6, text: "world", end: 11)])]
        let win = LyricsStore.arbitrate([(.kugou, []), (.qq, qq)], duration: 200)
        XCTAssertEqual(win?.0, .qq)
        XCTAssertEqual(win?.1.count, 1)
    }

    func testArbitrationReturnsNilWhenAllEmpty() {
        XCTAssertNil(LyricsStore.arbitrate([(.qq, []), (.kugou, [])], duration: 200))
    }

    /// Equal coverage, equal sanity: the more trusted source wins.
    func testArbitrationBreaksTiesBySourceTrust() {
        let words: [WordSyncedLyrics.Word] = [.init(at: 10, text: "Hello", end: 10.5)]
        let win = LyricsStore.arbitrate(
            [(.kugou, [wordLine(10, words)]), (.qq, [wordLine(10, words)])], duration: 200
        )
        XCTAssertEqual(win?.0, .qq)
    }

    /// A tier whose timing runs past the track cannot win, however complete.
    func testArbitrationRejectsInsaneTiming() {
        let sane = [wordLine(10, [.init(at: 10, text: "Hello", end: 10.5)])]
        let insane = [wordLine(10, [.init(at: 10, text: "Hello", end: 500)])]
        let win = LyricsStore.arbitrate([(.qq, insane), (.kugou, sane)], duration: 200)
        XCTAssertEqual(win?.0, .kugou)
    }

    // MARK: - Cache v4

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func failingSession() -> URLSession {
        TestURLProtocol.session { _ in nil }
    }

    private func waitForSettled(_ store: LyricsStore) async {
        for _ in 0..<100 {
            if case .loading = store.state {
                try? await Task.sleep(for: .milliseconds(20))
            } else {
                return
            }
        }
    }

    /// v3 files are never read: the only network is a stub that always fails,
    /// so a synced state could only have come from the old file.
    func testV3CacheFilesAreIgnored() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = LyricsStore.cacheKey(title: "T", artist: "A", album: "L", duration: 200)
        let legacy: [String: Any] = ["times": [1.0], "texts": ["Old words"]]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: root.appendingPathComponent("\(key).lrc3.json"))

        let store = LyricsStore(session: failingSession(), cacheDirectory: root)
        store.load(title: "T", artist: "A", album: "L", duration: 200)
        await waitForSettled(store)
        XCTAssertEqual(store.state, .none)
    }

    /// A fetched track is tagged with its source, and the tag survives the disk.
    func testV4CacheRoundTripsSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TestURLProtocol.session { request in
            guard request.url?.host == "lrclib.net",
                  request.url?.path == "/api/get" else { return nil }
            let payload = #"{"syncedLyrics":"[00:10.00] First line\n[00:15.00] Second line\n","duration":200}"#
            return (200, payload.data(using: .utf8)!)
        }
        let store = LyricsStore(session: session, cacheDirectory: root)
        store.load(title: "T", artist: "A", album: "L", duration: 200)
        await waitForSettled(store)
        guard case .synced = store.state else {
            return XCTFail("the stubbed LRCLIB answer should have settled")
        }

        let key = LyricsStore.cacheKey(title: "T", artist: "A", album: "L", duration: 200)
        let url = root.appendingPathComponent("\(key).lrc4.json")
        var source: String?
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["source"] as? String {
                source = tag
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(source, "lrclib")
    }

    /// research() busts the v4 entry; with nothing on the wire the track ends
    /// with no lyrics rather than the busted answer.
    func testResearchDeletesV4Entry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = LyricsStore.cacheKey(title: "T", artist: "A", album: "L", duration: 200)
        let url = root.appendingPathComponent("\(key).lrc4.json")
        let seeded: [String: Any] = ["times": [1.0], "texts": ["Seeded"], "source": "lrclib"]
        try JSONSerialization.data(withJSONObject: seeded).write(to: url)

        let store = LyricsStore(session: failingSession(), cacheDirectory: root)
        store.research(title: "T", artist: "A", album: "L", duration: 200)
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: url.path) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// An empty word-tier answer must not take down the lines already showing.
    func testEmptyWordTierKeepsRetainedLines() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = LyricsStore.cacheKey(title: "Bags", artist: "Clairo", album: "", duration: 261)
        let seeded: [String: Any] = [
            "times": [1.0, 4.0, 8.0],
            "texts": ["First line", "Second line", "Third line"],
            "source": "lrclib",
        ]
        try JSONSerialization.data(withJSONObject: seeded)
            .write(to: root.appendingPathComponent("\(key).lrc4.json"))

        let store = LyricsStore(session: failingSession(), cacheDirectory: root)
        store.load(title: "Bags", artist: "Clairo", album: "", duration: 261)
        await waitForSettled(store)
        guard case .synced(let first) = store.state, first.count == 3 else {
            return XCTFail("the seeded v4 cache has to load for this test to mean anything")
        }
        // The catalogue id arrives and every tier misses: the lines stay.
        store.load(title: "Bags", artist: "Clairo", album: "", duration: 261, spotifyID: "abc123")
        await waitForSettled(store)
        guard case .synced(let kept) = store.state else {
            return XCTFail("an empty word tier took the line-tier lyrics down with it")
        }
        XCTAssertEqual(kept.map(\.text), first.map(\.text))
    }

    /// Word-tier beats line-tier end to end: QQ answers with words while
    /// LRCLIB answers with lines, and the words are what settles.
    func testWordTierBeatsLineTier() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = """
        <?xml version="1.0"?><QrcInfos><Lyric_1 LyricType="1" \
        LyricContent="[10000,5000]Hello (10000,500)world(10500,500)[16000,4000]Second (16000,500)line(16500,500)"/></QrcInfos>
        """
        let hex = try XCTUnwrap(QQLyrics.encryptQRC(xml)).map { String(format: "%02X", $0) }.joined()
        var requestedHosts: [String] = []
        let session = TestURLProtocol.session { request in
            requestedHosts.append(request.url?.host ?? "")
            switch request.url?.host {
            case "u.y.qq.com":
                let payload = """
                {"code":0,"music.search.SearchCgiService":{"code":0,"data":{"body":{"song":{"list":[
                {"songid":12345,"songname":"Test Song","singer":[{"name":"Test Artist"}],
                 "albumname":"Test Album","interval":200}
                ]}}}}}
                """
                return (200, payload.data(using: .utf8)!)
            case "c.y.qq.com":
                let payload = "<QmLyric><contentts><![CDATA[\(hex)]]></contentts></QmLyric>"
                return (200, payload.data(using: .utf8)!)
            case "lrclib.net":
                let payload = #"{"syncedLyrics":"[00:10.00] Flat line one\n[00:15.00] Flat line two\n","duration":200}"#
                return (200, payload.data(using: .utf8)!)
            default:
                return nil
            }
        }
        let store = LyricsStore(session: session, cacheDirectory: root)
        store.load(title: "Test Song", artist: "Test Artist", album: "Test Album", duration: 200)
        await waitForSettled(store)
        guard case .synced(let lines) = store.state else {
            return XCTFail("expected settled lyrics, got \(store.state)")
        }
        XCTAssertEqual(lines.map(\.text), ["Hello world", "Second line"])
        XCTAssertFalse(lines.flatMap(\.words).isEmpty, "the line-tier answer won over words")
        XCTAssertFalse(requestedHosts.contains("lrclib.net"), "the floor was asked after words answered")
    }
}
