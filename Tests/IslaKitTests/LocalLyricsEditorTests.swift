import XCTest
@testable import IslaKit

@MainActor
final class LocalLyricsEditorTests: XCTestCase {
    nonisolated(unsafe) private let fileManager = FileManager.default
    nonisolated(unsafe) private var root = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    func testEditorSaveCreatesOwnedBoundCopyWithoutChangingSourceFile() throws {
        let source = root.appendingPathComponent("song.lrc")
        let raw = "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Before"
        try Data(raw.utf8).write(to: source, options: .atomic)
        let library = LocalLyricsLibrary(directory: root)
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(raw))
        draft.lines[0].text = "After"
        let editor = LocalLyricsEditor(library: library)

        let saved = try editor.saveOwnedCopy(draft, editedFrom: nil, binding: identity())

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), raw)
        XCTAssertEqual(saved.document.lines[0].text, "After")
        guard case .ready(let bound) = library.lookup(identity: identity()) else {
            return XCTFail("the saved copy must be bound to this track")
        }
        XCTAssertEqual(bound.id, saved.id)
    }

    func testEditorExportWritesAValidatedLRC() throws {
        let document = try LocalLyricsDocument.parse("[00:01.00]Before")
        let draft = LocalLyricsDraft(document: document)
        draft.lines[0].text = "After"
        let destination = root.appendingPathComponent("edited.lrc")

        try LocalLyricsEditor(library: LocalLyricsLibrary(directory: root)).export(draft, to: destination)

        XCTAssertEqual(
            try LocalLyricsDocument.parse(String(contentsOf: destination, encoding: .utf8)).lines[0].text,
            "After"
        )
    }

    func testEditingAWordTimedLineFallsBackToLineTiming() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[00:01.00]<00:01.00>Before <00:01.40>words"
        ))
        draft.lines[0].text = "After edit"

        let edited = try draft.document()

        XCTAssertTrue(edited.lines[0].words.isEmpty)
        XCTAssertEqual(edited.lines[0].text, "After edit")
        XCTAssertEqual(edited.granularity, .line)
    }

    /// Editing one line costs that line its word timing and no other (J-014):
    /// the rest keep their words and the document stays word-timed.
    func testEditingOneLineKeepsKaraokeOnTheOthers() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[00:01.00]<00:01.00>Before <00:01.40>words\n[00:03.00]<00:03.00>Kept <00:03.40>line"
        ))
        draft.lines[0].text = "After edit"

        let edited = try draft.document()

        XCTAssertTrue(edited.lines[0].words.isEmpty)
        XCTAssertEqual(edited.lines[1].words.map(\.text), ["Kept ", "line"])
        XCTAssertEqual(edited.granularity, .word)
    }

    /// An untouched line keeps its words even when they are joined by
    /// nothing. The editor compared the line to its words joined with a
    /// space, so a character-timed Chinese line ('我爱你' against '我 爱 你')
    /// looked edited, and every Save Copy stripped its karaoke (G-018).
    func testAnUneditedCharacterTimedLineKeepsItsWords() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[offset:-300]\n[00:01.00]<00:01.00>我<00:01.20>爱<00:01.40>你<00:01.80>"
        ))

        let saved = try draft.document()

        XCTAssertEqual(saved.lines[0].text, "我爱你")
        XCTAssertEqual(saved.lines[0].words.map(\.text), ["我", "爱", "你"])
        XCTAssertEqual(saved, try LocalLyricsDocument.parse(
            "[offset:-300]\n[00:01.00]<00:01.00>我<00:01.20>爱<00:01.40>你<00:01.80>"
        ), "a save that changes nothing changes nothing, offset and end marker included")
    }

    /// Save Copy binds the song Edit was pressed for, not the one playing
    /// when Save is pressed. The sheet read the coordinator's identity every
    /// time its parent redrew, so a playlist that moved on while the editor
    /// was up bound song A's edit to song B, and B showed A's words (J-009).
    func testSaveCopyBindsTheSongBeingEdited() throws {
        let library = LocalLyricsLibrary(directory: root)
        let media = MediaController()
        media.isolateFromPlayers()
        let coordinator = LyricsCoordinator(media: media, library: library, isEnabled: { true })
        coordinator.start()
        defer { coordinator.stop() }

        media.apply(playingSnapshot(title: "Song A"))
        let source = try library.importDocument(
            "[00:01.00]Words of A", binding: coordinator.currentLocalTrackIdentity, editedFrom: nil
        )
        let session = LocalLyricsEditor.EditingSession(
            candidate: source, identity: coordinator.currentLocalTrackIdentity
        )
        let songA = try XCTUnwrap(session.identity)
        XCTAssertEqual(session.title, "Song A", "the sheet names the song it is editing")

        media.apply(playingSnapshot(title: "Song B"))
        let songB = try XCTUnwrap(coordinator.currentLocalTrackIdentity)
        XCTAssertNotEqual(songA, songB, "the fixture: the playlist moved on while the editor was up")
        let beforeB = library.lookup(identity: songB)

        let draft = LocalLyricsDraft(document: source.document)
        draft.rows[0].line.text = "Edited words of A"
        let saved = try LocalLyricsEditor(library: library).saveOwnedCopy(draft, for: session)

        guard case .ready(let bound) = library.lookup(identity: songA) else {
            return XCTFail("the edit is bound to the song it was made for")
        }
        XCTAssertEqual(bound.id, saved.id)
        XCTAssertEqual(library.lookup(identity: songB), beforeB, "the song playing now is untouched")
    }

    /// Moving a word-timed line moves its words. The Timestamp field wrote
    /// only `line.at`, so a line moved later left its words behind before
    /// its own start, and the save's re-parse refused the file (J-015).
    func testRetimingAWordTimedLineMovesItsWords() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[00:10.00]<00:10.00>Moved <00:10.50>line<00:11.00>\n[00:20.00]Next"
        ))

        draft.retime(row: 0, to: 12.0)

        XCTAssertEqual(draft.rows[0].line.words.map(\.at), [12.0, 12.5])
        XCTAssertEqual(draft.rows[0].line.words.last?.end, 13.0)
        let saved = try draft.document()
        XCTAssertEqual(saved.lines[0].at, 12.0)
        XCTAssertEqual(saved.lines[0].words.map(\.at), [12.0, 12.5], "and the save keeps the karaoke")
    }

    /// A forgotten line can be put back between two others. Add only ever
    /// appended a second after the last row, and there was no way to move it.
    func testAnInsertedLineSavesInOrder() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[00:01.00]First\n[00:03.00]Third\n[00:05.00]Fifth"
        ))
        let ids = draft.rows.map(\.id)

        draft.insertLine(after: 0)
        XCTAssertEqual(draft.rows[1].line.at, 2.0, "halfway to the next row")
        XCTAssertEqual(draft.rows.map(\.id).filter(ids.contains), ids, "the other rows keep their identity")
        draft.rows[1].line.text = "Second"

        draft.insertLine(after: 3)
        XCTAssertEqual(draft.rows[4].line.at, 6.0, "after the last row, a second later")
        draft.rows[4].line.text = "Sixth"
        // A row set to a time out of screen order is sorted on save.
        draft.retime(row: 4, to: 4.0)

        XCTAssertEqual(try draft.document().lines.map(\.text), ["First", "Second", "Third", "Sixth", "Fifth"])
    }

    /// Removing a row removes that row, by identity, and the others keep
    /// theirs: rows were keyed by index, the pattern that traps when the
    /// removed row held focus.
    func testRemovingARowKeepsTheOthersIdentity() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[00:01.00]One\n[00:02.00]Two\n[00:03.00]Three"
        ))
        let ids = draft.rows.map(\.id)

        draft.removeRow(id: ids[1])

        XCTAssertEqual(draft.rows.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(draft.rows.map(\.line.text), ["One", "Three"])
    }

    /// A time Isla cannot write is reported against its row, by its position
    /// on screen. Every failure used to read "This LRC file is invalid." with
    /// no row named, and a negative or NaN time did not even fail: the writer
    /// clamped it to 0:00 and the line moved to the top without a word.
    func testAValidationErrorNamesTheRow() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[00:01.00]One\n[00:02.00]Two\n[00:03.00]Three\n[00:04.00]Four\n[00:05.00]Five"
        ))

        for bad in [-1, .nan, .infinity, 1_000 * 60] as [TimeInterval] {
            draft.rows[3].line.at = bad
            XCTAssertThrowsError(try draft.document(), "\(bad)") { error in
                XCTAssertEqual(error as? LocalLyricsDraft.ValidationError, .row(3))
            }
        }
        draft.rows[1].line.at = .nan
        XCTAssertThrowsError(try draft.validate()) { error in
            XCTAssertEqual(error as? LocalLyricsDraft.ValidationError, .row(1), "the first bad row on screen")
        }
        XCTAssertEqual(
            LocalLyricsDraft.ValidationError.row(1).message,
            localized("Line %d has a time Isla can't use.", 2),
            "the message counts from one, as the rows read"
        )
    }

    /// A blank row is a pause: it saves as a bare stamp, which the parser
    /// reads as the end of the line before it, and it ends that line even
    /// where the file already gave the line an end of its own, which the
    /// editor does not show. Placed after that end, the pause was written
    /// and then thrown away on the way back in.
    func testABlankRowEndsTheLineBeforeIt() throws {
        let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(
            "[00:01.00]Sung\n[00:04.00]\n[00:10.00]Next"
        ))
        XCTAssertEqual(draft.rows[0].line.end, 4.0, "the fixture: the file's own end")

        draft.insertLine(after: 0)
        XCTAssertEqual(draft.rows[1].line.at, 5.5, "halfway to the next row")
        draft.retime(row: 1, to: 6.0)

        let saved = try draft.document()

        XCTAssertEqual(saved.lines.map(\.text), ["Sung", "Next"])
        XCTAssertEqual(saved.lines[0].end, 6.0, "the pause the listener placed ends the line")
    }

    private func identity() -> LocalTrackIdentity {
        LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
    }

    private func playingSnapshot(title: String) -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = title
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
