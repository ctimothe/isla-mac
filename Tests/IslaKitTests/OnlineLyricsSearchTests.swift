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
        synced: Bool = true, instrumental: Bool = false
    ) -> String {
        let lyrics = synced ? #""syncedLyrics":"[00:10.00]First line\n[00:15.00]Second line","# : ""
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
}
