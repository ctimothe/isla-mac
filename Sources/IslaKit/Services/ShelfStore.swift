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
    private let limit = 60

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
        let stored = Self.storedURLs(in: defaults, key: defaultsKey)
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
    private static func storedURLs(in defaults: UserDefaults, key: String) -> [(url: URL, bookmark: Data?)] {
        let paths = (defaults.stringArray(forKey: key) ?? []).map(URL.init(fileURLWithPath:))
        guard let bookmarks = defaults.array(forKey: key + ".bookmarks") as? [Data],
              bookmarks.count == paths.count else { return paths.map { ($0, nil) } }
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
                return (path, nil)
            }
            return (url, stale ? nil : data)
        }
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
    func refreshFromDisk() {
        refreshesForTests += 1
        importNewRecordings()
        guard !items.isEmpty else { return }
        let gone = Set(items.filter { Self.isGone($0.url) }.map(\.id))
        var changed = !gone.isEmpty
        if !gone.isEmpty {
            items.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
        }
        // Cards from before dates were kept learn theirs from the file, now
        // that the file may be asked.
        for index in items.indices where items[index].date == nil {
            let values = try? items[index].url.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey])
            if let date = values?.creationDate ?? values?.contentModificationDate {
                items[index].date = date
                changed = true
            }
        }
        if changed {
            sortNewestFirst()
            persist()
        }
        items.forEach(loadThumbnail)
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
        guard NotchViewModel.importRecordingsEnabled else { return }
        guard let since = defaults.object(forKey: RecordingPickup.sinceKey) as? Date else { return }
        let seen = Set(defaults.stringArray(forKey: RecordingPickup.seenKey) ?? [])
        let result = RecordingPickup.fresh(
            in: folder.map { [$0] } ?? RecordingPickup.captureFolders(defaults: defaults),
            since: since, seen: seen
        )
        // Persisted even when nothing is offered: settling old files is what
        // keeps them settled, and a denied folder simply reports nothing.
        defaults.set(Array(result.seen.suffix(RecordingPickup.seenLimit)), forKey: RecordingPickup.seenKey)
        guard !result.urls.isEmpty else { return }
        add(result.urls, dates: result.dates)
    }

    /// Whether the file is actually gone, as opposed to merely out of reach.
    ///
    /// `fileExists` answers false to both, and the difference matters: a card
    /// whose file was deleted should leave the shelf, while one the app was
    /// just refused access to should stay exactly where it is. Treating them
    /// alike meant a single "Don't Allow" silently emptied the shelf of
    /// everything kept in Downloads, with the files still sitting there.
    static func isGone(_ url: URL) -> Bool {
        if isInTrash(url) { return true }
        do {
            return try !url.checkResourceIsReachable()
        } catch let error as NSError {
            return error.code == NSFileReadNoSuchFileError
        }
    }

    /// - Parameter dates: when each capture was taken, where known. A file
    ///   without one — a drop, a picture saved from the clipboard — is dated
    ///   now, which is when it happened.
    func add(_ urls: [URL], dates: [URL: Date] = [:]) {
        let now = Date()
        // Reversed, so that inserting each at the front leaves the drop in the
        // order it was made: A, B, C dropped together used to land C, B, A.
        for url in urls.reversed() where !items.contains(where: { $0.url == url }) {
            var item = ShelfItem(url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
            item.date = dates[url] ?? now
            items.insert(item, at: 0)
            loadThumbnail(item)
        }
        sortNewestFirst()
        // After sorting, so the cards past the limit are the oldest, not the
        // ones that happened to arrive first.
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    /// Newest first, by when each card's moment was.
    ///
    /// Cards used to sit in the order they arrived, and a capture is found
    /// when the shelf opens rather than when it is taken: a recording made at
    /// 14:47 but first seen at 16:40 sat above the one made at 16:37, filmed
    /// on 2026-09-21. Stable, so cards of the same moment keep their order,
    /// and undated ones wait at the end until the file can be asked.
    private func sortNewestFirst() {
        items = items.enumerated().sorted { lhs, rhs in
            let left = lhs.element.date ?? .distantPast
            let right = rhs.element.date ?? .distantPast
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Whether a file sits in a Trash — the user's, or a volume's.
    static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    private func loadThumbnail(_ item: ShelfItem) {
        // A square box QuickLook fits the content into, whatever its shape.
        // Generous enough that a landscape screenshot still lands above the
        // card's pixel size once it has been fitted.
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            // `nsImage` already carries the right point size for the
            // representation; deriving one from `contentRect` risks describing
            // a shape the bitmap does not have.
            let image = rep.nsImage
            Task { @MainActor in
                guard let self, let index = self.items.firstIndex(where: { $0.url == item.url }) else { return }
                self.items[index].icon = image
            }
        }
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
    /// the grabbed card belongs to it, otherwise just that card.
    func dragURLs(startingAt item: ShelfItem) -> [URL] {
        guard selection.contains(item.id) else { return [item.url] }
        return items.filter { selection.contains($0.id) }.map(\.url)
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
