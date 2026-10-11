import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Lyrics timed for a longer version of the song (ly/VERSION-01).
///
/// The owner's song: a 248 s track whose LRCLIB timeline was made for a cut of
/// about 267 s (first stamp 16.3 s, last 265.8 s, 70 lines), copied onto twenty
/// releases, so the listed length of a candidate says nothing about its
/// stamps. The lines ran about 10 s behind the voice, silently, and the
/// listener's correction was clamped at 1.5 s.
///
/// Every timeline here is synthetic: "Line 0", "Line 1", … at stamps shaped
/// like that one. No lyric text is in this file.
@MainActor
final class LyricVersionMismatchTests: XCTestCase {
    private static let duration: TimeInterval = 248

    /// `count` lines from `first` to `last` seconds, evenly spaced.
    private static func stamps(count: Int = 70, first: Double = 16.3, last: Double = 265.8) -> [Double] {
        (0..<count).map { first + Double($0) * (last - first) / Double(count - 1) }
    }

    private static func lrc(count: Int = 70, first: Double = 16.3, last: Double = 265.8) -> String {
        stamps(count: count, first: first, last: last).enumerated().map { index, at in
            let minutes = Int(at) / 60
            return String(format: "[%02d:%05.2f]Line %d", minutes, at - Double(minutes * 60), index)
        }.joined(separator: "\n")
    }

    private static func response(
        lrc: String = lrc(), duration: Double = 267, instrumental: Bool = false
    ) -> Data {
        let object: [String: Any] = ["syncedLyrics": lrc, "instrumental": instrumental, "duration": duration]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func found(_ data: Data, duration: TimeInterval) throws -> LyricTimeline {
        guard case .found(let timeline) = OnlineLyrics.timeline(from: data, status: 200, duration: duration) else {
            XCTFail("the synthetic answer was not found")
            throw NotFound()
        }
        return timeline
    }

    private struct NotFound: Error {}

    private static let identity = LocalTrackIdentity(
        playerID: "yandex", title: "Synthetic Song", artist: "Synthetic Artist", album: "Synthetic Album",
        duration: 248, recordingID: nil
    )

    // MARK: - Detection

    /// The last sung stamp minus the track's length, measured on the whole
    /// answer: the lines past the end are dropped from what shows, so the
    /// surviving timeline alone could never tell.
    func testAnAnswerTimedPastTheTrackIsMeasuredAndFlagged() throws {
        let timeline = try Self.found(Self.response(), duration: Self.duration)
        let overrun = try XCTUnwrap(timeline.overrun, "an online answer for a known length carries its overrun")
        XCTAssertEqual(overrun, 265.8 - 248, accuracy: 0.011)
        XCTAssertTrue(timeline.timedForLongerVersion)
        XCTAssertLessThanOrEqual(try XCTUnwrap(timeline.lines.last).at, Self.duration, "the unreachable tail is still dropped")
    }

    func testAnAnswerThatFitsIsNotFlagged() throws {
        let timeline = try Self.found(Self.response(), duration: 267)
        XCTAssertEqual(try XCTUnwrap(timeline.overrun), 265.8 - 267, accuracy: 0.011)
        XCTAssertFalse(timeline.timedForLongerVersion)
    }

    /// Three seconds is the tolerance two services rounding one file differ by
    /// (`OnlineLyrics.durationTolerance`): inside it is the same recording.
    func testTheToleranceIsTheSearchsThreeSeconds() throws {
        XCTAssertFalse(try Self.found(Self.response(), duration: 263).timedForLongerVersion, "2.8 s over")
        XCTAssertTrue(try Self.found(Self.response(), duration: 262).timedForLongerVersion, "3.8 s over")
    }

    func testAnUnknownLengthIsNeverFlagged() throws {
        for unknown in [0, -1, .infinity, .nan] as [TimeInterval] {
            let timeline = try Self.found(Self.response(), duration: unknown)
            XCTAssertNil(timeline.overrun, "length \(unknown)")
            XCTAssertFalse(timeline.timedForLongerVersion, "length \(unknown)")
        }
    }

    /// A file the listener imported is theirs; its stamps are not second-guessed.
    func testALocalFileIsNeverFlagged() throws {
        let document = try LocalLyricsDocument.parse(Self.lrc())
        let timeline = document.timeline(documentID: UUID())
        XCTAssertNil(timeline.overrun)
        XCTAssertFalse(timeline.timedForLongerVersion)
    }

    // MARK: - Ranking

    private func rows(_ specs: [(duration: Double, last: Double)]) throws -> [OnlineLyrics.SearchRow] {
        let json = specs.map { spec -> String in
            let body = Self.lrc(last: spec.last).replacingOccurrences(of: "\n", with: "\\n")
            return #"{"trackName":"Synthetic Song","artistName":"Synthetic Artist","duration":\#(spec.duration),"syncedLyrics":"\#(body)","instrumental":false}"#
        }
        return try JSONDecoder().decode([OnlineLyrics.SearchRow].self, from: Data("[\(json.joined(separator: ","))]".utf8))
    }

    /// Among rows that all overrun, the one that overruns least is the closest
    /// to the recording playing, however its listed length compares.
    func testTheSmallestOverrunWinsAmongOverrunningCandidates() throws {
        let rows = try rows([(247, 265.8), (249, 255), (248.5, 258)])
        let match = try XCTUnwrap(OnlineLyrics.bestCandidate(in: rows, for: Self.identity).match)
        XCTAssertFalse(match.fits)
        XCTAssertEqual(try XCTUnwrap(match.timeline.overrun), 255 - 248, accuracy: 0.011)
    }

    /// Equal overruns fall back to the closest listed length.
    func testTheClosestListedLengthBreaksATie() throws {
        let rows = try rows([(246, 265.8), (248.2, 265.8), (250.5, 265.8)])
        let match = try XCTUnwrap(OnlineLyrics.bestCandidate(in: rows, for: Self.identity).match)
        // Same stamps, so the stamps cannot say which row won; the row's own
        // length is not in the timeline. Ask for the winner by removing the
        // two that lose and comparing: the same call with the winner alone
        // must give the same timeline.
        let alone = try XCTUnwrap(OnlineLyrics.bestCandidate(in: [rows[1]], for: Self.identity).match)
        XCTAssertEqual(match.timeline, alone.timeline)
        XCTAssertEqual(try XCTUnwrap(match.timeline.overrun), 265.8 - 248, accuracy: 0.011)
    }

    /// A row that fits still outranks every overrunning one.
    func testARowThatFitsBeatsAnySmallerOverrun() throws {
        let rows = try rows([(248, 251.5), (250.9, 247)])
        let match = try XCTUnwrap(OnlineLyrics.bestCandidate(in: rows, for: Self.identity).match)
        XCTAssertTrue(match.fits)
    }

    private final class Server: @unchecked Sendable {
        let exact: String
        let search: String
        init(exact: String, search: String) { self.exact = exact; self.search = search }
        func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            let url = request.url!
            let body = url.path.hasSuffix("/get") ? exact : search
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func exactBody(last: Double) -> String {
        let body = Self.lrc(last: last).replacingOccurrences(of: "\n", with: "\\n")
        return #"{"syncedLyrics":"\#(body)","instrumental":false,"duration":248}"#
    }

    private func searchBody(_ specs: [(duration: Double, last: Double)]) throws -> String {
        let json = specs.map { spec -> String in
            let body = Self.lrc(last: spec.last).replacingOccurrences(of: "\n", with: "\\n")
            return #"{"trackName":"Synthetic Song","artistName":"Synthetic Artist","duration":\#(spec.duration),"syncedLyrics":"\#(body)","instrumental":false}"#
        }
        return "[\(json.joined(separator: ","))]"
    }

    /// The exact answer used to be held first and last: any search row that
    /// also overran was ignored, however much less.
    func testASearchRowThatOverrunsLessReplacesAnOverrunningExactAnswer() async throws {
        let server = Server(exact: exactBody(last: 265.8), search: try searchBody([(248, 255)]))
        let outcome = await OnlineLyrics.lookUp(Self.identity) { try server.answer($0) }
        guard case .found(let timeline) = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
        XCTAssertEqual(try XCTUnwrap(timeline.overrun), 255 - 248, accuracy: 0.011)
    }

    func testAnExactAnswerThatOverrunsLessIsKept() async throws {
        let server = Server(exact: exactBody(last: 255), search: try searchBody([(248, 265.8)]))
        let outcome = await OnlineLyrics.lookUp(Self.identity) { try server.answer($0) }
        guard case .found(let timeline) = outcome else { return XCTFail("expected lyrics, got \(outcome)") }
        XCTAssertEqual(try XCTUnwrap(timeline.overrun), 255 - 248, accuracy: 0.011)
    }

    // MARK: - The cache keeps it

    /// A hit is cached with only the lines the clock can reach, so the flag
    /// has to be stored beside them. A hit cached without it (format 2) is
    /// asked about once more, which is how a song already in the cache learns
    /// that it is timed for a longer version.
    func testTheOverrunSurvivesTheCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timeline = try Self.found(Self.response(), duration: Self.duration)
        let cache = OnlineLyricsCache(directory: directory)
        cache.remember(.found(timeline), for: Self.identity)
        XCTAssertEqual(cache.cached(Self.identity)??.overrun, timeline.overrun)
        XCTAssertFalse(cache.needsRefresh(Self.identity))

        await cache.flushForTests()
        let relaunched = OnlineLyricsCache(directory: directory)
        XCTAssertEqual(relaunched.cached(Self.identity)??.overrun, timeline.overrun)
        XCTAssertEqual(relaunched.cached(Self.identity)??.timedForLongerVersion, true)
    }

    func testAHitCachedBeforeTheOverrunWasKeptIsRefreshedOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = try JSONSerialization.jsonObject(with: JSONEncoder().encode([LyricsStore.Line(at: 1, text: "Old", end: 2)]))
        let stored: [String: Any] = [
            OnlineLyricsCache.key(Self.identity): [
                "lines": lines, "checkedAt": Date().timeIntervalSinceReferenceDate, "format": 2,
            ],
        ]
        try JSONSerialization.data(withJSONObject: stored).write(to: directory.appendingPathComponent("cache.json"))
        let cache = OnlineLyricsCache(directory: directory)
        XCTAssertNil(cache.cached(Self.identity)??.overrun)
        XCTAssertTrue(cache.needsRefresh(Self.identity))
    }

    // MARK: - Sync Here

    @MainActor
    private struct Rig {
        let store: LyricsStore
        let directory: URL
        let suiteName: String
        let suite: UserDefaults

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("version-\(UUID())", isDirectory: true)
            suiteName = "com.ctimothe.isla.version.\(UUID())"
            suite = UserDefaults(suiteName: suiteName)!
            store = LyricsStore(offsetsDirectory: directory, defaults: suite)
        }

        func relaunched() -> LyricsStore { LyricsStore(offsetsDirectory: directory, defaults: suite) }

        func release() {
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func overrunningTimeline() throws -> LyricTimeline {
        try Self.found(Self.response(), duration: Self.duration)
    }

    /// The voice is ahead of the lyric: at 6.3 s the singer is on the first
    /// line, stamped 16.3 s. The lines have to come earlier, a negative
    /// delay, and afterwards that line is current at that very moment through
    /// the same arithmetic every surface reads.
    func testSyncHereWhenTheVoiceIsAheadOfTheLyric() throws {
        let rig = Rig()
        defer { rig.release() }
        let timeline = LyricTimeline(lines: LyricsStore.Line.fixture(Self.stamps()), granularity: .line)
        rig.store.present(.ready(timeline))
        rig.store.activateTrackOffset(for: Self.identity)

        rig.store.syncTrackOffset(toLineAt: 16.3, position: 6.3, precisionSync: false)

        let lead = LyricSweep.lead(precisionSync: false, userOffset: 0, trackOffset: 0)
        XCTAssertEqual(rig.store.trackOffset, 6.3 + lead - 16.3, accuracy: 0.0001)
        XCTAssertLessThan(rig.store.trackOffset, 0, "positive is later; the lines must come earlier")
        Self.assertCurrent(0, at: 6.3, store: rig.store, lines: timeline.lines)
    }

    /// And the other way: the lyric is ahead of the voice.
    func testSyncHereWhenTheVoiceIsBehindTheLyric() throws {
        let rig = Rig()
        defer { rig.release() }
        let timeline = LyricTimeline(lines: LyricsStore.Line.fixture(Self.stamps()), granularity: .line)
        rig.store.present(.ready(timeline))
        rig.store.activateTrackOffset(for: Self.identity)

        rig.store.syncTrackOffset(toLineAt: timeline.lines[1].at, position: 30, precisionSync: false)

        XCTAssertGreaterThan(rig.store.trackOffset, 0)
        Self.assertCurrent(1, at: 30, store: rig.store, lines: timeline.lines)
    }

    /// The global Lyric Delay stays in force, so the per-track layer is only
    /// what is left: a sync made with +0.4 s global still lands the line.
    /// Precision sync reads the same lead model, and the sync must agree.
    func testSyncHereLeavesTheGlobalDelayInForce() throws {
        let rig = Rig()
        defer { rig.release() }
        let timeline = LyricTimeline(lines: LyricsStore.Line.fixture(Self.stamps()), granularity: .line)
        rig.store.present(.ready(timeline))
        rig.store.activateTrackOffset(for: Self.identity)
        rig.store.userOffset = 0.4

        rig.store.syncTrackOffset(toLineAt: timeline.lines[5].at, position: 70.123, precisionSync: true)
        Self.assertCurrent(5, at: 70.123, store: rig.store, lines: timeline.lines, precision: true)
    }

    private static func assertCurrent(
        _ index: Int, at position: TimeInterval, store: LyricsStore, lines: [LyricsStore.Line],
        precision: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) {
        let now = LyricSweep.position(
            position, precisionSync: precision, userOffset: store.userOffset, trackOffset: store.trackOffset
        )
        XCTAssertEqual(LyricSweep.index(in: lines, at: now), index, "the synced line is the current one", file: file, line: line)
        // And only from this moment: a hair earlier is still the line before.
        let before = LyricSweep.position(
            position - 0.01, precisionSync: precision, userOffset: store.userOffset, trackOffset: store.trackOffset
        )
        XCTAssertEqual(LyricSweep.index(in: lines, at: before), index > 0 ? index - 1 : nil, file: file, line: line)
    }

    /// Through the same store the Earlier and Later steppers use, so it
    /// survives a relaunch and is keyed by the track.
    func testSyncHereIsPersistedPerTrack() throws {
        let rig = Rig()
        defer { rig.release() }
        rig.store.present(.ready(try overrunningTimeline()))
        rig.store.activateTrackOffset(for: Self.identity)
        rig.store.syncTrackOffset(toLineAt: 16.3, position: 6.3, precisionSync: false)
        let synced = rig.store.trackOffset

        let again = rig.relaunched()
        XCTAssertEqual(again.trackOffset(for: Self.identity), synced, accuracy: 0.0001)
        let other = LocalTrackIdentity(
            playerID: "yandex", title: "Another", artist: "Synthetic Artist", album: "", duration: 200, recordingID: nil
        )
        XCTAssertEqual(again.trackOffset(for: other), 0, "no other track moved")
    }

    func testSyncHereWithNothingActiveDoesNothing() {
        let rig = Rig()
        defer { rig.release() }
        rig.store.syncTrackOffset(toLineAt: 16.3, position: 6.3, precisionSync: false)
        XCTAssertEqual(rig.store.trackOffset, 0)
    }

    // MARK: - Range

    /// 1.5 s could not undo a 10 s mismatch. The limit is 45 s now, for the
    /// steppers and for Sync Here alike, and no further.
    func testThePerTrackRangeIsFortyFiveSeconds() throws {
        XCTAssertEqual(LyricsStore.trackOffsetLimit, 45)
        let rig = Rig()
        defer { rig.release() }
        rig.store.present(.ready(try overrunningTimeline()))
        rig.store.activateTrackOffset(for: Self.identity)

        for _ in 0..<40 { rig.store.nudgeTrackOffset(by: 0.25) }
        XCTAssertEqual(rig.store.trackOffset, 10, accuracy: 0.0001, "a ten second correction is possible by hand")
        for _ in 0..<10 { rig.store.nudgeTrackOffset(by: 10) }
        XCTAssertEqual(rig.store.trackOffset, 45, "clamped at +45")
        for _ in 0..<10 { rig.store.nudgeTrackOffset(by: -10) }
        XCTAssertEqual(rig.store.trackOffset, -45, "clamped at -45")

        rig.store.syncTrackOffset(toLineAt: 200, position: 1, precisionSync: false)
        XCTAssertEqual(rig.store.trackOffset, -45, "a sync past the range is clamped, not refused")
        XCTAssertEqual(rig.relaunched().trackOffset(for: Self.identity), -45)
    }

    // MARK: - The notice

    func testTheNoticeShowsOnlyWhileTheTimelineOverrunsAndClearsAfterASync() throws {
        let rig = Rig()
        defer { rig.release() }
        rig.store.present(.ready(try overrunningTimeline()))
        rig.store.activateTrackOffset(for: Self.identity)
        XCTAssertTrue(rig.store.showsVersionMismatchNotice)

        rig.store.syncTrackOffset(toLineAt: 16.3, position: 6.3, precisionSync: false)
        XCTAssertFalse(rig.store.showsVersionMismatchNotice, "the listener dealt with it")

        rig.store.clearTrackOffset()
        XCTAssertTrue(rig.store.showsVersionMismatchNotice, "reset brings the notice back")

        rig.store.present(.ready(try Self.found(Self.response(), duration: 267)))
        XCTAssertFalse(rig.store.showsVersionMismatchNotice, "a timeline that fits has nothing to say")
        rig.store.present(.ready(LyricTimeline(lines: LyricsStore.Line.fixture(Self.stamps()), granularity: .line)))
        XCTAssertFalse(rig.store.showsVersionMismatchNotice, "nor one with an unknown length")
        rig.store.present(.noLocalLyrics)
        XCTAssertFalse(rig.store.showsVersionMismatchNotice)
    }

    // MARK: - The stage

    private static let size = CGSize(width: 504, height: 240)

    /// The stage says it once, in a row under the header, and VoiceOver reaches
    /// it as text; a row offers Sync Here as a named action; performing it
    /// lights that row at this moment and takes the notice away.
    func testTheStageShowsTheNoticeAndOffersSyncHere() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(elapsed: 27), on: isolated.stores.media)
        let timeline = try overrunningTimeline()
        let rig = Rig()
        defer { rig.release() }
        rig.store.present(.ready(timeline))
        rig.store.activateTrackOffset(for: Self.identity)

        let stage = LyricsStage(media: isolated.stores.media, lyrics: rig.store, dismiss: {})
            .defaultAppStorage(isolated.suite)
        let root = await AXProbe.tree(of: stage, size: Self.size)

        let notice = "These lyrics are timed for a longer version of the song and may run late. "
            + "Right-click the line being sung and choose Sync Here."
        XCTAssertNotNil(
            root.all { $0.label == notice || $0.title == notice || $0.value == notice }.first,
            "the notice is not in the tree\n\(root.dump)"
        )

        let synchronizable = root.all { $0.customActions.contains("Sync Here") }
        let target = try XCTUnwrap(synchronizable.first, "no row offers Sync Here\n\(root.dump)")
        let index = try XCTUnwrap(timeline.lines.firstIndex { $0.text == target.label }, "the row is a line of the song")

        XCTAssertTrue(target.perform(named: "Sync Here"), root.dump)
        let media = isolated.stores.media
        let now = LyricSweep.position(
            media.extrapolatedPosition(), precisionSync: media.precisionSync,
            userOffset: rig.store.userOffset, trackOffset: rig.store.trackOffset
        )
        XCTAssertEqual(LyricSweep.index(in: timeline.lines, at: now), index, "the chosen line is current now")
        XCTAssertNotEqual(rig.store.trackOffset, 0)

        let after = await root.reread(settle: 0.3)
        XCTAssertNil(
            after.all { $0.label == notice || $0.title == notice || $0.value == notice }.first,
            "the notice is gone once synced\n\(after.dump)"
        )
    }

    /// Sync Here is for any bad master, so a timeline that fits offers it too
    /// — with no notice, since there is nothing to warn about.
    func testTheStageOffersSyncHereWithoutANoticeWhenTheLyricFits() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(elapsed: 27), on: isolated.stores.media)
        let rig = Rig()
        defer { rig.release() }
        rig.store.present(.ready(try Self.found(Self.response(), duration: 267)))
        rig.store.activateTrackOffset(for: Self.identity)

        let stage = LyricsStage(media: isolated.stores.media, lyrics: rig.store, dismiss: {})
            .defaultAppStorage(isolated.suite)
        let root = await AXProbe.tree(of: stage, size: Self.size)
        XCTAssertFalse(root.all { $0.customActions.contains("Sync Here") }.isEmpty, root.dump)
        XCTAssertTrue(
            root.all { $0.label.hasPrefix("These lyrics are timed for a longer version") }.isEmpty,
            "no notice for a lyric that fits\n\(root.dump)"
        )
    }

    /// A row drawn without a Sync Here handler — the lock card's — offers no
    /// such action.
    func testARowWithoutAHandlerOffersNoSyncAction() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let row = LyricRow(
            line: .init(at: 1, text: "Card line"), isCurrent: false, distance: 1, at: 0, end: 5
        )
        let root = await AXProbe.tree(of: row, size: CGSize(width: 300, height: 60))
        XCTAssertNotNil(root.first(label: "Card line"), root.dump)
        XCTAssertTrue(root.all { $0.customActions.contains("Sync Here") }.isEmpty, root.dump)
    }
}

private extension LyricsStore.Line {
    static func fixture(_ stamps: [Double]) -> [LyricsStore.Line] {
        stamps.enumerated().map { LyricsStore.Line(at: $1, text: "Line \($0)") }
    }
}
