import AppKit
import Combine
import CoreServices
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
    /// When this copy was saved from the editor; nil for anything that is
    /// not an edit. A copy carries its source's tags word for word, so the
    /// chooser drew the two as identical buttons until this was shown.
    var editedAt: Date? = nil

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
    enum NetworkPolicy: Equatable, Sendable {
        case forbidden
    }

    static let networkPolicy: NetworkPolicy = .forbidden

    enum FileIssue: String, Codable, Equatable, Sendable {
        case malformed
        case unreadable
    }

    /// Why `readText(at:)` gave up on a file it could open: its bytes are no
    /// text in any encoding on the list. Separate from a parse error so the
    /// panel that asked can say which of the two it was.
    enum ReadError: Swift.Error, Equatable {
        case notText
    }

    /// The legacy encodings tried, in this order, once a file is neither
    /// UTF-8 nor marked as UTF-16 or UTF-32: the scripts of the people Isla
    /// is used by — Cyrillic, Chinese, Japanese, Korean — and Western
    /// European last, because Windows-1252 decodes nearly any byte and would
    /// win over the rest. It is never a blind guess: Foundation scores each
    /// candidate against the bytes and refuses one that would need a lossy
    /// conversion. Guessing Windows-1251 for every file that is not UTF-8 was
    /// rejected for exactly that reason — it decodes every byte sequence, so a
    /// GBK file would have come back as confident Cyrillic nonsense.
    nonisolated static let legacyEncodings: [String.Encoding] = [
        .windowsCP1251,
        encoding(.GB_18030_2000),
        .shiftJIS,
        encoding(.EUC_KR),
        .windowsCP1252,
    ]

    private nonisolated static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    /// Reads a lyric file as text, whatever wrote it.
    ///
    /// Every read used to be `String(contentsOf:encoding: .utf8)`. A file
    /// saved by a Windows lyric tool is rarely UTF-8, so a Russian listener's
    /// Windows-1251 LRC, a UTF-16 one and a GBK one each threw: Import closed
    /// its panel with nothing to show, and a folder scan filed the file as
    /// unreadable for good (G-007). Strict UTF-8 is still the first answer
    /// for anything it can read; a byte order mark is believed next; only
    /// then are the legacy encodings scored. What comes back is a `String`,
    /// so a copy written into `imports/` is UTF-8 from then on.
    nonisolated static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // The marks first, though strict UTF-8 is the commoner answer: ASCII
        // text in UTF-16 is full of NUL bytes, and NUL is valid UTF-8, so
        // a mark-less read could not be trusted to fail. A UTF-8 mark is
        // left to the UTF-8 read below; the parser skips it.
        let marked: [(mark: [UInt8], encoding: String.Encoding)] = [
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (mark, encoding) in marked where data.starts(with: mark) {
            if let text = String(data: data.dropFirst(mark.count), encoding: encoding) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        var lossy = ObjCBool(false)
        // The answer is read from `converted`, never from the returned
        // encoding: for bytes no candidate can decode, Foundation still
        // returns its best-scoring encoding, with no string.
        _ = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: legacyEncodings.map(\.rawValue),
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        guard let converted, !lossy.boolValue else { throw ReadError.notText }
        return converted as String
    }

    /// The files inside one selected folder that could not be shown — not
    /// text, or text with a broken stamp — by file name, for Settings to
    /// list under that folder's row. A folder that cannot be reached at all
    /// is listed under its own name.
    ///
    /// A scan always recorded these, and nothing ever drew them: a folder
    /// with two broken files looked exactly like one with none. It is read
    /// from the saved issues rather than kept as a second copy, and Settings
    /// redraws with it because every change to the issues advances
    /// `revision`.
    func unreadableFiles(in folder: URL) -> [String] {
        let path = folder.standardizedFileURL.path
        let roots = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        return state.issues
            .filter { issue in roots.contains { issue.path == $0 || issue.path.hasPrefix($0 + "/") } }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @Published private(set) var revision = 0
    @Published private(set) var unassignedImports: [LocalUnassignedImport] = []

    /// The support root shared with local timing-correction persistence.
    var storageDirectory: URL { root }
    var selectedFolders: [URL] { state.folders.map { URL(fileURLWithPath: $0.path) } }

    private struct StoredDocument: Codable, Equatable {
        let id: UUID
        let origin: LocalLyricsCandidate.Origin
        let path: String
        /// The document an editor save was made from (nil for a file the
        /// listener imported), and when any import was written. Optional so
        /// an index from any earlier build decodes unchanged — a copy saved
        /// before these existed simply reads as an import.
        var editedFrom: UUID? = nil
        var savedAt: Date? = nil
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
        /// Its own flag, not the migration's: everyone upgrading from 0.1.0
        /// has already finished that migration, which never knew lrc3.
        var legacyLrc3Removed = false

        enum CodingKeys: String, CodingKey {
            case documents, folders, bindings, issues, unassignedImports, legacyMigrationCompleted
            case legacyLrc3Removed
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The three lists that carry an enum are read an element at a
            // time. An index written by a newer build sharing this Application
            // Support folder can hold an origin or an issue this build has
            // never heard of, and one such entry used to fail the whole
            // decode: the library opened empty and saved that emptiness over
            // every folder, binding and import record. Now only that entry is
            // lost, the day this build next writes the index.
            documents = try container.decodeIfPresent(
                [Lossy<StoredDocument>].self, forKey: .documents
            )?.compactMap(\.value) ?? []
            folders = try container.decodeIfPresent([StoredFolder].self, forKey: .folders) ?? []
            bindings = try container.decodeIfPresent([String: UUID].self, forKey: .bindings) ?? [:]
            issues = try container.decodeIfPresent(
                [Lossy<StoredIssue>].self, forKey: .issues
            )?.compactMap(\.value) ?? []
            unassignedImports = try container.decodeIfPresent(
                [Lossy<StoredUnassignedImport>].self, forKey: .unassignedImports
            )?.compactMap(\.value) ?? []
            legacyMigrationCompleted = try container.decodeIfPresent(
                Bool.self, forKey: .legacyMigrationCompleted
            ) ?? false
            legacyLrc3Removed = try container.decodeIfPresent(
                Bool.self, forKey: .legacyLrc3Removed
            ) ?? false
        }
    }

    /// One element of a list that is kept when it decodes and dropped when it
    /// does not, rather than taking the whole list down with it.
    private struct Lossy<Element: Decodable>: Decodable {
        let value: Element?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Element.self)
        }
    }

    /// What a folder file looked like when it was read, from the values the
    /// directory walk prefetches. The status-change time is in it as well as
    /// the modification date: a sync client or `cp -p` can put a file's
    /// modification date back, and nothing can set the status-change time
    /// back — and a file saved by replacing it is a new file with a new one.
    private struct FileStamp: Equatable, Sendable {
        let modified: Date
        let changed: Date?
        let size: Int

        static let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentModificationDateKey, .attributeModificationDateKey, .fileSizeKey,
        ]

        init?(_ values: URLResourceValues) {
            guard let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
            self.modified = modified
            changed = values.attributeModificationDate
            self.size = size
        }
    }

    /// One folder file as a scan left it: the document it parsed to, or why
    /// it could not be shown. A stamp of nil never matches, so a file whose
    /// dates could not be read is read every time, as every file used to be.
    private struct ScannedFile: Sendable {
        enum Outcome: Sendable {
            case parsed(LocalLyricsDocument)
            case failed(FileIssue)
        }

        let stamp: FileStamp?
        let outcome: Outcome
    }

    /// What one walk of the selected folders found, in folder order: plain
    /// values, so the launch scan can make it off the main thread and hand
    /// it back to be applied.
    private struct FolderWalk: Sendable {
        struct Folder: Sendable {
            enum Finding: Sendable {
                case unreachable
                case unenumerable(path: String)
                case files([(path: String, file: ScannedFile)])
            }

            let path: String
            let finding: Finding
        }

        var folders: [Folder] = []
        var scanned: [String: ScannedFile] = [:]
    }

    /// What a rescan compares against to tell whether anything is news.
    private struct Baseline {
        let documents: [StoredDocument]
        let issues: [StoredIssue]
        let folders: [StoredFolder]
    }

    private struct Record {
        let stored: StoredDocument
        let document: LocalLyricsDocument

        var candidate: LocalLyricsCandidate {
            LocalLyricsCandidate(
                id: stored.id, document: document, origin: stored.origin,
                editedAt: stored.editedFrom == nil ? nil : stored.savedAt
            )
        }
    }

    private let root: URL
    private let importsDirectory: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private let onLookup: (LocalTrackIdentity) -> Void
    /// How a folder file's text is read. A seam for the tests, which count
    /// what a rescan reads; the app reads with `readText(at:)`. Sendable
    /// because the launch scan calls it off the main thread.
    private let readFile: @Sendable (URL) throws -> String
    private var state: State
    private var records: [UUID: Record] = [:]
    /// Every folder file the last scan saw, by path, with the stamp it had
    /// and what reading it gave. A rescan reads only a file whose stamp has
    /// moved and takes everything else from here. In memory only: the first
    /// scan after a launch still reads every file, though off the main thread.
    private var scanned: [String: ScannedFile] = [:]
    /// The launch scan of the selected folders, while it may still be out.
    private var launchScan: Task<Void, Never>?
    /// True until the launch scan has landed or been overtaken by a rescan:
    /// a folder document with nothing read for it yet is waiting, not broken.
    private var launchScanPending = false
    /// Advanced by every explicit rescan, so a launch scan that started
    /// before one cannot land after it with what it read earlier.
    private var scanGeneration = 0
    private var folderWatch: FolderWatch?
    private var scheduledRescan: DispatchWorkItem?
    /// Set when a pending rescan must also re-make the watch: the root of a
    /// watched folder moved, or a disk came or went.
    private var pendingReinstall = false
    private var watching = false

    init(
        directory: URL,
        legacyV5Directory: URL? = nil,
        legacyV4Directory: URL? = nil,
        onLookup: @escaping (LocalTrackIdentity) -> Void = { _ in },
        fileManager: FileManager = .default,
        readFile: @escaping @Sendable (URL) throws -> String = { try LocalLyricsLibrary.readText(at: $0) }
    ) {
        self.readFile = readFile
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
        removeLegacyLrc3Caches(in: v4)
        reloadImportedRecords()
        // Imports are read here, as before: they are the listener's own few
        // files in Isla's own folder. The selected folders can hold thousands,
        // and reading and parsing every one of them here held the main thread
        // for the whole walk before the island first drew (F-043). Their walk
        // runs off the main thread and lands a moment later.
        if state.folders.isEmpty {
            try? rescanFolders()
        } else {
            startLaunchScan()
        }
        rebuildUnassignedImports()
    }

    func importDocument(at url: URL, binding: LocalTrackIdentity?) throws -> LocalLyricsCandidate {
        let raw = try Self.readText(at: url)
        return try importDocument(raw, binding: binding)
    }

    func importDocument(
        _ raw: String, binding: LocalTrackIdentity?, editedFrom: UUID? = nil
    ) throws -> LocalLyricsCandidate {
        let document = try LocalLyricsDocument.parse(raw)
        let id = UUID()
        let destination = importsDirectory.appendingPathComponent("\(id.uuidString).lrc")
        try fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: destination, options: .atomic)

        let stored = StoredDocument(
            id: id, origin: .imported, path: destination.path, editedFrom: editedFrom, savedAt: Date()
        )
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
        state.folders.append(StoredFolder(path: standard.path, bookmark: Self.bookmark(for: standard)))
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
        scanned = scanned.filter { !$0.key.hasPrefix(path + "/") }
        pruneDanglingBindings()
        persist()
        advanceRevision()
        if watching { installFolderWatchers() }
    }

    /// Reads the selected folders again, on the main thread, and reads only
    /// the files that changed since the last scan.
    ///
    /// Every rescan used to read and parse every `.lrc` in every folder, and
    /// FSEvents brings one for any write anywhere under a watched folder: a
    /// large library stalled the panel each time Finder or a sync client
    /// touched it (F-043). A file whose stamp has not moved now keeps what
    /// reading it gave last time, and its id with it; only news still
    /// advances the revision.
    func rescanFolders() throws {
        // An explicit rescan overtakes a launch scan still out — Rescan in
        // Settings, a folder added in the first moments after launch. It
        // cannot wait for it here without blocking the main thread, so it
        // does the whole walk itself, and the launch scan, which may have
        // read the folders before whatever this rescan was asked to see,
        // is dropped when it lands.
        scanGeneration &+= 1
        if launchScanPending {
            launchScan?.cancel()
            launchScanPending = false
        }
        let before = baseline()
        // Before the walk: a folder that moved has its documents' paths
        // rewritten first, so they find their ids under the new path instead
        // of minting new ones.
        let located = followMovedFolders()
        let walk = Self.walk(
            folderPlan(located), known: scanned, fileManager: fileManager, readFile: readFile
        )
        apply(walk, since: before)
    }

    /// Returns once the launch scan of the selected folders has landed, or
    /// at once when there is none. A folder event waits on it rather than
    /// overtaking it, so the scan's work is not thrown away; the tests wait
    /// on it to read what it found.
    func waitForFolderScan() async {
        await launchScan?.value
    }

    /// Follows moved folders on the main thread — it rewrites the index —
    /// and walks and parses the folders on a background task, which hands
    /// what it found back to the main actor to apply.
    ///
    /// Until it lands, a song in one of the folders reads as no match, and
    /// the revision it then advances sends the track on screen back through
    /// resolution. The walk works on plain values: the folder list and a
    /// copy of the stamps, which at launch are empty, so the first scan of a
    /// session still parses every file — just not on the main thread.
    private func startLaunchScan() {
        let before = baseline()
        let located = followMovedFolders()
        // A folder found somewhere new is saved now rather than when the
        // scan lands, so a rescan that overtakes the scan cannot lose it.
        if state.folders != before.folders || state.documents != before.documents { persist() }
        let plan = folderPlan(located)
        let known = scanned
        let fileManager = fileManager
        let readFile = readFile
        let generation = scanGeneration
        launchScanPending = true
        launchScan = Task.detached(priority: .userInitiated) { [weak self] in
            let walk = Self.walk(plan, known: known, fileManager: fileManager, readFile: readFile)
            await self?.finishLaunchScan(walk, since: before, generation: generation)
        }
    }

    private func finishLaunchScan(_ walk: FolderWalk, since before: Baseline, generation: Int) {
        launchScan = nil
        guard generation == scanGeneration else { return }
        launchScanPending = false
        apply(walk, since: before)
    }

    private func baseline() -> Baseline {
        Baseline(documents: state.documents, issues: state.issues, folders: state.folders)
    }

    private func folderPlan(_ located: [URL?]) -> [(path: String, url: URL?)] {
        zip(state.folders, located).map { ($0.path, $1) }
    }

    /// Walks the folders and reads every `.lrc` whose stamp is not the one
    /// in `known`. Touches nothing of the library's, so it runs on any
    /// thread; a cancelled walk stops early, and its result is discarded.
    private nonisolated static func walk(
        _ plan: [(path: String, url: URL?)],
        known: [String: ScannedFile],
        fileManager: FileManager,
        readFile: @Sendable (URL) throws -> String
    ) -> FolderWalk {
        var walk = FolderWalk()
        walk.scanned.reserveCapacity(known.count)
        for (path, url) in plan {
            // A folder that cannot be reached — a disk unplugged, a share not
            // mounted, a folder since deleted — must not cost the others. Its
            // bookmark throws, and the rescan used to throw with it: the whole
            // rescan was abandoned, and every folder after the missing one
            // went unread for the session.
            let hadAccess = url?.startAccessingSecurityScopedResource() ?? false
            defer {
                if hadAccess { url?.stopAccessingSecurityScopedResource() }
            }
            guard let url, (try? url.checkResourceIsReachable()) == true else {
                walk.folders.append(.init(path: path, finding: .unreachable))
                continue
            }
            // The stamp's values are fetched with the listing, so a file that
            // has not changed costs no read and no parse — only its entry.
            guard let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: FileStamp.keys, options: [.skipsHiddenFiles]
            ) else {
                walk.folders.append(.init(path: path, finding: .unenumerable(path: url.path)))
                continue
            }

            var files: [(path: String, file: ScannedFile)] = []
            let keys = Set(FileStamp.keys)
            // Paths are kept in their standardized form — `/tmp`, not the
            // `/private/tmp` the walk hands back — because that is how every
            // index has saved them. Standardizing is most of what a file that
            // has not changed costs, so it is done once per directory, not
            // once per file.
            var standardDirectories: [Substring: String] = [:]
            for case let fileURL as URL in enumerator {
                if Task.isCancelled { return walk }
                guard fileURL.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame,
                      let values = try? fileURL.resourceValues(forKeys: keys),
                      values.isRegularFile == true
                else { continue }

                let raw = fileURL.path
                guard let slash = raw.lastIndex(of: "/") else { continue }
                let directory = raw[..<slash]
                let standard = standardDirectories[directory] ?? {
                    let path = URL(fileURLWithPath: String(directory), isDirectory: true).standardizedFileURL.path
                    standardDirectories[directory] = path
                    return path
                }()
                let filePath = standard + raw[slash...]
                let stamp = FileStamp(values)
                // This walk's own reading first: a folder inside another one
                // is walked twice, and its files are read once.
                let file: ScannedFile
                if let stamp, let earlier = walk.scanned[filePath] ?? known[filePath], earlier.stamp == stamp {
                    file = earlier
                } else {
                    do {
                        file = ScannedFile(stamp: stamp, outcome: .parsed(try LocalLyricsDocument.parse(readFile(fileURL))))
                    } catch {
                        file = ScannedFile(
                            stamp: stamp,
                            outcome: .failed(error is LocalLyricsDocument.Error ? .malformed : .unreadable)
                        )
                    }
                }
                walk.scanned[filePath] = file
                files.append((filePath, file))
            }
            walk.folders.append(.init(path: path, finding: .files(files)))
        }
        return walk
    }

    /// Applies a walk to the index and the records, and announces it only
    /// when something changed since `before`.
    ///
    /// Against the library as it is now, not as it was when the walk began:
    /// the launch scan lands a moment after the listener can act, and an
    /// import, a binding or a folder removed in that moment must stand.
    private func apply(_ walk: FolderWalk, since before: Baseline) {
        // First id wins, rather than a trap: an index written before `seen`
        // below can hold one path twice, and this runs as the library opens.
        let existingIDs = Dictionary(
            state.documents
                .filter { $0.origin == .referencedFolder }
                .map { ($0.path, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let imports = state.documents.filter { $0.origin == .imported }
        var references: [StoredDocument] = []
        // An import's issue is found by `reloadImportedRecords`, not by a
        // walk of the folders, so a rescan keeps it: replacing the list
        // wholesale would forget why a bound import cannot be shown.
        var issues = state.issues.filter { $0.path.hasPrefix(importsDirectory.path + "/") }
        // Every path this scan has indexed. A folder inside another one the
        // library reads is walked twice — on its own, and as part of its
        // parent — and each walk used to index every file again: one already
        // known went in twice under the same id, which trapped the next scan's
        // table above at every launch, and one arriving later got an id per
        // walk, so each lookup for its song became a choice between copies.
        var seen: Set<String> = []
        var contentChanged = false
        // A folder removed while the launch scan was out stays removed.
        let selected = Set(state.folders.map(\.path))

        for folder in walk.folders where selected.contains(folder.path) {
            switch folder.finding {
            case .unreachable:
                // It keeps the documents it had, so a track bound to one of
                // them finds the same id when the folder is back.
                let roots = [folder.path, URL(fileURLWithPath: folder.path).resolvingSymlinksInPath().path]
                for document in state.documents where document.origin == .referencedFolder {
                    guard roots.contains(where: { document.path.hasPrefix($0 + "/") }),
                          seen.insert(document.path).inserted else { continue }
                    references.append(document)
                }
                issues.append(StoredIssue(path: folder.path, issue: .unreadable))
            case .unenumerable(let path):
                issues.append(StoredIssue(path: path, issue: .unreadable))
            case .files(let files):
                for (path, file) in files {
                    guard seen.insert(path).inserted else { continue }
                    switch file.outcome {
                    case .parsed(let document):
                        let stored = StoredDocument(
                            id: existingIDs[path] ?? UUID(), origin: .referencedFolder, path: path
                        )
                        references.append(stored)
                        // A file taken from the stamps hands back the very
                        // document it parsed to last time, so this costs no
                        // more than a look at the same storage.
                        if records[stored.id]?.document != document { contentChanged = true }
                        records[stored.id] = Record(stored: stored, document: document)
                    case .failed(let issue):
                        issues.append(StoredIssue(path: path, issue: issue))
                        // A file the library already knew keeps its id while
                        // it is broken — saved half-edited from a text editor,
                        // or briefly unreadable. It used to leave the index, so
                        // its binding dangled and the fixed file came back
                        // under a new id nothing was bound to. Kept without a
                        // record, the binding answers `.malformed` until the
                        // file is fixed and then finds the same document again.
                        if let id = existingIDs[path] {
                            references.append(StoredDocument(id: id, origin: .referencedFolder, path: path))
                            if records.removeValue(forKey: id) != nil { contentChanged = true }
                        }
                    }
                }
            }
        }
        scanned = walk.scanned

        let surviving = Set(references.map(\.id))
        let kept = records.filter { $0.value.stored.origin == .imported || surviving.contains($0.key) }
        if kept.count != records.count { contentChanged = true }
        records = kept
        state.documents = imports + references
        state.issues = issues
        let pruned = pruneDanglingBindings()
        // Only news is announced. Every folder-watcher event lands here — any
        // file added, renamed or removed at a folder's top level, `.lrc` or
        // not — and each one rewrote the index and advanced the revision,
        // which sends the track on screen back through resolution and can
        // cancel and re-send its online lookup. What the records hold is
        // tracked as it changes above, rather than copied and compared
        // document by document, which was most of a quiet rescan's cost.
        guard pruned || contentChanged || state.documents != before.documents
                || state.issues != before.issues || state.folders != before.folders else { return }
        persist()
        advanceRevision()
    }

    func lookup(identity: LocalTrackIdentity) -> LocalLyricsLookup {
        onLookup(identity)
        let key = identityKey(identity)
        if let id = state.bindings[key] {
            if let record = records[id] { return .ready(record.candidate) }
            // Still in the index with nothing to show: a folder not reachable
            // right now, or a file that cannot be read or parsed. That is
            // said honestly and the binding is kept — a disk plugged back in,
            // or a file fixed, finds the same id again.
            if let stored = state.documents.first(where: { $0.id == id }) {
                // Not read yet: the launch scan is still walking its folder.
                // Saying the file cannot be read would be untrue, and matching
                // by tags could pick some other file for a song the listener
                // chose one for. No match for that moment; the revision the
                // scan advances asks again.
                if launchScanPending, stored.origin == .referencedFolder { return .noMatch }
                let path = location(of: stored)
                return .invalid(state.issues.first { $0.path == path }?.issue ?? .unreadable)
            }
            // Bound to a document the library no longer has at all. This
            // used to answer `.invalid(.unreadable)` on every play — "No
            // lyrics for this track." for good, and LRCLIB, asked only on
            // `.noMatch`, never asked. The binding goes and matching carries
            // on. Rescans prune these as they happen; this catches an index
            // saved before they did. Saved without advancing the revision,
            // which would send the track straight back through this lookup.
            state.bindings.removeValue(forKey: key)
            persist()
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
        if albumMatches.count > 1 {
            return newestEdit(among: albumMatches).map(LocalLyricsLookup.ready) ?? .ambiguous(albumMatches)
        }

        let durationMatches = titleArtist.filter {
            abs(($0.document.duration ?? .greatestFiniteMagnitude) - identity.duration) <= 0.5
        }
        if durationMatches.count == 1 { return .ready(durationMatches[0]) }
        if durationMatches.count > 1 {
            return newestEdit(among: durationMatches).map(LocalLyricsLookup.ready) ?? .ambiguous(durationMatches)
        }
        return .noMatch
    }

    /// The newest edit, when every candidate is one source and copies saved
    /// from it — directly, or from an earlier copy of it.
    ///
    /// Save Copy writes its copy with the source's tags, which is right: it
    /// is the same song. But once the binding that pointed at the copy was
    /// gone — Clear Bindings, or the song playing in another player — the
    /// source and every copy matched equally, and the song asked the
    /// listener to choose between identical buttons (J-025). The newest save
    /// is the one they meant. Two files that merely share tags are a real
    /// choice and still ask; older copies are kept, never deleted, and still
    /// offered whenever the chooser is shown.
    private func newestEdit(among candidates: [LocalLyricsCandidate]) -> LocalLyricsCandidate? {
        let stored = Dictionary(
            state.documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // A source deleted since keeps its id in its copies' lineage, so its
        // copies still group; a cycle, which only a hand-edited index could
        // hold, ends at the first repeat.
        func lineage(_ id: UUID) -> UUID {
            var current = id
            var visited: Set<UUID> = [id]
            while let parent = stored[current]?.editedFrom, visited.insert(parent).inserted {
                current = parent
            }
            return current
        }
        guard candidates.contains(where: { stored[$0.id]?.editedFrom != nil }),
              Set(candidates.map { lineage($0.id) }).count == 1
        else { return nil }
        // Order in the index breaks a tie in the clock: copies are appended
        // as they are saved.
        let order = Dictionary(
            state.documents.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        func age(_ candidate: LocalLyricsCandidate) -> (Date, Int) {
            (stored[candidate.id]?.savedAt ?? .distantPast, order[candidate.id] ?? -1)
        }
        return candidates.max { age($0) < age($1) }
    }

    func bind(_ candidate: LocalLyricsCandidate, to identity: LocalTrackIdentity) {
        guard records[candidate.id] != nil else { return }
        state.bindings[identityKey(identity)] = candidate.id
        state.unassignedImports.removeAll { $0.id == candidate.id }
        rebuildUnassignedImports()
        persist()
        advanceRevision()
    }

    /// Whether this track is bound to a document the library still holds,
    /// readable or not. It is what offers Remove Local Binding, so a binding
    /// to a broken file can still be removed from the page that shows it.
    func hasBinding(for identity: LocalTrackIdentity) -> Bool {
        guard let id = state.bindings[identityKey(identity)] else { return false }
        return state.documents.contains { $0.id == id }
    }

    /// The name of the file a document lives in, for the More menu's header
    /// (spec §5.2) — but only where the name is the person's own. A file from a
    /// selected folder keeps the name it has there; an import or a saved edit is
    /// an Isla-owned copy stored as `<uuid>.lrc`, a name nobody chose, so those
    /// answer nil and the caller names the file by its tags instead.
    func fileName(of documentID: UUID) -> String? {
        guard let stored = state.documents.first(where: { $0.id == documentID }),
              stored.origin == .referencedFolder else { return nil }
        return URL(fileURLWithPath: stored.path).lastPathComponent
    }

    /// The line a bound file's refusal points at, for "Line %d of this file has
    /// a time Isla can't read." (spec §5.4). The library keeps *that* a file is
    /// malformed (`FileIssue`) and not where, so this reads the bound file again
    /// and asks the parser; nil when the song has no binding, the file cannot be
    /// read, or the refusal is not about a time (an empty file).
    func invalidLine(for identity: LocalTrackIdentity) -> Int? {
        guard let id = state.bindings[identityKey(identity)],
              let stored = state.documents.first(where: { $0.id == id }),
              let raw = try? Self.readText(at: URL(fileURLWithPath: location(of: stored))) else { return nil }
        do {
            _ = try LocalLyricsDocument.parse(raw)
            return nil
        } catch LocalLyricsDocument.Error.invalidTimestamp(let line) {
            return line
        } catch LocalLyricsDocument.Error.invalidWordOrder(let line) {
            return line
        } catch {
            return nil
        }
    }

    /// What Edit Lyrics… opens on for a bound file Isla could not read: the file's
    /// own text, read tolerantly (`LocalLyricsDocument.parseRepairing`), so the
    /// good lines are rows and the broken one is a row to fix. It used to open an
    /// empty document, and Save Copy then replaced the binding with a near-empty
    /// copy of a file that had one bad stamp in it (review 2026-10-15). Nil when
    /// the song has no binding or its file cannot be read at all.
    func repairableDocument(for identity: LocalTrackIdentity) -> LocalLyricsDocument? {
        guard let id = state.bindings[identityKey(identity)],
              let stored = state.documents.first(where: { $0.id == id }),
              let raw = try? Self.readText(at: URL(fileURLWithPath: location(of: stored))) else { return nil }
        return LocalLyricsDocument.parseRepairing(raw)
    }

    func removeBinding(for identity: LocalTrackIdentity) {
        state.bindings.removeValue(forKey: identityKey(identity))
        persist()
        advanceRevision()
    }

    /// Deletes only copies Isla owns under `lyrics-local/imports`. Files from
    /// selected folders are deliberately never candidates for this operation.
    func clearImportedDocuments() {
        let imported = state.documents.filter { $0.origin == .imported }
        let importedIDs = Set(imported.map(\.id))
        // Only ever a file inside `imports/`: the path is rebuilt from the
        // file name there, never taken from the index as saved.
        for document in imported {
            try? fileManager.removeItem(atPath: importPath(for: document))
        }
        state.documents.removeAll { $0.origin == .imported }
        records = records.filter { !importedIDs.contains($0.key) }
        pruneDanglingBindings()
        state.issues.removeAll { $0.path.hasPrefix(importsDirectory.path + "/") }
        state.unassignedImports.removeAll {
            importedIDs.contains($0.id) || $0.path.hasPrefix(importsDirectory.path + "/")
        }
        rebuildUnassignedImports()
        persist()
        advanceRevision()
    }

    func clearBindings() {
        guard !state.bindings.isEmpty else { return }
        state.bindings.removeAll()
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
        pendingReinstall = false
        folderWatch = nil
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
            guard let raw = try? Self.readText(at: source) else {
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
                    let v4Name = Self.legacyCacheKey(
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

    /// Reads every import back as the library opens.
    ///
    /// An import that could not be read or parsed used to be skipped here,
    /// and the next save wrote the index without it: the file stayed in
    /// `imports/`, its binding pointed at nothing, and the song said "No
    /// lyrics for this track." with no message. It keeps its place now, with
    /// an issue that says why it cannot be shown.
    private func reloadImportedRecords() {
        var imported: [StoredDocument] = []
        var issues: [StoredIssue] = []
        for stored in state.documents where stored.origin == .imported {
            let current = StoredDocument(
                id: stored.id, origin: .imported, path: importPath(for: stored),
                editedFrom: stored.editedFrom, savedAt: stored.savedAt
            )
            imported.append(current)
            do {
                let raw = try Self.readText(at: URL(fileURLWithPath: current.path))
                records[stored.id] = Record(stored: current, document: try LocalLyricsDocument.parse(raw))
            } catch {
                issues.append(StoredIssue(
                    path: current.path, issue: error is LocalLyricsDocument.Error ? .malformed : .unreadable
                ))
            }
        }
        let locations = Set(imported.map(\.path))
        state.issues.removeAll { locations.contains($0.path) }
        state.issues += issues
        state.documents = imported + state.documents.filter { $0.origin == .referencedFolder }
    }

    /// Where an import is today: its file name inside this library's own
    /// `imports/` folder, whatever absolute path the index was saved with.
    ///
    /// Imports used to be read from that saved path, which names the home
    /// folder. Renaming the account, or a Migration Assistant restore under
    /// another user name, moved Application Support out from under every one
    /// of them, and every import and saved edit was lost at the next launch.
    /// Resolving by name needs no migration — an index from any build reads
    /// the same way — and the path is still saved in full, so a build from
    /// before this one can read the index too.
    private func importPath(for stored: StoredDocument) -> String {
        importsDirectory.appendingPathComponent(URL(fileURLWithPath: stored.path).lastPathComponent).path
    }

    private func location(of stored: StoredDocument) -> String {
        stored.origin == .imported ? importPath(for: stored) : stored.path
    }

    /// Drops every binding to a document that has left the index — a file
    /// deleted from a folder, a folder removed, imports cleared. Each used to
    /// leave its song on `.invalid(.unreadable)` for good. A document still
    /// indexed but unreachable keeps its binding: a disk plugged back in must
    /// find its songs bound as they were.
    @discardableResult
    private func pruneDanglingBindings() -> Bool {
        let known = Set(state.documents.map(\.id))
        let kept = state.bindings.filter { known.contains($0.value) }
        guard kept.count != state.bindings.count else { return false }
        state.bindings = kept
        return true
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
        let suffixes = [".lrc5.json", ".lrc4.json", ".lrc3.json"]
        for entry in files(in: directory, fileManager: fileManager)
        where suffixes.contains(where: entry.lastPathComponent.hasSuffix) {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Removes the LRCLIB answers 0.1.0 cached as `<key>.lrc3.json`, once.
    ///
    /// They sit in the same folder the migration reads, and the migration
    /// removed only lrc4 and lrc5 — and runs once, so for everyone already
    /// past it, third-party lyric text stayed on disk for good (J-016). Only
    /// lrc3 goes here, by its exact suffix: an lrc4 file can still carry a
    /// listener's timing nudge, which only the migration knows how to keep,
    /// and a `.lrc` of the listener's own in the same folder is theirs.
    ///
    /// Never from inside a test process on the real support directory: every
    /// `NotchStores()` a test builds opens it, and those files and that flag
    /// belong to whichever Isla is installed, which removes them itself.
    private func removeLegacyLrc3Caches(in v4Directory: URL) {
        guard !state.legacyLrc3Removed,
              !(PlayerBridge.isRunningTests && LyricsStore.isLiveSupportDirectory(v4Directory))
        else { return }
        for entry in Self.files(in: v4Directory, fileManager: fileManager)
        where entry.lastPathComponent.hasSuffix(".lrc3.json") {
            try? fileManager.removeItem(at: entry)
        }
        state.legacyLrc3Removed = true
        persist()
    }

    private static func legacyCacheKey(
        title: String, artist: String, album: String, duration: TimeInterval
    ) -> String {
        let identity = "\(title)|\(artist)|\(album)|\(Int(duration.rounded()))"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// A bookmark to a selected folder: security-scoped when the system will
    /// make one, a plain one otherwise.
    ///
    /// Only the scoped kind was ever tried, through `try?`. Isla is not
    /// sandboxed, and a process the system will not issue a scope extension
    /// to gets an error back — so a folder could be saved with no bookmark at
    /// all, and nothing then followed it when it was renamed or moved
    /// (J-011). A plain bookmark, which the shelf has always used, follows a
    /// move just as well; the scope is only ever needed by a sandboxed build.
    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Where a selected folder is now, and whether its bookmark asked to be
    /// made again.
    private func resolve(_ folder: StoredFolder) throws -> (url: URL, stale: Bool) {
        guard let bookmark = folder.bookmark else { return (URL(fileURLWithPath: folder.path), false) }
        var stale = false
        // Never mounting and never asking, like the shelf's bookmarks: this
        // runs on the main thread at launch, and a folder on a disk or share
        // that is not there must read as unreachable, not stall the launch
        // mounting it or put up a dialog nobody asked for.
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale
            )
            return (url, stale)
        } catch {
            // A plain bookmark, made where the scoped kind could not be, is
            // read without asking for a scope it never carried.
            let url = try URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale
            )
            return (url, stale)
        }
    }

    /// Follows every selected folder to where its bookmark says it is now,
    /// and answers that location for each folder, in order — nil for one that
    /// cannot be reached.
    ///
    /// A stale bookmark's freshly resolved location used to be discarded for
    /// the saved path, which no longer existed after a rename in Finder: the
    /// folder read as unreachable for good, Settings kept its old name, and
    /// after a relaunch every song bound to one of its files had no lyrics
    /// (J-011). Even a bookmark that was not stale, resolved somewhere new,
    /// was walked under the new path while ids were looked up under the old
    /// one, so every file came back under a new id and its binding was
    /// pruned. Now the folder's path and bookmark are rewritten, and so is the
    /// path of every document under it, before anything looks ids up.
    ///
    /// A folder saved with no bookmark at all gets one here, the first time
    /// it is found where it was left, so a folder added by an earlier build
    /// is followed from then on.
    private func followMovedFolders() -> [URL?] {
        var folders: [StoredFolder] = []
        var located: [URL?] = []
        for folder in state.folders {
            let resolved = try? resolve(folder)
            let current = resolved?.url.standardizedFileURL.path ?? folder.path
            let moved = !Self.samePlace(current, folder.path)
            // Deleting a folder in Finder moves it to the Trash, and the
            // bookmark follows it there. Followed, the library would go on
            // reading lyrics out of the Trash under the folder's old name; it
            // reads as gone instead, as a deleted folder always has, and its
            // bindings wait for it to be put back.
            guard let (url, stale) = resolved, !(moved && Self.isInTrash(current)),
                  (try? url.checkResourceIsReachable()) == true else {
                folders.append(folder)
                located.append(nil)
                continue
            }
            var followed = folder
            if moved || stale || folder.bookmark == nil {
                let hadAccess = url.startAccessingSecurityScopedResource()
                defer { if hadAccess { url.stopAccessingSecurityScopedResource() } }
                // A bookmark that cannot be made again keeps the old one: it
                // still found the folder this time.
                followed = StoredFolder(
                    path: moved ? current : folder.path,
                    bookmark: Self.bookmark(for: url) ?? folder.bookmark
                )
                if moved { moveDocuments(from: folder.path, to: current) }
            }
            // Moved onto a folder the library already reads — the user picked
            // the new location too — it is that folder now, read once.
            guard !folders.contains(where: { $0.path == followed.path }) else { continue }
            folders.append(followed)
            located.append(url)
        }
        state.folders = folders
        return located
    }

    /// Rewrites the path of every folder document under `old` to the same
    /// place under `new`, keeping its id: what a binding names is the id, and
    /// the path is only where to find it.
    private func moveDocuments(from old: String, to new: String) {
        let roots = [old, URL(fileURLWithPath: old).resolvingSymlinksInPath().path]
        state.documents = state.documents.map { document in
            guard document.origin == .referencedFolder,
                  let root = roots.first(where: { document.path.hasPrefix($0 + "/") })
            else { return document }
            return StoredDocument(
                id: document.id, origin: document.origin,
                path: new + document.path.dropFirst(root.count),
                editedFrom: document.editedFrom, savedAt: document.savedAt
            )
        }
        // The stamps move with them: a rename does not touch the files, so a
        // followed folder is not read again from scratch.
        scanned = Dictionary(
            scanned.map { path, file in
                guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return (path, file) }
                return (new + path.dropFirst(root.count), file)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Whether two paths name the same folder, `/var` and `/private/var`
    /// alike: a bookmark resolves to the real path, and the saved one may
    /// have been the path the user picked.
    private static func samePlace(_ first: String, _ second: String) -> Bool {
        let variants = { (path: String) -> Set<String> in
            [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        }
        return !variants(first).isDisjoint(with: variants(second))
    }

    /// Whether a path lies in a Trash: the home folder's `.Trash`, or the
    /// `.Trashes` a removable or external disk keeps at its root. Asked of a
    /// path only, so it never touches the disk.
    private static func isInTrash(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Watches every selected folder, all the way down, with one FSEvents
    /// stream.
    ///
    /// It was one kernel descriptor per top-level folder, which hears only
    /// entries added, renamed or removed directly inside that folder: a file
    /// in Artist/Album, a file a sync client rewrote in place, and a disk
    /// plugged back in were all missed until a relaunch or a manual Rescan
    /// (G-020). FSEvents reports any change anywhere under a path at the cost
    /// of one stream, however deep the library goes; a descriptor per
    /// subfolder was rejected because its count grows with the library, and
    /// a timed rescan because it wakes an idle Mac.
    ///
    /// The stream watches each folder at its saved path, which every rescan
    /// has already moved to wherever the bookmark followed it, and is made
    /// again whenever that may have changed — a watched folder renamed or
    /// moved, or a disk mounted, unmounted or renamed. The saved path rather
    /// than the bookmark's answer, so a folder sent to the Trash, which is
    /// not followed, is still heard when it is put back.
    private func installFolderWatchers() {
        folderWatch = nil
        guard !state.folders.isEmpty else { return }
        folderWatch = FolderWatch(paths: state.folders.map(\.path)) { [weak self] reinstall in
            MainActor.assumeIsolated { self?.scheduleFolderRescan(reinstall: reinstall) }
        }
    }

    /// Rescans on the next turn of the main queue, not inside the event's own
    /// callback: a reinstall releases the stream that called it. The stream's
    /// latency already gathered the burst, so nothing waits any longer.
    private func scheduleFolderRescan(reinstall: Bool) {
        pendingReinstall = pendingReinstall || reinstall
        scheduledRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                // A folder event in the first moments after launch waits for
                // the launch scan instead of overtaking it, and then reads
                // only what changed since.
                await self?.waitForFolderScan()
                guard let self, self.watching else { return }
                let reinstall = self.pendingReinstall
                self.pendingReinstall = false
                try? self.rescanFolders()
                // After the rescan, which is what moves a followed folder's
                // path: the new stream watches where it is now.
                if reinstall { self.installFolderWatchers() }
            }
        }
        scheduledRescan = work
        DispatchQueue.main.async(execute: work)
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
        guard fileManager.fileExists(atPath: url.path) else { return State() }
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            return state
        }
        // An index that is there but cannot be read used to be answered with
        // an empty library, which the legacy migration and the first rescan
        // then saved over it: every folder, binding and import record was
        // gone with no copy left, and the imported files were orphaned. It is
        // moved aside first, so that save lands next to it instead of on it.
        setAside(url, fileManager: fileManager)
        return State()
    }

    private static func setAside(_ url: URL, fileManager: FileManager) {
        let formatter = ISO8601DateFormatter()
        // No colons: Finder shows a colon in a file name as a slash.
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let stamp = formatter.string(from: Date())
        let directory = url.deletingLastPathComponent()
        var destination = directory.appendingPathComponent("index.unreadable-\(stamp).json")
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = directory.appendingPathComponent("index.unreadable-\(stamp)-\(attempt).json")
        }
        do {
            try fileManager.moveItem(at: url, to: destination)
            Log.storage.error("local lyrics index unreadable, kept aside as \(destination.lastPathComponent, privacy: .public)")
        } catch {
            Log.storage.error("local lyrics index unreadable and could not be kept aside: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// One FSEvents stream over the selected lyric folders, and the disk
/// notifications that say a folder may be somewhere else now. Everything it
/// hears is delivered on the main queue as one call: `true` when the watch
/// itself must be made again, `false` when a rescan is enough.
///
/// Owned by the library and torn down by being released, so a library that
/// goes away — or a watch replaced by a new one — can never be called back.
private final class FolderWatch {
    /// The debounce Settings and the inventory promise: the stream gathers
    /// every change within it into one callback, so a sync client writing a
    /// hundred files is one rescan.
    static let latency: CFTimeInterval = 0.15

    private let handler: (_ reinstall: Bool) -> Void
    private var stream: FSEventStreamRef?
    private var observers: [NSObjectProtocol] = []

    init(paths: [String], handler: @escaping (_ reinstall: Bool) -> Void) {
        self.handler = handler
        let center = NSWorkspace.shared.notificationCenter
        // A disk plugged back in is not a change under any watched path —
        // the path was not there to change — and a stream made while it was
        // away may never hear of it. A disk renamed moves every path on it.
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handler(true)
            })
        }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            // A watched folder's own path changed — renamed, moved, deleted
            // or put back — or a volume under it came or went: the stream
            // still names the old path, so it is made again after the rescan
            // has followed the folder.
            let moved = FSEventStreamEventFlags(
                kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
                    | kFSEventStreamEventFlagUnmount
            )
            let reinstall = (0..<count).contains { flags[$0] & moved != 0 }
            watch.handler(reinstall)
        }
        // WatchRoot is what reports the folder itself being renamed or moved;
        // without it the stream only hears what happens inside.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
