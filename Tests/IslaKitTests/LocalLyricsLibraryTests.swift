import XCTest
@testable import IslaKit

@MainActor
final class LocalLyricsLibraryTests: XCTestCase {
    nonisolated(unsafe) private let fileManager = FileManager.default
    nonisolated(unsafe) private var root = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let v5 = root.appendingPathComponent("lyrics-v5", isDirectory: true)
        try fileManager.createDirectory(
            at: v5.appendingPathComponent("overrides", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("lyrics", isDirectory: true),
            withIntermediateDirectories: true
        )
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

    /// A rescan that finds what was already there changes nothing. Every
    /// folder-watcher event lands here — any file added, renamed or removed at
    /// a folder's top level, `.lrc` or not — and each one rewrote the index and
    /// advanced the revision, which sends the track on screen back through
    /// resolution and can re-send its online lookup.
    func testARescanThatFindsNothingNewLeavesTheRevisionAlone() throws {
        let folder = try makeFolder(named: "Library")
        let url = try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        let settled = library.revision

        try write("not lyrics", to: folder.appendingPathComponent("notes.txt"))
        try library.rescanFolders()
        XCTAssertEqual(library.revision, settled, "nothing the library holds changed")

        try write("[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Changed", to: url)
        try library.rescanFolders()
        XCTAssertGreaterThan(library.revision, settled, "a changed document is news")
    }

    /// A folder that cannot be reached — a disk unplugged, a share not mounted —
    /// must not cost the others. Its bookmark throws, and the rescan used to
    /// throw with it: every folder after the missing one went unread for the
    /// session. It keeps the documents it had, so a track bound to one of them
    /// is bound to the same one when the folder comes back.
    func testAMissingFolderDoesNotHideTheOthersAndKeepsItsDocuments() throws {
        // Symlinks resolved, so the folder's stored path and the path its
        // bookmark resolves to are the same string, as they are in ~/Music.
        let base = root.resolvingSymlinksInPath()
        let away = base.appendingPathComponent("Away", isDirectory: true)
        let kept = base.appendingPathComponent("Kept", isDirectory: true)
        try fileManager.createDirectory(at: away, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: kept, withIntermediateDirectories: true)
        let awayLRC = "[ti:Other]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Away"
        try write(awayLRC, to: away.appendingPathComponent("other.lrc"))
        let song = try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: kept.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(away)
        try library.addFolder(kept)
        let other = identity(title: "Other")
        guard case .ready(let before) = library.lookup(identity: other) else {
            return XCTFail("the folder's document should resolve while it is there")
        }

        try fileManager.removeItem(at: away)
        try write("[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Changed", to: song)
        XCTAssertNoThrow(try library.rescanFolders(), "one missing folder must not abandon the rescan")
        guard case .ready(let current) = library.lookup(identity: identity()) else {
            return XCTFail("the reachable folder is still read")
        }
        XCTAssertEqual(current.timeline.lines.first?.text, "Changed")

        try fileManager.createDirectory(at: away, withIntermediateDirectories: true)
        try write(awayLRC, to: away.appendingPathComponent("other.lrc"))
        try library.rescanFolders()
        guard case .ready(let after) = library.lookup(identity: other) else {
            return XCTFail("the folder's document is back with the folder")
        }
        XCTAssertEqual(after.id, before.id, "the document keeps its id across the absence")
    }

    func testAmbiguousLookupUsesAnExplicitChooseCaption() {
        let caption = LyricsPresentation.compactCaption(
            for: .noLocalLyrics,
            currentLine: nil,
            localLookup: .ambiguous([])
        )

        XCTAssertEqual(caption, localized("Choose local lyrics…"))
    }

    func testMigrationCopiesTaggedV5OverrideAndDeletesLicensedEntries() throws {
        let track = identity(title: "Song", artist: "Artist", album: "Album", duration: 180)
        try write(studioLRC.replacingOccurrences(of: "Studio", with: "Private"), to: legacyOverrides.appendingPathComponent("old.lrc"))
        let licensed = legacyV5.appendingPathComponent("old.lrc5.json")
        try write("{}", to: licensed)

        let library = LocalLyricsLibrary(directory: root, legacyV5Directory: legacyV5)

        guard case .ready(let candidate) = library.lookup(identity: track) else {
            return XCTFail("the tagged override should migrate")
        }
        XCTAssertEqual(candidate.timeline.lines.first?.text, "Private")
        XCTAssertFalse(fileManager.fileExists(atPath: licensed.path))
    }

    func testMigrationKeepsTaglessOverrideAsUnassignedImport() throws {
        try write("[00:01.00]Private", to: legacyOverrides.appendingPathComponent("tagless.lrc"))

        let library = LocalLyricsLibrary(directory: root, legacyV5Directory: legacyV5)

        XCTAssertEqual(library.unassignedImports.count, 1)
    }

    func testMigrationCarriesReconstructableLegacyNudgeToTaggedOverride() throws {
        let track = identity(duration: 180.4)
        try write(studioLRC.replacingOccurrences(of: "Studio", with: "Private"), to: legacyOverrides.appendingPathComponent("old.lrc"))
        let legacyEntry = legacyV4.appendingPathComponent(legacyV4Name(for: track))
        try write(legacyV4Entry(trackOffset: 0.25), to: legacyEntry)

        _ = LocalLyricsLibrary(
            directory: root,
            legacyV5Directory: legacyV5,
            legacyV4Directory: legacyV4
        )
        let store = LyricsStore(offsetsDirectory: root.appendingPathComponent("lyrics-local"))
        store.activateTrackOffset(for: track)

        XCTAssertEqual(store.trackOffset, 0.25, accuracy: 0.001)
        XCTAssertFalse(fileManager.fileExists(atPath: legacyEntry.path))
    }

    func testMigrationClampsAnInvalidLegacyNudge() throws {
        let track = identity()
        try write(studioLRC, to: legacyOverrides.appendingPathComponent("old.lrc"))
        let legacyEntry = legacyV4.appendingPathComponent(legacyV4Name(for: track))
        try write(legacyV4Entry(trackOffset: 9), to: legacyEntry)

        _ = LocalLyricsLibrary(
            directory: root,
            legacyV5Directory: legacyV5,
            legacyV4Directory: legacyV4
        )
        let store = LyricsStore(offsetsDirectory: root.appendingPathComponent("lyrics-local"))
        store.activateTrackOffset(for: track)

        XCTAssertEqual(store.trackOffset, LyricsStore.trackOffsetLimit, accuracy: 0.001)
    }

    func testMigrationKeepsUnreconstructableLegacyNudgeForRecovery() throws {
        try write(legacyV4Entry(trackOffset: 0.25), to: legacyV4.appendingPathComponent("orphan.lrc4.json"))

        _ = LocalLyricsLibrary(
            directory: root,
            legacyV5Directory: legacyV5,
            legacyV4Directory: legacyV4
        )
        let store = LyricsStore(offsetsDirectory: root.appendingPathComponent("lyrics-local"))

        XCTAssertEqual(store.unassignedLegacyOffsets, [
            .init(filename: "orphan.lrc4.json", offset: 0.25),
        ])
    }

    func testNotchStoresMigrateLegacyNudgesBeforeLegacyCacheCleanup() throws {
        let track = identity()
        try write(studioLRC, to: legacyOverrides.appendingPathComponent("old.lrc"))
        let legacyEntry = legacyV4.appendingPathComponent(legacyV4Name(for: track))
        try write(legacyV4Entry(trackOffset: 0.25), to: legacyEntry)

        let stores = NotchStores(localLyricsDirectory: root)
        stores.lyrics.activateTrackOffset(for: track)

        XCTAssertEqual(stores.lyrics.trackOffset, 0.25, accuracy: 0.001)
        XCTAssertFalse(fileManager.fileExists(atPath: legacyEntry.path))
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

    private var legacyV5: URL {
        root.appendingPathComponent("lyrics-v5", isDirectory: true)
    }

    private var legacyOverrides: URL {
        legacyV5.appendingPathComponent("overrides", isDirectory: true)
    }

    private var legacyV4: URL {
        root.appendingPathComponent("lyrics", isDirectory: true)
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

    private func legacyV4Entry(trackOffset: TimeInterval) -> String {
        "{\"times\":[1],\"texts\":[\"old\"],\"trackOffset\":\(trackOffset)}"
    }

    private func legacyV4Name(for identity: LocalTrackIdentity) -> String {
        let value = "\(identity.title)|\(identity.artist)|\(identity.album)|\(Int(identity.duration.rounded()))"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx.lrc4.json", hash)
    }
}
