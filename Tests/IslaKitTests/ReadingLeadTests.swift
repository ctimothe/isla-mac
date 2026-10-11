import Combine
import XCTest
@testable import IslaKit

/// ly/READ-01: the island's one-line caption shows the next line a beat before
/// it is sung, because a person singing along reads a line before they voice
/// it. The timing of the highlight is untouched; only which line the caption
/// holds changes, as a pure function of the clock position.
@MainActor
final class ReadingLeadTests: XCTestCase {
    nonisolated(unsafe) private let fileManager = FileManager.default
    nonisolated(unsafe) private var root = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - The pure function

    private func continuous() -> [LyricsStore.Line] {
        [
            LyricsStore.Line(at: 10, text: "a"),
            LyricsStore.Line(at: 14, text: "b"),
            LyricsStore.Line(at: 18, text: "c"),
        ]
    }

    func testAFourSecondContinuousLineHandsOverHalfASecondEarly() throws {
        let lines = continuous()
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: 0.5)), 13.5, accuracy: 1e-9)

        let before = LyricSweep.readingMoment(in: lines, at: 13.49, readAhead: 0.5)
        XCTAssertEqual(before.current, 0, "still the sung line until the early moment")
        let at = LyricSweep.readingMoment(in: lines, at: 13.5, readAhead: 0.5)
        XCTAssertNil(at.current, "the next line is drawn like an upcoming line, not as sung")
        XCTAssertEqual(at.centre, 1)
        XCTAssertEqual(at.upcoming, 1)
        // And the voice arriving does not change it: line b is then current.
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 14, readAhead: 0.5).current, 1)
    }

    func testAShortLineGivesAwayAtMostFortyFivePercentOfItself() throws {
        let lines = [
            LyricsStore.Line(at: 10, text: "a"),
            LyricsStore.Line(at: 10.8, text: "b"),
            LyricsStore.Line(at: 20, text: "c"),
        ]
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: 0.5)), 10.8 - 0.36, accuracy: 1e-9)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 10.43, readAhead: 0.5).current, 0)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 10.45, readAhead: 0.5).centre, 1)
        // Two lines stamped at one moment (a bilingual LRC) have no room.
        let twins = [LyricsStore.Line(at: 10, text: "a"), LyricsStore.Line(at: 10, text: "b")]
        XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: twins, readAhead: 0.5))
    }

    func testAnHonouredGapAlreadyShowsTheNextLineFromItsEnd() {
        let lines = [
            LyricsStore.Line(at: 10, text: "a", end: 12),
            LyricsStore.Line(at: 20, text: "b"),
        ]
        XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: 0.5))
        for at in stride(from: 0.0, through: 30.0, by: 0.05) {
            XCTAssertEqual(
                LyricSweep.readingMoment(in: lines, at: at, readAhead: 0.5),
                LyricSweep.moment(in: lines, at: at), "at \(at)"
            )
        }
    }

    func testTheEarlyMomentNeverPrecedesThePreviousLinesFinalWord() throws {
        var lines = continuous()
        lines[0].words = [
            LyricWord(at: 10, text: "one", end: 11),
            LyricWord(at: 13.8, text: "two", end: nil),
        ]
        // 14 - 0.5 = 13.5 would cut the last word off; it waits for the word.
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: 0.5)), 13.8, accuracy: 1e-9)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.7, readAhead: 0.5).current, 0)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.8, readAhead: 0.5).centre, 1)
        // A final word that starts at the next stamp leaves no early moment.
        lines[0].words[1] = LyricWord(at: 14, text: "two", end: nil)
        XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: 0.5))
    }

    func testZeroReadAheadReproducesTodaysAnswerEverywhere() {
        let fixtures: [[LyricsStore.Line]] = [
            continuous(),
            [
                LyricsStore.Line(at: 5, text: "a", end: 9), LyricsStore.Line(at: 20, text: "b"),
                LyricsStore.Line(at: 20.6, text: "c"), LyricsStore.Line(at: 26, text: "d", end: 31),
            ],
            [LyricsStore.Line(at: 1, text: "only")],
        ]
        for lines in fixtures {
            for at in stride(from: -1.0, through: 40.0, by: 0.01) {
                XCTAssertEqual(
                    LyricSweep.readingMoment(in: lines, at: at, readAhead: 0),
                    LyricSweep.moment(in: lines, at: at), "at \(at)"
                )
            }
        }
    }

    func testIntroAndOutroAreUnchanged() {
        let lines = [LyricsStore.Line(at: 10, text: "a"), LyricsStore.Line(at: 14, text: "b", end: 18)]
        for at in [0.0, 5, 9.99, 18, 25, 100] {
            XCTAssertEqual(
                LyricSweep.readingMoment(in: lines, at: at, readAhead: 0.5),
                LyricSweep.moment(in: lines, at: at), "at \(at)"
            )
        }
    }

    func testTheSamePositionGivesTheSameAnswerAfterASeek() {
        let lines = continuous()
        let first = LyricSweep.readingMoment(in: lines, at: 13.6, readAhead: 0.5)
        _ = LyricSweep.readingMoment(in: lines, at: 2, readAhead: 0.5)
        _ = LyricSweep.readingMoment(in: lines, at: 17.9, readAhead: 0.5)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.6, readAhead: 0.5), first)
    }

    func testTheSweepOfTheCurrentLineIsUnchangedEverywhere() {
        let lines = [
            LyricsStore.Line(
                at: 10, text: "one two",
                words: [LyricWord(at: 10, text: "one", end: 11), LyricWord(at: 11, text: "two", end: nil)]
            ),
            LyricsStore.Line(at: 14, text: "b"),
        ]
        for wordTiming in [false, true] {
            for at in stride(from: 9.0, through: 16.0, by: 0.05) {
                let inputs = LyricInputs(
                    position: at - LyricSweep.standardLead, precisionSync: false, userOffset: 0, trackOffset: 0,
                    wordTiming: wordTiming
                )
                let early = LyricSweep.resolve(lines: lines, inputs: inputs, readAhead: 0.5)
                let plain = LyricSweep.resolve(lines: lines, inputs: inputs)
                if early.current != nil {
                    XCTAssertEqual(early, plain, "while the old line is still sung nothing differs, at \(at)")
                } else if plain.current != nil {
                    XCTAssertEqual(early.fraction, 0, "the early line is unswept")
                    XCTAssertEqual(early.centre, 1)
                }
            }
        }
    }

    func testDisplayedAnswersTheSungLineUnlessAskedToReadAhead() throws {
        let lines = continuous()
        let sung = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 13.7))
        XCTAssertEqual(sung.line.text, "a")
        XCTAssertTrue(sung.swept)
        let early = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 13.7, readAhead: 0.5))
        XCTAssertEqual(early.line.text, "b")
        XCTAssertFalse(early.swept)
    }

    // MARK: - The caption path

    func testTheCaptionResolvesThroughTheSharedFunctionAndTheOtherSurfacesDoNot() throws {
        let lines = continuous()
        // Lead 0.2: position 13.35 reads as 13.55, past the early moment.
        let inputs = LyricInputs(
            position: 13.35, precisionSync: false, userOffset: 0, trackOffset: 0, wordTiming: false
        )
        let caption = try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs, readAhead: 0.5))
        XCTAssertEqual(caption.centre, 1)
        XCTAssertNil(caption.current)
        XCTAssertEqual(caption.fraction, 0)
        XCTAssertEqual(caption, LyricSweep.resolve(lines: lines, inputs: inputs, readAhead: 0.5))

        let off = try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs, readAhead: 0))
        XCTAssertEqual(off.centre, 0)
        XCTAssertEqual(off.current, 0)
        // The default is today's behaviour, so the Lyric Delay preview, the
        // stage and the card keep it without being asked.
        XCTAssertEqual(try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs)), off)
        XCTAssertEqual(LyricsStage.resolve(lines: lines, inputs: inputs), off)
        XCTAssertEqual(LockScreenCard.resolve(lines: lines, inputs: inputs), off)
    }

    // MARK: - The setting

    private func makeStore(_ defaults: UserDefaults) -> LyricsStore {
        LyricsStore(offsetsDirectory: root.appendingPathComponent("offsets"), defaults: defaults)
    }

    func testTheSettingDefaultsToHalfASecondAndClampsToTheAllowedValues() throws {
        let suite = "ReadingLeadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(defaults)
        XCTAssertEqual(store.readAhead, 0.5)
        XCTAssertEqual(LyricsStore.readAheadKey, "lyrics.readAhead")

        store.readAhead = 0
        XCTAssertEqual(store.readAhead, 0, "Off is a choice, not an absent value")
        XCTAssertEqual(makeStore(defaults).readAhead, 0)

        store.readAhead = 0.3
        XCTAssertEqual(store.readAhead, 0.25)
        store.readAhead = 9
        XCTAssertEqual(store.readAhead, 0.75)
        store.readAhead = -2
        XCTAssertEqual(store.readAhead, 0)
        XCTAssertEqual(defaults.double(forKey: LyricsStore.readAheadKey), 0)

        defaults.set(0.61, forKey: LyricsStore.readAheadKey)
        XCTAssertEqual(makeStore(defaults).readAhead, 0.5, "a hand-edited value snaps to the nearest option")
        defaults.set(Double.nan, forKey: LyricsStore.readAheadKey)
        XCTAssertEqual(makeStore(defaults).readAhead, 0.5, "garbage is the default")
    }

    // MARK: - The wakes

    func testTheCoordinatorWakesTheCaptionOnTimeAndReRegistersWhenTheSettingChanges() throws {
        let url = root.appendingPathComponent("ends.lrc")
        try Data("""
        [ti:Song]
        [ar:Artist]
        [al:Album]
        [length:03:00]
        [00:10.00]One
        [00:15.00]
        [00:26.30]Two
        [00:30.00]
        [00:30.80]Three
        [00:40.00]
        """.utf8).write(to: url, options: .atomic)
        let library = LocalLyricsLibrary(directory: root)
        _ = try library.importDocument(at: url, binding: nil)
        let media = MediaController()
        media.isolateFromPlayers()
        let suite = "ReadingLeadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(defaults)
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { true }, presentation: store
        )
        coordinator.start()
        defer { coordinator.stop() }
        media.apply(playingSnapshot())
        guard case .ready = coordinator.availability else {
            return XCTFail("the fixture: the local file is the answer, got \(coordinator.availability)")
        }

        // One -> Two has an honoured end (no early switch). Two -> Three is
        // continuous: Two's empty stamp 0.8 s before Three is a breath, not an
        // honoured end, so the caption turns to Three early.
        func assertBoundaries(_ expected: [TimeInterval], _ note: String, line: UInt = #line) {
            let actual = media.lyricBoundariesForTests
            XCTAssertEqual(actual.count, expected.count, note, line: line)
            for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 1e-9, note, line: line) }
        }
        assertBoundaries([10, 15, 26.3, 30.8 - 0.5, 30.8, 40], "default 0.5 s")

        store.readAhead = 0.25
        assertBoundaries([10, 15, 26.3, 30.8 - 0.25, 30.8, 40], "0.25 s")
        store.readAhead = 0
        assertBoundaries([10, 15, 26.3, 30.8, 40], "Off registers nothing extra")
        store.readAhead = 0.75
        assertBoundaries([10, 15, 26.3, 30.8 - 0.75, 30.8, 40], "0.75 s")
    }

    private func playingSnapshot() -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Song"
        snapshot.artist = "Artist"
        snapshot.album = "Album"
        snapshot.duration = 180
        snapshot.elapsed = 4
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 42
        return snapshot
    }
}
