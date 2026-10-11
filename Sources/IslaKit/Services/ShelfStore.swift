import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker Isla puts on pasteboard writes of its own.
    static let islaInternal = NSPasteboard.PasteboardType(ProductIdentity.internalPasteboardType)
}

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    /// Changes only when `ShelfStore.followMove` follows the file somewhere
    /// else; the card keeps its id, and with it its place in a selection.
    var url: URL
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

    // MARK: The name a card draws

    /// A card's width and the inset its text keeps from either edge. Kept
    /// here, beside the name that has to fit between them, so the column the
    /// name is fitted to and the card that draws it cannot drift apart.
    static let cardWidth: CGFloat = 86
    static let cardInset: CGFloat = 6
    /// The column the name line has: 74 pt.
    static let cardNameWidth: CGFloat = cardWidth - 2 * cardInset

    /// The name cut to `budget` characters, keeping what tells it apart.
    ///
    /// SwiftUI's middle truncation split an 86 pt card's name in half, which
    /// kept about five characters each side: "Screenshot 2026-10-11 at
    /// 15.04.44.png" read "Scree….44.png", and so did every other capture on
    /// the shelf (H-025). Names in a shelf's families — captures, recordings,
    /// "Meeting notes", "Invoice 0042" — share their start and differ at their
    /// last word, so the last word and the extension are kept whole and the
    /// start gets whatever room is left, none if need be: "…15.04.44.png".
    /// The thumbnail and the help tag say the rest. A name with no last word
    /// short enough to keep is cut with its tail weighted two to one, since a
    /// camera's IMG_… and a download's hash also differ at the end.
    static func compactName(_ name: String, budget: Int) -> String {
        guard name.count > budget else { return name }
        guard budget > 1 else { return String(name.prefix(budget)) }
        let ellipsis = "…"
        var stem = name
        var ext = ""
        let pathExtension = (name as NSString).pathExtension
        // An extension the budget can carry with room to spare, and a real
        // one: "Version 1.5 final" has a dot, not an extension.
        if !pathExtension.isEmpty, !pathExtension.contains(where: \.isWhitespace),
           pathExtension.count + 1 <= budget - 3 {
            ext = "." + pathExtension
            stem = String(name.dropLast(ext.count))
        }
        func head(_ count: Int) -> String {
            String(stem.prefix(max(0, count))).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        if let space = stem.lastIndex(where: \.isWhitespace) {
            let tail = String(stem[stem.index(after: space)...]) + ext
            if !tail.isEmpty, tail.count + 1 <= budget {
                return head(budget - tail.count - 1) + ellipsis + tail
            }
        }
        let room = budget - ext.count - 1
        let kept = room / 3
        return head(kept) + ellipsis + String(stem.suffix(room - kept)) + ext
    }

    /// The longest `compactName` that `measure` says fits in `width`.
    static func compactName(_ name: String, fitting width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(name) > width else { return name }
        var budget = name.count - 1
        var candidate = compactName(name, budget: budget)
        while budget > 2, measure(candidate) > width {
            budget -= 1
            candidate = compactName(name, budget: budget)
        }
        return candidate
    }

    /// The card's name line as it is drawn: the caption role, regular, with
    /// the role's tracking. A count of characters is no measure of a 10 pt
    /// line — "Scr…15.04.44.png" is 16 of them and 86 pt, where "Invoice
    /// 0042.pdf" is 16 and 82 pt — and a name cut to a guess was cut again by
    /// SwiftUI, in the middle, which is the bug this exists to fix.
    static func measureCardName(_ text: String) -> CGFloat {
        let size = Theme.TypeRole.caption.size
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .kern: Theme.tracking(forSize: size),
        ]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    // MARK: The card menu's header

    /// The disabled first line of the card's menu: what the file is, how big,
    /// and where — "PNG image · 2.4 MB · in Desktop". Two files of the same
    /// name, a copy in Downloads and the original on the Desktop, were the
    /// same card until a person acted on one (M-23).
    ///
    /// An offline card has nothing to read, so it names the disk it lives on,
    /// which is what brings it back. The kind and the folder are in the
    /// system's words, as Finder shows them; the size is in the app's language.
    ///
    /// Asked by the menu's header view, which SwiftUI builds when the menu
    /// is, not on every pass of the card.
    func menuHeader(volumes: String = "/Volumes") -> String {
        let folder = url.deletingLastPathComponent()
        if isOffline {
            if let root = ShelfStore.volumeRoot(of: url, volumes: volumes) {
                return (root as NSString).lastPathComponent
            }
            return folder.lastPathComponent
        }
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey])
        let kind = values?.localizedTypeDescription
            ?? UTType(filenameExtension: url.pathExtension)?.localizedDescription
            ?? url.pathExtension.uppercased()
        let place = FileManager.default.displayName(atPath: folder.path)
        // A folder on the shelf has no size worth stating: `fileSize` is the
        // directory entry's, not its contents'.
        guard values?.isDirectory != true, let bytes = values?.fileSize else {
            return localized("%@ · in %@", kind, place)
        }
        let size = Int64(bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: appLanguage)))
        return localized("%@ · %@ · in %@", kind, size, place)
    }
}

/// Drop zone contents. Files are referenced, never copied — the shelf is a
/// holding area, so deleting the original removes it from the shelf. A file
/// moved by a drag out of the shelf is followed instead (`followMove`).
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Cards picked for a group drag. Empty means "drag whatever is grabbed".
    @Published private(set) var selection: Set<UUID> = []
    /// The card a Shift range extends from: the last one a plain click or a
    /// ⌘-click picked, as in Finder. It used to move on a plain click only,
    /// so ⌘-click A then ⇧-click D had no anchor at all and toggled D alone
    /// instead of selecting A…D (J-022). A ⌘-click that takes a card *out*
    /// of the selection leaves it where it was.
    private var anchor: UUID?

    /// One line the footer says about the last thing the shelf did on its
    /// own account — a drop that was already there, cards pushed past the
    /// cap. Nil most of the time; it lapses by itself after `noticeLifetime`.
    ///
    /// The footer shows it only while nothing is selected, in the slot the
    /// selection count uses, so one line shows at a time. Anything else that
    /// needs to say a sentence in that slot raises its own case here and
    /// goes through `show(_:)`, rather than growing a second line.
    @Published private(set) var notice: Notice?

    /// How long a notice stays. A seam so tests do not wait four seconds.
    var noticeLifetime: Duration = .seconds(4)
    /// The pending lapse of the current notice. A newer notice cancels it, or
    /// the older one's timer would cut the newer short.
    private var noticeLapse: Task<Void, Never>?

    /// What the footer can say.
    enum Notice: Equatable {
        /// Every card in a drop, or some of them, were already on the shelf,
        /// so nothing new appeared for them. Said because a drop that changes
        /// nothing used to look exactly like a drop that failed (F-035).
        case alreadyOnShelf
        /// The shelf was full and this many of its oldest cards left it to
        /// make room. Their files stay where they are.
        case evicted(Int)

        var text: String {
            switch self {
            case .alreadyOnShelf:
                return localized("Already on the Shelf")
            case .evicted(1):
                return localized("The Shelf holds %d, so the oldest card left it. Its file is untouched.", ShelfStore.limit)
            case .evicted(let count):
                return localized("The Shelf holds %d, so the %d oldest left it. Their files are untouched.", ShelfStore.limit, count)
            }
        }
    }

    /// What one `add` did, counted by card. `added` are the URLs that were
    /// new to the shelf; `duplicates`, the ones it already held (or that
    /// came twice in the same drop); `evicted`, the cards the cap trimmed
    /// afterwards, oldest first — which can include a newly added card older
    /// than everything already there.
    struct AddResult: Equatable {
        var added: Int
        var duplicates: Int
        var evicted: Int
    }

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
            // Recordings found on this open can fill the shelf as surely as
            // a drop can, and this pass runs with the shelf on screen.
            let evicted = trimToLimit(&cards)
            if evicted > 0 { show(.evicted(evicted)) }
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
        guard let stored = defaults.object(forKey: RecordingPickup.sinceKey) as? Date else { return nil }
        // A stamp the clock wrote in the future is pulled back to the present
        // and written back, here on the main thread that owns defaults (G-037).
        // Written back rather than only clamped: a clamp alone would move with
        // the clock, so each open's `since` would be that open's own moment,
        // and every capture would be judged older than the scan that found it
        // until real time passed the bad stamp.
        let since = RecordingPickup.effectiveSince(stored: stored)
        if since != stored { defaults.set(since, forKey: RecordingPickup.sinceKey) }
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
    ///
    /// Returns what became of the drop, and says it in the footer too: a URL
    /// already on the shelf, or a card past the cap, used to leave without a
    /// word, so dropping 100 photos lost 40 of them silently (F-035). The
    /// cap still evicts the oldest rather than refusing the newest — a full
    /// shelf that refused would stop new screenshots arriving, which is worse
    /// — but it says so now.
    @discardableResult
    func add(_ urls: [URL], dates: [URL: Date] = [:]) -> AddResult {
        var cards = items
        let arrived = merge(urls, dates: dates, into: &cards)
        cards = Self.newestFirst(cards)
        let evicted = trimToLimit(&cards)
        items = cards
        persist()
        for url in arrived where items.contains(where: { $0.url == url }) { loadThumbnail(url) }
        let result = AddResult(added: arrived.count, duplicates: urls.count - arrived.count, evicted: evicted)
        // Eviction first: losing cards matters more than a card that was
        // already there, and the slot holds one line.
        if result.evicted > 0 {
            show(.evicted(result.evicted))
        } else if result.duplicates > 0 {
            show(.alreadyOnShelf)
        }
        return result
    }

    /// Puts one line in the footer for `noticeLifetime`, replacing whatever
    /// was there and restarting the clock.
    func show(_ notice: Notice) {
        noticeLapse?.cancel()
        self.notice = notice
        let lifetime = noticeLifetime
        noticeLapse = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
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
    /// ones that happened to arrive first. Returns how many left.
    ///
    /// A trimmed card leaves the selection and the anchor with it. It used to
    /// stay selected with no card to show it: the footer read "3 selected"
    /// over two marked cards, and "Remove 3" would have promised one more
    /// than it could remove (J-022).
    @discardableResult
    private func trimToLimit(_ cards: inout [ShelfItem]) -> Int {
        guard cards.count > Self.limit else { return 0 }
        let trimmed = Set(cards[Self.limit...].map(\.id))
        cards.removeLast(cards.count - Self.limit)
        selection.subtract(trimmed)
        if let anchor, trimmed.contains(anchor) { self.anchor = nil }
        return trimmed.count
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

    /// Takes the selected cards off the shelf and leaves the rest — the
    /// footer's "Remove 2". Beside a selection the footer used to offer only
    /// Clear, which emptied the whole shelf (H-015). The files stay where
    /// they are, as with every removal.
    func removeSelected() {
        guard !selection.isEmpty else { return }
        let picked = selection
        items.removeAll { picked.contains($0.id) }
        selection.removeAll()
        anchor = nil
        persist()
    }

    // MARK: - Selection

    /// Plain click replaces the selection; ⌘ toggles one card; ⇧ selects the
    /// contiguous run between the anchor and the clicked card, matching Finder.
    /// A plain click or a ⌘-click that picks a card moves the anchor to it.
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
                anchor = item.id
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
        return selectedCards.map(\.url)
    }

    /// The picked cards there is a file behind, in shelf order: what the
    /// footer's action bar acts on, as a drag of the selection would.
    var selectedCards: [ShelfItem] {
        items.filter { selection.contains($0.id) && !$0.isOffline }
    }

    /// The cards a drag started on `item` lifts — the same ones as
    /// `dragURLs`, with the grabbed card moved to the front. The first card
    /// is the one drawn exactly under the pointer and the rest fan out behind
    /// it, so a group grabbed by its third card no longer showed the first
    /// card's picture where the pointer was.
    func dragCards(startingAt item: ShelfItem) -> [ShelfItem] {
        guard selection.contains(item.id) else { return item.isOffline ? [] : [item] }
        let picked = selectedCards
        return picked.filter { $0.id == item.id } + picked.filter { $0.id != item.id }
    }

    // MARK: - Following a dragged-out file

    /// How long to wait, each time, before asking again after a drag whose
    /// files had not moved yet when it ended. A seam so tests do not wait.
    ///
    /// Finder carries out a drop as a file operation of its own, after it
    /// has accepted the drop, so the drag can end with the file still where
    /// it was. A move within one disk is a rename and lands at once; the
    /// last ask is for a slower one. Past it, the next open of the Shelf
    /// settles the card the way it settles any other.
    var moveSettleDelays: [Duration] = [.milliseconds(300), .seconds(2)]

    /// Follows the files of a drag that ended in a move, or in the Trash.
    ///
    /// A ⌘-drag into a Finder folder moves the file, and the card used to
    /// keep the old path: double-click, Quick Look and a second drag all
    /// failed without a word, and the next open erased the card as deleted
    /// with the file one folder over (F-020). Each card's bookmark is
    /// resolved again. A new place updates the card in place — same id, same
    /// selection — and is saved. A file in a Trash, or one the bookmark can no
    /// longer find (a move to another disk is a copy and a delete, which no
    /// bookmark follows), takes its card with it.
    ///
    /// Returns the pending second look when some file had not moved yet, so
    /// tests can wait on it; nil when everything is settled.
    @discardableResult
    func followMove(_ urls: [URL]) -> Task<Void, Never>? {
        let waiting = follow(urls)
        guard !waiting.isEmpty else { return nil }
        let delays = moveSettleDelays
        return Task { [weak self] in
            var left = waiting
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, !left.isEmpty else { return }
                left = self.follow(left)
            }
        }
    }

    /// One pass of `followMove`. Returns the URLs whose files are still
    /// exactly where they were — not moved yet, or never moved at all.
    private func follow(_ urls: [URL]) -> [URL] {
        var cards = items
        var waiting: [URL] = []
        var gone: Set<UUID> = []
        var changed = false
        for url in urls {
            guard let index = cards.firstIndex(where: { $0.url == url }) else { continue }
            let place = Self.whereIs(url, bookmark: bookmarks[url])
            switch place {
            case .unmoved:
                waiting.append(url)
            case .gone:
                gone.insert(cards[index].id)
            case .moved(let new, let fresh):
                if cards.contains(where: { $0.url == new }) {
                    // Moved onto a file the shelf already holds: one card is
                    // enough for one file.
                    gone.insert(cards[index].id)
                    continue
                }
                cards[index].url = new
                // The bookmark found the file, so it is kept — unless the
                // system called it stale, and then the next save makes it
                // again, as `storedURLs` does at launch.
                bookmarks[url] = nil
                bookmarks[new] = fresh
                // The card's preview is of the same file, so it is not owed
                // again; only its key changes.
                if thumbnailed.remove(url) != nil { thumbnailed.insert(new) }
                if let pending = pendingIcons.removeValue(forKey: url) { pendingIcons[new] = pending }
                changed = true
            }
        }
        if !gone.isEmpty {
            cards.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
            if let anchor, gone.contains(anchor) { self.anchor = nil }
            changed = true
        }
        if changed {
            items = cards
            persist()
        }
        return waiting
    }

    /// What a card's bookmark says about where its file is now.
    private enum Place {
        case unmoved
        /// Found somewhere else; `bookmark` is the one to keep, nil if stale.
        case moved(URL, bookmark: Data?)
        case gone
    }

    /// Resolves a card's bookmark after a drag. Unlike `load`, this may
    /// look at the file: the person just dragged it, so the Shelf already
    /// had its answer for that folder.
    private static func whereIs(_ url: URL, bookmark: Data?) -> Place {
        var stale = false
        guard let bookmark, !bookmark.isEmpty, let found = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &stale
        ) else {
            // Nothing to follow it with: the path is the only answer.
            return FileManager.default.fileExists(atPath: url.path) ? .unmoved : .gone
        }
        if isInTrash(found) { return .gone }
        // Compared with links resolved: the bookmark answers with the real
        // path (`/private/var/…`) where the card may hold the one it was
        // dropped under (`/var/…`), and that is not a move.
        if found.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() { return .unmoved }
        return .moved(found, bookmark: stale ? nil : bookmark)
    }

    func reveal(_ item: ShelfItem) {
        reveal([item])
    }

    /// Every card at once, as Finder's own Show in Finder does for a
    /// selection: one window per folder, the files picked in it.
    func reveal(_ cards: [ShelfItem]) {
        guard !cards.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(cards.map(\.url))
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
