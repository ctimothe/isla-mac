import AppKit
import UniformTypeIdentifiers

struct ClipItem: Identifiable, Equatable {
    enum Payload: Equatable {
        case text(String)
        case file(URL)
        /// Several files copied at once. A multi-file copy used to be recorded
        /// as its first file alone, so pasting the entry back silently replaced
        /// the user's selection of twelve with one.
        case files([URL])
        /// A picture, kept in memory only (redesign spec §9.1, §9.4). Before
        /// this a copied picture went to the Shelf's screenshot vault or
        /// nowhere; it is now an entry like any other, under Include Images.
        case image(ClipImage)
    }

    let id: UUID
    let payload: Payload
    let date: Date
    /// Computed once at capture. `preview` used to trim the whole string on
    /// every render, for every row — twice, since the pane trimmed newlines out
    /// of the result — and a row is only ever a line high.
    let preview: String
    /// What the row draws it as, decided once at capture for the same reason
    /// (spec §9.1): the detectors are regular expressions, and a row that ran
    /// them would run them on every pass of a list of forty.
    let kind: ClipKind
    /// The host and path of a link, split for the row.
    let link: ClipLink?
    /// A single file's size in bytes, read once at capture. Nil for anything
    /// that is not a file on disk right now.
    let fileSize: Int64?
    /// Pinned entries sort first, do not count against the 40-entry cap and
    /// survive Clear History (spec §9.2, §9.4).
    var isPinned: Bool

    init(payload: Payload, date: Date, id: UUID = UUID(), isPinned: Bool = false) {
        self.id = id
        self.payload = payload
        self.date = date
        self.isPinned = isPinned
        self.preview = Self.preview(for: payload)
        switch payload {
        case .text(let string):
            let kind = ClipboardDetection.kind(ofText: string)
            self.kind = kind
            self.link = kind == .link ? ClipboardDetection.link(string) : nil
            self.fileSize = nil
        case .file(let url):
            self.kind = .file
            self.link = nil
            // Re-review 2026-10-15: a pin on a mount is restored without the
            // filesystem being asked (a gone network volume can hang this read
            // on the main thread), so its size is simply unknown.
            self.fileSize = PinnedClipboardFile.isNonLocal(url.path)
                ? nil
                : (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        case .files:
            self.kind = .files
            self.link = nil
            self.fileSize = nil
        case .image:
            self.kind = .image
            self.link = nil
            self.fileSize = nil
        }
    }

    private static func preview(for payload: Payload) -> String {
        switch payload {
        case .text(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let flattened = trimmed.replacingOccurrences(of: "\n", with: " ")
            return String(flattened.prefix(previewLimit))
        case .file(let url):
            return url.lastPathComponent
        case .files(let urls):
            guard let first = urls.first else { return "" }
            guard urls.count > 1 else { return first.lastPathComponent }
            return "\(first.lastPathComponent) + \(urls.count - 1)"
        case .image:
            return localized("Image")
        }
    }

    /// A row shows one line; anything past this could never be read.
    static let previewLimit = 512

    /// The kind's own glyph — the leading mark for text-like kinds, and the
    /// glyph a covered row wears for the kinds whose real mark would show the
    /// content (spec §9.1, §9.4).
    var symbol: String {
        switch kind {
        case .text: return "text.alignleft"
        case .colour: return "square.fill"
        case .code: return "curlybraces"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .files: return "doc.on.doc"
        }
    }

    /// The text the search field matches (spec §9.3): the whole string for the
    /// text kinds — a match past the 512 characters a row can show still finds
    /// the entry — the names for files, and the word "Image" with where it
    /// came from for a picture.
    var searchText: String {
        switch payload {
        case .text(let string): return string
        case .file(let url): return url.lastPathComponent
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: " ")
        case .image(let image): return [preview, image.sourceApp].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// The string a text kind holds, or nil for pictures and files.
    var text: String? {
        if case .text(let string) = payload { return string }
        return nil
    }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool { lhs.payload == rhs.payload }
}

/// What macOS lets Isla read from the pasteboard: Privacy & Security > Paste
/// from Other Apps, on macOS 15.4 and later. `unknown` is a system that does
/// not say (older macOS, or the policy left at its default), and it is
/// treated as readable: stopping history until the system answers would end
/// it for every user on a Mac that never enforces the policy.
enum ClipboardAccess { case unknown, ask, allowed, denied }

/// Polls the general pasteboard's change counter. Cheap: one integer read
/// twice a second, and nothing at all is read until the counter moves. When
/// it moves, the type list decides what to read, and only what a switch wants
/// is read: under Paste from Other Apps set to Ask, every content read is an
/// alert the user has to answer.
@MainActor
final class ClipboardStore: ObservableObject {
    /// The history, newest first. Pinned entries are *listed* first (`listed`)
    /// but are not stored apart: where an entry sits in this array is when it
    /// was last used, which is what the 40-entry cap and "freshly used entries
    /// bubble to the top" are about.
    @Published private(set) var items: [ClipItem] = [] {
        didSet { persistPinsIfWanted() }
    }

    /// Raised for image data on the pasteboard — a screenshot taken straight to
    /// the clipboard, which would otherwise vanish after one paste.
    var onImage: ((Data) -> Void)?

    /// Raised for movie bytes on the pasteboard — a captured recording copied
    /// as data — with the container extension the bytes were copied as. The
    /// vault names the file from it, like screenshots are named from theirs.
    var onMovieData: ((Data, String) -> Void)?

    /// Raised for each copied file that is a movie. The file is already on
    /// disk, so there is nothing for the vault to write; the shelf references
    /// it directly, the way a drop would.
    var onMovieFile: ((URL) -> Void)?

    /// Whether clipboard captures are worth reading at all. Asked before the
    /// TIFF → PNG encode, not after: with screenshot saving switched off, a
    /// copied picture would otherwise be encoded in full and then thrown away.
    /// Recordings answer to the same switch — a capture is megabytes, and off
    /// means off for all of them. Copied files are exempt: they are already on
    /// disk, so the shelf references them without writing anything.
    var wantsImages: () -> Bool = { true }

    /// Whether a copied picture becomes a history entry (Include Images, spec
    /// §9.4). Independent of `wantsImages`, which is Save Clipboard
    /// Screenshots and keeps working exactly as before: either switch makes the
    /// store read the picture, once, and each takes what it asked for. A seam
    /// whose default is off, so a store built by a test never reads a picture
    /// into memory unasked; the session's `NotchStores` wires the real switch,
    /// which is on unless the person turned it off.
    var keepsImages: () -> Bool = { false }

    /// The app in front when a picture was copied, for "Image 1200 × 1200 ·
    /// Photos". The poll runs within half a second of the copy, so the front
    /// app is nearly always the one that made it; Isla itself never counts
    /// (copying a picture back out of the history is not "from Isla"). A seam,
    /// because a test's front app is whatever the runner is.
    var sourceApp: () -> String? = {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app?.localizedName
    }

    /// Where Keep Pinned Items saves the pins, and whether it is on. Both
    /// unset by default: a store built by a test never touches Application
    /// Support, and the session wires the real file and the real switch.
    var pinnedFile: PinnedClipboardFile?
    var keepsPinned: () -> Bool = { false }
    /// Whether a saved file pin still exists, asked at load for paths that could
    /// be local (`PinnedClipboardFile.load`). Nil asks `FileManager`; a test
    /// injects its own so no path outside a temporary folder is ever touched.
    var pinnedFileExists: ((String) -> Bool)?
    /// What the file held when it was last written or read, so a copy that
    /// changes no pin writes nothing.
    private var persistedPins: [PinnedClipboardFile.Record]?

    /// The pictures' limits, injectable so a test crosses the 25 MB line with a
    /// few kilobytes.
    var imageByteLimit = ClipImage.byteLimit
    var imageMaximumPixels = ClipImage.maximumPixels

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    /// Set by a lock's stop, spent by the next start. See
    /// `stop(rebaseliningOnResume:)`.
    private var rebaselineOnStart = false
    /// Entries kept besides the pinned ones (spec §9.4: "pins do not count
    /// against it").
    private let limit = 40
    /// Types an app sets to keep a copy out of history tools. Presence is what
    /// counts, not content: a type can be declared with data that is still on
    /// its way, and asking for the bytes would then answer nil for a password
    /// that is about to arrive. `ConcealedType` is what password managers set;
    /// the other two mark copies made by a machine rather than by a hand.
    ///
    /// The second group are the proprietary markers nspasteboard.org lists
    /// from before its universal types existed, and asks history tools to keep
    /// honouring: TextExpander and Butler, TypeIt4Me, Typinator, and
    /// 1Password. A tool that still sets only one of these had its passwords
    /// and snippet expansions recorded. KeeWeb's marker is not on that list
    /// and is honoured anyway: a password manager's copy is the one most
    /// worth skipping, and one more name in a type check costs nothing.
    private let optOut: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
        .init("de.petermaurer.TransientPasteboardType"),
        .init("com.typeit4me.clipping"),
        .init("Pasteboard generator type"),
        .init("com.agilebits.onepassword"),
        .init("net.antelle.keeweb"),
    ]

    /// Whether copies are recorded in the history. Screenshots and recordings
    /// still reach the Shelf when this is off, under their own switch.
    var recordsHistory: () -> Bool = { true }

    /// Asks the system what it currently lets Isla read. A seam rather than a
    /// direct read, because tests have to play Ask and Don't Allow on a Mac
    /// where the test runner is always allowed.
    var accessBehavior: () -> ClipboardAccess

    /// The last answer `accessBehavior` gave. `denied` means the poll has
    /// stopped itself, and stays stopped until `recheckAccess()` finds the
    /// answer changed.
    @Published private(set) var access: ClipboardAccess = .unknown

    /// Every content read this store has made: bytes, strings or file
    /// objects, never the change counter or the type list. Under Ask each
    /// one can raise the system's alert, so this is the number a user would
    /// have had to answer, and tests hold it to a ceiling. Counted here
    /// rather than at the pasteboard because AppKit asks a lazy data provider
    /// once and keeps its nil, so a provider cannot see a retry.
    private(set) var contentReadCount = 0

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
        self.accessBehavior = { [pasteboard] in Self.systemAccess(of: pasteboard) }
    }

    nonisolated static func systemAccess(of pasteboard: NSPasteboard) -> ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .unknown }
        switch pasteboard.accessBehavior {
        case .ask: return .ask
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        case .default: return .unknown
        @unknown default: return .unknown
        }
    }

    func start() {
        stop()
        // A lock asked for a fresh start (see `stop(rebaseliningOnResume:)`).
        // Spent here, once, whichever path resumes first — unlock or the
        // display waking — and before the access check, so a poll that Don't
        // Allow keeps down cannot carry the request to a later start.
        if rebaselineOnStart {
            rebaselineOnStart = false
            lastChangeCount = pasteboard.changeCount
        }
        // Don't Allow leaves the poll nothing it may read. A display waking
        // calls this too, and a poll restarted under it would only stop itself
        // again at the next copy; it stays down until the answer changes.
        let now = accessBehavior()
        publish(now)
        guard now != .denied else { return }
        // Otherwise any copy made while the poll was stopped still counts: the
        // counter is compared against where it stood before, not re-baselined
        // here, so a pause for display sleep does not swallow the copy that
        // happened just before it.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
        // The half-second is a ceiling, not a beat: nobody notices a copy
        // landing in history a fifth of a second late, and the slack lets the
        // system fold this wake-up into others.
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// - Parameter rebaseliningOnResume: true for a lock. Whatever reaches the
    ///   pasteboard while the Mac is locked — a Universal Clipboard arrival
    ///   from the phone, a `pbcopy` over ssh — was not copied by the person at
    ///   the keyboard, and the next `start()` begins from the pasteboard as it
    ///   is then. Plain `start()` kept the old baseline for display sleep's
    ///   sake, so the first poll after unlock used to record exactly what the
    ///   lock had stopped the poll to keep out. A plain stop leaves the
    ///   request standing rather than clearing it: a display that sleeps after
    ///   the lock stops the poll again, and the wake after unlock must still
    ///   start fresh. The cost is a copy made in the half-second before the
    ///   lock, inside one poll interval, which is not recorded; reading the
    ///   pasteboard at lock time to catch it would be a content read for a
    ///   window that short.
    func stop(rebaseliningOnResume: Bool = false) {
        timer?.invalidate()
        timer = nil
        if rebaseliningOnResume { rebaselineOnStart = true }
    }

    var isPolling: Bool { timer != nil }

    /// Starts polling from the pasteboard as it is now, without the copy made
    /// before. For a switch turned on: a password copied while history was
    /// off, or a picture copied while screenshot saving was off, must not be
    /// what the first poll records. `start()` keeps the baseline on purpose,
    /// for a display waking, where the copy just before sleep does count.
    func startFresh() {
        lastChangeCount = pasteboard.changeCount
        start()
    }

    /// Asks the system again, and restarts a poll that Don't Allow stopped
    /// once the answer has changed. The poll cannot notice by itself: it is
    /// stopped. Fresh, because a copy made while reading was refused is not
    /// one the user expects to find recorded later. Called when the Clipboard
    /// tab appears, the moment a user back from System Settings looks.
    func recheckAccess() {
        let wasDenied = access == .denied
        let now = accessBehavior()
        publish(now)
        guard wasDenied, now != .denied, recordsHistory() || wantsImages() else { return }
        startFresh()
    }

    private func publish(_ now: ClipboardAccess) {
        if access != now { access = now }
    }

    /// Stops the poll and says why. Everything up to now is spent: there is
    /// nothing a later poll could read of it.
    private func enterDenied() {
        lastChangeCount = pasteboard.changeCount
        stop()
        publish(.denied)
    }

    /// Clear History: everything but the pins (spec §9.4). A pinned entry is
    /// removed only by Unpin then Remove, or by Remove on the pinned row.
    func clear() {
        items.removeAll { !$0.isPinned }
    }

    /// Everything, pins included — for history being switched off, where the
    /// promise is that nothing is kept.
    func clearAll() {
        items.removeAll()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
    }

    /// Drops the pictures and keeps the rest: Include Images turned off means
    /// pictures are not kept (spec §9.4).
    func removeImages() {
        items.removeAll { $0.kind == .image }
    }

    func setPinned(_ item: ClipItem, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), items[index].isPinned != pinned else { return }
        items[index].isPinned = pinned
    }

    func togglePin(_ item: ClipItem) {
        setPinned(item, !item.isPinned)
    }

    /// The list as the pane draws it: pinned entries first, each group newest
    /// first (spec §9.2).
    var listed: [ClipItem] { Self.listed(items) }

    static func listed(_ items: [ClipItem]) -> [ClipItem] {
        items.filter(\.isPinned) + items.filter { !$0.isPinned }
    }

    /// Puts an entry back on the pasteboard without re-recording it.
    func copy(_ item: ClipItem) {
        pasteboard.clearContents()
        switch item.payload {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .file(let url):
            pasteboard.writeObjects([url as NSURL])
        case .files(let urls):
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        case .image(let image):
            pasteboard.setData(image.data, forType: image.type)
        }
        lastChangeCount = pasteboard.changeCount
        bubble(item)
    }

    /// Copy as Plain Text (spec §9.2, renamed from Paste as Plain Text in review 2026-10-15): the entry's string alone, with the
    /// whitespace a selection drags along trimmed off. Isla has no Accessibility
    /// permission and so cannot press ⌘V in the front app; what it can do is
    /// leave exactly the plain string on the pasteboard, which is what a
    /// pasted-as-plain-text result is made of. Returns false for an entry that
    /// holds no string.
    @discardableResult
    func copyPlainText(_ item: ClipItem) -> Bool {
        guard let string = item.text else { return false }
        pasteboard.clearContents()
        pasteboard.setString(string.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        lastChangeCount = pasteboard.changeCount
        bubble(item)
        return true
    }

    /// Freshly used entries bubble to the top.
    private func bubble(_ item: ClipItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }), index != 0 {
            let moved = items.remove(at: index)
            items.insert(moved, at: 0)
        }
    }

    /// The still-picture flavours a copy may carry, in the order one is read:
    /// the declared formats first, TIFF last. The pasteboard lists a converted
    /// TIFF beside a declared PNG, JPEG or HEIC — uncompressed, tens of
    /// megabytes — so a TIFF is read only when it is all there is. A copy that
    /// lists a PNG beside a JPEG keeps the PNG.
    /// A JPEG alone is what Preview's "Copy" of a photo, a browser's image
    /// copy of a JPEG and several camera apps put on the pasteboard, and the
    /// plan used to see only PNG and TIFF — those copies were silently
    /// `.nothing` (review 2026-10-15). HEIC is the same story from a phone.
    /// `ClipImage` hands the bytes to ImageIO, which decodes all four.
    static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    static let heicType = NSPasteboard.PasteboardType("public.heic")
    static let imageFlavours: [NSPasteboard.PasteboardType] = [.png, jpegType, heicType, .tiff]

    /// The flavour to read for a copy that lists `types`, or nil for no picture.
    static func imageFlavour(in types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        imageFlavours.first(where: types.contains)
    }

    /// What one copy is read for, decided from its type list alone.
    enum ReadPlan: Equatable { case files, movieData, image, text, nothing }

    /// Pure, so the precedence can be read in one place.
    ///
    /// - A copied file arrives as a URL, not as image data, so files win
    ///   first. They are read only for a switch that wants them: history
    ///   records them, and the image switch hands a copied recording to the
    ///   Shelf.
    /// - Movie bytes before stills: a recording is the rarer signal, and when
    ///   one is present it is the capture rather than anything else the copy
    ///   carried alongside it.
    /// - Text beside an image goes to history. A Numbers range or a rich-text
    ///   selection carries a picture of itself, and it used to become a
    ///   screenshot card while the text the user copied never reached
    ///   history. With history off the picture is all a switch wants.
    /// - History off: text is not even read.
    ///
    /// - Parameter keepImages: Include Images (spec §9.4). A picture is read
    ///   when either it or Save Clipboard Screenshots wants one, and a single
    ///   read serves both: under Ask each content read is an alert, so a second
    ///   switch must never mean a second read of the same copy. Recordings
    ///   answer to Save Clipboard Screenshots alone — Include Images keeps
    ///   pictures, not films.
    static func readPlan(
        types: [NSPasteboard.PasteboardType], history: Bool, images: Bool, keepImages: Bool = false
    ) -> ReadPlan {
        let hasText = types.contains(.string)
        if types.contains(.fileURL), history || images { return .files }
        if images, types.contains(where: isMovieType) { return .movieData }
        if images || (history && keepImages) {
            if imageFlavour(in: types) != nil, !(history && hasText) { return .image }
        }
        if history, hasText { return .text }
        return .nothing
    }

    func pollNow() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }

        // Don't Allow: nothing here may be read, and polling on would only
        // ask again at every copy.
        let before = accessBehavior()
        publish(before)
        guard before != .denied else {
            enterDenied()
            return
        }

        // The type list is metadata, not content, so it is read freely. The
        // markers used to be checked by asking for their bytes, which is a
        // content read: under Ask, every Shelf copy would have raised an
        // alert for Isla's own data. Our own write is skipped so copying a
        // screenshot back out of the Shelf does not save it all over again.
        let types = pasteboard.types ?? []
        guard !types.contains(where: { optOut.contains($0) || $0 == .islaInternal }) else {
            lastChangeCount = changeCount
            return
        }

        let plan = Self.readPlan(
            types: types, history: recordsHistory(), images: wantsImages(), keepImages: keepsImages()
        )
        if plan == .image {
            // The image path owns this generation from here: a Continuity
            // picture is still on its way, and its wait checks the counter
            // itself. Leaving the count unspent would start a second wait at
            // the next tick.
            lastChangeCount = changeCount
            encodeImage(at: changeCount)
            return
        }

        // The count is spent only once a read has answered. It used to be
        // spent before any read, so a read macOS refused while its alert was
        // up lost that copy for good, even after the user chose Allow.
        if read(plan) {
            lastChangeCount = changeCount
            return
        }
        // The types promised content and the read came back empty. Ask again:
        // the answer may have changed while the read was waiting on the alert.
        let after = accessBehavior()
        publish(after)
        switch after {
        case .denied:
            enterDenied()
        case .allowed:
            // Allow answered mid-read. Once, now, and no more: a second empty
            // answer is not a refusal.
            _ = read(plan)
            lastChangeCount = changeCount
        case .ask, .unknown:
            // Spent, so the next tick cannot raise a second alert for a copy
            // the user already refused.
            lastChangeCount = changeCount
        }
    }

    /// Reads what the plan names and hands it on. False only when the types
    /// promised content and the read answered nil, the shape a refusal takes;
    /// whitespace or a plan of nothing is an answer.
    private func read(_ plan: ReadPlan) -> Bool {
        switch plan {
        case .files:
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            contentReadCount += 1
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
                  !urls.isEmpty else { return false }
            // All of them, not just the first: a Finder copy of a selection is
            // one copy, and pasting the history entry has to reproduce it.
            let payload: ClipItem.Payload = urls.count == 1 ? .file(urls[0]) : .files(urls)
            if recordsHistory() { record(ClipItem(payload: payload, date: Date())) }
            // A copied recording belongs on the shelf, not only in history —
            // the same arrival screenshots get through the vault. Files need no
            // capture switch: nothing is written, only referenced.
            for url in urls where Self.isMovieFile(url) { onMovieFile?(url) }
            return true
        case .movieData:
            guard let (data, ext) = movieData() else { return false }
            onMovieData?(data, ext)
            return true
        case .text:
            contentReadCount += 1
            guard let string = pasteboard.string(forType: .string) else { return false }
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            record(ClipItem(payload: .text(Self.capped(string)), date: Date()))
            return true
        case .image, .nothing:
            return true
        }
    }

    /// Movie bytes and the container they were copied as, when the pasteboard
    /// carries a recording. Matched by conformance rather than by a fixed type
    /// list: copies arrive as `public.mpeg-4`, `com.apple.m4v-video` or plain
    /// `public.movie` depending on where they were copied from, and a list
    /// would recognise exactly the sources it was written against. `.movie`
    /// rather than the wider `.audiovisualContent`, which also claims pure
    /// audio — a copied song is not a captured recording.
    ///
    /// Single-shot, unlike the image path: pictures arrive over Continuity in
    /// two parts — the type first, the bytes over the air — while a recording
    /// is either on the pasteboard whole or not at all.
    private func movieData() -> (data: Data, ext: String)? {
        guard let types = pasteboard.types else { return nil }
        for type in types where Self.isMovieType(type) {
            guard let data = readData(type) else { continue }
            return (data, UTType(type.rawValue)?.preferredFilenameExtension ?? "mov")
        }
        return nil
    }

    private static func isMovieType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .movie) ?? false
    }

    /// Whether this file is a recording the shelf can hold. Asked by container
    /// conformance, so a future container the shelf has never seen still
    /// answers honestly instead of matching an extension list.
    private static func isMovieFile(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    /// Longest text kept per entry.
    ///
    /// The history was bounded by count alone, so forty copies of a log file
    /// pinned forty whole log files in memory for the rest of the session.
    /// Anything past this cannot be read in a one-line row or pasted back
    /// usefully from a scratch panel.
    nonisolated static let maximumTextBytes = 256 * 1024

    nonisolated static func capped(_ string: String) -> String {
        guard string.utf8.count > maximumTextBytes else { return string }
        return String(decoding: Array(string.utf8.prefix(maximumTextBytes)), as: UTF8.self)
    }

    /// Reads the picture and, if it needs transcoding, does that off the main
    /// thread.
    ///
    /// A TIFF from the pasteboard is uncompressed — tens of megabytes for a
    /// Retina screen — and decoding it and re-encoding to PNG used to happen on
    /// the main actor, freezing the panel, the pointer sampler and every
    /// animation for as long as it took.
    ///
    /// A copy made on the phone arrives in two parts: macOS puts the type on
    /// the pasteboard the moment the phone announces it, and the picture itself
    /// is still coming over the air, so there may be nothing to read yet. That
    /// case waits — but only while the system lets Isla read. Under Ask an
    /// empty answer is a refusal, and the wait used to read again every half
    /// second: up to thirteen alerts for one copy the user had already
    /// refused.
    private func encodeImage(at changeCount: Int, attempt: Int = 0) {
        // One flavour per attempt. The pasteboard lists a TIFF for a declared
        // PNG and the other way round, converted from the same bytes, so
        // asking for the second after the first came back empty was a second
        // read of nothing — and a second alert under Ask.
        let types = pasteboard.types ?? []
        let flavour = Self.imageFlavour(in: types)
        if let flavour, let data = readData(flavour) {
            process(original: data, type: flavour, at: changeCount)
            return
        }

        // Nothing readable. Whether that is a picture still in flight or a
        // refusal is the system's answer, so ask it.
        let now = accessBehavior()
        publish(now)
        switch now {
        case .denied:
            enterDenied()
            return
        case .ask:
            // A refusal. Reading again, or falling back to the text, would
            // only raise the alert again.
            return
        case .allowed, .unknown:
            break
        }

        // Give up after a few seconds, or once the copy no longer offers a
        // picture at all, and fall back to whatever else it carried.
        guard attempt < 12, flavour != nil else {
            recordTextFallback(at: changeCount)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.pasteboard.changeCount == changeCount else { return }
                // Image saving can be switched off while a picture is still in
                // flight. The copy is still worth recording — dropping it
                // outright lost the text it came with too, and the change
                // counter was already marked seen so nothing would re-poll it.
                guard self.wantsImages() || (self.recordsHistory() && self.keepsImages()) else {
                    self.recordTextFallback(at: changeCount)
                    return
                }
                self.encodeImage(at: changeCount, attempt: attempt + 1)
            }
        }
    }

    /// Turns the one read of the picture into what the switches asked for, off
    /// the main thread.
    ///
    /// Save Clipboard Screenshots wants a PNG for the vault — which, for a TIFF,
    /// is the tens-of-megabytes decode and re-encode that once froze the panel,
    /// and is still skipped when only history wants the picture. Include Images
    /// wants the entry: the original bytes up to 25 MB (else a 2048 px PNG) and
    /// a thumbnail (`ClipImage.make`). Both come from the same bytes, read once.
    private func process(original: Data, type: NSPasteboard.PasteboardType, at changeCount: Int) {
        let needsPNG = wantsImages()
        let needsEntry = recordsHistory() && keepsImages()
        let source = needsEntry ? sourceApp() : nil
        let byteLimit = imageByteLimit
        let maximumPixels = imageMaximumPixels
        DispatchQueue.global(qos: .userInitiated).async {
            var png: Data?
            if needsPNG {
                png = type == .png
                    ? original
                    : NSBitmapImageRep(data: original)?.representation(using: .png, properties: [:])
            }
            let image = needsEntry
                ? ClipImage.make(
                    data: original, type: type, sourceApp: source,
                    byteLimit: byteLimit, maximumPixels: maximumPixels
                )
                : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.deliverImage(png: png, entry: image, at: changeCount)
                }
            }
        }
    }

    private func deliverImage(png: Data?, entry: ClipImage?, at changeCount: Int) {
        // The pasteboard may have moved on while the encode was running, and a
        // newer copy is the newer intention.
        guard pasteboard.changeCount == changeCount else { return }
        // Both switches are asked again here, not trusted from when the read
        // began: either can be turned off while a picture is in flight, and an
        // off switch gets nothing.
        var delivered = false
        if wantsImages(), let png {
            onImage?(png)
            delivered = true
        }
        if recordsHistory(), keepsImages(), let entry {
            record(ClipItem(payload: .image(entry), date: Date()))
            delivered = true
        }
        // Nothing took the picture — undecodable data, or the switches went off
        // mid-flight. The copy may still have carried text, and dropping it
        // outright lost that too: the change counter is already marked seen, so
        // nothing would re-poll it.
        if !delivered { recordTextFallback(at: changeCount) }
    }

    /// Every byte read goes through here, so `contentReadCount` cannot miss
    /// one.
    private func readData(_ type: NSPasteboard.PasteboardType) -> Data? {
        contentReadCount += 1
        return pasteboard.data(forType: type)
    }

    private func recordTextFallback(at changeCount: Int) {
        // History off means text is not read, on this path as on the main
        // one: the fallback used to read and record it regardless of the
        // switch. Asked of the type list first, so a copy with no text costs
        // no read.
        guard pasteboard.changeCount == changeCount, recordsHistory(),
              pasteboard.types?.contains(.string) == true else { return }
        contentReadCount += 1
        guard let string = pasteboard.string(forType: .string),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Capped like every other text capture: this path used to be the one
        // way an unbounded string still reached the history.
        record(ClipItem(payload: .text(Self.capped(string)), date: Date()))
    }

    /// Internal rather than private as a seam for the headless visual lab,
    /// which fills the history without reading any pasteboard. The app
    /// itself only ever reaches it through `pollNow`.
    ///
    /// The 40-entry cap counts the entries that are not pinned, and the picture
    /// cap counts pictures: a thirteenth drops the oldest (spec §9.4), a pinned
    /// one last, since a pin is a promise and a picture the person has not
    /// pinned is the cheaper thing to lose.
    func record(_ item: ClipItem) {
        var item = item
        // The same thing copied again is one entry, moved to the top. If the
        // one it replaces was pinned, the pin stays: copying a pinned note a
        // second time is not a request to unpin it.
        if let same = items.first(where: { $0 == item }), same.isPinned { item.isPinned = true }
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
        trim()
    }

    private func trim() {
        var kept = items
        let unpinned = kept.filter { !$0.isPinned }
        if unpinned.count > limit {
            let drop = Set(unpinned.suffix(unpinned.count - limit).map(\.id))
            kept.removeAll { drop.contains($0.id) }
        }
        let pictures = kept.filter { $0.kind == .image }
        if pictures.count > ClipImage.maximumEntries {
            let excess = pictures.count - ClipImage.maximumEntries
            // Oldest first among the unpinned, then the oldest pinned ones.
            let ordered = pictures.reversed().filter { !$0.isPinned } + pictures.reversed().filter(\.isPinned)
            let drop = Set(ordered.prefix(excess).map(\.id))
            kept.removeAll { drop.contains($0.id) }
        }
        if kept.count != items.count { items = kept }
    }

    // MARK: Keep Pinned Items (spec §9.4)

    /// At launch: with the switch on, the saved pins join the history as pinned
    /// entries; with it off, a leftover file is removed — the switch is the
    /// whole of the consent, and a file on disk the setting no longer asks for
    /// is not something to leave lying about.
    func loadPinned() {
        guard let pinnedFile else { return }
        guard keepsPinned() else {
            pinnedFile.delete()
            persistedPins = nil
            return
        }
        let records = pinnedFile.load(exists: pinnedFileExists)
        persistedPins = records
        // Under whatever the history already holds, oldest last, in the order
        // the file kept them.
        let restored = records.map { ClipItem(payload: $0.payload, date: $0.date, isPinned: true) }
        let known = items
        items = restored.filter { entry in !known.contains { $0 == entry } } + known
    }

    /// The Settings switch moved: on writes the pins held now, off deletes the
    /// file (spec §9.4: "Turning it off deletes the file").
    func keepPinnedChanged() {
        guard let pinnedFile else { return }
        if keepsPinned() {
            persistedPins = nil
            persistPinsIfWanted()
        } else {
            pinnedFile.delete()
            persistedPins = nil
        }
    }

    private func persistPinsIfWanted() {
        guard let pinnedFile, keepsPinned() else { return }
        let records = PinnedClipboardFile.records(from: items)
        guard records != persistedPins else { return }
        do {
            try pinnedFile.save(records)
            persistedPins = records
        } catch {
            // The pins are still pinned in memory; the next change tries again.
            Log.storage.error("cannot save pinned clipboard items: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
        }
    }
}
