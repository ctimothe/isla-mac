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

    /// A folder inside another one the library reads is walked twice: on its
    /// own, and as part of its parent. Each file used to be indexed once per
    /// walk. One already indexed went in twice under the same id, and the next
    /// rescan built its path-to-id table from that — a trap in
    /// `Dictionary(uniqueKeysWithValues:)`, and since the library rescans as it
    /// opens, a crash at every launch. One arriving later got an id per walk,
    /// and every lookup for its song became a choice between two copies.
    func testAFolderInsideAnotherReadsEachFileOnce() throws {
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
        guard case .ready = relaunched.lookup(identity: identity()) else {
            return XCTFail("the next launch reads the same single document")
        }
    }

    /// An index written by a newer build can carry an origin this build has
    /// never heard of. One such entry used to fail the whole decode, the
    /// library opened empty and wrote that emptiness straight back: every
    /// folder, binding and import record gone, the imported files orphaned.
    /// Only the entry this build cannot read is dropped now.
    func testAnUnknownOriginLosesOnlyThatEntry() throws {
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
