import Combine
import XCTest
@testable import IslaKit

/// ly/READ-01: the island's one-line caption shows the next line a beat before
/// it is sung, because a person singing along reads a line before they voice
/// it. The timing of the highlight is untouched; only which line the caption
/// holds changes, as a pure function of the clock position.
///
/// ly/READ-02: the default is Auto, an early time that follows the length of
/// the line about to be read (0.30 s for a few words, 0.50 s from fifty
/// characters), because a fixed half second was perfect on a slow ballad of
/// long lines and a bit much elsewhere. The fixed 0.3 s and 0.5 s choices
/// behave exactly as READ-01's fixed values did.
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
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .half)), 13.5, accuracy: 1e-9)

        let before = LyricSweep.readingMoment(in: lines, at: 13.49, readAhead: .half)
        XCTAssertEqual(before.current, 0, "still the sung line until the early moment")
        let at = LyricSweep.readingMoment(in: lines, at: 13.5, readAhead: .half)
        XCTAssertNil(at.current, "the next line is drawn like an upcoming line, not as sung")
        XCTAssertEqual(at.centre, 1)
        XCTAssertEqual(at.upcoming, 1)
        // And the voice arriving does not change it: line b is then current.
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 14, readAhead: .half).current, 1)
    }

    func testAShortLineGivesAwayAtMostFortyFivePercentOfItself() throws {
        let lines = [
            LyricsStore.Line(at: 10, text: "a"),
            LyricsStore.Line(at: 10.8, text: "b"),
            LyricsStore.Line(at: 20, text: "c"),
        ]
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .half)), 10.8 - 0.36, accuracy: 1e-9)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 10.43, readAhead: .half).current, 0)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 10.45, readAhead: .half).centre, 1)
        // Two lines stamped at one moment (a bilingual LRC) have no room.
        let twins = [LyricsStore.Line(at: 10, text: "a"), LyricsStore.Line(at: 10, text: "b")]
        XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: twins, readAhead: .half))
    }

    func testAnHonouredGapAlreadyShowsTheNextLineFromItsEnd() {
        let lines = [
            LyricsStore.Line(at: 10, text: "a", end: 12),
            LyricsStore.Line(at: 20, text: "b"),
        ]
        XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .half))
        for at in stride(from: 0.0, through: 30.0, by: 0.05) {
            XCTAssertEqual(
                LyricSweep.readingMoment(in: lines, at: at, readAhead: .half),
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
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .half)), 13.8, accuracy: 1e-9)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.7, readAhead: .half).current, 0)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.8, readAhead: .half).centre, 1)
        // A final word that starts at the next stamp leaves no early moment.
        lines[0].words[1] = LyricWord(at: 14, text: "two", end: nil)
        XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .half))
    }

    // MARK: - Auto (ly/READ-02)

    /// A continuous song whose second line has `text`; the first line is four
    /// seconds long, so the 45 percent cap (1.8 s) never binds.
    private func transition(into text: String) -> [LyricsStore.Line] {
        [
            LyricsStore.Line(at: 10, text: "a"),
            LyricsStore.Line(at: 14, text: text),
            LyricsStore.Line(at: 18, text: "c"),
        ]
    }

    private func autoLead(into text: String) throws -> TimeInterval {
        let lines = transition(into: text)
        return 14 - (try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .auto)))
    }

    func testAutoFollowsTheLengthOfTheNextLine() throws {
        // A very short line: the floor.
        XCTAssertEqual(try autoLead(into: "Oh"), 0.308, accuracy: 1e-9)
        XCTAssertEqual(LyricReadAhead.automaticSeconds(forCharacters: 0), 0.30, accuracy: 1e-12)
        // Thirty characters: 0.30 + 0.004 * 30.
        let thirty = String(repeating: "x", count: 30)
        XCTAssertEqual(try autoLead(into: thirty), 0.42, accuracy: 1e-9)
        // Fifty and beyond: the ceiling.
        XCTAssertEqual(try autoLead(into: String(repeating: "x", count: 50)), 0.50, accuracy: 1e-9)
        XCTAssertEqual(try autoLead(into: String(repeating: "x", count: 200)), 0.50, accuracy: 1e-9)
    }

    func testAutoCountsVisibleCharactersOfTheTrimmedText() throws {
        let thirty = String(repeating: "x", count: 30)
        XCTAssertEqual(try autoLead(into: "  " + thirty + " \n"), 0.42, accuracy: 1e-9, "whitespace is not read")
        // A family emoji is one Character though it is several UTF-16 units.
        let family = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 30)
        XCTAssertEqual(family.count, 30)
        XCTAssertEqual(try autoLead(into: family), 0.42, accuracy: 1e-9)
    }

    func testAutoIsNeverOutsideThirtyAndFiftyHundredthsBeforeTheCaps() {
        var previous = 0.0
        for count in 0...300 {
            let seconds = LyricReadAhead.automaticSeconds(forCharacters: count)
            XCTAssertGreaterThanOrEqual(seconds, 0.30 - 1e-12, "\(count) characters")
            XCTAssertLessThanOrEqual(seconds, 0.50 + 1e-12, "\(count) characters")
            XCTAssertGreaterThanOrEqual(seconds, previous - 1e-12, "longer lines never read earlier")
            previous = seconds
        }
        for fixed in [LyricReadAhead.off, .threeTenths, .half] {
            XCTAssertEqual(fixed.seconds(forNextLine: "anything at all"), fixed.fixedSeconds)
        }
        XCTAssertEqual(LyricReadAhead.threeTenths.fixedSeconds, 0.3)
        XCTAssertEqual(LyricReadAhead.half.fixedSeconds, 0.5)
        XCTAssertEqual(LyricReadAhead.off.fixedSeconds, 0)
        XCTAssertNil(LyricReadAhead.auto.fixedSeconds)
    }

    func testTheCapsStillBindAutoAndMayPullATurnBelowThirtyHundredths() throws {
        // A half-second line cannot give away more than 45 percent of itself,
        // so even Auto's floor of 0.30 s yields 0.225 s here. That is the cap
        // protecting the line being sung, not a hole in the floor.
        let short = [
            LyricsStore.Line(at: 10, text: "a"),
            LyricsStore.Line(at: 10.5, text: String(repeating: "x", count: 80)),
            LyricsStore.Line(at: 20, text: "c"),
        ]
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: short, readAhead: .auto)), 10.5 - 0.225, accuracy: 1e-9)

        // The previous line's final word still holds the turn back.
        var words = transition(into: String(repeating: "x", count: 80))
        words[0].words = [LyricWord(at: 10, text: "one", end: 11), LyricWord(at: 13.8, text: "two", end: nil)]
        XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: words, readAhead: .auto)), 13.8, accuracy: 1e-9)

        // An honoured gap still shows the next line from the end, with no early turn.
        let gap = [
            LyricsStore.Line(at: 10, text: "a", end: 12),
            LyricsStore.Line(at: 20, text: String(repeating: "x", count: 80)),
        ]
        XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: gap, readAhead: .auto))
    }

    func testAutoDrawsTheTurnWhereItSaysAndIsAPureFunctionOfThePosition() throws {
        let lines = transition(into: String(repeating: "x", count: 30))   // turns at 13.58
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.579, readAhead: .auto).current, 0)
        let at = LyricSweep.readingMoment(in: lines, at: 13.58, readAhead: .auto)
        XCTAssertNil(at.current)
        XCTAssertEqual(at.centre, 1)
        let first = LyricSweep.readingMoment(in: lines, at: 13.7, readAhead: .auto)
        _ = LyricSweep.readingMoment(in: lines, at: 2, readAhead: .auto)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.7, readAhead: .auto), first)
    }

    func testTheFixedChoicesBehaveAsTheFixedValuesDid() throws {
        let long = transition(into: String(repeating: "x", count: 80))
        let tiny = transition(into: "Oh")
        for lines in [long, tiny] {
            XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .threeTenths)), 13.7, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .half)), 13.5, accuracy: 1e-9)
            XCTAssertNil(LyricSweep.readAheadStart(before: 1, in: lines, readAhead: .off))
        }
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
                    LyricSweep.readingMoment(in: lines, at: at, readAhead: .off),
                    LyricSweep.moment(in: lines, at: at), "at \(at)"
                )
            }
        }
    }

    func testIntroAndOutroAreUnchanged() {
        let lines = [LyricsStore.Line(at: 10, text: "a"), LyricsStore.Line(at: 14, text: "b", end: 18)]
        for at in [0.0, 5, 9.99, 18, 25, 100] {
            XCTAssertEqual(
                LyricSweep.readingMoment(in: lines, at: at, readAhead: .half),
                LyricSweep.moment(in: lines, at: at), "at \(at)"
            )
        }
    }

    func testTheSamePositionGivesTheSameAnswerAfterASeek() {
        let lines = continuous()
        let first = LyricSweep.readingMoment(in: lines, at: 13.6, readAhead: .half)
        _ = LyricSweep.readingMoment(in: lines, at: 2, readAhead: .half)
        _ = LyricSweep.readingMoment(in: lines, at: 17.9, readAhead: .half)
        XCTAssertEqual(LyricSweep.readingMoment(in: lines, at: 13.6, readAhead: .half), first)
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
                let early = LyricSweep.resolve(lines: lines, inputs: inputs, readAhead: .half)
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
        let early = try XCTUnwrap(LyricSweep.displayed(lines: lines, at: 13.7, readAhead: .half))
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
        let caption = try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs, readAhead: .half))
        XCTAssertEqual(caption.centre, 1)
        XCTAssertNil(caption.current)
        XCTAssertEqual(caption.fraction, 0)
        XCTAssertEqual(caption, LyricSweep.resolve(lines: lines, inputs: inputs, readAhead: .half))

        let off = try XCTUnwrap(MediaPane.captionResolution(lines: lines, inputs: inputs, readAhead: .off))
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

    func testTheSettingDefaultsToAutoAndSurvivesARelaunch() throws {
        let suite = "ReadingLeadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LyricsStore.readAheadKey, "lyrics.readAhead")
        let store = makeStore(defaults)
        XCTAssertEqual(store.readAhead, .auto, "an absent key is Auto")
        XCTAssertNil(defaults.object(forKey: LyricsStore.readAheadKey), "reading the default writes nothing")

        store.readAhead = .off
        XCTAssertEqual(defaults.double(forKey: LyricsStore.readAheadKey), 0)
        XCTAssertNotNil(defaults.object(forKey: LyricsStore.readAheadKey), "Off is a choice, not an absent value")
        XCTAssertEqual(makeStore(defaults).readAhead, .off)

        store.readAhead = .threeTenths
        XCTAssertEqual(defaults.double(forKey: LyricsStore.readAheadKey), 0.3)
        XCTAssertEqual(makeStore(defaults).readAhead, .threeTenths)
        store.readAhead = .half
        XCTAssertEqual(defaults.double(forKey: LyricsStore.readAheadKey), 0.5)
        XCTAssertEqual(makeStore(defaults).readAhead, .half)

        store.readAhead = .auto
        XCTAssertNil(defaults.object(forKey: LyricsStore.readAheadKey), "Auto is the absence of a stored value")
        XCTAssertEqual(makeStore(defaults).readAhead, .auto)
    }

    func testAStoredNumberSnapsToTheNearestFixedChoice() throws {
        let suite = "ReadingLeadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func loaded(_ value: Any) -> LyricReadAhead {
            defaults.set(value, forKey: LyricsStore.readAheadKey)
            return makeStore(defaults).readAhead
        }
        XCTAssertEqual(loaded(0.25), .threeTenths, "READ-01's 0.25 s")
        XCTAssertEqual(loaded(0.75), .half, "READ-01's 0.75 s")
        XCTAssertEqual(loaded(0.5), .half, "READ-01's default stays a fixed 0.5 s")
        XCTAssertEqual(loaded(0.3), .threeTenths)
        XCTAssertEqual(loaded(0.39), .threeTenths)
        XCTAssertEqual(loaded(0.61), .half)
        XCTAssertEqual(loaded(9.0), .half)
        XCTAssertEqual(loaded(0.0), .off)
        XCTAssertEqual(loaded(-2.0), .off)
        XCTAssertEqual(loaded(Double.nan), .auto, "garbage is the default")
        XCTAssertEqual(loaded(Double.infinity), .auto, "garbage is the default")
        XCTAssertEqual(loaded("often"), .auto, "a value of the wrong type is the default")
    }

    // MARK: - The wakes

    func testTheCoordinatorWakesTheCaptionOnTimeAndReRegistersWhenTheSettingChanges() throws {
        let url = root.appendingPathComponent("ends.lrc")
        let longText = "A fairly long line that carries on past fifty characters"
        XCTAssertGreaterThan(longText.count, 50)
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
        [00:36.00]\(longText)
        [00:44.00]
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
        // honoured end, so the caption turns to Three early. Three -> the long
        // line is continuous too. Under Auto the two early times differ
        // because the lines they turn to differ in length.
        func assertBoundaries(_ expected: [TimeInterval], _ note: String, line: UInt = #line) {
            let actual = media.lyricBoundariesForTests
            XCTAssertEqual(actual.count, expected.count, "\(note): \(actual)", line: line)
            for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 1e-9, note, line: line) }
        }
        let three = 0.30 + 0.004 * 5   // "Three"
        assertBoundaries(
            [10, 15, 26.3, 30.8 - three, 30.8, 36 - 0.5, 36, 44],
            "Auto: a short line early by less, a long one by 0.5 s"
        )

        store.readAhead = .threeTenths
        assertBoundaries([10, 15, 26.3, 30.8 - 0.3, 30.8, 36 - 0.3, 36, 44], "0.3 s")
        store.readAhead = .off
        assertBoundaries([10, 15, 26.3, 30.8, 36, 44], "Off registers nothing extra")
        store.readAhead = .half
        assertBoundaries([10, 15, 26.3, 30.8 - 0.5, 30.8, 36 - 0.5, 36, 44], "0.5 s")
        store.readAhead = .auto
        assertBoundaries([10, 15, 26.3, 30.8 - three, 30.8, 36 - 0.5, 36, 44], "back to Auto")
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
