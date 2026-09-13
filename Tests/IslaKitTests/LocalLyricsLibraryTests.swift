import XCTest
@testable import IslaKit

@MainActor
final class LocalLyricsLibraryTests: XCTestCase {
    nonisolated(unsafe) private let fileManager = FileManager.default
    nonisolated(unsafe) private var root = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    func testUniqueAlbumMatchResolvesAnImportedDocument() throws {
        let library = LocalLyricsLibrary(directory: root)
        _ = try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: nil)

        guard case .ready(let candidate) = library.lookup(identity: identity(
            title: "Song", artist: "Artist", album: "Album", duration: 180
        )) else { return XCTFail("one exact local candidate should resolve") }

        XCTAssertEqual(candidate.timeline.documentID, candidate.id)
        XCTAssertEqual(candidate.timeline.lines.map(\.text), ["Studio"])
    }

    func testAmbiguousVersionsNeverAutoMatch() throws {
        let library = LocalLyricsLibrary(directory: root)
        _ = try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: nil)
        _ = try library.importDocument(at: try writeLRC("acoustic", contents: acousticLRC), binding: nil)

        guard case .ambiguous(let candidates) = library.lookup(identity: identity(
            title: "Song", artist: "Artist", album: "", duration: 180
        )) else { return XCTFail("versions without an exact discriminator must not auto-match") }

        XCTAssertEqual(candidates.count, 2)
    }

    func testExplicitBindingWinsOverAutomaticCandidate() throws {
        let library = LocalLyricsLibrary(directory: root)
        let track = identity(title: "Song", artist: "Artist", album: "Album", duration: 180)
        let live = try library.importDocument(at: try writeLRC("live", contents: liveLRC), binding: track)
        _ = try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: nil)

        guard case .ready(let chosen) = library.lookup(identity: track) else {
            return XCTFail("a binding should resolve")
        }

        XCTAssertEqual(chosen.id, live.id)
    }

    func testRescanReplacesChangedReferencedFolderFile() throws {
        let folder = try makeFolder(named: "Library")
        let url = try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)

        try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Changed",
            to: url
        )
        try library.rescanFolders()

        guard case .ready(let candidate) = library.lookup(identity: identity()) else {
            return XCTFail("the replacement should remain a unique local match")
        }

        XCTAssertEqual(candidate.timeline.lines.first?.text, "Changed")
    }

    func testAmbiguousLookupUsesAnExplicitChooseCaption() {
        let caption = LyricsPresentation.compactCaption(
            for: .noLocalLyrics,
            currentLine: nil,
            localLookup: .ambiguous([])
        )

        XCTAssertEqual(caption, localized("Choose local lyrics…"))
    }

    private var studioLRC: String {
        "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Studio"
    }

    private var acousticLRC: String {
        "[ti:Song]\n[ar:Artist]\n[al:Acoustic]\n[length:03:00]\n[00:01.00]Acoustic"
    }

    private var liveLRC: String {
        "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Live"
    }

    private func identity(
        title: String = "Song", artist: String = "Artist", album: String = "Album",
        duration: TimeInterval = 180
    ) -> LocalTrackIdentity {
        LocalTrackIdentity(
            playerID: "test", title: title, artist: artist, album: album,
            duration: duration, recordingID: nil
        )
    }

    private func writeLRC(_ name: String, contents: String) throws -> URL {
        try write(contents, to: root.appendingPathComponent("\(name).lrc"))
    }

    private func makeFolder(named name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    private func write(_ contents: String, to url: URL) throws -> URL {
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }
}
