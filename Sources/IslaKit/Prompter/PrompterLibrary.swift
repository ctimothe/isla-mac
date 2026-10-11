import Combine
import Foundation

// Foundation (and Combine for `ObservableObject`) only, like the rest of the
// prompter's model layer: no AppKit, no SwiftUI. Everything that reaches the
// disk or the clock comes in through an initializer, so a test owns both and
// never touches Application Support.

// MARK: - File seam

/// The library's one file, as the library needs to see it. Four verbs, no
/// paths: a test substitutes an in-memory file and the production type below
/// keeps every path decision (and every `FileManager` call) to itself.
protocol PrompterFileIO {
    /// Whether the library file is there, without reading it.
    func exists() -> Bool
    /// The file's bytes. Throws when it cannot be read; never creates anything.
    func read() throws -> Data
    /// Replaces the file in one step: a reader sees the old file or the new
    /// one, and a failure leaves the old one exactly as it was.
    func writeAtomically(_ data: Data) throws
    /// Copies the current file next to itself under `name` and returns the
    /// name actually used (a second copy in the same second gets a suffix
    /// rather than overwriting the first).
    func copyAside(as name: String) throws -> String
}

/// `~/Library/Application Support/Isla/Prompter/library.json` (spec 12.1).
struct FilePrompterFileIO: PrompterFileIO {
    static let fileName = "library.json"

    let directory: URL

    /// Resolved from `AppPaths.live.supportDirectory` rather than through
    /// `AppPaths.supportFile(_:)`, which creates the support folder as a side
    /// effect. Reading the library (or asking whether it exists) must create
    /// nothing, so the folders are made by the first write and not before.
    static var live: FilePrompterFileIO {
        FilePrompterFileIO(
            directory: AppPaths.live.supportDirectory.appendingPathComponent("Prompter", isDirectory: true)
        )
    }

    private var file: URL { directory.appendingPathComponent(Self.fileName) }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    func read() throws -> Data {
        try Data(contentsOf: file)
    }

    func writeAtomically(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `.atomic` writes a temporary file in the same folder and renames it
        // over the library, so a crash or a full disk halfway through leaves
        // the previous library whole instead of a truncated one.
        try data.write(to: file, options: .atomic)
    }

    func copyAside(as name: String) throws -> String {
        let fm = FileManager.default
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        try fm.copyItem(at: file, to: directory.appendingPathComponent(candidate))
        return candidate
    }
}

// MARK: - Debounce

/// Coalesces a burst of "save me" requests into one. The scheduler is the
/// session's `PrompterScheduling`, so a test advances time by hand.
///
/// The writer the removed stores used (`DebouncedWrite`) left with them. This
/// one is deliberately small: it knows nothing about files, only about when to
/// run its action.
@MainActor
final class DebouncedWriter {
    private let delay: TimeInterval
    private let scheduler: PrompterScheduling
    private let action: @MainActor () -> Void
    private var timer: PrompterCancellable?

    init(delay: TimeInterval, scheduler: PrompterScheduling, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.scheduler = scheduler
        self.action = action
    }

    var isPending: Bool { timer != nil }

    /// Starts (or restarts) the window; the action runs once, `delay` after
    /// the last call.
    func schedule() {
        timer?.cancel()
        timer = scheduler.after(delay) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.action()
        }
    }

    /// Runs the action now if one is pending. A flush with nothing pending is
    /// a no-op, so quitting with the switch off writes nothing.
    func flush() {
        guard let pending = timer else { return }
        pending.cancel()
        timer = nil
        action()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Model

/// One script as stored (spec 12.1): pages are raw text, exactly what the
/// editor holds. Read marks are *not* stored here: spec 20.2 #11 keeps them in
/// the session, and the schema in 12.1 has no field for them.
struct PrompterScriptRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var pages: [String]
}

/// Why the library refused or could not do something. The cases map onto the
/// failure surfaces of spec 14.4: the limit cases are field errors, the rest
/// are read through `PrompterLibrary.status` and `writeFailure` for the inline
/// alert.
enum PrompterLibraryError: Error, Equatable {
    /// `load()` has not run; nothing was read or created.
    case notLoaded
    /// The file was written by a newer Isla; this one only reads it.
    case readOnly
    /// The file could not be read or decoded; writing stays off until the
    /// owner starts a fresh library.
    case writingDisabled
    /// `startFreshLibrary()` on a library that is not broken.
    case nothingToReplace
    /// `startFreshLibrary()` on an unreadable file of which no copy could be
    /// made, even on a second try: replacing it would destroy the only copy
    /// of the owner's scripts (ruling 20.6 #4).
    case noCopyKept
    case tooManyPages(limit: Int)
    case scriptTooLong(limit: Int)
    case tooManyScripts(limit: Int)
    case titleTooLong(limit: Int)
    case noSuchScript
    case noSuchPage
    /// The last write failed (disk full, read-only folder, volume gone). The
    /// in-memory edits are kept and the next flush tries again.
    case writeFailed
}

enum PrompterLibraryStatus: Equatable {
    /// Nothing has asked for the library yet; no I/O has happened.
    case notLoaded
    /// Loaded (or absent and empty); edits are saved.
    case ready
    /// A valid file from a newer Isla: readable, never written.
    case newerVersion(Int)
    /// Exists but could not be read or decoded: never overwritten.
    /// `corruptCopy` names the `library.corrupt-<timestamp>.json` made before
    /// anything could be saved, or nil when even the copy failed.
    case unreadable(corruptCopy: String?)
}

@MainActor
final class PrompterLibrary: ObservableObject {
    static let schemaVersion = 1
    static let maxPagesPerScript = 200
    static let maxCharactersPerScript = 1_000_000
    static let maxScripts = 500
    /// Characters in a script's title (ruling 20.6 #8c). Long enough for any
    /// talk's name, short enough that a pasted paragraph cannot become one.
    nonisolated static let maxTitleLength = 80
    static let saveDelay: TimeInterval = 0.5

    @Published private(set) var scripts: [PrompterScriptRecord] = []
    @Published private(set) var currentScriptID: UUID?
    @Published private(set) var status: PrompterLibraryStatus = .notLoaded
    /// Non-nil while the last write failed. Cleared by the next successful one.
    @Published private(set) var writeFailure: PrompterLibraryError?
    /// True when `load()` found no file at all. The tab seeds its sample
    /// script on this and on nothing else: an emptied library has a file and
    /// is not seeded again (spec 5.1 item 4).
    private(set) var isFirstRun = false

    private let io: PrompterFileIO
    private let now: () -> Date
    private var writer: DebouncedWriter!
    /// Edits not yet on disk. Separate from the writer's timer because a write
    /// that failed is still owed: the timer is gone, the edits are not.
    private var dirty = false

    /// Performs no I/O. The file is not read, created or touched until
    /// something calls `load()`: with the feature switch off the library must
    /// leave no trace (spec 4).
    init(
        io: PrompterFileIO = FilePrompterFileIO.live,
        scheduler: PrompterScheduling = MainQueuePrompterScheduler(),
        now: @escaping () -> Date = Date.init
    ) {
        self.io = io
        self.now = now
        writer = DebouncedWriter(delay: Self.saveDelay, scheduler: scheduler) { [weak self] in
            self?.saveIfNeeded()
        }
    }

    var canWrite: Bool { status == .ready }

    func script(_ id: UUID) -> PrompterScriptRecord? {
        scripts.first { $0.id == id }
    }

    // MARK: Loading

    /// Reads the file once; later calls do nothing. A missing file is an empty
    /// writable library and is *not* created here (E-53).
    func load() {
        guard status == .notLoaded else { return }
        guard io.exists() else {
            isFirstRun = true
            status = .ready
            return
        }
        let data: Data
        do {
            data = try io.read()
        } catch {
            Log.storage.error("prompter library unreadable: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            quarantine()
            return
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.version >= 1 else {
            quarantine()
            return
        }
        if probe.version > Self.schemaVersion {
            // A newer Isla wrote this. Decoding it with this version's shape
            // could drop fields the newer one needs, and saving would then
            // destroy them, so it is shown as nothing and never written.
            status = .newerVersion(probe.version)
            return
        }
        do {
            let file = try Self.decoder.decode(LibraryFile.self, from: data)
            scripts = file.scripts
            currentScriptID = file.currentScriptID.flatMap { id in file.scripts.contains { $0.id == id } ? id : nil }
            status = .ready
        } catch {
            Log.storage.error("prompter library undecodable: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            quarantine()
        }
    }

    /// The old `TeleprompterStore` replaced a file it could not decode with an
    /// empty one on the next keystroke, and the owner's scripts went with it.
    /// So a file that exists but cannot be understood is copied aside first,
    /// and writing stays off until `startFreshLibrary()`.
    private func quarantine() {
        status = .unreadable(corruptCopy: copyAside())
    }

    /// The copy `quarantine` makes, or nil when it could not be made: a file
    /// unreadable for its permissions usually cannot be copied either, and a
    /// full disk refuses the copy of a corrupt one.
    private func copyAside() -> String? {
        let name = "library.corrupt-\(Self.timestamp(now())).json"
        do {
            return try io.copyAside(as: name)
        } catch {
            Log.storage.error("prompter library copy-aside failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            return nil
        }
    }

    /// The owner's choice after "Couldn't read your scripts": an empty library
    /// replaces the unreadable file. Only from the unreadable state; a newer
    /// version's file is never replaced from inside an older Isla.
    ///
    /// Only once a copy of the old file exists. With none, this replaced the
    /// only copy of the owner's scripts with an empty library, under an alert
    /// that said a copy had been kept. The copy is tried once more here (the
    /// disk may have room now); if that fails too, nothing is written and the
    /// library stays read-only (ruling 20.6 #4).
    func startFreshLibrary() throws {
        switch status {
        case .notLoaded: throw PrompterLibraryError.notLoaded
        case .newerVersion: throw PrompterLibraryError.readOnly
        case .ready: throw PrompterLibraryError.nothingToReplace
        case .unreadable(.some):
            break
        case .unreadable(nil):
            guard let copy = copyAside() else { throw PrompterLibraryError.noCopyKept }
            status = .unreadable(corruptCopy: copy)
        }
        scripts = []
        currentScriptID = nil
        isFirstRun = false
        status = .ready
        dirty = true
        writer.cancel()
        saveIfNeeded()
    }

    // MARK: Saving

    /// Writes any pending edit now. Called on session start, when the switch
    /// turns off and at termination (spec 12.1). Does nothing when nothing is
    /// owed, so it is safe to call unconditionally, including before `load()`.
    func flush() {
        writer.cancel()
        saveIfNeeded()
    }

    private func saveIfNeeded() {
        guard dirty, canWrite else { return }
        let file = LibraryFile(version: Self.schemaVersion, currentScriptID: currentScriptID, scripts: scripts)
        do {
            try io.writeAtomically(try Self.encoder.encode(file))
            dirty = false
            if writeFailure != nil { writeFailure = nil }
        } catch {
            // In-memory edits stay (E-55) and `dirty` stays set, so the next
            // flush or edit tries again. The failure is published once, not
            // per attempt.
            Log.storage.error("prompter library write failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            if writeFailure == nil { writeFailure = .writeFailed }
        }
    }

    private func markChanged() {
        dirty = true
        writer.schedule()
    }

    // MARK: Editing

    private func requireWritable() throws {
        switch status {
        case .notLoaded: throw PrompterLibraryError.notLoaded
        case .newerVersion: throw PrompterLibraryError.readOnly
        case .unreadable: throw PrompterLibraryError.writingDisabled
        case .ready: break
        }
    }

    private func index(of id: UUID) throws -> Int {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { throw PrompterLibraryError.noSuchScript }
        return index
    }

    @discardableResult
    func addScript(title: String, pages: [String] = [""]) throws -> UUID {
        try requireWritable()
        guard scripts.count < Self.maxScripts else { throw PrompterLibraryError.tooManyScripts(limit: Self.maxScripts) }
        try Self.validate(pages: pages, growing: nil)
        let record = PrompterScriptRecord(id: UUID(), title: title, updatedAt: now(), pages: pages)
        scripts.append(record)
        markChanged()
        return record.id
    }

    /// The copy sits right after the original. Titles are the caller's to
    /// choose (they are localized); identity is the id, so duplicates are fine.
    @discardableResult
    func duplicateScript(_ id: UUID, title: String) throws -> UUID {
        try requireWritable()
        let at = try index(of: id)
        guard scripts.count < Self.maxScripts else { throw PrompterLibraryError.tooManyScripts(limit: Self.maxScripts) }
        let record = PrompterScriptRecord(id: UUID(), title: title, updatedAt: now(), pages: scripts[at].pages)
        scripts.insert(record, at: at + 1)
        markChanged()
        return record.id
    }

    /// A title over `maxTitleLength` is refused, never cut, like every other
    /// limit here.
    func renameScript(_ id: UUID, title: String) throws {
        try requireWritable()
        let at = try index(of: id)
        guard title.count <= Self.maxTitleLength else {
            throw PrompterLibraryError.titleTooLong(limit: Self.maxTitleLength)
        }
        scripts[at].title = title
        scripts[at].updatedAt = now()
        markChanged()
    }

    func deleteScript(_ id: UUID) throws {
        try requireWritable()
        let at = try index(of: id)
        scripts.remove(at: at)
        if currentScriptID == id { currentScriptID = nil }
        markChanged()
    }

    /// An unknown id is ignored rather than stored: a pointer to nothing
    /// would be written to disk and read back as one. Allowed in a read-only
    /// library (selecting what to look at is not an edit) but then never saved.
    func setCurrentScript(_ id: UUID?) {
        guard id == nil || scripts.contains(where: { $0.id == id }) else { return }
        guard currentScriptID != id else { return }
        currentScriptID = id
        if canWrite { markChanged() }
    }

    func setPage(scriptID: UUID, index page: Int, text: String) throws {
        try requireWritable()
        let at = try index(of: scriptID)
        guard scripts[at].pages.indices.contains(page) else { throw PrompterLibraryError.noSuchPage }
        var pages = scripts[at].pages
        pages[page] = text
        try Self.validate(pages: pages, growing: scripts[at].pages)
        scripts[at].pages = pages
        scripts[at].updatedAt = now()
        markChanged()
    }

    /// Appends a page and returns its index.
    @discardableResult
    func addPage(scriptID: UUID, text: String = "") throws -> Int {
        try requireWritable()
        let at = try index(of: scriptID)
        let pages = scripts[at].pages + [text]
        try Self.validate(pages: pages, growing: scripts[at].pages)
        scripts[at].pages = pages
        scripts[at].updatedAt = now()
        markChanged()
        return pages.count - 1
    }

    func deletePage(scriptID: UUID, index page: Int) throws {
        try requireWritable()
        let at = try index(of: scriptID)
        guard scripts[at].pages.indices.contains(page) else { throw PrompterLibraryError.noSuchPage }
        scripts[at].pages.remove(at: page)
        scripts[at].updatedAt = now()
        markChanged()
    }

    /// The page at `from` ends up at index `to`.
    func movePage(scriptID: UUID, from: Int, to: Int) throws {
        try requireWritable()
        let at = try index(of: scriptID)
        let indices = scripts[at].pages.indices
        guard indices.contains(from), indices.contains(to) else { throw PrompterLibraryError.noSuchPage }
        let page = scripts[at].pages.remove(at: from)
        scripts[at].pages.insert(page, at: to)
        scripts[at].updatedAt = now()
        markChanged()
    }

    // MARK: Limits

    /// Refuses an edit that would put a script over 200 pages or 1,000,000
    /// characters (spec 12.1, E-57); nothing is ever truncated.
    ///
    /// `growing` is the script's pages before the edit. A hand-edited file
    /// loaded over a limit is not rejected or cut on load, and the owner must
    /// be able to shorten it: an edit over the limit is refused only if it
    /// makes the script bigger than it was.
    private static func validate(pages: [String], growing before: [String]?) throws {
        if pages.count > maxPagesPerScript, pages.count > (before?.count ?? 0) {
            throw PrompterLibraryError.tooManyPages(limit: maxPagesPerScript)
        }
        let after = characterCount(pages)
        if after > maxCharactersPerScript, after > (before.map(characterCount) ?? 0) {
            throw PrompterLibraryError.scriptTooLong(limit: maxCharactersPerScript)
        }
    }

    /// Characters, as the owner counts them (a family emoji is one). UTF-16
    /// units are never fewer than characters, so a script whose unit count is
    /// under the limit is under it and the grapheme walk, which is slow on a
    /// megabyte, runs only when it could matter.
    private static func characterCount(_ pages: [String]) -> Int {
        let units = pages.reduce(0) { $0 + $1.utf16.count }
        if units <= maxCharactersPerScript { return units }
        return pages.reduce(0) { $0 + $1.count }
    }

    // MARK: Coding

    private struct VersionProbe: Decodable { let version: Int }

    private struct LibraryFile: Codable {
        var version: Int
        var currentScriptID: UUID?
        var scripts: [PrompterScriptRecord]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// ISO 8601, with or without fractional seconds: a hand-edited date with
    /// milliseconds is still a date, and rejecting it would quarantine a good
    /// library.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date"))
        }
        return decoder
    }()

    /// `20261012T101500Z`: UTC, sortable, and free of the colons a file name
    /// should not carry.
    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
