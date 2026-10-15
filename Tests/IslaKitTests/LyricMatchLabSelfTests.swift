import Foundation
import XCTest
@testable import IslaKit

/// The Lyrics Match Lab's own plumbing, held by tests of its own.
///
/// Each case here pins one repair from the adversarial review of 2026-10-15.
/// Like every lab case they throw `XCTSkip` unless `ISLA_MATCH_LAB` names a
/// directory, so `./scripts/check` never runs them; to run them, point the
/// variable at any directory (they read nothing from it) and filter to this
/// class:
///
///     ISLA_MATCH_LAB=$(mktemp -d) swift test --filter LyricMatchLabSelfTests
///
/// Everything is synthetic: made-up words and stamps, no lyric text. The one
/// case that touches a socket (`testTransportFailureReadsUncached`) connects to
/// 127.0.0.1:1, which nothing listens on, so curl fails at once and nothing
/// leaves the machine.
@MainActor
final class LyricMatchLabSelfTests: XCTestCase {
    // MARK: Synthetic records

    private func synced(step: Double, count: Int, word: String = "lorem") -> String {
        (0..<count).map { index in
            let at = Double(index) * step
            return String(format: "[%02d:%05.2f]%@ %d", Int(at) / 60, at.truncatingRemainder(dividingBy: 60), word, index)
        }.joined(separator: "\n")
    }

    private func record(id: Int, duration: Double, lyrics: String) throws -> MatchRecord {
        let object: [String: Any] = [
            "id": id, "trackName": "Made Up Title", "artistName": "Made Up Artist",
            "duration": duration, "instrumental": false, "syncedLyrics": lyrics,
        ]
        return try JSONDecoder().decode(MatchRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func identity(duration: Double) -> LocalTrackIdentity {
        LocalTrackIdentity(
            playerID: "lab", title: "Made Up Title", artist: "Made Up Artist", album: "",
            duration: duration, recordingID: nil
        )
    }

    // MARK: F11

    /// A fitting search row was credited to an overrunning `/api/get` record
    /// whose reachable lines were the same: `reachable` drops the lines past
    /// the track's end, so the two read alike, and the get was listed first.
    func testRecoverNeedsTheSameOverrun() throws {
        _ = try MatchLab.requireRoot()
        let identity = identity(duration: 100)
        // The get record runs to 200 s: 11 reachable lines and an overrun of 100 s.
        let longCut = try record(id: 1, duration: 100, lyrics: synced(step: 10, count: 21))
        // The search row ends at 100 s with the same text on the same stamps: no overrun.
        let fitting = try record(id: 2, duration: 100, lyrics: synced(step: 10, count: 11))
        let candidates = [
            MatchLab.Candidate(exchange: 0, row: 0, via: "get", record: longCut),
            MatchLab.Candidate(exchange: 1, row: 0, via: "search", record: fitting),
        ]
        guard case .found(let ofLongCut) = OnlineLyrics.timeline(
            from: MatchLab.getShaped(longCut), status: 200, duration: 100
        ), case .found(let ofFitting) = OnlineLyrics.timeline(
            from: MatchLab.getShaped(fitting), status: 200, duration: 100
        ) else { return XCTFail("the synthetic records must parse") }
        XCTAssertTrue(MatchLab.sameLines(ofLongCut.lines, ofFitting.lines), "the premise: the reachable lines are equal")
        XCTAssertEqual(ofLongCut.overrun ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(ofFitting.overrun ?? -1, 0, accuracy: 1e-6)

        let credited = MatchLab.recover(target: ofFitting, identity: identity, candidates: candidates)
        XCTAssertEqual(credited?.id, 2, "the fitting row, not the overrunning get record")
        XCTAssertEqual(credited?.via, "search")
        XCTAssertEqual(credited?.ambiguous ?? [], [], "the get record is not a candidate for this timeline at all")

        let longer = MatchLab.recover(target: ofLongCut, identity: identity, candidates: candidates)
        XCTAssertEqual(longer?.id, 1)
        XCTAssertEqual(longer?.via, "get")
    }

    // MARK: F17

    /// In record mode a curl transport failure is not an answer. It was logged
    /// as a `.failure`, so the lookup read `failed` and the next record run
    /// believed it. It is a `.miss`: the lookup reads `uncached` and the next
    /// run asks again.
    func testTransportFailureReadsUncached() async throws {
        let root = try MatchLab.requireRoot()
        let scratch = root.appendingPathComponent("self-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let transport = ReplayTransport(root: scratch, record: true, maxLive: 1)
        transport.beginLookup()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/api/get?track_name=made%20up")!)
        request.timeoutInterval = 5
        do {
            _ = try await transport.fetch(request)
            XCTFail("nothing listens on 127.0.0.1:1")
        } catch {
            // expected
        }
        let exchanges = transport.takeExchanges()
        XCTAssertEqual(exchanges.count, 1)
        XCTAssertEqual(exchanges.first?.kind, .miss)
        XCTAssertNil(exchanges.first?.status)

        let variant = try XCTUnwrap(MatchVariant([
            "track_id": "self/000", "variant": "canonical", "title": "Made Up Title",
            "artist": "Made Up Artist", "album": "", "duration": 100,
        ]))
        let row = LyricMatchLabLookupTests.row(
            variant: variant, outcome: .failed, exchanges: exchanges, elapsed: .zero
        )
        XCTAssertEqual(row["outcome"] as? String, "uncached")
        // and nothing was written to the cache for the next run to believe
        XCTAssertNil(MatchLab.cacheEntry(scratch, key: exchanges[0].key))
    }

    // MARK: F18

    /// `ISLA_MATCH_OUT` and `ISLA_MATCH_REPORTS` name directories under the
    /// root; the default is the baseline's `results` and `reports`.
    func testOutputDirectoryFollowsTheEnvironment() throws {
        let root = try MatchLab.requireRoot()
        let saved = (getenv(MatchLab.outKey).map { String(cString: $0) }, getenv(MatchLab.reportsKey).map { String(cString: $0) })
        defer {
            for (key, value) in [(MatchLab.outKey, saved.0), (MatchLab.reportsKey, saved.1)] {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        unsetenv(MatchLab.outKey)
        unsetenv(MatchLab.reportsKey)
        XCTAssertEqual(MatchLab.resultsURL(root, "isla-lookups.jsonl").path, root.path + "/results/isla-lookups.jsonl")
        XCTAssertEqual(MatchLab.reportsURL(root, "diagnose-input.jsonl").path, root.path + "/reports/diagnose-input.jsonl")

        setenv(MatchLab.outKey, "candidate", 1)
        setenv(MatchLab.reportsKey, "candidate-reports", 1)
        XCTAssertEqual(MatchLab.resultsURL(root, "isla-lookups.jsonl").path, root.path + "/candidate/isla-lookups.jsonl")
        XCTAssertEqual(MatchLab.reportsURL(root, "diagnose-input.jsonl").path, root.path + "/candidate-reports/diagnose-input.jsonl")
        XCTAssertNoThrow(try MatchLab.requireRoot())

        // a name that is a path would write outside the root: refused, not followed
        for bad in ["../elsewhere", "a/b", "..", "."] {
            setenv(MatchLab.outKey, bad, 1)
            XCTAssertThrowsError(try MatchLab.requireRoot(), bad)
            XCTAssertEqual(MatchLab.outDirectory, MatchLab.defaultOut, "an unusable name never reaches a URL")
        }
        XCTAssertFalse(MatchLab.isPlainDirectoryName(""))
        XCTAssertTrue(MatchLab.isPlainDirectoryName("candidate-2"))
    }

    // MARK: F15

    /// A line's duration is the end the timeline gives it when Isla honours
    /// one, not the gap to the next line, which includes the instrumental
    /// break the line already ended before.
    func testLineDurationUsesTheLinesOwnEnd() throws {
        _ = try MatchLab.requireRoot()
        let lines = [
            LyricsStore.Line(at: 10, text: "one", end: 14),     // sung for 4 s, then a 16 s break
            LyricsStore.Line(at: 30, text: "two", end: 30.5),   // an end closer than the honoured gap is ignored
            LyricsStore.Line(at: 31, text: "three"),            // no end: until the next line
            LyricsStore.Line(at: 40, text: "four"),             // the last line: to the track's end, capped at 10 s
        ]
        XCTAssertEqual(LyricMatchLabReadabilityTests.duration(of: 0, in: lines, trackEnd: 100), 4, accuracy: 1e-9)
        XCTAssertEqual(LyricMatchLabReadabilityTests.duration(of: 1, in: lines, trackEnd: 100), 1, accuracy: 1e-9)
        XCTAssertEqual(LyricMatchLabReadabilityTests.duration(of: 2, in: lines, trackEnd: 100), 9, accuracy: 1e-9)
        XCTAssertEqual(LyricMatchLabReadabilityTests.duration(of: 3, in: lines, trackEnd: 100), 10, accuracy: 1e-9)
        XCTAssertEqual(LyricMatchLabReadabilityTests.duration(of: 3, in: lines, trackEnd: 43), 3, accuracy: 1e-9)
    }
}
