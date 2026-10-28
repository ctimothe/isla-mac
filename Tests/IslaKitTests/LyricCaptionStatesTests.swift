import Combine
import XCTest
@testable import IslaKit

/// "Compact music and lock-card captions never go blank" (checklist, manual
/// parity gates): the state table, walked through the real coordinator rather
/// than asserted one value at a time.
///
/// The words under the song are one function of the coordinator's availability
/// (`LyricsPresentation.compactCaption`, which the lock card draws) and the
/// stage's sentence is another of the same state (`LyricsPageState`). Each step
/// here puts the coordinator in one of the states the checklist names —
/// disabled, settling, finding, ready, none, invalid file, retry, import,
/// binding removal and ambiguous-file selection — and reads both, *after the
/// operation has returned*: the coordinator re-resolves through a quiet
/// `.resolving` inside every change, but nothing draws between two statements
/// of one main-actor turn, so a state a surface can show is the state a step
/// ends in.
///
/// The one state allowed to say nothing is `.resolving`, on purpose: the slot
/// holds its height so that an answer inside `quietGrace` never flashes a
/// spinner (`LyricsAvailability.resolving`). Its half of the contract is that
/// it never lasts — `testSettlingIsQuietAndThenAdmitsToTheWait` and
/// `testALengthlessTrackIsQuietAndThenSaysItIsLive` hold the promotion.
@MainActor
final class LyricCaptionStatesTests: XCTestCase {
    nonisolated(unsafe) private let fileManager = FileManager.default
    nonisolated(unsafe) private var root = URL(fileURLWithPath: "/tmp")
    private var savedQuietGrace: TimeInterval = 0
    private var savedNoLengthGrace: TimeInterval = 0

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        savedQuietGrace = LyricsCoordinator.quietGrace
        savedNoLengthGrace = LyricsCoordinator.noLengthGrace
        LabLocalization.use("en")
    }

    override func tearDownWithError() throws {
        LyricsCoordinator.quietGrace = savedQuietGrace
        LyricsCoordinator.noLengthGrace = savedNoLengthGrace
        try? fileManager.removeItem(at: root)
    }

    // MARK: - The rig

    private struct Rig {
        let coordinator: LyricsCoordinator
        let media: MediaController
        let lyrics: LyricsStore
        let library: LocalLyricsLibrary
        let enabled: Flag
        let online: Flag
    }

    private final class Flag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private func rig(
        enabled: Bool = true, online: Bool = false,
        onlineLookUp: @escaping (LocalTrackIdentity) async -> OnlineLyrics.Outcome = { _ in .none }
    ) -> Rig {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let lyrics = LyricsStore(offsetsDirectory: root.appendingPathComponent("offsets"))
        let enabledFlag = Flag(enabled), onlineFlag = Flag(online)
        let coordinator = LyricsCoordinator(
            media: media, library: library, isEnabled: { enabledFlag.value },
            isOnlineEnabled: { onlineFlag.value }, presentation: lyrics,
            onlineCache: OnlineLyricsCache(directory: root.appendingPathComponent("online")),
            onlineLookUp: onlineLookUp
        )
        coordinator.start()
        return Rig(
            coordinator: coordinator, media: media, lyrics: lyrics, library: library,
            enabled: enabledFlag, online: onlineFlag
        )
    }

    /// What the lock card draws under the song and what the stage says, for the
    /// state the coordinator is in now. Fails, with the step's name, on a blank
    /// where the state is not the quiet one.
    @discardableResult
    private func assertSpeaks(
        _ rig: Rig, _ step: String, line: String? = nil,
        file: StaticString = #filePath, at lineNumber: UInt = #line
    ) -> String {
        let availability = rig.coordinator.availability
        XCTAssertNotEqual(availability, .resolving, "\(step): the quiet state is not where a step may end", file: file, line: lineNumber)
        let caption = LyricsPresentation.compactCaption(
            for: availability, currentLine: line, localLookup: rig.coordinator.localLookup,
            onlineEnabled: rig.online.value
        )
        XCTAssertFalse(
            caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(step): the card's caption is blank in \(availability)", file: file, line: lineNumber
        )
        let page = LyricsPageState.state(
            availability: availability, lyricsState: rig.lyrics.state,
            localLookup: rig.coordinator.localLookup, onlineEnabled: rig.online.value, invalidLine: nil
        )
        XCTAssertNotEqual(page, .resolving, "\(step): the stage says nothing in \(availability)", file: file, line: lineNumber)
        return caption
    }

    private func playing(
        title: String = "Song", duration: TimeInterval = 180
    ) -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = title
        snapshot.artist = "Artist"
        snapshot.album = "Album"
        snapshot.duration = duration
        snapshot.elapsed = 4
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 42
        return snapshot
    }

    private func lrcFile(_ name: String, tagged: Bool, line: String) throws -> URL {
        let tags = tagged ? "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n" : ""
        let url = root.appendingPathComponent("\(name).lrc")
        try Data("\(tags)[00:01.00]\(line)\n[00:05.00]Second".utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: - The table

    /// Every state the checklist names, in the order a listener meets them,
    /// each read the moment its operation returns.
    func testEveryStateOfTheCaptionTableSaysSomething() throws {
        let rig = rig(enabled: false)
        defer { rig.coordinator.stop() }
        rig.media.setActive(true)
        defer { rig.media.setActive(false) }

        // Disabled: Show Lyrics is off.
        rig.media.apply(playing())
        XCTAssertEqual(rig.coordinator.availability, .disabled)
        XCTAssertEqual(assertSpeaks(rig, "disabled"), localized("Lyrics are off."))

        // Turned on with nothing local and nothing online: none.
        rig.enabled.value = true
        rig.coordinator.refreshVisibility()
        XCTAssertEqual(rig.coordinator.availability, .noLocalLyrics)
        XCTAssertEqual(assertSpeaks(rig, "none"), localized("No lyrics on this Mac."))

        // Retry with nothing to find: the same honest sentence, not a blank.
        rig.coordinator.retry()
        XCTAssertEqual(assertSpeaks(rig, "retry"), localized("No lyrics on this Mac."))

        // Import: a file bound to the song that was playing. Ready, and the
        // card says the line when it has one and "Finding lyrics…" before it
        // has (`currentLine` is nil until the clock reaches a stamp).
        let identity = try XCTUnwrap(rig.coordinator.currentLocalTrackIdentity)
        try rig.coordinator.importLocalFile(at: lrcFile("untagged", tagged: false, line: "Opening"), for: identity)
        guard case .ready = rig.coordinator.availability else {
            return XCTFail("the import is showing: \(rig.coordinator.availability)")
        }
        XCTAssertEqual(assertSpeaks(rig, "import before the first line"), localized("Finding lyrics…"))
        XCTAssertEqual(assertSpeaks(rig, "import on a line", line: "Opening"), "Opening")
        XCTAssertEqual(assertSpeaks(rig, "import on a blank line", line: "  "), localized("Finding lyrics…"))

        // Binding removal: the untagged file has nothing but its binding to
        // find the song by, so the song goes back to none.
        rig.coordinator.removeLocalBinding()
        XCTAssertEqual(rig.coordinator.availability, .noLocalLyrics)
        XCTAssertEqual(assertSpeaks(rig, "binding removal"), localized("No lyrics on this Mac."))

        // Online on: the same miss says nothing was found, not where it looked.
        rig.online.value = true
        XCTAssertEqual(assertSpeaks(rig, "none, online on"), localized("No lyrics found for this song."))
        rig.online.value = false

        // Ambiguous: two files with the song's tags. The first shows; the
        // second, arriving while it shows, does not take it away mid-song
        // (check 422, `LyricsCoordinator.keepingShown`). The next time the
        // song is identified the card asks the listener to choose, and
        // choosing shows the one chosen.
        try rig.library.importDocument(at: lrcFile("studio", tagged: true, line: "Studio"), binding: nil)
        guard case .ready(let studio) = rig.coordinator.availability else {
            return XCTFail("one tagged file shows: \(rig.coordinator.availability)")
        }
        try rig.library.importDocument(at: lrcFile("acoustic", tagged: true, line: "Acoustic"), binding: nil)
        XCTAssertEqual(rig.coordinator.availability, .ready(studio), "a tie that arrived mid-song replaced the shown file")
        rig.coordinator.refreshVisibility()
        guard case .ambiguous(let candidates) = try XCTUnwrap(rig.coordinator.localLookup) else {
            return XCTFail("two versions with one set of tags must not auto-match: \(String(describing: rig.coordinator.localLookup))")
        }
        XCTAssertEqual(rig.coordinator.availability, .noLocalLyrics)
        XCTAssertEqual(assertSpeaks(rig, "ambiguous"), localized("Choose local lyrics…"))
        rig.coordinator.selectLocalCandidate(try XCTUnwrap(candidates.first))
        guard case .ready = rig.coordinator.availability else {
            return XCTFail("the chosen file is showing: \(rig.coordinator.availability)")
        }
        XCTAssertEqual(assertSpeaks(rig, "ambiguous-file selection"), localized("Finding lyrics…"))

        // Off again at the end: the card says so rather than keeping the last
        // song's words.
        rig.enabled.value = false
        rig.coordinator.refreshVisibility()
        XCTAssertEqual(assertSpeaks(rig, "disabled again"), localized("Lyrics are off."))
    }

    /// A bound file that stops parsing: the card names the file as the
    /// problem, in words, rather than going blank or saying there is none.
    func testAnInvalidFileSaysSo() throws {
        let folder = root.appendingPathComponent("Library", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let good = "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First"
        let file = folder.appendingPathComponent("song.lrc")
        try Data(good.utf8).write(to: file, options: .atomic)

        let rig = rig()
        defer { rig.coordinator.stop() }
        rig.media.setActive(true)
        defer { rig.media.setActive(false) }
        try rig.library.addFolder(folder)
        rig.media.apply(playing())
        guard case .ready(let candidate) = try XCTUnwrap(rig.coordinator.localLookup) else {
            return XCTFail("the fixture: the folder's file matches the song")
        }
        rig.coordinator.selectLocalCandidate(candidate)

        try Data("not lyrics at all".utf8).write(to: file, options: .atomic)
        try rig.library.rescanFolders()
        guard case .invalidLocalFile = rig.coordinator.availability else {
            return XCTFail("the bound file is broken: \(rig.coordinator.availability)")
        }
        XCTAssertEqual(assertSpeaks(rig, "invalid file"), localized("Can't read the lyrics file for this song."))
        XCTAssertEqual(
            LyricsPageState.state(
                availability: rig.coordinator.availability, lyricsState: rig.lyrics.state,
                localLookup: rig.coordinator.localLookup, onlineEnabled: false, invalidLine: nil
            ),
            .unreadable(line: nil), "and the stage names the file too"
        )
    }

    // MARK: - The quiet state is brief

    /// Settling → finding: a lookup that takes a moment is quiet inside the
    /// grace (the slot holds its height) and then admits to the wait; the
    /// answer replaces that with a sentence. At no moment after the grace is
    /// the card blank.
    func testSettlingIsQuietAndThenAdmitsToTheWait() async throws {
        LyricsCoordinator.quietGrace = 0.05
        let rig = rig(online: true, onlineLookUp: { _ in
            try? await Task.sleep(for: .milliseconds(400))
            return .none
        })
        defer { rig.coordinator.stop() }
        rig.media.setActive(true)
        defer { rig.media.setActive(false) }

        rig.media.apply(playing())
        XCTAssertEqual(rig.coordinator.availability, .resolving, "a new song starts quiet")
        XCTAssertEqual(
            LyricsPresentation.compactCaption(for: .resolving, currentLine: nil), "",
            "quiet on purpose: the slot holds its height and no spinner flashes for a fast answer"
        )

        for _ in 0..<50 where rig.coordinator.availability == .resolving {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(rig.coordinator.availability, .findingLocalLyrics, "the wait is real: say so")
        XCTAssertEqual(assertSpeaks(rig, "finding"), localized("Finding lyrics…"))

        for _ in 0..<100 where rig.coordinator.availability == .findingLocalLyrics {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(rig.coordinator.availability, .noLocalLyrics, "the answer came: nothing found")
        XCTAssertEqual(assertSpeaks(rig, "none after the wait"), localized("No lyrics found for this song."))

        // Retry forgets the miss and asks again: the card never sits blank
        // while it does.
        rig.coordinator.retry()
        for _ in 0..<100 where rig.coordinator.availability == .resolving {
            try await Task.sleep(for: .milliseconds(10))
        }
        assertSpeaks(rig, "retry asking again")
    }

    /// A track the player has not given a length: quiet through the grace, then
    /// the card says it is live audio.
    func testALengthlessTrackIsQuietAndThenSaysItIsLive() async throws {
        LyricsCoordinator.noLengthGrace = 0.05
        let rig = rig()
        defer { rig.coordinator.stop() }
        rig.media.setActive(true)
        defer { rig.media.setActive(false) }

        rig.media.apply(playing(duration: 0))
        XCTAssertEqual(rig.coordinator.availability, .resolving, "a length may still be on its way")
        for _ in 0..<50 where rig.coordinator.availability == .resolving {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(rig.coordinator.availability, .cannotLookUp(.noLength))
        XCTAssertEqual(assertSpeaks(rig, "live audio"), localized("No lyrics for live audio."))

        rig.media.apply(playing(title: "  "))
        XCTAssertEqual(assertSpeaks(rig, "no title"), localized("This track has no title to look up."))
    }
}
