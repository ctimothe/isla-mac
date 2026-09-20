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
    func testTheCacheRemembersAnswersAndNotFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OnlineLyricsCache(directory: directory)

        XCTAssertNil(cache.cached(track), "nothing asked yet means ask")

        cache.remember(.failed, for: track)
        XCTAssertNil(cache.cached(track), "a failure is not an answer; the next play asks again")

        cache.remember(.none, for: track)
        XCTAssertEqual(cache.cached(track), .some(nil), "a remembered miss stays a miss")

        let timeline = LyricTimeline(
            lines: [LyricsStore.Line(at: 1, text: "One")], granularity: .line
        )
        cache.remember(.found(timeline), for: track)
        XCTAssertEqual(cache.cached(track)??.lines.first?.text, "One")

        // And it survives a relaunch, which is the whole point of a file.
        XCTAssertEqual(OnlineLyricsCache(directory: directory).cached(track)??.lines.count, 1)

        cache.forget(track)
        XCTAssertNil(cache.cached(track), "Retry must mean retry")
    }

    /// The same recording from two players is one lookup, not two.
    func testTheCacheIsKeyedByTheRecordingNotThePlayer() {
        let fromMusic = LocalTrackIdentity(
            playerID: "music", title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, recordingID: nil
        )
        XCTAssertEqual(OnlineLyricsCache.key(track), OnlineLyricsCache.key(fromMusic))
    }
}
