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

/// The only lyric-data authority in Isla. Its inputs are explicit LRC imports
/// and explicitly selected folders; it has no remote resolver or transport.
@MainActor
final class LocalLyricsLibrary: ObservableObject {
    enum FileIssue: String, Codable, Equatable, Sendable {
        case malformed
        case unreadable
    }

    @Published private(set) var revision = 0

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

    private struct State: Codable {
        var documents: [StoredDocument] = []
        var folders: [StoredFolder] = []
        var bindings: [String: UUID] = [:]
        var issues: [StoredIssue] = []
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

    /// `legacyV5Directory` and `legacyV4Directory` are accepted now so the
    /// migration task can be introduced without changing this public seam.
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
        reloadImportedRecords()
        try? rescanFolders()
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
