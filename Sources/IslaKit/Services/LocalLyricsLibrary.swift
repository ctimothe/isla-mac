import Combine
import Darwin
import Foundation

/// Stable, local-only description of the recording currently playing.
struct LocalTrackIdentity: Codable, Equatable, Hashable, Sendable {
    let playerID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let recordingID: String?
}

struct LocalLyricsCandidate: Identifiable, Equatable, Sendable {
    enum Origin: String, Codable, Equatable, Sendable {
        case imported
        case referencedFolder
    }

    let id: UUID
    let document: LocalLyricsDocument
    let origin: Origin

    var timeline: LyricTimeline {
        document.timeline(documentID: id)
    }
}

enum LocalLyricsLookup: Equatable {
    case ready(LocalLyricsCandidate)
    case noMatch
    case ambiguous([LocalLyricsCandidate])
    case invalid(LocalLyricsLibrary.FileIssue)
}

/// A migrated local document that needs an explicit binding before it can be
/// displayed. Its contents remain in Isla-owned storage; a parsed candidate is
/// available for an explicit binding, while malformed files surface only their
/// filename and validation state.
struct LocalUnassignedImport: Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let issue: LocalLyricsLibrary.FileIssue?
    let candidate: LocalLyricsCandidate?
}

/// The only lyric-data authority in Isla. Its inputs are explicit LRC imports
/// and explicitly selected folders; it has no remote resolver or transport.
@MainActor
final class LocalLyricsLibrary: ObservableObject {
    enum FileIssue: String, Codable, Equatable, Sendable {
        case malformed
        case unreadable
    }

    @Published private(set) var revision = 0
    @Published private(set) var unassignedImports: [LocalUnassignedImport] = []

    /// The support root shared with local timing-correction persistence.
    var storageDirectory: URL { root }

    private struct StoredDocument: Codable, Equatable {
        let id: UUID
        let origin: LocalLyricsCandidate.Origin
        let path: String
    }

    private struct StoredFolder: Codable, Equatable {
        let path: String
        let bookmark: Data?
    }

    private struct StoredIssue: Codable, Equatable {
        let path: String
        let issue: FileIssue
    }

    private struct StoredUnassignedImport: Codable, Equatable {
        let id: UUID
        let path: String
        let issue: FileIssue?
    }

    private struct State: Codable {
        var documents: [StoredDocument] = []
        var folders: [StoredFolder] = []
        var bindings: [String: UUID] = [:]
        var issues: [StoredIssue] = []
        var unassignedImports: [StoredUnassignedImport] = []
        var legacyMigrationCompleted = false

        enum CodingKeys: String, CodingKey {
            case documents, folders, bindings, issues, unassignedImports, legacyMigrationCompleted
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            documents = try container.decodeIfPresent([StoredDocument].self, forKey: .documents) ?? []
            folders = try container.decodeIfPresent([StoredFolder].self, forKey: .folders) ?? []
            bindings = try container.decodeIfPresent([String: UUID].self, forKey: .bindings) ?? [:]
            issues = try container.decodeIfPresent([StoredIssue].self, forKey: .issues) ?? []
            unassignedImports = try container.decodeIfPresent(
                [StoredUnassignedImport].self, forKey: .unassignedImports
            ) ?? []
            legacyMigrationCompleted = try container.decodeIfPresent(
                Bool.self, forKey: .legacyMigrationCompleted
            ) ?? false
        }
    }

    private struct Record {
        let stored: StoredDocument
        let document: LocalLyricsDocument

        var candidate: LocalLyricsCandidate {
            LocalLyricsCandidate(id: stored.id, document: document, origin: stored.origin)
        }
    }

    private let root: URL
    private let importsDirectory: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private let onLookup: (LocalTrackIdentity) -> Void
    private var state: State
    private var records: [UUID: Record] = [:]
    private var folderWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var scheduledRescan: DispatchWorkItem?
    private var watching = false

    init(
        directory: URL,
        legacyV5Directory: URL? = nil,
        legacyV4Directory: URL? = nil,
        onLookup: @escaping (LocalTrackIdentity) -> Void = { _ in },
        fileManager: FileManager = .default
    ) {
        root = directory.appendingPathComponent("lyrics-local", isDirectory: true)
        importsDirectory = root.appendingPathComponent("imports", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        self.fileManager = fileManager
        self.onLookup = onLookup
        state = Self.loadState(from: indexURL, fileManager: fileManager)
        try? fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        let v5 = legacyV5Directory ?? directory.appendingPathComponent("lyrics-v5", isDirectory: true)
        let v4 = legacyV4Directory ?? directory.appendingPathComponent("lyrics", isDirectory: true)
        migrateLegacyData(v5Directory: v5, v4Directory: v4)
        reloadImportedRecords()
        try? rescanFolders()
        rebuildUnassignedImports()
    }

    func importDocument(at url: URL, binding: LocalTrackIdentity?) throws -> LocalLyricsCandidate {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try importDocument(raw, binding: binding)
    }

    func importDocument(_ raw: String, binding: LocalTrackIdentity?) throws -> LocalLyricsCandidate {
        let document = try LocalLyricsDocument.parse(raw)
        let id = UUID()
        let destination = importsDirectory.appendingPathComponent("\(id.uuidString).lrc")
        try fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: destination, options: .atomic)

        let stored = StoredDocument(id: id, origin: .imported, path: destination.path)
        let record = Record(stored: stored, document: document)
        state.documents.append(stored)
        records[id] = record
        if let binding { state.bindings[identityKey(binding)] = id }
        persist()
        advanceRevision()
        return record.candidate
    }

    func addFolder(_ url: URL) throws {
        let standard = url.standardizedFileURL
        guard !state.folders.contains(where: { $0.path == standard.path }) else { return }
        let bookmark = try? standard.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        state.folders.append(StoredFolder(path: standard.path, bookmark: bookmark))
        try rescanFolders()
        persist()
        if watching { installFolderWatchers() }
    }

    func removeFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        state.folders.removeAll { $0.path == path }
        state.documents.removeAll { $0.origin == .referencedFolder && $0.path.hasPrefix(path + "/") }
        records = records.filter { $0.value.stored.origin != .referencedFolder || !$0.value.stored.path.hasPrefix(path + "/") }
        state.issues.removeAll { $0.path.hasPrefix(path + "/") }
        persist()
        advanceRevision()
        if watching { installFolderWatchers() }
    }

    func rescanFolders() throws {
        let existingIDs = Dictionary(
            uniqueKeysWithValues: state.documents
                .filter { $0.origin == .referencedFolder }
                .map { ($0.path, $0.id) }
        )
        let imports = state.documents.filter { $0.origin == .imported }
        var references: [StoredDocument] = []
        var issues: [StoredIssue] = []

        for folder in state.folders {
            let url = try resolve(folder)
            let hadAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hadAccess { url.stopAccessingSecurityScopedResource() }
            }

            guard let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else {
                issues.append(StoredIssue(path: url.path, issue: .unreadable))
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame,
                      (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }

                let path = fileURL.standardizedFileURL.path
                do {
                    let raw = try String(contentsOf: fileURL, encoding: .utf8)
                    let document = try LocalLyricsDocument.parse(raw)
                    let stored = StoredDocument(
                        id: existingIDs[path] ?? UUID(), origin: .referencedFolder, path: path
                    )
                    references.append(stored)
                    records[stored.id] = Record(stored: stored, document: document)
                } catch is LocalLyricsDocument.Error {
                    issues.append(StoredIssue(path: path, issue: .malformed))
                } catch {
                    issues.append(StoredIssue(path: path, issue: .unreadable))
                }
            }
        }

        let surviving = Set(references.map(\.id))
        records = records.filter { $0.value.stored.origin == .imported || surviving.contains($0.key) }
        state.documents = imports + references
        state.issues = issues
        persist()
        advanceRevision()
    }

    func lookup(identity: LocalTrackIdentity) -> LocalLyricsLookup {
        onLookup(identity)
        if let id = state.bindings[identityKey(identity)] {
            if let record = records[id] { return .ready(record.candidate) }
            return .invalid(.unreadable)
        }

        let candidates = records.values.map(\.candidate).filter { candidate in
            let metadata = candidate.document.metadata
            guard let title = metadata.title, let artist = metadata.artist,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let duration = candidate.document.duration else {
                return false
            }
            return abs(duration - identity.duration) <= 2
        }

        let titleArtist = candidates.filter {
            normalized($0.document.metadata.title ?? "") == normalized(identity.title)
                && normalized($0.document.metadata.artist ?? "") == normalized(identity.artist)
        }
        let albumMatches = titleArtist.filter {
            normalized($0.document.metadata.album ?? "") == normalized(identity.album)
                && abs(($0.document.duration ?? .greatestFiniteMagnitude) - identity.duration) <= 2
        }
        if albumMatches.count == 1 { return .ready(albumMatches[0]) }
        if albumMatches.count > 1 { return .ambiguous(albumMatches) }

        let durationMatches = titleArtist.filter {
            abs(($0.document.duration ?? .greatestFiniteMagnitude) - identity.duration) <= 0.5
        }
        if durationMatches.count == 1 { return .ready(durationMatches[0]) }
        if durationMatches.count > 1 { return .ambiguous(durationMatches) }
        return .noMatch
    }

    func bind(_ candidate: LocalLyricsCandidate, to identity: LocalTrackIdentity) {
        guard records[candidate.id] != nil else { return }
        state.bindings[identityKey(identity)] = candidate.id
        state.unassignedImports.removeAll { $0.id == candidate.id }
        rebuildUnassignedImports()
        persist()
        advanceRevision()
    }

    func removeBinding(for identity: LocalTrackIdentity) {
        state.bindings.removeValue(forKey: identityKey(identity))
        persist()
        advanceRevision()
    }

    func startWatchingFolders() {
        guard !watching else { return }
        watching = true
        installFolderWatchers()
    }

    func stopWatchingFolders() {
        watching = false
        scheduledRescan?.cancel()
        scheduledRescan = nil
        folderWatchers.values.forEach { $0.cancel() }
        folderWatchers.removeAll()
    }

    /// Makes the only permitted exception to the new file format boundary:
    /// user-authored LRC overrides move into the new local library, then every
    /// cache entry from retired lyric sources is removed. No remote lyric text
    /// is decoded, displayed, or copied during this pass.
    private func migrateLegacyData(v5Directory: URL, v4Directory: URL) {
        guard !state.legacyMigrationCompleted else { return }

        var recoveredOffsets: [LyricsStore.LegacyOffsetMigration] = []
        var matchedV4Paths = Set<String>()
        let overrides = v5Directory.appendingPathComponent("overrides", isDirectory: true)
        for source in Self.files(
            in: overrides,
            fileManager: fileManager,
            matching: { $0.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame }
        ) {
            let id = UUID()
            let destination = importsDirectory.appendingPathComponent("\(id.uuidString).lrc")
            guard let raw = try? String(contentsOf: source, encoding: .utf8) else {
                state.unassignedImports.append(
                    StoredUnassignedImport(id: id, path: source.path, issue: .unreadable)
                )
                continue
            }
            do {
                try Data(raw.utf8).write(to: destination, options: .atomic)
            } catch {
                // The source stays in the prior location and is named in the
                // recovery list; migration never destroys a user file it could
                // not make durable in its new home.
                state.unassignedImports.append(
                    StoredUnassignedImport(id: id, path: source.path, issue: .unreadable)
                )
                continue
            }

            do {
                let document = try LocalLyricsDocument.parse(raw)
                let stored = StoredDocument(id: id, origin: .imported, path: destination.path)
                state.documents.append(stored)
                if let identity = Self.legacyIdentity(for: document) {
                    let v4Name = LyricsStore.cacheKey(
                        title: identity.title,
                        artist: identity.artist,
                        album: identity.album,
                        duration: identity.duration
                    )
                    let v4 = v4Directory.appendingPathComponent("\(v4Name).lrc4.json")
                    if let offset = Self.legacyTrackOffset(at: v4) {
                        recoveredOffsets.append(.init(identity: identity, offset: offset))
                        matchedV4Paths.insert(v4.standardizedFileURL.path)
                    }
                } else {
                    state.unassignedImports.append(
                        StoredUnassignedImport(id: id, path: destination.path, issue: nil)
                    )
                }
            } catch {
                state.issues.append(StoredIssue(path: destination.path, issue: .malformed))
                state.unassignedImports.append(
                    StoredUnassignedImport(id: id, path: destination.path, issue: .malformed)
                )
            }
        }

        let legacyV4Entries = Self.files(in: v4Directory, fileManager: fileManager) {
            $0.lastPathComponent.hasSuffix(".lrc4.json")
        }
        let unassignedOffsets = legacyV4Entries.compactMap { entry -> LyricsStore.UnassignedLegacyOffset? in
            guard !matchedV4Paths.contains(entry.standardizedFileURL.path),
                  let offset = Self.legacyTrackOffset(at: entry)
            else { return nil }
            return LyricsStore.UnassignedLegacyOffset(filename: entry.lastPathComponent, offset: offset)
        }
        LyricsStore.migrateLegacyOffsets(
            recoveredOffsets,
            unassigned: unassignedOffsets,
            directory: root,
            fileManager: fileManager
        )

        Self.removeLegacyCacheEntries(in: v5Directory, fileManager: fileManager)
        Self.removeLegacyCacheEntries(in: v4Directory, fileManager: fileManager)
        state.legacyMigrationCompleted = true
        persist()
    }

    private func rebuildUnassignedImports() {
        unassignedImports = state.unassignedImports.map { stored in
            LocalUnassignedImport(
                id: stored.id,
                filename: URL(fileURLWithPath: stored.path).lastPathComponent,
                issue: stored.issue,
                candidate: records[stored.id]?.candidate
            )
        }
    }

    private func reloadImportedRecords() {
        var imported: [StoredDocument] = []
        for stored in state.documents where stored.origin == .imported {
            guard let raw = try? String(contentsOfFile: stored.path, encoding: .utf8),
                  let document = try? LocalLyricsDocument.parse(raw)
            else { continue }
            imported.append(stored)
            records[stored.id] = Record(stored: stored, document: document)
        }
        state.documents = imported + state.documents.filter { $0.origin == .referencedFolder }
    }

    private static func legacyIdentity(for document: LocalLyricsDocument) -> LocalTrackIdentity? {
        guard let title = document.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              let artist = document.metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              let album = document.metadata.album,
              let duration = document.duration,
              !title.isEmpty, !artist.isEmpty
        else { return nil }
        return LocalTrackIdentity(
            playerID: "legacy", title: title, artist: artist, album: album,
            duration: duration, recordingID: nil
        )
    }

    private static func legacyTrackOffset(at url: URL) -> TimeInterval? {
        struct Entry: Decodable { let trackOffset: TimeInterval? }
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              let offset = entry.trackOffset,
              abs(offset) > 0.000_001
        else { return nil }
        return offset
    }

    private static func files(
        in directory: URL,
        fileManager: FileManager = .default,
        matching: (URL) -> Bool = { _ in true }
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && matching(url)
        }
    }

    private static func removeLegacyCacheEntries(in directory: URL, fileManager: FileManager) {
        for entry in files(in: directory, fileManager: fileManager) where entry.lastPathComponent.hasSuffix(".lrc5.json")
            || entry.lastPathComponent.hasSuffix(".lrc4.json") {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func resolve(_ folder: StoredFolder) throws -> URL {
        guard let bookmark = folder.bookmark else { return URL(fileURLWithPath: folder.path) }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        return stale ? URL(fileURLWithPath: folder.path) : url
    }

    private func installFolderWatchers() {
        folderWatchers.values.forEach { $0.cancel() }
        folderWatchers.removeAll()
        for folder in state.folders {
            let url = (try? resolve(folder)) ?? URL(fileURLWithPath: folder.path)
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleFolderRescan() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            folderWatchers[folder.path] = source
        }
    }

    private func scheduleFolderRescan() {
        scheduledRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in try? self?.rescanFolders() }
        }
        scheduledRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    private func identityKey(_ identity: LocalTrackIdentity) -> String {
        [
            identity.playerID, identity.title, identity.artist, identity.album,
            String(format: "%.3f", identity.duration), identity.recordingID ?? "",
        ].joined(separator: "\u{1F}")
    }

    private func normalized(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let collapsed = compatible.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(collapsed).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func persist() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func advanceRevision() {
        revision &+= 1
    }

    private static func loadState(from url: URL, fileManager: FileManager) -> State {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }
}
