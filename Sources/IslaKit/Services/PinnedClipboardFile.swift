import Foundation

/// The one file Keep Pinned Items writes (spec §9.4, owner decision 10):
/// `~/Library/Application Support/Isla/pinned-clipboard.plist`.
///
/// What it holds is exactly the pinned entries that are text or file URLs —
/// never a picture, which is memory only — and it holds nothing at all unless
/// the person turned the switch on. It never leaves the Mac, and it is
/// readable by the person alone: written with POSIX permissions 0600, into a
/// directory made 0700, and put in place by a rename, so a reader (or a crash)
/// sees the old file or the new one and never half of either.
///
/// The URL is injected. A test hands it a temporary folder; the app hands it
/// `PinnedClipboardFile.live`, which no test reaches.
struct PinnedClipboardFile {
    let url: URL

    /// The only place the app keeps it.
    static var live: PinnedClipboardFile? {
        AppPaths.live.supportFile("pinned-clipboard.plist").map(PinnedClipboardFile.init(url:))
    }

    /// The most pins a file is believed to hold. Far past anything a person
    /// pins by hand; a file claiming more is damaged or hostile, and loading
    /// it whole would be an unbounded read into memory.
    static let maximumEntries = 500

    /// One saved pin: the payload and when it was copied (so its age still
    /// reads true after a relaunch).
    struct Record: Equatable {
        let payload: ClipItem.Payload
        let date: Date
    }

    /// The pinned entries worth saving, from the history as it stands: text
    /// and file kinds, in the order the list shows them. Images are skipped by
    /// kind, not by accident: the 25 MB original is not something to leave in
    /// Application Support.
    static func records(from items: [ClipItem]) -> [Record] {
        items.filter(\.isPinned).compactMap { item in
            switch item.payload {
            case .text, .file, .files: return Record(payload: item.payload, date: item.date)
            case .image: return nil
            }
        }
    }

    // MARK: Writing

    /// Writes the records, or removes the file when there are none: an empty
    /// file is a file that says "you kept pins here once".
    ///
    /// Throws what the filesystem threw. The caller logs it and carries on —
    /// a pin that could not be saved is still pinned in memory.
    func save(_ records: [Record], using fm: FileManager = .default) throws {
        guard !records.isEmpty else {
            delete(using: fm)
            return
        }
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: Self.propertyList(records), format: .xml, options: 0
        )
        // A temporary file made 0600 from the start, then renamed over the
        // real one. `Data.write(options: .atomic)` is atomic, but creates the
        // file with the process umask first — world-readable for as long as it
        // takes to chmod it, which is the window this avoids.
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Removes the file. A file that is not there is already what was asked.
    func delete(using fm: FileManager = .default) {
        try? fm.removeItem(at: url)
    }

    // MARK: Reading

    /// The saved pins, or none. Never throws and never crashes: a file that is
    /// missing, unreadable, from a newer Isla, damaged by a half-finished
    /// write elsewhere or edited by hand into nonsense is simply not pins, and
    /// the next save replaces it.
    ///
    /// **Files come back only if they are local and still there** (review
    /// 2026-10-15). A pinned file is a path, and `ClipItem.init` reads the file's
    /// size on the main thread at launch: a path on a network mount that has
    /// gone away can hang that read for as long as the mount's timeout, with
    /// the whole island frozen behind it. Anything under `/Volumes/` or
    /// `/Network/` is dropped without the filesystem being asked about it, and
    /// anything else is kept only if `exists` says so. A stack of files keeps
    /// the ones that qualify; none left, the pin is gone.
    ///
    /// - Parameter exists: injectable so a test can prove a mount path is never
    ///   asked about; the app asks `FileManager`.
    func load(using fm: FileManager = .default, exists: ((String) -> Bool)? = nil) -> [Record] {
        guard let data = fm.contents(atPath: url.path),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = object as? [String: Any],
              root["version"] as? Int == Self.version,
              let entries = root["items"] as? [[String: Any]] else { return [] }
        let present = exists ?? { fm.fileExists(atPath: $0) }
        return entries.prefix(Self.maximumEntries)
            .compactMap(Self.record(from:))
            .compactMap { Self.keepingLocalFiles($0, exists: present) }
    }

    /// Paths under these are volumes that may not be local, or not there.
    static let nonLocalPrefixes = ["/Volumes/", "/Network/"]

    static func isLocalAndPresent(_ path: String, exists: (String) -> Bool) -> Bool {
        if nonLocalPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        return exists(path)
    }

    static func keepingLocalFiles(_ record: Record, exists: (String) -> Bool) -> Record? {
        switch record.payload {
        case .text, .image:
            return record
        case .file(let url):
            return isLocalAndPresent(url.path, exists: exists) ? record : nil
        case .files(let urls):
            let kept = urls.filter { isLocalAndPresent($0.path, exists: exists) }
            switch kept.count {
            case 0: return nil
            case 1: return Record(payload: .file(kept[0]), date: record.date)
            default: return Record(payload: .files(kept), date: record.date)
            }
        }
    }

    // MARK: The format

    static let version = 1

    static func propertyList(_ records: [Record]) -> [String: Any] {
        let entries: [[String: Any]] = records.compactMap { record in
            var entry: [String: Any] = ["date": record.date]
            switch record.payload {
            case .text(let string):
                entry["kind"] = "text"
                entry["text"] = string
            case .file(let url):
                entry["kind"] = "file"
                entry["path"] = url.path
            case .files(let urls):
                entry["kind"] = "files"
                entry["paths"] = urls.map(\.path)
            case .image:
                return nil
            }
            return entry
        }
        return ["version": version, "items": entries]
    }

    static func record(from entry: [String: Any]) -> Record? {
        guard let kind = entry["kind"] as? String, let date = entry["date"] as? Date else { return nil }
        switch kind {
        case "text":
            guard let text = entry["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Record(payload: .text(ClipboardStore.capped(text)), date: date)
        case "file":
            guard let path = entry["path"] as? String, path.hasPrefix("/") else { return nil }
            return Record(payload: .file(URL(fileURLWithPath: path)), date: date)
        case "files":
            guard let paths = entry["paths"] as? [String], paths.count > 1,
                  paths.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
            return Record(payload: .files(paths.map { URL(fileURLWithPath: $0) }), date: date)
        default:
            return nil
        }
    }
}
