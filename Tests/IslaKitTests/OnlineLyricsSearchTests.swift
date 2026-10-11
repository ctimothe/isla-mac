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
}
