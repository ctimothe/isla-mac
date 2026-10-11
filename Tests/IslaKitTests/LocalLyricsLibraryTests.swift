import Combine
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

    /// A watched folder renamed or moved in Finder is followed by its
    /// bookmark. The freshly resolved location used to be thrown away
    /// whenever the bookmark said it was stale, so Isla went on probing the
    /// old path: the folder read as unreachable, Settings listed the old
    /// name, and after a relaunch every song bound to one of its files said
    /// "No lyrics for this track." (J-011). The documents keep their ids
    /// under the new path, so the bindings survive the move.
    func testAMovedFolderIsFollowedAndKeepsItsBindings() async throws {
        // Symlinks resolved, as in the missing-folder test: a bookmark
        // resolves to the real path, and ~/Music has no symlink in it. Not
        // "Lyrics": on a case-insensitive disk that is setUp's legacy
        // "lyrics" folder.
        let base = root.resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("Songs", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        guard case .ready(let found) = library.lookup(identity: identity()) else {
            return XCTFail("the folder's document should resolve before the move")
        }
        // Bound to a track its tags do not describe, so only the binding can
        // find it again: a match by title would pass without one.
        let bound = identity(title: "Bound Elsewhere", album: "Elsewhere")
        library.bind(found, to: bound)

        let moved = base.appendingPathComponent("LRC", isDirectory: true)
        try fileManager.moveItem(at: folder, to: moved)

        let relaunched = LocalLyricsLibrary(directory: root)
        XCTAssertEqual(
            relaunched.selectedFolders.map { $0.resolvingSymlinksInPath().path },
            [moved.path], "Settings names the folder where it is now"
        )
        await relaunched.waitForFolderScan()
        guard case .ready(let after) = relaunched.lookup(identity: bound) else {
            return XCTFail("the binding still finds its document after the move")
        }
        XCTAssertEqual(after.id, found.id, "the document keeps its id under the new path")
        XCTAssertEqual(after.timeline.lines.first?.text, "First")
        XCTAssertTrue(
            relaunched.unreadableFiles(in: moved).isEmpty,
            "a followed folder is not reported as unreachable"
        )

        // And the move is saved: the next launch starts from the new path.
        let again = LocalLyricsLibrary(directory: root)
        await again.waitForFolderScan()
        guard case .ready(let third) = again.lookup(identity: bound) else {
            return XCTFail("the followed location was persisted")
        }
        XCTAssertEqual(third.id, found.id)
    }

    /// Deleting a folder in Finder moves it to the Trash, and its bookmark
    /// follows it there. Following a move must not read lyrics out of the
    /// Trash: the folder reads as gone, as a deleted one always has, and its
    /// bindings wait for it to be put back.
    func testAFolderMovedToTheTrashIsNotFollowed() async throws {
        let base = root.resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("Songs", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        guard case .ready(let found) = library.lookup(identity: identity()) else {
            return XCTFail("the folder's document should resolve before the move")
        }
        let bound = identity(title: "Bound Elsewhere", album: "Elsewhere")
        library.bind(found, to: bound)

        let trash = base.appendingPathComponent(".Trash", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        try fileManager.moveItem(at: folder, to: trash.appendingPathComponent("Songs"))
        try library.rescanFolders()
        XCTAssertEqual(
            library.selectedFolders.map { $0.resolvingSymlinksInPath().path }, [folder.path],
            "a folder in the Trash is not where the library reads from"
        )

        // Across a relaunch, as with any folder that cannot be reached: the
        // binding is kept and says the file cannot be read.
        let relaunched = LocalLyricsLibrary(directory: root)
        XCTAssertEqual(
            relaunched.selectedFolders.map { $0.resolvingSymlinksInPath().path }, [folder.path]
        )
        await relaunched.waitForFolderScan()
        XCTAssertEqual(relaunched.lookup(identity: bound), .invalid(.unreadable))
    }

    /// The watcher saw only entries changed directly inside each top-level
    /// folder: one kernel descriptor per folder, notified of its own writes,
    /// renames and deletes. A library laid out as Artist/Album/song.lrc never
    /// heard of a new file until a relaunch or a manual Rescan, despite the
    /// 150 ms the inventory promises (G-020).
    func testAFileAddedInASubfolderIsSeenWithoutARescan() throws {
        let folder = try makeFolder(named: "Library")
        let album = folder.appendingPathComponent("Artist/Album", isDirectory: true)
        // Made before watching starts: creating Artist would itself be a
        // top-level change, which even the old watcher saw.
        try fileManager.createDirectory(at: album, withIntermediateDirectories: true)
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        library.startWatchingFolders()
        defer { library.stopWatchingFolders() }

        let seen = expectation(on: library) {
            if case .ready = library.lookup(identity: self.identity(title: "New")) { return true }
            return false
        }
        try write(
            "[ti:New]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Deep",
            to: album.appendingPathComponent("new.lrc")
        )
        wait(for: [seen.expectation], timeout: 3)
        seen.cancel()
    }

    /// A sync client rewrites a file in place: the folder's own entries do
    /// not change, so a descriptor on the folder heard nothing, and the old
    /// lyrics stayed on screen until a Rescan (G-020).
    func testAFileRewrittenInPlaceIsSeenWithoutARescan() throws {
        let folder = try makeFolder(named: "Library")
        let song = try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        library.startWatchingFolders()
        defer { library.stopWatchingFolders() }

        let seen = expectation(on: library) {
            guard case .ready(let candidate) = library.lookup(identity: self.identity()) else { return false }
            return candidate.timeline.lines.first?.text == "Changed"
        }
        // Not atomic: the same inode is truncated and written, as a sync
        // client or an editor saving in place does.
        try Data("[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Changed".utf8).write(to: song)
        wait(for: [seen.expectation], timeout: 3)
        seen.cancel()
    }

    /// Renamed while it is watched, the folder is followed at once — no
    /// relaunch — and files added under its new name are seen: the watch is
    /// re-made over the new path rather than left on the old one.
    func testAWatchedFolderRenamedWhileWatchedIsFollowed() throws {
        let base = root.resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("Songs", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        library.startWatchingFolders()
        defer { library.stopWatchingFolders() }

        let moved = base.appendingPathComponent("LRC", isDirectory: true)
        let followed = expectation(on: library) {
            library.selectedFolders.map { $0.resolvingSymlinksInPath().path } == [moved.path]
        }
        try fileManager.moveItem(at: folder, to: moved)
        wait(for: [followed.expectation], timeout: 3)
        followed.cancel()

        let seen = expectation(on: library) {
            if case .ready = library.lookup(identity: self.identity(title: "New")) { return true }
            return false
        }
        try write(
            "[ti:New]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]After",
            to: moved.appendingPathComponent("new.lrc")
        )
        wait(for: [seen.expectation], timeout: 3)
        seen.cancel()
    }

    /// A folder inside another one the library reads is walked twice: on its
    /// own, and as part of its parent. Each file used to be indexed once per
    /// walk. One already indexed went in twice under the same id, and the next
    /// rescan built its path-to-id table from that — a trap in
    /// `Dictionary(uniqueKeysWithValues:)`, and since the library rescans as it
    /// opens, a crash at every launch. One arriving later got an id per walk,
    /// and every lookup for its song became a choice between two copies.
    func testAFolderInsideAnotherReadsEachFileOnce() async throws {
        let outer = try makeFolder(named: "Music")
        let inner = outer.appendingPathComponent("Albums", isDirectory: true)
        try fileManager.createDirectory(at: inner, withIntermediateDirectories: true)
        try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: inner.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(outer)
        try library.addFolder(inner)
        try library.rescanFolders()

        try write(
            "[ti:Other]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Later",
            to: inner.appendingPathComponent("other.lrc")
        )
        try library.rescanFolders()
        for title in ["Song", "Other"] {
            guard case .ready = library.lookup(identity: identity(title: title)) else {
                return XCTFail("\(title): one file is one document, not a choice between two")
            }
        }

        // And an index an earlier build already wrote with a file in it twice
        // is read as the library opens, not trapped on.
        let index = root.appendingPathComponent("lyrics-local/index.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        )
        let documents = try XCTUnwrap(json["documents"] as? [[String: Any]])
        json["documents"] = documents + documents
        try JSONSerialization.data(withJSONObject: json).write(to: index)
        let relaunched = LocalLyricsLibrary(directory: root)
        await relaunched.waitForFolderScan()
        guard case .ready = relaunched.lookup(identity: identity()) else {
            return XCTFail("the next launch reads the same single document")
        }
    }

    /// An index written by a newer build can carry an origin this build has
    /// never heard of. One such entry used to fail the whole decode, the
    /// library opened empty and wrote that emptiness straight back: every
    /// folder, binding and import record gone, the imported files orphaned.
    /// Only the entry this build cannot read is dropped now.
    func testAnUnknownOriginLosesOnlyThatEntry() async throws {
        let folder = try makeFolder(named: "Library")
        try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        guard case .ready(let candidate) = library.lookup(identity: identity()) else {
            return XCTFail("the folder's document should resolve")
        }
        // Bound to a track its tags do not describe, so only the binding can
        // find it: a lookup that resolves proves the binding survived.
        let renamed = identity(title: "Renamed", duration: 240)
        library.bind(candidate, to: renamed)

        let index = root.appendingPathComponent("lyrics-local/index.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        )
        let documents = try XCTUnwrap(json["documents"] as? [[String: Any]])
        json["documents"] = documents + [[
            "id": UUID().uuidString, "origin": "cloud", "path": "/elsewhere/song.lrc",
        ]]
        var issues = (json["issues"] as? [[String: Any]]) ?? []
        issues.append(["path": "/elsewhere/broken.lrc", "issue": "quarantined"])
        json["issues"] = issues
        try JSONSerialization.data(withJSONObject: json).write(to: index)

        let relaunched = LocalLyricsLibrary(directory: root)
        XCTAssertEqual(
            relaunched.selectedFolders.map(\.standardizedFileURL.path),
            [folder.standardizedFileURL.path],
            "the folder outlives an entry this build cannot read"
        )
        await relaunched.waitForFolderScan()
        guard case .ready(let bound) = relaunched.lookup(identity: renamed) else {
            return XCTFail("the binding outlives an entry this build cannot read")
        }
        XCTAssertEqual(bound.id, candidate.id)
    }

    /// An index that cannot be read at all is moved aside before anything is
    /// written, so the library's first save cannot destroy the only record of
    /// the folders and bindings it held.
    func testAnUnreadableIndexIsKeptAside() throws {
        let directory = root.appendingPathComponent("lyrics-local", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{not json".utf8)
        try original.write(to: directory.appendingPathComponent("index.json"))

        _ = LocalLyricsLibrary(directory: root)

        let kept = try fileManager.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix("index.unreadable-") && $0.hasSuffix(".json")
        }
        XCTAssertEqual(kept.count, 1, "the unreadable index is set aside, not overwritten")
        let first = try XCTUnwrap(kept.first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(first)), original)
    }

    /// A binding whose file is gone used to answer `.invalid(.unreadable)`
    /// forever: the song said "No lyrics for this track." on every play, the
    /// online path (which runs only on `.noMatch`) was never asked, and the
    /// only way out was clearing every binding at once. The binding is pruned
    /// with its document now, so the song is matched as if it had never been
    /// bound — and the index on disk forgets it too.
    func testABindingWhoseFileIsGoneFallsBackToMatching() throws {
        let folder = try makeFolder(named: "Library")
        let file = try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        guard case .ready(let candidate) = library.lookup(identity: identity()) else {
            return XCTFail("the fixture: the folder's document resolves")
        }
        // Bound to a track its tags do not describe, so only the binding finds it.
        let bound = identity(title: "Renamed", duration: 240)
        library.bind(candidate, to: bound)
        XCTAssertTrue(library.hasBinding(for: bound))

        try fileManager.removeItem(at: file)
        try library.rescanFolders()

        XCTAssertEqual(library.lookup(identity: bound), .noMatch, "matching continues, so LRCLIB can answer")
        XCTAssertFalse(library.hasBinding(for: bound), "nothing is left to remove")
        let index = root.appendingPathComponent("lyrics-local/index.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        )
        XCTAssertEqual((json["bindings"] as? [String: Any])?.count, 0, "the dangling binding is not saved")
    }

    /// Removing the folder a bound file came from prunes the binding the same
    /// way, and so does clearing the imports a binding pointed at.
    func testRemovingTheFolderOrTheImportsPrunesTheirBindings() throws {
        let folder = try makeFolder(named: "Library")
        try write(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First",
            to: folder.appendingPathComponent("song.lrc")
        )
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        guard case .ready(let candidate) = library.lookup(identity: identity()) else {
            return XCTFail("the fixture: the folder's document resolves")
        }
        let fromFolder = identity(title: "Renamed", duration: 240)
        library.bind(candidate, to: fromFolder)
        let fromImport = identity(title: "Other", duration: 200)
        _ = try library.importDocument(liveLRC, binding: fromImport)

        library.removeFolder(folder)
        XCTAssertFalse(library.hasBinding(for: fromFolder))
        XCTAssertEqual(library.lookup(identity: fromFolder), .noMatch)

        library.clearImportedDocuments()
        XCTAssertFalse(library.hasBinding(for: fromImport))
        XCTAssertEqual(library.lookup(identity: fromImport), .noMatch)
    }

    /// Imports used to be found by the absolute path they were written to, so
    /// a renamed account or a Migration Assistant restore under another user
    /// name lost every import and every edit, and their songs said "No lyrics
    /// for this track." with no message. An import is found by its file name
    /// inside the imports folder now, wherever that folder has gone.
    func testImportsSurviveAMovedSupportFolder() throws {
        let library = LocalLyricsLibrary(directory: root)
        let bound = identity(title: "Renamed", duration: 240)
        let imported = try library.importDocument(liveLRC, binding: bound)

        let moved = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: moved) }
        try fileManager.copyItem(at: root, to: moved)
        // The old home is gone, as it is after a rename or a restore.
        try fileManager.removeItem(at: root.appendingPathComponent("lyrics-local"))

        let relaunched = LocalLyricsLibrary(directory: moved)
        guard case .ready(let candidate) = relaunched.lookup(identity: bound) else {
            return XCTFail("the import is found where the support folder is now")
        }
        XCTAssertEqual(candidate.id, imported.id)
        XCTAssertEqual(candidate.timeline.lines.first?.text, "Live")
        XCTAssertTrue(relaunched.hasBinding(for: bound))
    }

    /// An import a later build cannot parse — a hand edit, a stricter parser —
    /// used to be dropped from the index at launch and gone at the next save,
    /// its binding left pointing at nothing. It keeps its place now and says
    /// what is wrong with it, so the binding answers honestly and can still
    /// be removed.
    func testAnUnparseableImportKeepsItsPlaceAndItsBinding() throws {
        let library = LocalLyricsLibrary(directory: root)
        let bound = identity(title: "Renamed", duration: 240)
        let imported = try library.importDocument(liveLRC, binding: bound)
        try write(
            "not lyrics at all",
            to: root.appendingPathComponent("lyrics-local/imports/\(imported.id.uuidString).lrc")
        )

        let relaunched = LocalLyricsLibrary(directory: root)
        XCTAssertEqual(relaunched.lookup(identity: bound), .invalid(.malformed))
        XCTAssertTrue(relaunched.hasBinding(for: bound), "the binding is still there to remove")
        // Anything that saves the index must keep the import in it.
        try relaunched.addFolder(try makeFolder(named: "Empty"))
        let index = root.appendingPathComponent("lyrics-local/index.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        )
        let ids = (json["documents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains(imported.id.uuidString), "the import keeps its place in the index")
    }

    /// A bound folder file that stops parsing — saved half-edited in a text
    /// editor — keeps its id while it is broken, so the binding answers
    /// `.malformed` and finds the same document once the file is fixed.
    func testABrokenFolderFileKeepsItsBindingUntilItIsFixed() throws {
        let folder = try makeFolder(named: "Library")
        let good = "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]First"
        let file = try write(good, to: folder.appendingPathComponent("song.lrc"))
        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)
        guard case .ready(let candidate) = library.lookup(identity: identity()) else {
            return XCTFail("the fixture: the folder's document resolves")
        }
        let bound = identity(title: "Renamed", duration: 240)
        library.bind(candidate, to: bound)

        try write("not lyrics at all", to: file)
        try library.rescanFolders()
        XCTAssertEqual(library.lookup(identity: bound), .invalid(.malformed))
        XCTAssertTrue(library.hasBinding(for: bound))

        try write(good, to: file)
        try library.rescanFolders()
        guard case .ready(let fixed) = library.lookup(identity: bound) else {
            return XCTFail("the fixed file answers the binding again")
        }
        XCTAssertEqual(fixed.id, candidate.id)
    }

    /// Every folder event — and FSEvents reports any write anywhere under a
    /// watched folder — re-read and re-parsed every `.lrc` in every folder on
    /// the main thread, with no look at whether a file had changed (F-043).
    /// A large library stalled the panel each time a sync client touched it.
    /// A file whose stamp has not moved is not read again.
    func testARescanWithNoChangeReadsNothing() throws {
        let folder = try makeFolder(named: "Library")
        for number in 0..<20 {
            try write(lrc(title: "Song \(number)"), to: folder.appendingPathComponent("song-\(number).lrc"))
        }
        let reads = ReadCounter()
        let library = LocalLyricsLibrary(directory: root, readFile: reads.read)
        try library.addFolder(folder)
        XCTAssertEqual(reads.count, 20, "the first scan reads every file")
        let settled = library.revision

        try library.rescanFolders()
        XCTAssertEqual(reads.count, 20, "nothing changed, so nothing is read again")
        XCTAssertEqual(library.revision, settled, "and nothing is announced")
        guard case .ready = library.lookup(identity: identity(title: "Song 7")) else {
            return XCTFail("a file not re-read is still in the library")
        }
    }

    /// One file touched is one file read, and its siblings keep their ids.
    func testATouchedFileIsReReadAlone() throws {
        let folder = try makeFolder(named: "Library")
        for number in 0..<20 {
            try write(lrc(title: "Song \(number)"), to: folder.appendingPathComponent("song-\(number).lrc"))
        }
        let reads = ReadCounter()
        let library = LocalLyricsLibrary(directory: root, readFile: reads.read)
        try library.addFolder(folder)
        guard case .ready(let sibling) = library.lookup(identity: identity(title: "Song 4")) else {
            return XCTFail("the fixture: a sibling resolves")
        }
        let before = reads.count

        let touched = folder.appendingPathComponent("song-3.lrc")
        let later = Date().addingTimeInterval(60)
        try fileManager.setAttributes([.modificationDate: later], ofItemAtPath: touched.path)
        try library.rescanFolders()
        XCTAssertEqual(reads.count - before, 1, "only the touched file is read")
        XCTAssertEqual(reads.names.last, "song-3.lrc")
        guard case .ready(let again) = library.lookup(identity: identity(title: "Song 4")) else {
            return XCTFail("the sibling still resolves")
        }
        XCTAssertEqual(again.id, sibling.id)

        // An edit of the same size, its modification date then put back — a
        // sync client restoring the server's date does exactly that — is
        // still seen: the file's status-change time moves with any write and
        // nothing can set it back.
        try write(lrc(title: "Song 3", line: "Fresh"), to: touched)
        try fileManager.setAttributes([.modificationDate: later], ofItemAtPath: touched.path)
        try library.rescanFolders()
        guard case .ready(let edited) = library.lookup(identity: identity(title: "Song 3")) else {
            return XCTFail("the edited file resolves")
        }
        XCTAssertEqual(edited.timeline.lines.first?.text, "Fresh")
    }

    /// The launch scan of the selected folders runs off the main thread now,
    /// so `init` returns before a large library is read. What it read must
    /// still be there before anything needs it: an already indexed song is
    /// found once the scan lands, a bound one meanwhile reads as no match
    /// rather than as a broken file, and the scan leaves the next rescan
    /// nothing to read again.
    func testAnIndexedFolderIsReadyAfterLaunch() async throws {
        let folder = try makeFolder(named: "Library")
        try write(lrc(title: "Song"), to: folder.appendingPathComponent("song.lrc"))
        try write(lrc(title: "Other"), to: folder.appendingPathComponent("other.lrc"))
        let first = LocalLyricsLibrary(directory: root)
        try first.addFolder(folder)
        guard case .ready(let found) = first.lookup(identity: identity(title: "Other")) else {
            return XCTFail("the fixture: the folder's document resolves")
        }
        let bound = identity(title: "Renamed", duration: 240)
        first.bind(found, to: bound)

        let reads = ReadCounter()
        let relaunched = LocalLyricsLibrary(directory: root, readFile: reads.read)
        // Nothing the walk found can have landed yet: it is applied on the
        // main actor, which this test has not given up since `init`.
        XCTAssertEqual(relaunched.lookup(identity: identity()), .noMatch, "init does not wait for the walk")
        XCTAssertEqual(relaunched.lookup(identity: bound), .noMatch, "not yet read is not unreadable")
        XCTAssertTrue(relaunched.hasBinding(for: bound), "and the binding is not pruned while it waits")

        await relaunched.waitForFolderScan()
        guard case .ready(let song) = relaunched.lookup(identity: identity()) else {
            return XCTFail("an indexed folder's song is found once the launch scan lands")
        }
        XCTAssertEqual(song.timeline.lines.first?.text, "First")
        guard case .ready(let other) = relaunched.lookup(identity: bound) else {
            return XCTFail("the binding finds its document once the launch scan lands")
        }
        XCTAssertEqual(other.id, found.id, "the document keeps its id across the launch")

        let launched = reads.count
        XCTAssertEqual(launched, 2)
        try relaunched.rescanFolders()
        XCTAssertEqual(reads.count, launched, "the launch scan's stamps serve the next rescan")
    }

    /// The launch scan runs while the listener can already act. A Rescan or a
    /// removed folder in that window must not be undone when the scan, read
    /// before either, lands afterwards.
    func testTheLaunchScanNeverUndoesWhatHappenedWhileItRan() async throws {
        let kept = try makeFolder(named: "Kept")
        let dropped = try makeFolder(named: "Dropped")
        let song = try write(lrc(title: "Song"), to: kept.appendingPathComponent("song.lrc"))
        try write(lrc(title: "Other"), to: dropped.appendingPathComponent("other.lrc"))
        let first = LocalLyricsLibrary(directory: root)
        try first.addFolder(kept)
        try first.addFolder(dropped)

        let relaunched = LocalLyricsLibrary(directory: root)
        relaunched.removeFolder(dropped)
        await relaunched.waitForFolderScan()
        XCTAssertEqual(
            relaunched.lookup(identity: identity(title: "Other")), .noMatch,
            "a folder removed during the launch scan stays removed"
        )
        guard case .ready = relaunched.lookup(identity: identity()) else {
            return XCTFail("the folder still selected is read")
        }

        let again = LocalLyricsLibrary(directory: root)
        try write(lrc(title: "Song", line: "Rescanned"), to: song)
        try again.rescanFolders()
        await again.waitForFolderScan()
        guard case .ready(let current) = again.lookup(identity: identity()) else {
            return XCTFail("the rescan's document resolves")
        }
        XCTAssertEqual(current.timeline.lines.first?.text, "Rescanned", "an explicit rescan wins over the launch scan")
    }

    /// The figures F-043 asks for, on a synthetic 1,000-file folder in the
    /// test's own temporary directory — never the listener's folders. Timed,
    /// not asserted: the numbers belong in the task's report, and a timing
    /// bound would fail on a loaded build machine. What is asserted is the
    /// mechanism: a no-change rescan reads no file, and the launch scan is
    /// what reads the folder, after `init` has returned.
    func testAThousandFileFolderIsCheapToRescanAndToOpen() async throws {
        let folder = try makeFolder(named: "Large")
        for number in 0..<1_000 {
            try write(
                lrc(title: "Song \(number)", lines: 40),
                to: folder.appendingPathComponent("song-\(number).lrc")
            )
        }
        let reads = ReadCounter()
        let library = LocalLyricsLibrary(directory: root, readFile: reads.read)
        var clock = ContinuousClock.now
        try library.addFolder(folder)
        let fullScan = ContinuousClock.now - clock
        XCTAssertEqual(reads.count, 1_000)

        // The best of five: the first after a full scan pays for warming
        // what the full scan left behind, and a folder event is the steady
        // state, not the first one.
        var noChange = Duration.seconds(60)
        for _ in 0..<5 {
            clock = ContinuousClock.now
            try library.rescanFolders()
            noChange = min(noChange, ContinuousClock.now - clock)
        }
        XCTAssertEqual(reads.count, 1_000, "a no-change event reads no file")

        let launchReads = ReadCounter()
        clock = ContinuousClock.now
        let relaunched = LocalLyricsLibrary(directory: root, readFile: launchReads.read)
        let launch = ContinuousClock.now - clock
        await relaunched.waitForFolderScan()
        XCTAssertEqual(launchReads.count, 1_000, "the launch scan reads the folder")
        guard case .ready = relaunched.lookup(identity: identity(title: "Song 999")) else {
            return XCTFail("the large folder is read at launch")
        }
        print("F-043 1,000 files: full scan \(fullScan), no-change rescan \(noChange), init on the main thread \(launch)")
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

        // The pre-local nudge was written when corrections were added to the
        // lead; the store's sign migration reads it back as the delay it
        // always meant, so the line lights exactly where it did.
        XCTAssertEqual(store.trackOffset, -0.25, accuracy: 0.001)
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

        XCTAssertEqual(store.trackOffset, -LyricsStore.trackOffsetLimit, accuracy: 0.001)
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
            .init(filename: "orphan.lrc4.json", offset: -0.25),
        ])
    }

    func testNotchStoresMigrateLegacyNudgesBeforeLegacyCacheCleanup() throws {
        let track = identity()
        try write(studioLRC, to: legacyOverrides.appendingPathComponent("old.lrc"))
        let legacyEntry = legacyV4.appendingPathComponent(legacyV4Name(for: track))
        try write(legacyV4Entry(trackOffset: 0.25), to: legacyEntry)

        let stores = NotchStores(localLyricsDirectory: root)
        stores.lyrics.activateTrackOffset(for: track)

        XCTAssertEqual(stores.lyrics.trackOffset, -0.25, accuracy: 0.001)
        XCTAssertFalse(fileManager.fileExists(atPath: legacyEntry.path))
    }

    /// A file saved by a Windows lyric tool is rarely UTF-8. Every read was
    /// `String(contentsOf:encoding: .utf8)`, so a Russian listener's
    /// Windows-1251 LRC, a UTF-16 one with its byte order mark and a GB18030
    /// one all threw, and Import closed its panel with nothing to show for it
    /// (G-007). Each now reads with its exact text — and the copy kept in
    /// `imports/` is UTF-8, so the next launch reads it with no detection.
    func testLegacyEncodingsAreRead() throws {
        let cyrillic = "[ti:Группа крови]\n[ar:Кино]\n[al:Группа крови]\n[length:03:00]\n[00:01.00]Тёплое место, но улицы ждут"
        let wide = "[ti:Кукушка]\n[ar:Кино]\n[al:Чёрный альбом]\n[length:06:00]\n[00:01.00]Песен ещё ненаписанных сколько?"
        let chinese = "[ti:月亮代表我的心]\n[ar:邓丽君]\n[al:岛国之情歌]\n[length:03:00]\n[00:01.00]你问我爱你有多深"
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let files: [(name: String, data: Data, text: String)] = [
            ("cp1251", try XCTUnwrap(cyrillic.data(using: .windowsCP1251)), cyrillic),
            ("utf16", Data([0xFF, 0xFE]) + (try XCTUnwrap(wide.data(using: .utf16LittleEndian))), wide),
            ("gb18030", try XCTUnwrap(chinese.data(using: gb18030)), chinese),
        ]

        let library = LocalLyricsLibrary(directory: root)
        for file in files {
            let url = root.appendingPathComponent("\(file.name).lrc")
            try file.data.write(to: url, options: .atomic)
            XCTAssertNil(String(data: file.data, encoding: .utf8), "the fixture: \(file.name) is not UTF-8")

            let expected = try LocalLyricsDocument.parse(file.text)
            let candidate = try library.importDocument(at: url, binding: nil)
            XCTAssertEqual(candidate.document, expected, file.name)
        }

        let relaunched = LocalLyricsLibrary(directory: root)
        guard case .ready(let candidate) = relaunched.lookup(identity: identity(
            title: "Группа крови", artist: "Кино", album: "Группа крови", duration: 180
        )) else { return XCTFail("the kept copy reads back after a relaunch") }
        XCTAssertEqual(candidate.timeline.lines.map(\.text), ["Тёплое место, но улицы ждут"])
    }

    /// Bytes that are no text in any encoding Isla reads are refused with a
    /// reason of their own, so the panel that asked can say "Couldn't read
    /// this file as text." rather than nothing at all. Windows-1252 decodes
    /// nearly any byte, so it is the last guess and not the first: these
    /// three are undefined in every encoding on the list.
    func testBytesThatAreNotTextAreRefusedAsSuch() throws {
        let url = root.appendingPathComponent("noise.lrc")
        try Data([0x98, 0x81, 0xFF]).write(to: url, options: .atomic)
        let library = LocalLyricsLibrary(directory: root)

        XCTAssertThrowsError(try library.importDocument(at: url, binding: nil)) { error in
            XCTAssertEqual(error as? LocalLyricsLibrary.ReadError, .notText)
        }
    }

    /// A folder scan records why a file could not be shown, and those reasons
    /// were never drawn: a folder of lyrics with two broken files looked
    /// exactly like one with none. They are published by folder, by name,
    /// for Settings to list under the folder's row.
    func testAFolderNamesTheFilesItCouldNotRead() throws {
        let folder = try makeFolder(named: "Lyrics")
        try XCTUnwrap(
            "[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Звезда".data(using: .windowsCP1251)
        ).write(to: folder.appendingPathComponent("good.lrc"), options: .atomic)
        try write("[00:01.00]a\n[00:7x.00]b", to: folder.appendingPathComponent("broken.lrc"))
        try Data([0x98, 0x81, 0xFF]).write(to: folder.appendingPathComponent("noise.lrc"), options: .atomic)

        let library = LocalLyricsLibrary(directory: root)
        try library.addFolder(folder)

        XCTAssertEqual(library.unreadableFiles(in: folder), ["broken.lrc", "noise.lrc"])
        guard case .ready(let candidate) = library.lookup(identity: identity()) else {
            return XCTFail("the Windows-1251 file in the folder is read like any other")
        }
        XCTAssertEqual(candidate.timeline.lines.map(\.text), ["Звезда"])

        // Fixed, the name leaves the list.
        try write("[00:01.00]a\n[00:07.00]b", to: folder.appendingPathComponent("broken.lrc"))
        try library.rescanFolders()
        XCTAssertEqual(library.unreadableFiles(in: folder), ["noise.lrc"])
    }

    /// Save Copy writes a new import with the source's own tags, so once the
    /// binding was gone — Clear Bindings, or the song playing in another
    /// player — the song turned ambiguous behind a choice between the source
    /// and every copy (J-025). One source and its edits are one lineage now,
    /// and the newest edit is the answer; unrelated files still ask.
    func testTwoSavedEditsThenClearBindingsPicksTheNewestEdit() throws {
        let library = LocalLyricsLibrary(directory: root)
        let editor = LocalLyricsEditor(library: library)
        let track = identity()
        let source = try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: track)

        let firstDraft = LocalLyricsDraft(document: source.document)
        firstDraft.lines[0].text = "First edit"
        let first = try editor.saveOwnedCopy(firstDraft, editedFrom: source.id, binding: track)
        // The second edit starts from the first, as it does on the page: the
        // bound song shows the first edit, and Edit opens that.
        let secondDraft = LocalLyricsDraft(document: first.document)
        secondDraft.lines[0].text = "Second edit"
        let second = try editor.saveOwnedCopy(secondDraft, editedFrom: first.id, binding: track)

        library.clearBindings()

        guard case .ready(let chosen) = library.lookup(identity: track) else {
            return XCTFail("one source and its edits resolve to the newest edit, not a chooser")
        }
        XCTAssertEqual(chosen.id, second.id)
        XCTAssertNotNil(chosen.editedAt)
        XCTAssertNil(source.editedAt)

        // The lineage and save time survive a relaunch.
        let relaunched = LocalLyricsLibrary(directory: root)
        guard case .ready(let again) = relaunched.lookup(identity: track) else {
            return XCTFail("the lineage is saved in the index")
        }
        XCTAssertEqual(again.id, second.id)

        // An unrelated file with the same tags still asks.
        _ = try library.importDocument(at: try writeLRC("live", contents: liveLRC), binding: nil)
        guard case .ambiguous(let candidates) = library.lookup(identity: track) else {
            return XCTFail("an unrelated file is still a choice")
        }
        XCTAssertEqual(candidates.count, 4)
    }

    /// The chooser drew the source and its copy as two identical buttons.
    /// An edit says so, with the time it was saved.
    func testCandidateLabelsSayWhichIsAnEdit() throws {
        let library = LocalLyricsLibrary(directory: root)
        let source = try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: nil)
        let edit = try LocalLyricsEditor(library: library).saveOwnedCopy(
            LocalLyricsDraft(document: source.document), editedFrom: source.id, binding: nil
        )
        let savedAt = try XCTUnwrap(edit.editedAt)

        let editLabel = LyricsStage.candidateLabel(edit)
        let sourceLabel = LyricsStage.candidateLabel(source)
        XCTAssertNotEqual(editLabel, sourceLabel)
        XCTAssertTrue(editLabel.contains(localized(
            "Edited %@", savedAt.formatted(date: .abbreviated, time: .shortened)
        )), editLabel)
        XCTAssertFalse(sourceLabel.contains(localized("Edited %@", "")), sourceLabel)
    }

    /// v0.1.0 cached LRCLIB answers as `<key>.lrc3.json` in the same folder
    /// the migration reads, and the migration removed only lrc4 and lrc5 —
    /// and has already run for everyone upgrading — so third-party lyric text
    /// stayed on disk for good (J-016). It goes once, behind its own flag,
    /// by its exact suffix, and a user's own file beside it stays.
    func testLrc3CachesAreRemovedOnceAndUserFilesAreNot() throws {
        let index = root.appendingPathComponent("lyrics-local/index.json")
        try fileManager.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("{\"legacyMigrationCompleted\":true}", to: index)
        let cache = try write("{}", to: legacyV4.appendingPathComponent("0123456789abcdef.lrc3.json"))
        let userFile = try write(studioLRC, to: legacyV4.appendingPathComponent("song.lrc"))
        let lookalike = try write("{}", to: legacyV4.appendingPathComponent("notes.lrc3.json.txt"))

        _ = LocalLyricsLibrary(directory: root)

        XCTAssertFalse(fileManager.fileExists(atPath: cache.path))
        XCTAssertTrue(fileManager.fileExists(atPath: userFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: lookalike.path))

        // Once: a second launch leaves the folder alone.
        let later = try write("{}", to: legacyV4.appendingPathComponent("fedcba9876543210.lrc3.json"))
        _ = LocalLyricsLibrary(directory: root)
        XCTAssertTrue(fileManager.fileExists(atPath: later.path))
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

    /// An expectation met the first time `condition` holds after the library
    /// announces a change. Checked on every revision rather than on the first
    /// one, so an unrelated rescan in between cannot satisfy it early.
    private func expectation(
        on library: LocalLyricsLibrary, _ condition: @escaping () -> Bool
    ) -> (expectation: XCTestExpectation, cancel: () -> Void) {
        let met = expectation(description: "the library saw the change")
        met.assertForOverFulfill = false
        let subscription = library.$revision.dropFirst().sink { _ in
            // `@Published` announces before it stores; the library's state is
            // already changed by then, but give the revision itself a turn.
            DispatchQueue.main.async { if condition() { met.fulfill() } }
        }
        return (met, { subscription.cancel() })
    }

    private func lrc(title: String, line: String = "First", lines: Int = 1) -> String {
        let body = (0..<lines).map { "[\(String(format: "%02d:%02d.00", $0 / 60, $0 % 60 + 1))]\(line)" }
        return (["[ti:\(title)]", "[ar:Artist]", "[al:Album]", "[length:03:00]"] + body)
            .joined(separator: "\n")
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

/// A `readFile` that counts what the library reads, from whichever thread
/// the scan runs on, and reads it the way the library would.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var count: Int { lock.withLock { paths.count } }
    var names: [String] { lock.withLock { paths } }

    func read(_ url: URL) throws -> String {
        lock.withLock { paths.append(url.lastPathComponent) }
        return try LocalLyricsLibrary.readText(at: url)
    }
}
