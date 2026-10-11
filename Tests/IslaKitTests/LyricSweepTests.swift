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
}
