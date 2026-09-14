import XCTest
@testable import IslaKit

/// One clock for every lyric surface.
@MainActor
final class LyricSweepTests: XCTestCase {

    /// The live Spotify probe measured the precision surface 178ms behind at
    /// p95 with a 150ms lead. A 250ms lead brings that measured tail under
    /// the 150ms release gate without asking listeners to nudge every track.
    func testTheMeasuredClockLagCalibratesTheSharedDefaultLead() {
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: -0.4), -0.15, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 1.2), 1.45, accuracy: 0.0001)
        XCTAssertEqual(
            LyricSweep.position(10, precisionSync: true, userOffset: 0.5), 10.75, accuracy: 0.0001
        )
    }

    /// The listener's global correction and the local track nudge sum at read.
    func testLeadSumsTheLocalOffsetLayers() {
        XCTAssertEqual(
            LyricSweep.lead(precisionSync: false, userOffset: 1.0, trackOffset: 0.25),
            1.5, accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricSweep.lead(precisionSync: true, userOffset: -0.5, trackOffset: -0.1),
            -0.35, accuracy: 0.0001
        )
    }

    /// The defaulted layers keep every caller on the calibrated shared clock.
    func testLeadDefaultsUseTheCalibratedValues() {
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: 0), 0.25, accuracy: 0.0001)
    }

    func testPositionCarriesBothLocalOffsetLayers() {
        XCTAssertEqual(
            LyricSweep.position(10, precisionSync: true, userOffset: 0.5, trackOffset: -0.25),
            10.5, accuracy: 0.0001
        )
    }

    func testLocalTrackOffsetPersistsByBoundIdentity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
        let store = LyricsStore(offsetsDirectory: root)
        store.activateTrackOffset(for: identity)
        store.nudgeTrackOffset(by: 0.25)

        let reloaded = LyricsStore(offsetsDirectory: root)

        XCTAssertEqual(reloaded.trackOffset(for: identity), 0.25, accuracy: 0.001)
    }

    /// Word timing wins wherever a source carried it; the singing-speed estimate
    /// is only for lines that never got any.
    func testWordTimingWinsOverTheEstimate() {
        let timed = LyricsStore.Line(
            at: 0,
            text: "one two",
            words: [
                LyricWord(at: 0, text: "one", end: 1),
                LyricWord(at: 1, text: "two", end: 2),
            ]
        )
        XCTAssertEqual(
            LyricSweep.fraction(line: timed, at: 1, end: 2),
            LyricSweep.wordFraction(words: timed.words, at: 1, lineEnd: 2),
            accuracy: 0.0001
        )

        let untimed = LyricsStore.Line(at: 0, text: "one two")
        let span = LyricsStore.sweepSpan(text: untimed.text, slot: 2)
        XCTAssertEqual(LyricSweep.fraction(line: untimed, at: 1, end: 2), 1 / span, accuracy: 0.0001)
    }

    func testTheFractionNeverLeavesZeroToOne() {
        let line = LyricsStore.Line(at: 10, text: "a line of words")
        XCTAssertEqual(LyricSweep.fraction(line: line, at: 0, end: 20), 0, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.fraction(line: line, at: 9_999, end: 20), 1, accuracy: 0.0001)
    }

    /// The frozen-position case, which is what "pause it and the words go" was.
    func testAPositionBeforeTheFirstLineStillHasSomethingToShow() throws {
        let lines = [
            LyricsStore.Line(at: 1.58, text: "first"),
            LyricsStore.Line(at: 18.2, text: "second"),
        ]
        let early = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 0.4))
        XCTAssertEqual(early.line.text, "first")
        XCTAssertFalse(early.swept)
        XCTAssertEqual(early.end, 18.2, accuracy: 0.0001)
    }
}
