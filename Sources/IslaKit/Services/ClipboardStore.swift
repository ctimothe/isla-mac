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
    }

    let id = UUID()
    let payload: Payload
    let date: Date
    /// Computed once at capture. `preview` used to trim the whole string on
    /// every render, for every row — twice, since the pane trimmed newlines out
    /// of the result — and a row is only ever a line high.
    let preview: String

    init(payload: Payload, date: Date) {
        self.payload = payload
        self.date = date
        self.preview = Self.preview(for: payload)
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
        }
    }

    /// A row shows one line; anything past this could never be read.
    static let previewLimit = 512

    var symbol: String {
        switch payload {
        case .text(let string):
            if string.hasPrefix("http://") || string.hasPrefix("https://") { return "link" }
            return "text.alignleft"
        case .file:
            return "doc"
        case .files:
            return "doc.on.doc"
        }
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
    @Published private(set) var items: [ClipItem] = []

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

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    /// Set by a lock's stop, spent by the next start. See
    /// `stop(rebaseliningOnResume:)`.
    private var rebaselineOnStart = false
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

    func clear() {
        items.removeAll()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
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
        }
        lastChangeCount = pasteboard.changeCount
        // Freshly used entries bubble to the top.
        if let index = items.firstIndex(where: { $0.id == item.id }), index != 0 {
            items.remove(at: index)
            items.insert(item, at: 0)
        }
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
    static func readPlan(
        types: [NSPasteboard.PasteboardType], history: Bool, images: Bool
    ) -> ReadPlan {
        let hasText = types.contains(.string)
        if types.contains(.fileURL), history || images { return .files }
        if images {
            if types.contains(where: isMovieType) { return .movieData }
            if types.contains(.png) || types.contains(.tiff), !(history && hasText) { return .image }
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

        let plan = Self.readPlan(types: types, history: recordsHistory(), images: wantsImages())
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
    static let maximumTextBytes = 256 * 1024

    private static func capped(_ string: String) -> String {
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
        let hasPNG = types.contains(.png)
        if hasPNG {
            if let png = readData(.png) {
                deliverImage(png, at: changeCount)
                return
            }
        } else if types.contains(.tiff), let tiff = readData(.tiff) {
            DispatchQueue.global(qos: .userInitiated).async {
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let png else {
                            // Undecodable image data. The copy may still have
                            // carried text, and dropping it outright lost that
                            // too — the change counter is already marked seen,
                            // so nothing would re-poll it.
                            self.recordTextFallback(at: changeCount)
                            return
                        }
                        self.deliverImage(png, at: changeCount)
                    }
                }
            }
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
        guard attempt < 12, hasPNG || types.contains(.tiff) else {
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
                guard self.wantsImages() else {
                    self.recordTextFallback(at: changeCount)
                    return
                }
                self.encodeImage(at: changeCount, attempt: attempt + 1)
            }
        }
    }

    private func deliverImage(_ png: Data, at changeCount: Int) {
        // The pasteboard may have moved on while the encode was running, and a
        // newer copy is the newer intention.
        guard pasteboard.changeCount == changeCount else { return }
        guard wantsImages() else {
            recordTextFallback(at: changeCount)
            return
        }
        onImage?(png)
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
    func record(_ item: ClipItem) {
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }
}
