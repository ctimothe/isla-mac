import Darwin
import Foundation

/// One download in progress, as the island's ring shows it.
struct DownloadProgress: Equatable {
    /// The file's final name, as it will be when done ("report.pdf"), derived
    /// from the in-progress name. Chromium's `Unconfirmed 123.crdownload` has
    /// no better name yet, so it is "Unconfirmed 123" until the browser
    /// renames it.
    var name: String
    var bytesSoFar: Int64
    /// nil when the browser does not say: Chrome's `.crdownload` and
    /// Firefox's `.part` carry no length, and only Safari writes one down.
    var totalBytes: Int64?

    /// 0...1 when the total is known and above zero, else nil. A browser that
    /// reports a total and then sends a few bytes more than it promised does
    /// not push the ring past full.
    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesSoFar) / Double(totalBytes)))
    }
}

/// What a download folder's watch announces.
enum DownloadEvent: Equatable {
    /// A download finished: the final file, which exists now.
    case finished(URL)
    /// A file or folder arrived by AirDrop.
    case airDropReceived(URL)
}

/// Follows a download folder (`~/Downloads` in the app) for the island's
/// Downloads activity: a ring while a browser downloads, a confirmation when
/// it finishes, and an announcement for a file that arrived by AirDrop.
///
/// Nothing here reads a file's contents. The watch looks at names, at the size
/// of what is in progress, at Safari's own progress record and at the
/// quarantine mark, and that is all it needs: a browser says it is downloading
/// by the name it gives the file, and the system says who delivered a file by
/// the mark it puts on it.
///
/// Recognised by name, since no browser shares its state any other way:
/// Safari's `<name>.download` (a bundle holding the partial file and an
/// `Info.plist`), Chromium's `<name>.crdownload` — including
/// `Unconfirmed <n>.crdownload`, its name for a download whose file name is
/// not settled — Firefox's `<name>.part`, and Opera's `.opdownload`.
///
/// The folder is watched by the kernel, not polled: a write to a folder is an
/// entry added, removed or renamed in it. A download's size grows without
/// touching the folder, so while one is in progress, and only then, the watch
/// looks again every `tick` seconds. With nothing in progress it asks the
/// system for nothing at all.
///
/// Reading `~/Downloads` raises macOS's own folder prompt the first time, so
/// the setting that starts this watch is off by default. A folder the system
/// refuses to list is not an error and not news: the watch keeps what it knew
/// and tries again on the next change, so a permission granted a minute later
/// starts to work without a restart.
@MainActor
final class DownloadWatch {
    /// What a folder entry says about itself.
    struct Entry: Equatable, Sendable {
        /// A file's size, or a bundle's contents summed: Safari's partial file
        /// sits inside `<name>.download`, so the bundle's own size is the
        /// bytes so far.
        var size: Int64
        var isDirectory: Bool
        var created: Date?
    }

    /// What the watch reads and how it waits: the folder, `FileManager`,
    /// `getxattr` and a vnode source in the app; a table of files, a scripted
    /// clock and a hand-pulled change notification in a test. The sequencing
    /// is what needs holding — a rename that lands after the delete, a
    /// placeholder beside a `.part`, a listing the system refused — and none
    /// of it can be reached with a real folder and a real browser.
    struct Environment {
        var folder: URL
        /// The folder's entries, one level deep, or nil when the system would
        /// not list it (no permission, folder gone).
        var list: @Sendable (URL) -> [URL]?
        /// Size, kind and creation date of one in-progress entry; nil when it
        /// vanished between the listing and this call.
        var attributes: @Sendable (URL) -> Entry?
        /// Safari's bytes so far and total from `<bundle>.download/Info.plist`,
        /// or nil when the file is not there (yet) or does not parse.
        var readSafariInfo: @Sendable (URL) -> (soFar: Int64?, total: Int64?)?
        /// The agent field of the `com.apple.quarantine` attribute — the app
        /// that wrote the file ("sharingd" for AirDrop) — or nil when there is
        /// no mark, or it is not written yet.
        var quarantineAgent: @Sendable (URL) -> String?
        /// Calls `changed` whenever the folder gains, loses or renames an
        /// entry. Returns what stops it.
        var observe: @MainActor (_ folder: URL, _ changed: @escaping @Sendable () -> Void) -> (() -> Void)
        /// Runs a read away from the main thread.
        var offMain: @Sendable (@escaping @Sendable () -> Void) -> Void
        var onMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        /// Runs `work` on the main actor after `delay` seconds.
        var after: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> Void
        var now: @MainActor () -> Date

        static func live(folder: URL) -> Environment {
            Environment(
                folder: folder,
                list: { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: []) },
                attributes: { DownloadWatch.liveAttributes($0) },
                readSafariInfo: { DownloadWatch.liveSafariInfo($0) },
                quarantineAgent: { DownloadWatch.liveQuarantineAgent($0) },
                observe: { folder, changed in DownloadWatch.liveObserve(folder, changed) },
                // Utility, not user-initiated: a sum over a bundle and a few
                // xattr reads are no one's wait; the ring follows on the next
                // half second anyway.
                offMain: { DispatchQueue.global(qos: .utility).async(execute: $0) },
                onMain: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
                after: { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
                },
                now: { Date() }
            )
        }
    }

    /// How often a download in progress is looked at again. Its size grows
    /// without a write to the folder; half a second is a ring that moves
    /// smoothly enough and a read that costs one listing and a few sizes.
    nonisolated static let tick: TimeInterval = 0.5

    /// How long a vanished download waits for its final file. A browser
    /// renames or moves the finished file into place, and that can land after
    /// the delete the folder reported: the entry is gone at once, the file
    /// shortly after. Past this, a download with no file is a cancelled one.
    nonisolated static let finishGrace: TimeInterval = 1

    /// How many times a new file's quarantine mark is read before it counts
    /// as having none. AirDrop writes the file and then marks it, so the first
    /// read can be early; one more, a `finishGrace` later, settles it.
    nonisolated static let markReads = 2

    nonisolated static let inProgressExtensions = ["download", "crdownload", "part", "opdownload"]

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// In-progress downloads, oldest first.
    private(set) var active: [DownloadProgress] = []
    var onActiveChange: (([DownloadProgress]) -> Void)?
    var onEvent: ((DownloadEvent) -> Void)?

    private var running = false
    /// Stamps each start, so a read that lands after a stop, or after a stop
    /// and a start, is dropped and so is a timer from the run before.
    private var session = 0
    private var stopObserving: (() -> Void)?
    private var scanning = false
    private var rescanRequested = false
    private var tickScheduled = false

    /// Whether the first listing has been taken: what is in the folder then is
    /// not news, whatever put it there.
    private var seeded = false
    /// Every visible entry that is not a download in progress, as of the last
    /// listing: a name outside it is a new arrival.
    private var known: Set<String> = []
    /// What the last listing found in progress, by the in-progress file name.
    private var tracked: [String: Tracked] = [:]
    /// Downloads whose entry vanished and whose file has not shown up: the
    /// final name and when to give up on it.
    private var awaiting: [String: Date] = [:]
    /// New files whose quarantine mark has not been read yet, and how many
    /// reads they have had.
    private var unmarked: [String: Int] = [:]

    private struct Tracked {
        var progress: DownloadProgress
        var created: Date?
    }

    /// One entry of a listing, with what was read away from the main thread.
    private struct Item: Sendable {
        var name: String
        var url: URL
        var entry: Entry?
        var safari: (soFar: Int64?, total: Int64?)?
        var agent: String?
    }

    private struct Listing: Sendable {
        var inProgress: [Item]
        /// Visible entries that are not downloads in progress.
        var others: [Item]
    }

    // MARK: - Start and stop

    func start() {
        guard !running else { return }
        running = true
        session &+= 1
        let started = session
        stopObserving = environment.observe(environment.folder) { [weak self] in
            // The system calls back on its own queue; every watch decision is
            // made on the main actor, one read at a time.
            self?.environment.onMain { [weak self] in
                guard let self, self.running, self.session == started else { return }
                self.scan()
            }
        }
        scan()
    }

    func stop() {
        guard running else { return }
        running = false
        session &+= 1
        stopObserving?()
        stopObserving = nil
        scanning = false
        rescanRequested = false
        tickScheduled = false
        seeded = false
        known = []
        tracked = [:]
        awaiting = [:]
        unmarked = [:]
        if !active.isEmpty {
            active = []
            onActiveChange?([])
        }
    }

    // MARK: - Scanning

    /// Looks at the folder once. Only one read is in flight: a change that
    /// comes while it runs asks for another when it lands, so the answer is
    /// never older than the last change and the folder is never listed twice
    /// at once.
    private func scan() {
        guard running else { return }
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        let started = session
        let folder = environment.folder
        let list = environment.list
        let attributes = environment.attributes
        let readSafariInfo = environment.readSafariInfo
        let quarantineAgent = environment.quarantineAgent
        let onMain = environment.onMain
        // Which names get their quarantine mark read: the new ones, and the
        // ones read before that had none yet. Never on the first listing.
        let seeded = seeded
        let known = known
        let unmarked = Set(unmarked.keys)

        environment.offMain { [weak self] in
            let listing = DownloadWatch.read(
                folder: folder, list: list, attributes: attributes, readSafariInfo: readSafariInfo,
                quarantineAgent: quarantineAgent, seeded: seeded, known: known, unmarked: unmarked
            )
            onMain { [weak self] in
                guard let self, self.running, self.session == started else { return }
                self.scanning = false
                if let listing {
                    self.apply(listing)
                } else {
                    // A refused listing keeps what was known, and the tick
                    // keeps going: a permission granted meanwhile is found on
                    // the next one, with no folder change to prompt it.
                    self.scheduleTick()
                }
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.scan()
                }
            }
        }
    }

    /// The directory read, away from the main thread. Attributes are asked of
    /// downloads in progress only: summing a big folder somebody AirDropped,
    /// for a file that is not changing, is a read for nothing.
    private nonisolated static func read(
        folder: URL,
        list: @Sendable (URL) -> [URL]?,
        attributes: @Sendable (URL) -> Entry?,
        readSafariInfo: @Sendable (URL) -> (soFar: Int64?, total: Int64?)?,
        quarantineAgent: @Sendable (URL) -> String?,
        seeded: Bool, known: Set<String>, unmarked: Set<String>
    ) -> Listing? {
        // A refused listing is nil, and nil keeps what the watch knew.
        guard let urls = list(folder) else { return nil }
        var inProgress: [Item] = []
        var others: [Item] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            if finalName(of: name) != nil {
                guard let entry = attributes(url) else { continue }
                let safari = entry.isDirectory && name.lowercased().hasSuffix(".download") ? readSafariInfo(url) : nil
                inProgress.append(Item(name: name, url: url, entry: entry, safari: safari, agent: nil))
            } else {
                let wantsMark = seeded && (!known.contains(name) || unmarked.contains(name))
                others.append(Item(
                    name: name, url: url, entry: nil, safari: nil,
                    agent: wantsMark ? quarantineAgent(url) : nil
                ))
            }
        }
        return Listing(inProgress: inProgress, others: others)
    }

    /// The name a file will have when its download is done, or nil when this
    /// is not a download in progress. Case-insensitive, because a browser's
    /// suffix is its own and a file system may not care; the base name keeps
    /// its case.
    nonisolated static func finalName(of name: String) -> String? {
        guard !name.hasPrefix(".") else { return nil }
        let lower = name.lowercased()
        for ext in inProgressExtensions where lower.hasSuffix("." + ext) {
            let base = String(name.dropLast(ext.count + 1))
            return base.isEmpty ? nil : base
        }
        return nil
    }

    // MARK: - Applying a listing

    private func apply(_ listing: Listing) {
        let now = environment.now()
        let previousActive = active
        var events: [DownloadEvent] = []
        let visible = Dictionary(listing.others.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // What is in progress now.
        var current: [String: Tracked] = [:]
        var finalNames: Set<String> = []
        for item in listing.inProgress {
            guard let entry = item.entry, let final = Self.finalName(of: item.name) else { continue }
            // Safari's own count first: it is the browser's, where the bundle's
            // size is only what has reached the disk. Without a plist yet, the
            // size alone, and no total.
            let soFar = item.safari?.soFar ?? entry.size
            let progress = DownloadProgress(name: final, bytesSoFar: max(0, soFar), totalBytes: item.safari?.total)
            current[item.name] = Tracked(progress: progress, created: entry.created)
            finalNames.insert(final)
        }

        // A download whose entry is gone is finished if its file is there, and
        // may be if it is about to be; nothing there for good is a cancelled
        // one, and says nothing. The first listing has nothing to compare with.
        var finishedNow: Set<String> = []
        for (entryName, gone) in tracked where current[entryName] == nil {
            let final = gone.progress.name
            if let file = visible[final] {
                finishedNow.insert(final)
                events.append(.finished(file.url))
            } else {
                awaiting[final] = now.addingTimeInterval(Self.finishGrace)
            }
        }
        for (final, deadline) in awaiting {
            if let file = visible[final] {
                finishedNow.insert(final)
                events.append(.finished(file.url))
                awaiting[final] = nil
            } else if now >= deadline {
                awaiting[final] = nil
            }
        }

        // Arrivals. A name is new when the last listing did not have it. Not
        // news: a download's final file (a Firefox placeholder is there before
        // its `.part` is gone), and anything the first listing found.
        var undecided: [String: Int] = [:]
        if seeded {
            for item in listing.others {
                let name = item.name
                let isNew = !known.contains(name)
                guard isNew || unmarked[name] != nil else { continue }
                if finalNames.contains(name) || finishedNow.contains(name) { continue }
                let reads = (unmarked[name] ?? 0) + 1
                if let agent = item.agent {
                    if Self.isAirDrop(agent) { events.append(.airDropReceived(item.url)) }
                } else if reads < Self.markReads {
                    undecided[name] = reads
                }
            }
        }
        unmarked = undecided
        known = Set(listing.others.map(\.name))
        seeded = true
        tracked = current

        let ordered = current.values.sorted {
            ($0.created ?? .distantFuture, $0.progress.name) < ($1.created ?? .distantFuture, $1.progress.name)
        }.map(\.progress)
        if ordered != previousActive {
            active = ordered
            onActiveChange?(ordered)
        }
        for event in events { onEvent?(event) }

        scheduleFollowUps()
    }

    /// Arrivals' marks and a vanished download's file are both read once more
    /// a `finishGrace` later, and a download in progress is looked at again
    /// every `tick`. Nothing else asks the system for anything.
    private func scheduleFollowUps() {
        let started = session
        if !awaiting.isEmpty || !unmarked.isEmpty {
            environment.after(Self.finishGrace) { [weak self] in
                guard let self, self.running, self.session == started else { return }
                self.scan()
            }
        }
        scheduleTick()
    }

    private func scheduleTick() {
        let started = session
        if !active.isEmpty, !tickScheduled {
            tickScheduled = true
            environment.after(Self.tick) { [weak self] in
                guard let self, self.running, self.session == started else { return }
                self.tickScheduled = false
                // The download may have ended since the tick was set: then it
                // is the end of the ticking, and nothing is read.
                if !self.active.isEmpty { self.scan() }
            }
        }
    }

    /// Whether a quarantine agent is AirDrop's. `sharingd` is the daemon that
    /// receives the transfer and writes the mark.
    nonisolated static func isAirDrop(_ agent: String) -> Bool {
        let lower = agent.lowercased()
        return lower.contains("sharingd") || lower.contains("airdrop")
    }

    // MARK: - The live environment

    private nonisolated static func liveAttributes(_ url: URL) -> Entry? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .creationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = values.isDirectory ?? false
        var size = Int64(values.fileSize ?? 0)
        if isDirectory {
            size = 0
            let walk = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
            )
            while let child = walk?.nextObject() as? URL {
                guard let childValues = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      childValues.isRegularFile == true else { continue }
                size += Int64(childValues.fileSize ?? 0)
            }
        }
        return Entry(size: size, isDirectory: isDirectory, created: values.creationDate)
    }

    /// Safari's progress record. The key names come from Safari's own
    /// `Downloads.plist` and from its `.download` bundles as documented in
    /// 2004 (Mac OS X Hints, "Resuming a download after Safari crashes");
    /// current Safari writing them into each bundle is not confirmed. A plist
    /// without them gives nil values, and the caller falls back to the size.
    private nonisolated static func liveSafariInfo(_ bundle: URL) -> (soFar: Int64?, total: Int64?)? {
        let plist = bundle.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        func number(_ key: String) -> Int64? {
            (dictionary[key] as? NSNumber).map { Int64(truncating: $0) }
        }
        return (number("DownloadEntryProgressBytesSoFar"), number("DownloadEntryProgressTotalToLoad"))
    }

    /// The third field of `flags;hex-time;agent;uuid`, as `Diagnostics` reads
    /// the same attribute whole.
    private nonisolated static func liveQuarantineAgent(_ url: URL) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read > 0, let value = String(bytes: buffer.prefix(read), encoding: .utf8) else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        return String(fields[2])
    }

    /// A vnode source on the folder: the kernel reports a write when an entry
    /// is added, removed or renamed inside it. `O_EVTONLY` takes a descriptor
    /// for events only, which does not keep a volume from unmounting. A folder
    /// that cannot be opened is not watched, and the watch reports nothing
    /// rather than guessing.
    private static func liveObserve(_ folder: URL, _ changed: @escaping @Sendable () -> Void) -> (() -> Void) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return {} }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend], queue: .main
        )
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return { source.cancel() }
    }
}
