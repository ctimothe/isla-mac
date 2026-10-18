import XCTest
@testable import IslaKit

/// A count a `@Sendable` transport closure may safely bump. Locked rather than
/// atomic because the test only ever reads it after awaiting.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// The one lyric path that leaves the Mac, and the rules it is held to.
@MainActor
final class OnlineLyricsTests: XCTestCase {
    private let track = LocalTrackIdentity(
        playerID: "spotify", title: "not a lot, just forever", artist: "Adrianne Lenker",
        album: "songs", duration: 250.2, recordingID: nil
    )

    /// The four fields that identify a recording, and no fifth.
    ///
    /// Duration is included because it is what stops a single matching its own
    /// ten-minute live cut — the wrong-version failure the offline design named
    /// outright. Nothing identifying the listener is sent, and the test says so
    /// by naming the whole query rather than checking for absences.
    func testTheRequestCarriesTheRecordingAndNothingElse() throws {
        let request = try XCTUnwrap(OnlineLyrics.request(for: track))
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.host, "lrclib.net")
        XCTAssertEqual(components.path, "/api/get")
        let sent = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(sent, [
            "track_name": "not a lot, just forever",
            "artist_name": "Adrianne Lenker",
            "album_name": "songs",
            "duration": "250",
        ])
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"), OnlineLyrics.userAgent,
            "the service asks clients to identify themselves"
        )
    }

    /// A track with no artist is not worth asking about: the endpoint matches
    /// on the pair, and a bare title would match some other recording entirely.
    func testAnUnidentifiableTrackIsNeverAskedAbout() async {
        let nameless = LocalTrackIdentity(
            playerID: "spotify", title: "", artist: "", album: "", duration: 0, recordingID: nil
        )
        XCTAssertNil(OnlineLyrics.request(for: nameless))
        let asked = Counter()
        let outcome = await OnlineLyrics.lookUp(nameless) { _ in
            asked.bump()
            return (Data(), URLResponse())
        }
        XCTAssertEqual(asked.value, 0, "no request may be made for a track that cannot be identified")
        XCTAssertEqual(outcome, .none)
    }

    /// The service's own answers, read the way it means them.
    func testTheServicesAnswersAreReadAsItMeansThem() {
        let synced = """
        {"syncedLyrics":"[00:10.58] Through your eyes I see\\n[00:15.77] A smile you bring to me",
         "plainLyrics":"x","instrumental":false}
        """
        guard case .found(let timeline) = OnlineLyrics.timeline(
            from: Data(synced.utf8), status: 200
        ) else { return XCTFail("timed words are a result") }
        XCTAssertEqual(timeline.lines.count, 2)
        XCTAssertEqual(timeline.lines.first?.text, "Through your eyes I see")
        XCTAssertEqual(timeline.lines.first?.at ?? 0, 10.58, accuracy: 0.001)
        // Never invented: LRCLIB carries line-level LRC, so the karaoke sweep
        // stays off for anything from here.
        XCTAssertEqual(timeline.granularity, .line)

        // 404 is the honest "no such recording" and is an answer, not a fault.
        XCTAssertEqual(
            OnlineLyrics.timeline(from: Data("{}".utf8), status: 404), .none
        )
        // Anything else that is not a success is worth retrying, so it must not
        // be mistaken for "this track has no lyrics" and cached as final.
        XCTAssertEqual(
            OnlineLyrics.timeline(from: Data("{}".utf8), status: 503), .failed
        )
        // An instrumental has no words, and a plain sheet has no timing. Both
        // are "none" rather than something to put on a stage that scrolls.
        XCTAssertEqual(
            OnlineLyrics.timeline(from: Data(#"{"instrumental":true}"#.utf8), status: 200), .none
        )
        XCTAssertEqual(
            OnlineLyrics.timeline(from: Data(#"{"plainLyrics":"no timing here"}"#.utf8), status: 200),
            .none
        )
    }

    /// A hit and a miss are both remembered; a failure never is.
    func testTheCacheRemembersAnswersAndNotFailures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OnlineLyricsCache(directory: directory)

        XCTAssertTrue(cache.cached(track) == nil, "nothing asked yet means ask")

        cache.remember(.failed, for: track)
        XCTAssertTrue(cache.cached(track) == nil, "a failure is not an answer; the next play asks again")

        cache.remember(.none, for: track)
        XCTAssertEqual(cache.cached(track), .some(nil), "a remembered miss stays a miss")

        let timeline = LyricTimeline(
            lines: [LyricsStore.Line(at: 1, text: "One")], granularity: .line
        )
        cache.remember(.found(timeline), for: track)
        XCTAssertEqual(cache.cached(track)??.lines.first?.text, "One")

        // And it survives a relaunch, which is the whole point of a file.
        // Flushed first: writes coalesce off the main thread so a run of fast
        // skips costs one write rather than one per answer.
        await cache.flushForTests()
        XCTAssertEqual(OnlineLyricsCache(directory: directory).cached(track)??.lines.count, 1)

        cache.forget(track)
        XCTAssertTrue(cache.cached(track) == nil, "Retry must mean retry")
    }

    /// A miss stamped in the future is asked about again. Its age was the
    /// clock now minus the stamp, with nothing refusing a negative answer, so
    /// a miss written while the clock ran a day fast was believed for the
    /// fortnight plus the day (G-037). A negative age is a clock that was
    /// wrong, not a miss that is fresh.
    func testAMissStampedInTheFutureIsAskedAgain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ahead = Date().addingTimeInterval(86400).timeIntervalSinceReferenceDate
        let stored: [String: Any] = [
            OnlineLyricsCache.key(track): ["checkedAt": ahead, "searched": true],
        ]
        try JSONSerialization.data(withJSONObject: stored)
            .write(to: directory.appendingPathComponent("cache.json"))

        let cache = OnlineLyricsCache(directory: directory)
        XCTAssertTrue(cache.cached(track) == nil, "a miss from the future is not believed")

        // The same miss stamped an hour ago, the ordinary case, still stands.
        let recent = Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: [
            OnlineLyricsCache.key(track): ["checkedAt": recent, "searched": true],
        ]).write(to: directory.appendingPathComponent("cache.json"))
        XCTAssertEqual(OnlineLyricsCache(directory: directory).cached(track), .some(nil))
    }

    /// The cache keeps its newest answers, not every answer ever. A hit carries
    /// the song's whole timeline, and nothing used to leave: every song ever
    /// looked up stayed in memory and in the file, re-encoded whole at each new
    /// answer, for the life of the install. Past its capacity the answers
    /// checked longest ago go — at load, and as new ones arrive.
    func testTheCacheKeepsItsNewestAnswersPastItsCapacity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func song(_ number: Int) -> LocalTrackIdentity {
            LocalTrackIdentity(
                playerID: "music", title: "Song \(number)", artist: "Artist", album: "Album",
                duration: 200, recordingID: nil
            )
        }
        let stored = Dictionary(uniqueKeysWithValues: (1...3).map { number in
            (OnlineLyricsCache.key(song(number)), ["lines": [], "checkedAt": Double(number) * 1000] as [String: Any])
        })
        try JSONSerialization.data(withJSONObject: stored).write(to: directory.appendingPathComponent("cache.json"))

        let cache = OnlineLyricsCache(directory: directory, capacity: 2)
        XCTAssertTrue(cache.cached(song(1)) == nil, "the answer checked longest ago left at load")
        XCTAssertFalse(cache.cached(song(2)) == nil)
        XCTAssertFalse(cache.cached(song(3)) == nil)

        cache.remember(.none, for: song(4))
        XCTAssertTrue(cache.cached(song(2)) == nil, "a new answer pushes out the oldest")
        XCTAssertFalse(cache.cached(song(3)) == nil)
        XCTAssertEqual(cache.cached(song(4)), .some(nil))
    }

    /// The same recording from two players is one lookup, not two.
    func testTheCacheIsKeyedByTheRecordingNotThePlayer() {
        let fromMusic = LocalTrackIdentity(
            playerID: "music", title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, recordingID: nil
        )
        XCTAssertEqual(OnlineLyricsCache.key(track), OnlineLyricsCache.key(fromMusic))
    }

    /// A synced answer the parser refused is remembered — or every play of
    /// that song would ask again — but under the parser revision that refused
    /// it. It used to be cached as a plain miss, so a song whose LRCLIB text
    /// held one '<3' showed "No lyrics found" for 14 days, through the very
    /// release that learned to read it.
    func testAnUnreadableAnswerIsAskedAgainOnceTheParserImproves() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OnlineLyricsCache(directory: directory)
        cache.remember(.unreadable, for: track)
        XCTAssertEqual(cache.cached(track), .some(nil), "presented as a miss, and not asked again at once")
        await cache.flushForTests()

        let same = OnlineLyricsCache(directory: directory)
        XCTAssertEqual(same.cached(track), .some(nil), "the same parser would refuse it again")

        let newer = OnlineLyricsCache(
            directory: directory, parserRevision: LocalLyricsDocument.parserRevision + 1
        )
        XCTAssertTrue(newer.cached(track) == nil, "a parser that reads more is worth asking again")

        // An ordinary miss is a fact about the catalogue, not the parser.
        let other = LocalTrackIdentity(
            playerID: "music", title: "Other", artist: "Artist", album: "", duration: 100, recordingID: nil
        )
        newer.remember(.none, for: other)
        XCTAssertEqual(newer.cached(other), .some(nil))
    }

    /// A hit cached before lines carried their ends (2026-10-11) shows at
    /// once — never a blank stage while the network answers — and is flagged
    /// for exactly one refresh. Only a found answer replaces it; anything
    /// else leaves the old words up and settles the flag, so the refresh is
    /// one request per song, not one per play. A failure settles nothing:
    /// the next play may well reach the service.
    func testAHitFromBeforeLineEndsIsRefreshedOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = LocalTrackIdentity(
            playerID: "music", title: "Second", artist: "Artist", album: "", duration: 120, recordingID: nil
        )
        let oldLines = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([LyricsStore.Line(at: 1, text: "Old")])
        )
        // Written the way the cache wrote hits before it had a format.
        let now = Date().timeIntervalSinceReferenceDate
        let stored: [String: Any] = [
            OnlineLyricsCache.key(track): ["lines": oldLines, "checkedAt": now],
            OnlineLyricsCache.key(second): ["lines": oldLines, "checkedAt": now],
        ]
        try JSONSerialization.data(withJSONObject: stored)
            .write(to: directory.appendingPathComponent("cache.json"))

        let cache = OnlineLyricsCache(directory: directory)
        XCTAssertEqual(cache.cached(track)??.lines.first?.text, "Old", "served at once")
        XCTAssertTrue(cache.needsRefresh(track))

        cache.remember(.failed, for: track)
        XCTAssertTrue(cache.needsRefresh(track), "a failure says nothing; ask on the next play")

        cache.remember(.none, for: track)
        XCTAssertEqual(cache.cached(track)??.lines.first?.text, "Old", "a miss never replaces a hit")
        XCTAssertFalse(cache.needsRefresh(track), "asked once")

        let fresh = LyricTimeline(
            lines: [LyricsStore.Line(at: 1, text: "New", end: 3)], granularity: .line
        )
        XCTAssertTrue(cache.needsRefresh(second))
        cache.remember(.found(fresh), for: second)
        XCTAssertEqual(cache.cached(second)??.lines.first?.end, 3, "replaced by the answer with line ends")
        XCTAssertFalse(cache.needsRefresh(second))

        // A hit remembered today carries ends already and is never refreshed.
        let third = LocalTrackIdentity(
            playerID: "music", title: "Third", artist: "Artist", album: "", duration: 90, recordingID: nil
        )
        cache.remember(.found(fresh), for: third)
        XCTAssertFalse(cache.needsRefresh(third))

        await cache.flushForTests()
        let relaunched = OnlineLyricsCache(directory: directory)
        XCTAssertFalse(relaunched.needsRefresh(track), "settled across a relaunch")
        XCTAssertFalse(relaunched.needsRefresh(second))
        XCTAssertEqual(relaunched.cached(track)??.lines.first?.text, "Old")
    }

    // MARK: - Too many requests

    private func response(_ headers: [String: String], status: Int = 429) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://lrclib.net/api/get")!, statusCode: status,
            httpVersion: nil, headerFields: headers
        )!
    }

    /// Retry-After is delay-seconds or an HTTP-date (RFC 9110 section 10.2.3),
    /// and the gateway in front of LRCLIB is free to send either. A date is
    /// measured against the response's own Date header, not this Mac's clock,
    /// which may be minutes off; only without one does the local clock stand
    /// in. A nonsense header is clamped to a day, so it cannot silence lyrics
    /// for a week.
    func testRetryAfterReadsSecondsAndAnHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        func parsed(_ headers: [String: String]) -> TimeInterval? {
            OnlineLyrics.retryAfter(from: response(headers), now: now)
        }
        XCTAssertEqual(parsed(["Retry-After": "120"]), 120)
        XCTAssertEqual(parsed(["Retry-After": "0"]), 0)
        XCTAssertEqual(parsed([
            "Date": "Sun, 06 Nov 1994 08:49:37 GMT",
            "Retry-After": "Sun, 06 Nov 1994 08:51:07 GMT",
        ]), 90, "a date is measured against the response's own Date")
        XCTAssertEqual(parsed([
            "Date": "Sun, 06 Nov 1994 08:49:37 GMT",
            "Retry-After": "Sun, 06 Nov 1994 08:40:00 GMT",
        ]), 0, "a date already past is no wait at all")
        XCTAssertNil(parsed(["Retry-After": "soon"]))
        XCTAssertNil(parsed([:]))
        XCTAssertEqual(parsed(["Retry-After": "999999999"]), OnlineLyrics.longestRetryAfter)
        XCTAssertEqual(OnlineLyrics.longestRetryAfter, 86_400)

        // Delay-seconds is digits only: a sign or a fraction is no delay.
        XCTAssertNil(parsed(["Retry-After": "-5"]))
        XCTAssertNil(parsed(["Retry-After": "+5"]))
        XCTAssertNil(parsed(["Retry-After": "1.5"]))
        XCTAssertEqual(parsed(["retry-after": "45"]), 45, "header names are case-insensitive")

        // The two obsolete HTTP-date forms a recipient must still accept
        // (RFC 9110 section 5.6.7), the same 90 s after the same Date.
        XCTAssertEqual(parsed([
            "Date": "Sun, 06 Nov 1994 08:49:37 GMT",
            "Retry-After": "Sunday, 06-Nov-94 08:51:07 GMT",
        ]), 90, "rfc850")
        XCTAssertEqual(parsed([
            "Date": "Sun, 06 Nov 1994 08:49:37 GMT",
            "Retry-After": "Sun Nov  6 08:51:07 1994",
        ]), 90, "asctime, with its padded one-digit day")
        XCTAssertEqual(parsed([
            "Date": "Sunday, 06-Nov-94 08:49:37 GMT",
            "Retry-After": "Sun Nov 6 08:51:07 1994",
        ]), 90, "the Date header may be an obsolete form too")

        // No Date header: this Mac's clock is the only one there is.
        let local = Date(timeIntervalSince1970: 784_111_777)  // Sun, 06 Nov 1994 08:49:37 GMT
        XCTAssertEqual(
            OnlineLyrics.retryAfter(
                from: response(["Retry-After": "Sun, 06 Nov 1994 08:50:37 GMT"]), now: local
            ), 60
        )
    }

    /// A limited answer says nothing about the recording, so it is not an
    /// answer to remember — a miss cached from a 429 would have hidden the
    /// song's words for a fortnight on the strength of a busy gateway.
    func testTheCacheNeverRemembersALimitedAnswer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OnlineLyricsCache(directory: directory)

        cache.remember(.limited(retryAfter: 60), for: track)
        XCTAssertTrue(cache.cached(track) == nil, "nothing is stored for a 429; the song asks again later")
        cache.remember(.limited(retryAfter: nil), for: track)
        XCTAssertTrue(cache.cached(track) == nil)

        // And it does not disturb a hit that is already there.
        let timeline = LyricTimeline(
            lines: [LyricsStore.Line(at: 1, text: "One", end: 2)], granularity: .line
        )
        cache.remember(.found(timeline), for: track)
        cache.remember(.limited(retryAfter: 60), for: track)
        XCTAssertEqual(cache.cached(track)??.lines.first?.text, "One")
        XCTAssertFalse(cache.needsRefresh(track))
    }
}
