import XCTest
@testable import IslaKit

/// The exact query, then the search.
///
/// Checked against LRCLIB on 2026-09-21: "waltz", "We Say Goodbye" and "Spit"
/// all have timed lyrics there, filed under albums Spotify does not name, and
/// each showed "No lyrics found" because the exact query needs all four of
/// title, artist, album and duration to agree.
final class OnlineLyricsSearchTests: XCTestCase {
    private func track(
        title: String = "waltz", artist: String = "Esha Tewari",
        album: String = "waltz", duration: TimeInterval = 164
    ) -> LocalTrackIdentity {
        LocalTrackIdentity(
            playerID: "spotify", title: title, artist: artist, album: album,
            duration: duration, recordingID: nil
        )
    }

    private static func row(
        title: String = "waltz", artist: String = "Esha Tewari", duration: Double = 164,
        synced: Bool = true, instrumental: Bool = false, lyrics text: String? = nil
    ) -> String {
        let body = text ?? #"[00:10.00]First line\n[00:15.00]Second line"#
        let lyrics = synced ? #""syncedLyrics":"\#(body)","# : ""
        return #"{"trackName":"\#(title)","artistName":"\#(artist)","albumName":"wraith","duration":\#(duration),\#(lyrics)"instrumental":\#(instrumental)}"#
    }

    /// A transport that answers the exact query with `exact` and every search
    /// with `search`, counting the requests.
    private final class Server: @unchecked Sendable {
        var requests: [URL] = []
        let exact: (status: Int, body: String)
        let search: Result<String, Error>
        init(exact: (Int, String), search: Result<String, Error>) {
            self.exact = exact
            self.search = search
        }
        func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            let url = request.url!
            requests.append(url)
            if url.path.hasSuffix("/get") {
                return (Data(exact.body.utf8), HTTPURLResponse(url: url, statusCode: exact.status, httpVersion: nil, headerFields: nil)!)
            }
            let body = try search.get()
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testAMissOnTheExactQueryIsFoundBySearch() async {
        let server = Server(exact: (404, "{}"), search: .success("[\(Self.row())]"))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        guard case .found(let timeline) = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
        XCTAssertEqual(timeline.lines.first?.text, "First line")
    }

    /// Another length is another recording — a live take, an edit.
    func testACandidateOfAnotherLengthIsRefused() async {
        let server = Server(exact: (404, "{}"), search: .success("[\(Self.row(duration: 180))]"))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        XCTAssertEqual(outcome, .none)
    }

    /// Untimed words are not shown as if they were timed.
    func testAnUntimedCandidateIsNotTaken() async {
        let server = Server(exact: (404, "{}"), search: .success("[\(Self.row(synced: false))]"))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        XCTAssertEqual(outcome, .none)
    }

    /// An instrumental is an answer; the search would only find it again.
    func testAnInstrumentalIsNotSearched() async {
        let server = Server(exact: (200, #"{"instrumental":true}"#), search: .success("[]"))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        XCTAssertEqual(outcome, .none)
        XCTAssertEqual(server.requests.count, 1)
    }

    /// A search that could not be asked says nothing about the catalogue: a
    /// failure to retry, never a miss to remember.
    func testASearchThatCannotBeAskedIsAFailure() async {
        let server = Server(exact: (404, "{}"), search: .failure(URLError(.notConnectedToInternet)))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        XCTAssertEqual(outcome, .failed)
    }

    /// The edition is set aside, and the company: a remaster is found under
    /// its plain title, a duet under its first-named artist.
    func testTheEditionAndTheCompanyAreSetAside() async {
        XCTAssertEqual(OnlineLyrics.baseTitle("Child Psychology - 2023 Remaster"), "Child Psychology")
        XCTAssertEqual(OnlineLyrics.baseTitle("Sky Blue Skin - Demo - September 1996"), "Sky Blue Skin")
        XCTAssertEqual(OnlineLyrics.baseTitle("Song (feat. Someone)"), "Song")
        XCTAssertEqual(OnlineLyrics.baseTitle("Love - Hate"), "Love - Hate", "a dash that is part of the title stays")
        XCTAssertEqual(OnlineLyrics.primaryArtist("Hope Sandoval & The Warm Inventions"), "Hope Sandoval")
        XCTAssertEqual(OnlineLyrics.primaryArtist("Mitski, Someone"), "Mitski")
        XCTAssertEqual(OnlineLyrics.comparable("Don’t Stop"), OnlineLyrics.comparable("dont stop"))

        let server = Server(exact: (404, "{}"), search: .success("[\(Self.row(title: "Child Psychology", artist: "Black Box Recorder", duration: 247))]"))
        let outcome = await OnlineLyrics.lookUp(track(
            title: "Child Psychology - 2023 Remaster", artist: "Black Box Recorder, Someone",
            album: "England Made Me", duration: 247.5
        )) { try server.answer($0) }
        guard case .found = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
    }

    /// A miss remembered before the search existed is asked again; one the
    /// search also missed is believed.
    @MainActor
    func testAMissFromBeforeTheSearchIsAskedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-online-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = track()
        let key = OnlineLyricsCache.key(identity)
        let old = [key: ["checkedAt": Date().timeIntervalSinceReferenceDate]]
        try JSONSerialization.data(withJSONObject: old).write(to: directory.appendingPathComponent("cache.json"))

        let cache = OnlineLyricsCache(directory: directory)
        XCTAssertTrue(cache.cached(identity) == nil, "an exact-only miss is asked again")
        cache.remember(.none, for: identity)
        XCTAssertEqual(cache.cached(identity), .some(nil), "a searched miss is believed")
    }

    // MARK: - A recording's lyrics fit its length

    /// Two rows inside the three-second tolerance, and the one closer in
    /// length is timed to another cut: its last line is stamped 40 s after the
    /// track has ended. The lyric lab found 1,249 lines in 69 of 540 tracks
    /// stamped past their own record's length, and closest-length-wins took
    /// them. A row whose words fit the track now outranks one whose words do
    /// not, before length is compared at all.
    func testACandidateTimedPastTheTrackRanksBelowOneThatFits() throws {
        let overrun = Self.row(
            duration: 164, lyrics: #"[00:10.00]Overrun first\n[03:24.00]Overrun last"#
        )
        let fits = Self.row(
            duration: 166, lyrics: #"[00:10.00]Fits first\n[02:30.00]Fits last"#
        )
        let rows = try JSONDecoder().decode(
            [OnlineLyrics.SearchRow].self, from: Data("[\(overrun),\(fits)]".utf8)
        )
        let match = try XCTUnwrap(OnlineLyrics.bestMatch(in: rows, for: track()))
        XCTAssertEqual(match.lines.map(\.text), ["Fits first", "Fits last"])
    }

    /// The exact answer overruns and the search has nothing better. It is
    /// still the recording the four fields named, so it is kept — a found
    /// lyric never turns into a miss — but only with the lines the clock can
    /// reach. A line past the track's end can never light, and a stage that
    /// lists it shows words that are not in the song playing.
    func testAnOverrunningAnswerWithNoBetterRowKeepsOnlyItsReachableLines() async {
        let exact = #"{"syncedLyrics":"[00:10.00]Reachable\n[02:40.00]Still reachable\n[03:24.00]Past the end","instrumental":false,"duration":164}"#
        let server = Server(exact: (200, exact), search: .success("[]"))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        guard case .found(let timeline) = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
        XCTAssertEqual(timeline.lines.map(\.text), ["Reachable", "Still reachable"])
        XCTAssertTrue(timeline.lines.allSatisfy { $0.at <= 164 }, "no line past the track's end")
        XCTAssertGreaterThan(server.requests.count, 1, "an overrunning answer asks the search for a better row")
    }

    /// And when the search does have a row that fits, that row is the answer.
    func testAnOverrunningAnswerGivesWayToARowThatFits() async {
        let exact = #"{"syncedLyrics":"[00:10.00]Exact\n[03:24.00]Past the end","instrumental":false,"duration":164}"#
        let fits = Self.row(duration: 165, lyrics: #"[00:10.00]Fits\n[02:30.00]Fits last"#)
        let server = Server(exact: (200, exact), search: .success("[\(fits)]"))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        guard case .found(let timeline) = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
        XCTAssertEqual(timeline.lines.first?.text, "Fits")
    }

    /// Full-width and CJK brackets are editions too, and a title that is all
    /// bracket is the title. "(Nice Dream)" used to strip to nothing, and
    /// `bestMatch` returned nil for an empty title before it read a row.
    func testFullWidthAndAllBracketTitles() throws {
        XCTAssertEqual(OnlineLyrics.baseTitle("Title（Remastered）"), "Title")
        XCTAssertEqual(OnlineLyrics.baseTitle("Title【Live】"), "Title")
        XCTAssertEqual(OnlineLyrics.baseTitle("Title「Single Version」"), "Title")
        XCTAssertEqual(OnlineLyrics.baseTitle("(Nice Dream)"), "(Nice Dream)")
        XCTAssertEqual(OnlineLyrics.baseTitle("(Nice Dream) - 2009 Remaster"), "(Nice Dream)")

        let rows = try JSONDecoder().decode(
            [OnlineLyrics.SearchRow].self,
            from: Data("[\(Self.row(title: "(Nice Dream)", artist: "Radiohead", duration: 233))]".utf8)
        )
        XCTAssertNotNil(OnlineLyrics.bestMatch(
            in: rows, for: track(title: "(Nice Dream)", artist: "Radiohead", album: "The Bends", duration: 233)
        ))
    }

    /// A timed answer the parser cannot read is not "LRCLIB has no lyrics":
    /// the words are there, and a later parser may read them.
    func testASyncedAnswerThatCannotBeReadIsUnreadableNotAMiss() async {
        let exact = #"{"syncedLyrics":"[00:7x.00]Mistyped stamp","instrumental":false,"duration":164}"#
        XCTAssertEqual(OnlineLyrics.timeline(from: Data(exact.utf8), status: 200), .unreadable)
        let server = Server(exact: (200, exact), search: .success("[]"))
        let outcome = await OnlineLyrics.lookUp(track()) { try server.answer($0) }
        XCTAssertEqual(outcome, .unreadable)
    }

    // MARK: - Too many requests, and a server that is only busy

    /// A transport that plays back one scripted answer per request, whatever
    /// the URL, and counts what it was asked. Past its script it answers 418,
    /// so a request the lookup should not have sent shows up in the count and
    /// in the outcome rather than as a crash.
    private final class ScriptedServer: @unchecked Sendable {
        struct Reply {
            var status: Int
            var headers: [String: String] = [:]
            var body = "{}"
        }
        private let lock = NSLock()
        private var script: [Reply]
        private var asked: [URL] = []
        init(_ script: [Reply]) { self.script = script }
        var requests: [URL] { lock.lock(); defer { lock.unlock() }; return asked }
        func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            lock.lock(); defer { lock.unlock() }
            let url = request.url!
            asked.append(url)
            let reply = script.isEmpty ? Reply(status: 418) : script.removeFirst()
            return (
                Data(reply.body.utf8),
                HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            )
        }
    }

    /// The seconds a lookup asked to sleep, without sleeping them.
    private final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [TimeInterval] = []
        var seconds: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return asked }
        func sleep(_ seconds: TimeInterval) async { record(seconds) }
        private func record(_ seconds: TimeInterval) { lock.lock(); asked.append(seconds); lock.unlock() }
    }

    private static let hitBody = #"{"syncedLyrics":"[00:10.00]First line\n[00:15.00]Second line","instrumental":false,"duration":164}"#
    private static let overrunBody = #"{"syncedLyrics":"[00:10.00]Reachable\n[03:24.00]Past the end","instrumental":false,"duration":164}"#

    /// A track whose title and artist carry an edition and a company, so the
    /// lookup has two search queries to make after the exact one.
    private func twoQueryTrack() -> LocalTrackIdentity {
        track(title: "Child Psychology - 2023 Remaster", artist: "Black Box Recorder, Someone", album: "England Made Me", duration: 164)
    }

    private func lookUp(
        _ identity: LocalTrackIdentity, server: ScriptedServer, sleeps: SleepLog = SleepLog()
    ) async -> OnlineLyrics.Outcome {
        await OnlineLyrics.lookUp(identity, transport: { try server.answer($0) }, sleep: { await sleeps.sleep($0) })
    }

    /// A 429 on the exact query ends the lookup there: the search would ask the
    /// same gateway the same question a second later. The outcome carries the
    /// service's own Retry-After so the pause can honour it.
    func testA429OnTheExactQueryStopsTheLookUp() async {
        let server = ScriptedServer([.init(status: 429, headers: ["Retry-After": "120"])])
        let outcome = await lookUp(twoQueryTrack(), server: server)
        XCTAssertEqual(outcome, .limited(retryAfter: 120))
        XCTAssertEqual(server.requests.count, 1, "no search is sent after a 429")
    }

    /// The same on a search: the second search query is not sent. The lookup
    /// used to `continue` past any failed search status, so one limited
    /// lookup was three requests against a gateway that had said stop.
    func testA429OnASearchStopsTheRemainingQueries() async {
        let server = ScriptedServer([
            .init(status: 404),
            .init(status: 429, headers: ["Retry-After": "60"]),
        ])
        let outcome = await lookUp(twoQueryTrack(), server: server)
        XCTAssertEqual(outcome, .limited(retryAfter: 60))
        XCTAssertEqual(server.requests.count, 2, "the exact query and the first search, and no more")
    }

    /// A found lyric is never turned into a miss by being checked harder. The
    /// exact answer overran the track and the search was limited: the exact
    /// answer stands, and nothing more is sent. The pause is not armed from
    /// this lookup; the next song's first request meets the 429 and arms it,
    /// which costs one request.
    func testA429AfterAnOverrunningAnswerKeepsTheAnswer() async {
        let server = ScriptedServer([
            .init(status: 200, body: Self.overrunBody),
            .init(status: 429, headers: ["Retry-After": "60"]),
        ])
        let outcome = await lookUp(twoQueryTrack(), server: server)
        guard case .found(let timeline) = outcome else { return XCTFail("expected the exact answer, got \(outcome)") }
        XCTAssertEqual(timeline.lines.map(\.text), ["Reachable"])
        XCTAssertEqual(server.requests.count, 2)
    }

    /// LRCLIB's own server answers overload with 503 and `Retry-After: 1`. A
    /// wait that short is worth taking once: the second ask is the answer.
    func testA503WithAShortRetryAfterIsAskedOnceMore() async {
        let server = ScriptedServer([
            .init(status: 503, headers: ["Retry-After": "1"]),
            .init(status: 200, body: Self.hitBody),
        ])
        let sleeps = SleepLog()
        let outcome = await lookUp(track(), server: server, sleeps: sleeps)
        guard case .found(let timeline) = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
        XCTAssertEqual(timeline.lines.first?.text, "First line")
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(sleeps.seconds, [1])
    }

    /// Once, not until it works: a server still overloaded after the wait is
    /// not helped by a third request.
    func testASecond503Fails() async {
        let server = ScriptedServer([
            .init(status: 503, headers: ["Retry-After": "1"]),
            .init(status: 503, headers: ["Retry-After": "1"]),
        ])
        let outcome = await lookUp(track(), server: server)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(server.requests.count, 2)
    }

    /// Somebody is looking at "Finding lyrics" while this runs: a server that
    /// asks for half a minute is not waited for.
    func testA503WithALongRetryAfterFailsWithoutWaiting() async {
        let server = ScriptedServer([.init(status: 503, headers: ["Retry-After": "30"])])
        let sleeps = SleepLog()
        let outcome = await lookUp(track(), server: server, sleeps: sleeps)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(sleeps.seconds, [])
    }

    /// A 503 with no Retry-After is not retried either: nothing says the wait
    /// would be short.
    func testA503WithNoRetryAfterFailsWithoutWaiting() async {
        let server = ScriptedServer([.init(status: 503)])
        let sleeps = SleepLog()
        let outcome = await lookUp(track(), server: server, sleeps: sleeps)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(sleeps.seconds, [])
    }

    /// The next search query would meet the same overloaded server, so a 5xx
    /// ends the loop. A decode error or a thrown transport error says nothing
    /// about the server and still lets the next query try.
    func testA5xxOnASearchStopsTheRemainingQueries() async {
        let server = ScriptedServer([.init(status: 404), .init(status: 500)])
        let outcome = await lookUp(twoQueryTrack(), server: server)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(server.requests.count, 2)
    }

    /// And a search row that cannot be decoded is the old behaviour: the loop
    /// goes on to the second query.
    func testAnUnreadableSearchAnswerStillTriesTheNextQuery() async {
        let server = ScriptedServer([
            .init(status: 404),
            .init(status: 200, body: "not json"),
            .init(status: 200, body: "[\(Self.row(title: "Child Psychology", artist: "Black Box Recorder", duration: 164))]"),
        ])
        let outcome = await lookUp(twoQueryTrack(), server: server)
        guard case .found = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
        XCTAssertEqual(server.requests.count, 3)
    }

    /// A lookup that is cancelled while it waits out a 503 does not send the
    /// second request: a skip must not leave requests running.
    func testACancelledLookUpDoesNotAskAgainAfterTheWait() async {
        let server = ScriptedServer([
            .init(status: 503, headers: ["Retry-After": "1"]),
            .init(status: 200, body: Self.hitBody),
        ])
        let identity = track()
        let task = Task {
            await OnlineLyrics.lookUp(
                identity, transport: { try server.answer($0) },
                sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } }
            )
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(server.requests.count, 1)
    }
}
