import XCTest
@testable import IslaKit

/// One clock for every lyric surface.
@MainActor
final class LyricSweepTests: XCTestCase {

    /// Two measured terms and no grid. The live Spotify probe put the clock
    /// 0.10s behind the audio; the other 0.10s is the anticipation every
    /// karaoke surface carries. The quarter-second the lead used to hold in
    /// reserve for the ticker's grid is gone with the grid: the clock now
    /// wakes on the frame a line is due (`MediaControllerTests`).
    func testTheMeasuredClockLagCalibratesTheSharedDefaultLead() {
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), 0.20, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: 0), 0.20, accuracy: 0.0001)
        // A delay comes off the lead: +0.4 of delay leaves the line 0.20s late.
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: 0.4), -0.20, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: -1.2), 1.40, accuracy: 0.0001)
        XCTAssertEqual(
            LyricSweep.position(10, precisionSync: true, userOffset: -0.5), 10.70, accuracy: 0.0001
        )
    }

    /// The listener's global correction and the local track nudge sum at read,
    /// and the sum is a delay: it comes off the lead.
    func testLeadSumsTheLocalOffsetLayers() {
        XCTAssertEqual(
            LyricSweep.lead(precisionSync: false, userOffset: -1.0, trackOffset: -0.25),
            1.45, accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricSweep.lead(precisionSync: true, userOffset: 0.5, trackOffset: 0.1),
            -0.40, accuracy: 0.0001
        )
    }

    /// The defaulted layers keep every caller on the calibrated shared clock.
    func testLeadDefaultsUseTheCalibratedValues() {
        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), 0.20, accuracy: 0.0001)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: 0), 0.20, accuracy: 0.0001)
    }

    func testPositionCarriesBothLocalOffsetLayers() {
        XCTAssertEqual(
            LyricSweep.position(10, precisionSync: true, userOffset: -0.5, trackOffset: 0.25),
            10.45, accuracy: 0.0001
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

    /// A nudge corrects the file it was made against, not the song. Nudges
    /// were keyed by player, title, artist, album and length only, so a song
    /// nudged +0.5 s against one file kept the +0.5 s after a correctly timed
    /// file was imported or a retimed edit saved, and the new file came out
    /// half a second wrong (J-024). The key is unchanged — adding the file to
    /// it would have orphaned every nudge already saved — and the entry
    /// records the file instead.
    func testANudgeDoesNotFollowTheSongToAnotherFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LyricSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
        let first = UUID()
        let second = UUID()
        let store = LyricsStore(offsetsDirectory: root, defaults: defaults)
        store.activateTrackOffset(for: identity, documentID: first)
        store.nudgeTrackOffset(by: 0.5)
        XCTAssertEqual(store.trackOffset, 0.5, accuracy: 1e-9)

        store.activateTrackOffset(for: identity, documentID: second)
        XCTAssertEqual(store.trackOffset, 0, accuracy: 1e-9, "another file starts uncorrected")
        // The catalogue's timeline is another file too.
        store.activateTrackOffset(for: identity, documentID: nil)
        XCTAssertEqual(store.trackOffset, 0, accuracy: 1e-9, "nor does it follow onto the catalogue's words")

        store.activateTrackOffset(for: identity, documentID: first)
        XCTAssertEqual(store.trackOffset, 0.5, accuracy: 1e-9, "the file it corrected keeps it")

        // And it survives a relaunch with its file.
        let reloaded = LyricsStore(offsetsDirectory: root, defaults: defaults)
        XCTAssertEqual(reloaded.trackOffset(for: identity, documentID: first), 0.5, accuracy: 1e-9)
        XCTAssertEqual(reloaded.trackOffset(for: identity, documentID: second), 0, accuracy: 1e-9)
    }

    /// J-024's own case: the nudge was made against the catalogue's words,
    /// which carry no document id, and then a correctly timed file was
    /// imported. The catalogue's nudge stays with the catalogue.
    func testACatalogueNudgeDoesNotFollowTheSongToAnImportedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LyricSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
        let store = LyricsStore(offsetsDirectory: root, defaults: defaults)
        store.activateTrackOffset(for: identity, documentID: nil)
        store.nudgeTrackOffset(by: 0.5)

        store.activateTrackOffset(for: identity, documentID: UUID())
        XCTAssertEqual(store.trackOffset, 0, accuracy: 1e-9)

        store.activateTrackOffset(for: identity, documentID: nil)
        XCTAssertEqual(store.trackOffset, 0.5, accuracy: 1e-9, "the catalogue's words keep it")
    }

    /// An entry written before nudges recorded their file says nothing about
    /// which file it corrected, so it goes on applying to whichever one is
    /// showing, exactly as it did. Dropping it would have silently undone
    /// every correction a listener had already made.
    func testANudgeSavedBeforeFilesWereRecordedStillApplies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LyricSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Any store opened on the directory leaves it at the new sign, so the
        // file written below is read as it is.
        _ = LyricsStore(offsetsDirectory: root, defaults: defaults)
        let key = ["test", "Song", "Artist", "Album", "180.000", ""].joined(separator: "\u{1F}")
        // Exactly the shape the previous build wrote: identity and offset,
        // nothing else.
        let saved: [String: Any] = [key: [
            "identity": [
                "playerID": "test", "title": "Song", "artist": "Artist", "album": "Album", "duration": 180,
            ],
            "offset": 0.5,
        ]]
        try JSONSerialization.data(withJSONObject: saved)
            .write(to: root.appendingPathComponent("offsets.json"))
        let identity = LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )

        let store = LyricsStore(offsetsDirectory: root, defaults: defaults)
        store.activateTrackOffset(for: identity, documentID: UUID())
        XCTAssertEqual(store.trackOffset, 0.5, accuracy: 1e-9)
        store.activateTrackOffset(for: identity, documentID: nil)
        XCTAssertEqual(store.trackOffset, 0.5, accuracy: 1e-9)
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

    // MARK: - Which way a correction moves

    /// "Lyric Delay" is a delay. Settings says "negative shows lyrics earlier;
    /// positive, later", the Shortcuts action says the same, and the case it
    /// exists for is the AirPods listener whose lines light before the voice
    /// arrives. The lead used to *add* the correction, so a positive delay lit
    /// every line earlier: the listener followed the note and made it worse.
    func testAPositiveDelayShowsLyricsLater() {
        let lines = [LyricsStore.Line(at: 10, text: "a")]
        // 0.15s before the stamp, inside the 0.20s standard lead: lit.
        XCTAssertEqual(
            LyricSweep.index(
                in: lines, at: LyricSweep.position(9.85, precisionSync: false, userOffset: 0)
            ),
            0
        )
        // Half a second of delay holds the same line back past that moment.
        XCTAssertNil(
            LyricSweep.index(
                in: lines, at: LyricSweep.position(9.85, precisionSync: false, userOffset: 0.5)
            ),
            "a positive delay has to show the line later, not earlier"
        )
    }

    /// The stage's minus button is labelled "Lyrics Earlier" and nudges the
    /// track layer by −0.25. Earlier means a larger lead: the line lights at
    /// a smaller player position.
    func testLyricsEarlierMovesLinesEarlier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LyricSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
        let store = LyricsStore(offsetsDirectory: root, defaults: defaults)
        store.activateTrackOffset(for: identity)
        let before = LyricSweep.lead(
            precisionSync: false, userOffset: store.userOffset, trackOffset: store.trackOffset
        )

        store.nudgeTrackOffset(by: -0.25)

        XCTAssertEqual(
            LyricSweep.lead(
                precisionSync: false, userOffset: store.userOffset, trackOffset: store.trackOffset
            ),
            before + 0.25, accuracy: 0.0001,
            "Lyrics Earlier has to raise the lead"
        )
    }

    /// Flipping the sign must not move a single listener's lyrics. The owner
    /// tuned −0.247 s under the old sign; read under the new one it would have
    /// shifted every line by half a second. So every stored correction — the
    /// global one in defaults, the per-track ones in offsets.json and the
    /// unassigned legacy ones — is negated exactly once, and the effective
    /// lead comes out of the upgrade identical.
    func testTheSignMigrationKeepsEveryListenersTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LyricSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-0.247, forKey: LyricsStore.offsetKey)
        XCTAssertNil(defaults.object(forKey: LyricsStore.offsetSignVersionKey))

        let identity = LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
        // What a shipped build left on disk: written in the old sign, before
        // any marker existed.
        LyricsStore.migrateLegacyOffsets(
            [.init(identity: identity, offset: 0.5)],
            unassigned: [.init(filename: "orphan.lrc4.json", offset: 0.75)],
            directory: root
        )
        let oldLead = LyricSweep.standardLead + (-0.247) + 0.5

        let store = LyricsStore(offsetsDirectory: root, defaults: defaults)
        store.activateTrackOffset(for: identity)

        XCTAssertEqual(store.userOffset, 0.247, accuracy: 1e-9)
        XCTAssertEqual(defaults.double(forKey: LyricsStore.offsetKey), 0.247, accuracy: 1e-9)
        XCTAssertEqual(store.trackOffset, -0.5, accuracy: 1e-9)
        XCTAssertEqual(store.unassignedLegacyOffsets, [.init(filename: "orphan.lrc4.json", offset: -0.75)])
        XCTAssertEqual(
            LyricSweep.lead(
                precisionSync: false, userOffset: store.userOffset, trackOffset: store.trackOffset
            ),
            oldLead, accuracy: 1e-9,
            "the upgrade must leave every line exactly where it was"
        )

        // Once, and only once: a second launch reads what the first wrote.
        let again = LyricsStore(offsetsDirectory: root, defaults: defaults)
        again.activateTrackOffset(for: identity)
        XCTAssertEqual(again.userOffset, 0.247, accuracy: 1e-9)
        XCTAssertEqual(again.trackOffset, -0.5, accuracy: 1e-9)
        XCTAssertEqual(again.unassignedLegacyOffsets, [.init(filename: "orphan.lrc4.json", offset: -0.75)])
    }

    /// The local library re-runs its legacy import whenever its index is
    /// reset, and that import still reads pre-local corrections in the old
    /// sign. Landing in a directory that has already flipped, each one has to
    /// be flipped on the way in, or it would come back inverted.
    func testALegacyOffsetMigratedAfterTheSignFlipKeepsItsTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LyricSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Any store opened on the directory leaves it at the new sign.
        _ = LyricsStore(offsetsDirectory: root, defaults: defaults)

        let identity = LocalTrackIdentity(
            playerID: "legacy", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
        LyricsStore.migrateLegacyOffsets(
            [.init(identity: identity, offset: 0.5)],
            unassigned: [.init(filename: "orphan.lrc4.json", offset: 0.75)],
            directory: root
        )

        let store = LyricsStore(offsetsDirectory: root, defaults: defaults)
        XCTAssertEqual(store.trackOffset(for: identity), -0.5, accuracy: 1e-9)
        XCTAssertEqual(store.unassignedLegacyOffsets, [.init(filename: "orphan.lrc4.json", offset: -0.75)])
    }

    /// A test process never rewrites the listener's own offsets: those belong
    /// to the installed Isla, which may still be a build that adds them. Held
    /// as the pure path check, so a regression here cannot itself touch the
    /// real files.
    func testATestRunLeavesTheInstalledAppsOffsetsAlone() {
        XCTAssertTrue(PlayerBridge.isRunningTests)
        let live = AppPaths.live.supportDirectory
        XCTAssertTrue(LyricsStore.isLiveSupportDirectory(live))
        XCTAssertTrue(LyricsStore.isLiveSupportDirectory(live.appendingPathComponent("lyrics-local")))
        XCTAssertFalse(LyricsStore.isLiveSupportDirectory(
            live.deletingLastPathComponent().appendingPathComponent(live.lastPathComponent + "Other")
        ))
        XCTAssertFalse(LyricsStore.isLiveSupportDirectory(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ))
    }

    // MARK: - The lead as a sum of named terms

    /// The lead used to be one 0.20 s constant, and no constant fits both a
    /// built-in route and a Bluetooth one (lyric lab L7). It is now the sum of
    /// the terms the lab named, each of which can be re-measured on its own;
    /// the two corrections still come off it exactly as before.
    func testTheLeadIsTheSumOfItsNamedTerms() {
        let saved = LyricSweep.model
        defer { LyricSweep.model = saved }
        let rise = Theme.springRiseTime(
            response: Theme.lyricScrollResponse, damping: Theme.lyricScrollDamping, level: 0.5
        )
        LyricSweep.model = LyricLeadModel(
            anchorLag: 0.138, timerWake: 0.0001, frameRate: 120, onsetRise: rise,
            anticipation: 0.040, outputLatency: 0.0273, unmeasuredPlayerDelay: 0.05
        )
        let hand = 0.138 + 0.0001 + 0.5 / 120 + 1.0 / 120 + rise + 0.040 - 0.0273 - 0.05

        XCTAssertEqual(LyricSweep.lead(precisionSync: false, userOffset: 0), hand, accuracy: 1e-9)
        XCTAssertEqual(LyricSweep.lead(precisionSync: true, userOffset: 0), hand, accuracy: 1e-9)
        XCTAssertEqual(
            LyricSweep.lead(precisionSync: false, userOffset: 0.247, trackOffset: 0.1),
            hand - 0.347, accuracy: 1e-9,
            "both corrections are delays and come off the summed lead"
        )
    }

    /// The model is calibrated so that the built-in route at 120 Hz — the
    /// one the shipped 0.20 s was tuned on — keeps exactly that lead.
    func testTheBuiltInRouteKeepsTheShippedLead() {
        let model = LyricLeadModel.calibrated
        XCTAssertEqual(model.frameRate, 120)
        XCTAssertEqual(model.outputLatency, 0.0273, accuracy: 1e-9)
        XCTAssertEqual(model.lead, 0.200, accuracy: 0.001)
        XCTAssertEqual(model.lead, LyricLeadModel.calibrationLead, accuracy: 1e-9, "exactly, not nearly")
        XCTAssertEqual(
            model.unmeasuredPlayerDelay, 0.0672, accuracy: 0.0001,
            "the placeholder is the plan's ~67 ms; a large move here means a term changed under it"
        )
        XCTAssertEqual(LyricSweep.model, model, "the shipped clock starts on the calibrated model")
        XCTAssertEqual(LyricSweep.standardLead, model.lead, accuracy: 1e-12)
        XCTAssertEqual(LyricSweep.precisionLead, model.lead, accuracy: 1e-12)
    }

    /// The reported output latency is measured and logged but not yet part of
    /// the sum. Applied, it would move every stored correction tuned on one
    /// route by the difference to another (173 ms between built-in speakers
    /// and AirPods), and a player that already compensates for it would count
    /// it twice. So on every route the lead stays today's.
    func testTheMeasuredOutputLatencyIsNotAppliedYet() {
        XCTAssertFalse(LyricLeadModel.appliesOutputLatency)
        var model = LyricLeadModel.calibrated
        let builtIn = model.lead
        for reported in [0, 0.020, 0.0273, 0.200, 0.350] {
            model.outputLatency = reported
            XCTAssertEqual(model.lead, builtIn, accuracy: 1e-12, "reported \(reported) s moved the lead")
        }
    }

    /// The onset crossfade is the largest render term (L-09): `LyricRow`
    /// lights a line on `Theme.lyricScroll`, which is half-way there about
    /// 104 ms after the line is due. The lab's numbers, from the same spring.
    func testTheOnsetRiseIsTheLyricSpringsHalfway() {
        let response = Theme.lyricScrollResponse, damping = Theme.lyricScrollDamping
        XCTAssertEqual(Theme.springRiseTime(response: 0.42, damping: 0.86, level: 0.1), 0.0347, accuracy: 0.0005)
        XCTAssertEqual(Theme.springRiseTime(response: 0.42, damping: 0.86, level: 0.5), 0.1039, accuracy: 0.0005)
        XCTAssertEqual(Theme.springRiseTime(response: 0.42, damping: 0.86, level: 0.9), 0.2158, accuracy: 0.0005)
        // Critically damped, the same response is slower to its midpoint —
        // the 8 ms the model absorbs if the spring's damping ever changes.
        XCTAssertEqual(Theme.springRiseTime(response: 0.42, damping: 1, level: 0.5), 0.1122, accuracy: 0.0005)
        XCTAssertEqual(
            LyricLeadModel.calibrated.onsetRise,
            Theme.springRiseTime(response: response, damping: damping, level: 0.5),
            accuracy: 1e-12, "the rise is read from Theme, so a spring change moves it"
        )
    }

    /// An island screen whose refresh rate is unknown is counted as 60 Hz,
    /// the slower and therefore safer guess for how long a frame waits.
    func testAnUnknownFrameRateCountsAsSixtyHertz() {
        var model = LyricLeadModel.calibrated
        model.frameRate = 0
        XCTAssertEqual(model.frameHalf, 0.5 / 60, accuracy: 1e-12)
        XCTAssertEqual(model.compositor, 1.0 / 60, accuracy: 1e-12)
    }
}
