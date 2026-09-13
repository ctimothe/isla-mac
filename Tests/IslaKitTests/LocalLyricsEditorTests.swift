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

        let saved = try editor.saveOwnedCopy(draft, binding: identity())

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

    private func identity() -> LocalTrackIdentity {
        LocalTrackIdentity(
            playerID: "test", title: "Song", artist: "Artist", album: "Album",
            duration: 180, recordingID: nil
        )
    }
}
