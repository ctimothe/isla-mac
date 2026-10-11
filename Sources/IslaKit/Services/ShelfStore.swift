import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker Isla puts on pasteboard writes of its own.
    static let islaInternal = NSPasteboard.PasteboardType(ProductIdentity.internalPasteboardType)
}

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Starts as the file-type icon and is replaced by a real preview once
    /// QuickLook renders one — a shelf of identical PNG icons is useless when
    /// what it holds is screenshots.
    var icon: NSImage
    /// The moment the card belongs to: when a capture was taken, or when a
    /// file was dropped. The shelf reads newest first by it. Nil only for a
    /// card from before dates were kept, until the shelf is next opened and
    /// the file itself can be asked.
    var date: Date?
    /// The file lives on a disk that is not plugged in right now — an
    /// ejected USB stick, an SMB share that went away with the network.
    /// The card stays, dimmed, and comes back to life when the disk does.
    /// Not saved: whether a disk is mounted is asked again on every open.
    var isOffline = false
    var name: String { url.lastPathComponent }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.url == rhs.url }

    /// How long ago, the way a person says it: "Just now", "5 min. ago",
    /// "2 hr. ago", "yesterday". In the app's own language, not the system's,
    /// so a card never reads half in one and half in the other.
    static func age(of date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return localized("Just now") }
        return ageFormatter.localizedString(for: date, relativeTo: now)
    }

    /// One formatter for every card. Each card draws its age on every pass of
    /// the shelf — every thirty seconds, and on every change — and used to
    /// build and configure a formatter of its own each time. The app's language
    /// is settled for the life of the process, so the locale is too.
    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()
}

/// Drop zone contents. Files are referenced, never copied — the shelf is a
/// holding area, so moving the original away simply removes it from the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Cards picked for a group drag. Empty means "drag whatever is grabbed".
    @Published private(set) var selection: Set<UUID> = []
    /// The last plainly-clicked card, from which a Shift range extends —
    /// matching Finder, where Shift always reaches back to the last item
    /// clicked without a modifier, not to whatever Cmd-click last touched.
    private var anchor: UUID?

    private let defaultsKey = "shelf.urls"
    private let defaults: UserDefaults
    /// Generous, because saved screenshots accumulate here and nothing is
    /// deleted behind the user's back. Cards past the limit leave the shelf,
    /// but their files stay in the folder.
    ///
    /// Read by the empty Shelf's copy as well, which says how many cards it
    /// holds: one number, so the sentence cannot drift from the trim.
    static let limit = 60

    /// Each card's bookmark, made once — when the card arrived, or read back
    /// with it at launch — and reused until the card leaves.
    ///
    /// `persist` runs on every change to the shelf, and making a bookmark reads
    /// the file's and the volume's metadata. It used to bookmark the whole
    /// shelf on every save: one copied screenshot meant up to sixty such reads
    /// on the main thread with the panel shut — touching files in Desktop and
    /// Downloads that `load()` goes out of its way not to touch — and the
    /// system log carried hundreds of bookmark creations per session.
    private var bookmarks: [URL: Data] = [:]

    /// Makes one card's bookmark. A seam so `ShelfStoreTests` can count them.
    var makeBookmark: (URL) -> Data? = {
        try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The roots of every mounted volume, as standardized paths. Asked off
    /// the main thread by `refreshFromDisk`, and by `load` only for a card
    /// whose bookmark would not resolve. A seam so tests can eject a disk
    /// they never had.
    var mountedVolumes: @Sendable () -> Set<String> = {
        Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map(\.standardizedFileURL.path))
    }

    /// What `refreshFromDisk` asks of each card, off the main thread. A seam
    /// so tests can point `/Volumes` at a folder of their own, and record
    /// which thread did the asking.
    var verdictFor: @Sendable (URL, Set<String>) -> Verdict = { url, mounted in
        ShelfStore.verdict(for: url, mounted: mounted)
    }

    /// Asks QuickLook for one card's preview; the answer arrives on any
    /// thread, nil when there is none. A seam so tests can count requests.
    var requestThumbnail: (URL, @escaping @Sendable (NSImage?) -> Void) -> Void = { url, done in
        // A square box QuickLook fits the content into, whatever its shape.
        // Generous enough that a landscape screenshot still lands above the
        // card's pixel size once it has been fitted.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            // `nsImage` already carries the right point size for the
            // representation; deriving one from `contentRect` risks describing
            // a shape the bitmap does not have.
            done(rep?.nsImage)
        }
    }

    /// Cards whose preview has been asked for, or has arrived, since the
    /// shelf was loaded. Every open used to ask QuickLook for all sixty
    /// again, and each answer landed as its own redraw of the whole panel in
    /// the middle of the tab transition.
    private var thumbnailed: Set<URL> = []
    /// Previews that have arrived and not yet been drawn — flushed together,
    /// so a burst of sixty answers is one change to `items` rather than sixty.
    private var pendingIcons: [URL: NSImage] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Rebuilds the cards from the stored paths without reading a single file.
    ///
    /// Nothing here touches the disk, and that is the whole point. Since
    /// Catalina, the first look at anything inside Desktop, Documents or
    /// Downloads raises a system permission prompt — for `stat` as much as for
    /// a read — and this used to run at launch, for every card, whether or not
    /// anyone was going to open the shelf. One file dragged in from Downloads
    /// months ago meant a dialog on every cold start, arriving with no visible
    /// cause: the panel was not even open. Isla promises no permissions until
    /// the calendar is opened, and this quietly broke that promise.
    ///
    /// So the icon comes from the file *name* — the extension is enough to
    /// name a type, and a type is enough to draw an icon — and whether the file
    /// is still there is not asked until someone looks at the shelf.
    ///
    /// One qualification since bookmarks were added: resolving a bookmark does
    /// touch the filesystem. It is done with `.withoutUI` and `.withoutMounting`
    /// so it can neither prompt nor mount, and it reads only the bookmark's own
    /// record rather than the file — but this is no longer literally zero disk
    /// access, and the stored path is used unchanged whenever resolution fails.
    func load() {
        // Card ids are minted per instance, so a reload orphans any selection:
        // the ids it holds now name nothing. Kept, they showed as a phantom
        // "Selected: N" in the footer with no card marked (#10).
        selection.removeAll()
        // A reload builds every card again from its generic icon, so every
        // preview is owed again.
        thumbnailed.removeAll()
        pendingIcons.removeAll()
        let stored = Self.storedURLs(in: defaults, key: defaultsKey, mounted: mountedVolumes)
        let urls = stored.map(\.url)
        bookmarks = Dictionary(
            stored.compactMap { entry in entry.bookmark.map { (entry.url, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let stamps = defaults.array(forKey: defaultsKey + ".dates") as? [Double]
        items = urls.enumerated().compactMap { index, url in
            // A path check, not a disk read: a card whose file went to the
            // Trash is a deleted card. The shelf used to follow a trashed
            // recording's bookmark into ~/.Trash and keep offering it.
            guard !Self.isInTrash(url) else { return nil }
            var item = ShelfItem(url: url, icon: Self.icon(forName: url))
            if let stamps, stamps.count == urls.count, stamps[index] > 0 {
                item.date = Date(timeIntervalSince1970: stamps[index])
            }
            return item
        }
    }

    /// Bookmarks first, raw paths second.
    ///
    /// Cards used to be stored as absolute path strings, which survive nothing:
    /// a rename of the home folder, a migration to a new Mac, a renamed volume,
    /// and every path at once points at nothing. `refreshFromDisk` then read
    /// that as "the files were deleted" and erased the whole shelf, files still
    /// sitting where they always were. A bookmark follows the file instead.
    /// Paths are still read so an existing shelf survives the upgrade.
    ///
    /// Each card comes back with the bookmark worth keeping: one that resolved
    /// and is not stale. A stale one is made again at the next save, which is
    /// what the system asks of a stale bookmark.
    ///
    /// One that fails to resolve because its disk is not plugged in is kept
    /// as it was. Resolution never mounts, so a bookmark to an ejected disk
    /// always fails here; dropping it meant the next save wrote an empty
    /// Data in its place, and the one record able to follow the file once
    /// the disk came back under another name was gone for good (F-001).
    private static func storedURLs(
        in defaults: UserDefaults, key: String, mounted: () -> Set<String>
    ) -> [(url: URL, bookmark: Data?)] {
        let paths = (defaults.stringArray(forKey: key) ?? []).map(URL.init(fileURLWithPath:))
        guard let bookmarks = defaults.array(forKey: key + ".bookmarks") as? [Data],
              bookmarks.count == paths.count else { return paths.map { ($0, nil) } }
        // Asked at most once, and only if a card on a volume failed to
        // resolve: the mount table is the kernel's, not a read of any disk.
        var mountedRoots: Set<String>?
        return zip(bookmarks, paths).map { data, path in
            var stale = false
            guard !data.isEmpty, let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI, .withoutMounting],
                bookmarkDataIsStale: &stale
            ) else {
                // No bookmark, or one that no longer resolves: the stored path
                // is still the best answer, and `refreshFromDisk` decides
                // whether the file is really gone.
                if !data.isEmpty, let root = volumeRoot(of: path) {
                    if mountedRoots == nil { mountedRoots = mounted() }
                    if mountedRoots?.contains(root) == false { return (path, data) }
                }
                return (path, nil)
            }
            return (url, stale ? nil : data)
        }
    }

    /// The root of the volume a path lives on, when it lives under
    /// `volumes` — `/Volumes/Backup` for `/Volumes/Backup/report.pdf` — and
    /// nil for anything on the startup disk.
    nonisolated static func volumeRoot(of url: URL, volumes: String = "/Volumes") -> String? {
        let base = URL(fileURLWithPath: volumes, isDirectory: true).standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > base.count + 1, Array(components.prefix(base.count)) == base else { return nil }
        return NSString.path(withComponents: Array(components.prefix(base.count + 1)))
    }

    /// An icon for a path, derived from its extension alone.
    private static func icon(forName url: URL) -> NSImage {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// How many passes `refreshFromDisk` has made — each one a reachability
    /// check and a QuickLook request per card. Counted for `FirstRunTests`.
    private(set) var refreshesForTests = 0

    /// Called when the shelf comes into view, and only then.
    ///
    /// This is where the disk is finally touched: missing files leave, real
    /// icons and previews arrive. If a permission prompt is coming, it comes
    /// here — with the shelf on screen and the cards in front of the person
    /// being asked, which is the difference between a question and an
    /// interruption.
    ///
    /// The asking itself happens off the main thread. It used to run here, on
    /// the main actor, one reachability check per card in the middle of the
    /// tab transition — and a card on a sleeping disk or a half-dead network
    /// share held the whole panel for as long as the check took (F-022). The
    /// cards are snapshotted here, judged on a utility thread, and the answer
    /// comes back in one hop, matched by URL rather than by position, so a
    /// card added or removed while the pass was out is neither lost nor
    /// brought back.
    ///
    /// The count is still taken synchronously: `FirstRunTests` read it right
    /// after the tab changes. The returned task finishes once the answer has
    /// been applied, which is what tests wait on.
    @discardableResult
    func refreshFromDisk() -> Task<Void, Never> {
        refreshesForTests += 1
        let urls = items.map(\.url)
        let undated = Set(items.filter { $0.date == nil }.map(\.url))
        let pickup = pickupInputs(from: nil)
        let mountedVolumes = mountedVolumes
        let verdictFor = verdictFor
        let pass = Task.detached(priority: .utility) { () -> DiskPass in
            var pass = DiskPass()
            if let pickup {
                pass.recordings = RecordingPickup.fresh(in: pickup.folders, since: pickup.since, seen: pickup.seen)
            }
            guard !urls.isEmpty else { return pass }
            let mounted = mountedVolumes()
            for url in urls {
                let verdict = verdictFor(url, mounted)
                pass.verdicts[url] = verdict
                // Cards from before dates were kept learn theirs from the
                // file, now that the file may be asked — when there is a file
                // to ask.
                guard undated.contains(url), verdict == .present || verdict == .unreachable else { continue }
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                if let date = values?.creationDate ?? values?.contentModificationDate {
                    pass.dates[url] = date
                }
            }
            return pass
        }
        return Task { [weak self] in
            let found = await pass.value
            self?.apply(found)
        }
    }

    /// What one pass over the disk found, carried back to the main thread in
    /// one piece.
    private struct DiskPass: Sendable {
        var verdicts: [URL: Verdict] = [:]
        var dates: [URL: Date] = [:]
        var recordings: (urls: [URL], dates: [URL: Date], seen: Set<String>, missing: [URL])?
    }

    /// The pass, applied in one write: gone cards leave, offline ones dim,
    /// undated ones learn their date, fresh recordings arrive — then one sort,
    /// at most one save, and previews for whatever has none yet.
    private func apply(_ pass: DiskPass) {
        var cards = items
        // `changed` is anything worth saving; `redrawn`, anything worth
        // drawing. An offline flag is the second and not the first: whether a
        // disk is mounted is asked again on every open, never stored.
        var changed = false
        var redrawn = false
        let gone = Set(cards.filter { pass.verdicts[$0.url] == .gone }.map(\.id))
        if !gone.isEmpty {
            cards.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
            changed = true
        }
        for index in cards.indices {
            let url = cards[index].url
            if let verdict = pass.verdicts[url], cards[index].isOffline != (verdict == .offline) {
                cards[index].isOffline = verdict == .offline
                redrawn = true
            }
            if cards[index].date == nil, let date = pass.dates[url] {
                cards[index].date = date
                changed = true
            }
        }
        var arrived: [URL] = []
        if let found = pass.recordings {
            settle(found.seen, missing: found.missing)
            arrived = merge(found.urls, dates: found.dates, into: &cards)
        }
        if changed || !arrived.isEmpty {
            cards = Self.newestFirst(cards)
            trimToLimit(&cards)
        }
        if changed || redrawn || !arrived.isEmpty { items = cards }
        if changed || !arrived.isEmpty { persist() }
        // Forget the previews of cards that have left, so the set stays the
        // size of the shelf; ask for the ones still owed. An offline card is
        // skipped: QuickLook has no file to read until the disk is back.
        thumbnailed.formIntersection(items.map(\.url))
        for card in items where !card.isOffline { loadThumbnail(card.url) }
    }

    /// Screen recordings the system saved since the feature first ran, picked
    /// up with no copy step. Runs on shelf open — the one moment touching the
    /// captures folder is an answered question rather than an interruption —
    /// and never in the background: a recording finished while away is simply
    /// there on the next open.
    ///
    /// The folder is a parameter rather than read inside so tests can point it
    /// at a temporary directory: the live one is Screenshot.app's save
    /// location, and a test must never scan the real Desktop.
    func importNewRecordings(from folder: URL? = nil) {
        guard let pickup = pickupInputs(from: folder) else { return }
        let result = RecordingPickup.fresh(in: pickup.folders, since: pickup.since, seen: pickup.seen)
        settle(result.seen, missing: result.missing)
        guard !result.urls.isEmpty else { return }
        add(result.urls, dates: result.dates)
    }

    /// What a recordings scan needs from defaults, read on the main thread
    /// before the scan leaves it. Nil when the feature is off or has not
    /// started — and then no folder is touched at all.
    private struct PickupInputs: Sendable {
        let folders: [URL]
        let since: Date
        let seen: Set<String>
    }

    private func pickupInputs(from folder: URL?) -> PickupInputs? {
        guard NotchViewModel.importRecordingsEnabled else { return nil }
        guard let since = defaults.object(forKey: RecordingPickup.sinceKey) as? Date else { return nil }
        return PickupInputs(
            folders: folder.map { [$0] } ?? RecordingPickup.captureFolders(defaults: defaults),
            since: since,
            seen: Set(defaults.stringArray(forKey: RecordingPickup.seenKey) ?? [])
        )
    }

    /// Persisted even when nothing is offered, and a denied folder simply
    /// reports nothing. Capture folders the scan found deleted leave the
    /// remembered list here, on the main thread that owns defaults, so a
    /// retired folder is probed once more at most rather than on every open.
    private func settle(_ seen: Set<String>, missing: [URL]) {
        defaults.set(Array(seen.suffix(RecordingPickup.seenLimit)), forKey: RecordingPickup.seenKey)
        RecordingPickup.forget(missing, defaults: defaults)
    }

    /// What became of a card's file, as far as the disk can say.
    enum Verdict: Sendable, Equatable {
        /// There, and readable.
        case present
        /// On a disk that is not plugged in. Kept, dimmed, until it is.
        case offline
        /// Deleted, or in a Trash. The card leaves.
        case gone
        /// There, but the app was refused a look. Kept exactly as it was.
        case unreachable
    }

    /// Whether the file is actually gone, as opposed to merely out of reach.
    ///
    /// `fileExists` answers false to both, and the difference matters: a card
    /// whose file was deleted should leave the shelf, while one the app was
    /// just refused access to should stay exactly where it is. Treating them
    /// alike meant a single "Don't Allow" silently emptied the shelf of
    /// everything kept in Downloads, with the files still sitting there.
    ///
    /// An ejected disk is the same trap a second time: a path under an
    /// unmounted `/Volumes` root answers "no such file", exactly like a
    /// deleted one, and every card on a USB stick or an SMB share used to
    /// leave the shelf on the next open — for good, since the save after it
    /// wrote the shorter list (F-001). So the mount table is asked first. A
    /// root that is a link rather than a mount point — `/Volumes/Macintosh HD`
    /// points at `/` — is asked like any other path, or a deleted file on the
    /// startup disk would sit on the shelf as "not connected" forever.
    ///
    /// - Parameter mounted: the roots of every mounted volume, standardized.
    /// - Parameter volumes: where volumes mount; a parameter so tests can
    ///   stand in a folder of their own.
    nonisolated static func verdict(for url: URL, mounted: Set<String>, volumes: String = "/Volumes") -> Verdict {
        if isInTrash(url) { return .gone }
        if let root = volumeRoot(of: url, volumes: volumes), !mounted.contains(root),
           (try? FileManager.default.destinationOfSymbolicLink(atPath: root)) == nil {
            return .offline
        }
        do {
            return try url.checkResourceIsReachable() ? .present : .gone
        } catch let error as NSError {
            return error.code == NSFileReadNoSuchFileError ? .gone : .unreachable
        }
    }

    /// - Parameter dates: when each capture was taken, where known. A file
    ///   without one — a drop, a picture saved from the clipboard — is dated
    ///   now, which is when it happened.
    func add(_ urls: [URL], dates: [URL: Date] = [:]) {
        var cards = items
        let arrived = merge(urls, dates: dates, into: &cards)
        cards = Self.newestFirst(cards)
        trimToLimit(&cards)
        items = cards
        persist()
        for url in arrived where items.contains(where: { $0.url == url }) { loadThumbnail(url) }
    }

    /// New cards at the front, in the order they came; a URL already on the
    /// shelf is left where it is. Returns the URLs that were new.
    private func merge(_ urls: [URL], dates: [URL: Date], into cards: inout [ShelfItem]) -> [URL] {
        let now = Date()
        var arrived: [URL] = []
        // Reversed, so that inserting each at the front leaves the drop in the
        // order it was made: A, B, C dropped together used to land C, B, A.
        for url in urls.reversed() where !cards.contains(where: { $0.url == url }) {
            var item = ShelfItem(url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
            item.date = dates[url] ?? now
            cards.insert(item, at: 0)
            // A card back on the shelf after leaving it starts from the
            // generic icon again, so its preview is owed again.
            thumbnailed.remove(url)
            arrived.append(url)
        }
        return arrived
    }

    /// After sorting, so the cards past the limit are the oldest, not the
    /// ones that happened to arrive first.
    private func trimToLimit(_ cards: inout [ShelfItem]) {
        if cards.count > Self.limit { cards.removeLast(cards.count - Self.limit) }
    }

    /// Newest first, by when each card's moment was.
    ///
    /// Cards used to sit in the order they arrived, and a capture is found
    /// when the shelf opens rather than when it is taken: a recording made at
    /// 14:47 but first seen at 16:40 sat above the one made at 16:37, filmed
    /// on 2026-09-21. Stable, so cards of the same moment keep their order,
    /// and undated ones wait at the end until the file can be asked.
    private static func newestFirst(_ cards: [ShelfItem]) -> [ShelfItem] {
        cards.enumerated().sorted { lhs, rhs in
            let left = lhs.element.date ?? .distantPast
            let right = rhs.element.date ?? .distantPast
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Whether a file sits in a Trash — the user's, or a volume's.
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    /// Asks for one card's preview, unless it has been asked for already
    /// since the shelf was loaded.
    private func loadThumbnail(_ url: URL) {
        guard thumbnailed.insert(url).inserted else { return }
        requestThumbnail(url) { [weak self] image in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.thumbnailArrived(image, for: url) }
            }
        }
    }

    private var flushScheduled = false

    /// One preview's answer. Held rather than drawn, and flushed with every
    /// other answer that reaches the main queue before the flush does: each
    /// one used to be its own write to `items`, and every write redraws the
    /// whole panel the shelf sits in.
    private func thumbnailArrived(_ image: NSImage?, for url: URL) {
        guard let image else {
            // No preview this time — a folder the app was refused, a file
            // QuickLook could not read yet. Asked again on the next open
            // rather than never.
            thumbnailed.remove(url)
            return
        }
        pendingIcons[url] = image
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushIcons() }
        }
    }

    private func flushIcons() {
        flushScheduled = false
        guard !pendingIcons.isEmpty else { return }
        var cards = items
        var drawn = false
        for index in cards.indices {
            guard let icon = pendingIcons[cards[index].url] else { continue }
            cards[index].icon = icon
            drawn = true
        }
        pendingIcons.removeAll()
        if drawn { items = cards }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        persist()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        persist()
    }

    // MARK: - Selection

    /// Plain click replaces the selection; ⌘ toggles one card; ⇧ selects the
    /// contiguous run between the anchor and the clicked card, matching Finder.
    func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift),
           let anchor,
           let anchorIndex = items.firstIndex(where: { $0.id == anchor }),
           let targetIndex = items.firstIndex(where: { $0.id == item.id }) {
            let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            selection = Set(items[range].map(\.id))
            return
        }
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else if selection == [item.id] {
            selection.removeAll()
            anchor = nil
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }

    func isSelected(_ item: ShelfItem) -> Bool { selection.contains(item.id) }

    func clearSelection() { selection.removeAll() }

    /// Files a drag started on `item` should carry: the whole selection when
    /// the grabbed card belongs to it, otherwise just that card. A card whose
    /// disk is not plugged in is left out: there is no file behind it to
    /// hand over, and the receiving app would be given a path to nothing.
    func dragURLs(startingAt item: ShelfItem) -> [URL] {
        guard selection.contains(item.id) else { return item.isOffline ? [] : [item.url] }
        return items.filter { selection.contains($0.id) && !$0.isOffline }.map(\.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Puts the card back on the pasteboard. Images go as image data as well as
    /// a file reference, so pasting works both in Finder and in an editor.
    func copy(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The file goes on first and everything below is added to the item it
        // creates. Order is the whole of it: `setData` always writes to the
        // first item, `writeObjects` appends a new one — so marking first put
        // the picture on one item and the file on another. One card then
        // arrives as two objects, and an editor that accepts both pastes the
        // screenshot twice.
        pasteboard.writeObjects([item.url as NSURL])
        // Tells ClipboardStore this change came from us, so a copied screenshot
        // is not saved to disk a second time.
        pasteboard.setData(Data(), forType: .islaInternal)
        if let type = UTType(filenameExtension: item.url.pathExtension), type.conforms(to: .image) {
            // Read off the main thread. A dropped photo can be tens of
            // megabytes, and reading it whole inside the click handler stalled
            // the open panel for the length of the read. The URL is already on
            // the pasteboard by now, so a paste that lands first still works;
            // the bytes join it a moment later.
            let url = item.url
            let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
            let expected = pasteboard.changeCount
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Declared as what the bytes are, not renamed to TIFF:
                        // consumers that trust the declared type would save a
                        // "TIFF" with JPEG inside (#9). The UTI is already the
                        // pasteboard type identifier.
                        let pasteboard = NSPasteboard.general
                        guard pasteboard.changeCount == expected else { return }
                        pasteboard.setData(data, forType: pasteboardType)
                    }
                }
            }
        }
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    private func persist() {
        // Both forms: the bookmark is what survives a move, the path keeps an
        // older build (and anybody reading defaults by hand) able to make sense
        // of the list.
        let urls = items.map(\.url)
        defaults.set(urls.map(\.path), forKey: defaultsKey)
        // One entry per card, in the same order as the paths — an empty Data
        // where a bookmark could not be made, never a shorter array. Dropping
        // the failures instead misaligned the two lists, and since the loader
        // prefers bookmarks whenever the key exists, a single unbookmarkable
        // file silently deleted its own card at the next launch.
        //
        // Made once per card and reused — see `bookmarks`. A failure is not
        // kept, so that card is tried again at the next save, as it always was.
        var kept: [URL: Data] = [:]
        let stored = urls.map { url -> Data in
            guard let data = bookmarks[url] ?? makeBookmark(url), !data.isEmpty else { return Data() }
            kept[url] = data
            return data
        }
        bookmarks = kept
        defaults.set(stored, forKey: defaultsKey + ".bookmarks")
        defaults.set(items.map { $0.date?.timeIntervalSince1970 ?? 0 }, forKey: defaultsKey + ".dates")
    }
}
