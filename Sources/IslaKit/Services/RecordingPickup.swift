import Foundation
import UniformTypeIdentifiers

/// Screen captures the system saved to disk, picked up with no copy step.
///
/// Screenshot.app writes captures to a folder — its configured location, or
/// the Desktop by default — and nothing about a file it saved reaches the
/// pasteboard, so the clipboard path never sees one. The shelf scans that
/// folder when it opens and offers what was captured since the feature first
/// ran. Nothing is copied: the shelf holds the file where macOS put it, so
/// dragging a card out drags the original and deleting it there removes the
/// card.
///
/// Both kinds, because a person who captures the screen does not think of the
/// two as different features. A movie is taken on its type alone — Screenshot
/// is effectively the only thing writing movies into a capture folder. A still
/// has to carry the system's capture mark or match a capture *prefix* as well,
/// because a capture folder is very often the Desktop, and a folder full of
/// somebody's working files must not be swept onto the shelf wholesale.
///
/// The permission story is one prompt, once: the first scan touches a folder
/// macOS guards, the system asks, and the grant sticks. After that every open
/// is silent. Denied means the scan throws and the shelf shows what it
/// already holds — never a crash, never a second prompt manufactured here.
/// Nothing watches in the background: the scan runs on shelf open, which is
/// the same in-context moment the shelf's own validation already uses.
enum RecordingPickup {
    /// When the pickup first ran. Everything already on disk then predates the
    /// feature and is never offered; only what finished after counts as new.
    /// Stamped at app start rather than at the first shelf open, so a
    /// recording made between install and that first open is still picked up.
    static let sinceKey = "recordings.since"
    /// Filenames already offered — so a removed card stays removed instead of
    /// returning on every open.
    static let seenKey = "recordings.seen"
    /// How many remembered filenames are kept. The set exists so a removed
    /// card stays removed: without it every open would re-import what was
    /// just thrown away, and without the cap a heavy recorder grows defaults
    /// forever with names of files long trashed.
    static let seenLimit = 1000

    /// The `since` a scan may use: the stored one, unless it is ahead of the
    /// clock, and then the clock.
    ///
    /// The stamp is written once, at the first launch, with whatever the
    /// clock said. A Mac whose clock ran ahead then — a new VM, or a first
    /// boot before NTP answered — stored a moment that had not happened yet,
    /// and every capture until real time caught up was judged older than the
    /// feature. None reached the Shelf, and nothing ever moved the stamp back,
    /// so fixing the clock did not help (G-037). A stamp in the future can
    /// only be a clock that was wrong; the present is the nearest honest
    /// answer. Captures from the skewed stretch that were already passed over
    /// are not recovered: nothing about them was remembered, by design.
    static func effectiveSince(stored: Date, now: Date = Date()) -> Date {
        min(stored, now)
    }

    /// Captures in `folders` that finished after `since` and were never
    /// offered, oldest first — the shelf inserts each at the front, so
    /// ascending lands them in the order they were recorded. Every capture
    /// offered is folded into the returned set; one from before `since` is
    /// not, because the date already settles it on every open.
    ///
    /// `missing` names the folders the disk says are not there at all — not
    /// the ones it refused to show — so the caller can stop listing a capture
    /// folder that was deleted (J-021).
    static func fresh(
        in folders: [URL], since: Date, seen: Set<String>, prefixes: [String] = capturePrefixes()
    ) -> (urls: [URL], dates: [URL: Date], seen: Set<String>, missing: [URL]) {
        var seen = seen
        var fresh: [(url: URL, date: Date)] = []
        var missing: [URL] = []
        // Every folder captures have been sent to, not only the current one: a
        // person who changes the save location mid-session would otherwise lose
        // everything already sitting in the old one.
        for folder in folders {
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Only "no such file". A refused folder throws a permission
                // error instead, and that one must stay listed: it is still
                // where captures go, and the person may yet allow it.
                missing.append(folder)
                continue
            } catch {
                continue
            }
            collect(contents, since: since, prefixes: prefixes, seen: &seen, into: &fresh)
        }
        trimSeen(&seen, folders: folders)
        fresh.sort { $0.date < $1.date }
        // The dates travel with the files: a capture is found when the shelf
        // opens, and it belongs where it was taken, not where it was found.
        let dates = Dictionary(fresh.map { ($0.url, $0.date) }, uniquingKeysWith: { first, _ in first })
        return (fresh.map(\.url), dates, seen, missing)
    }

    /// One folder's worth, folded into the running answer.
    private static func collect(
        _ urls: [URL], since: Date, prefixes: [String],
        seen: inout Set<String>, into fresh: inout [(url: URL, date: Date)]
    ) {
        for url in urls {
            guard isCapture(url, prefixes: prefixes) else { continue }
            guard !seen.contains(url.lastPathComponent) else { continue }
            // The date is asked before the name is remembered. Every capture
            // met used to be remembered, so a Desktop with 1,500 screenshots
            // from before the install filled the 1,000-name memory on the
            // first open, and the trim then pushed out names of cards a person
            // had removed, which came back (K-012). `since` never moves, so an
            // old file is settled by its date alone; the date was prefetched
            // with the listing, so asking again on every open costs nothing.
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard date > since else { continue }
            seen.insert(url.lastPathComponent)
            fresh.append((url, date))
        }
    }

    /// Whether this file is something the screen-capture tool wrote.
    ///
    /// A movie in a capture folder is taken on its type: Screenshot is
    /// effectively the only thing that puts one there, and a recording renamed
    /// by hand should still arrive. A still must also be marked as a capture
    /// by the system or carry a capture prefix, because the capture folder is
    /// so often the Desktop — without that rule, opening the shelf once would
    /// sweep up every picture somebody keeps there.
    ///
    /// The mark is asked after the name, and only of images, so the common
    /// case costs no system call. The prefix rule stays beside it: a tool that
    /// copies files without their extended attributes would otherwise strip
    /// the only thing that made a capture recognisable.
    static func isCapture(_ url: URL, prefixes: [String] = capturePrefixes()) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        if type.conforms(to: .movie) { return true }
        guard type.conforms(to: .image) else { return false }
        let name = url.lastPathComponent
        if prefixes.contains(where: { !$0.isEmpty && name.hasPrefix($0) }) { return true }
        return CaptureMetadata.hasScreenCaptureAttribute(url)
    }

    /// What a capture is called here.
    ///
    /// `com.apple.screencapture name` holds a custom prefix when one is set,
    /// and the system's own is localized — so every language's word from
    /// Screenshot's own table is accepted, with the English defaults kept as
    /// well, for a Mac whose language changed after the captures were taken.
    static func capturePrefixes(
        customName: String? = customCaptureName(), systemWords: [String] = systemCaptureWords
    ) -> [String] {
        // "LWScreenShot" is what the login window names a screenshot taken on
        // the lock screen, whatever the capture name or language — and it is
        // why those never reached the shelf (filmed 2026-09-21: two lock-screen
        // captures sitting in the save folder, offered nowhere).
        var prefixes = ["Screenshot", "Screen Recording", "LWScreenShot"]
        if let customName, !customName.isEmpty { prefixes.insert(customName, at: 0) }
        for word in systemWords where !prefixes.contains(word) { prefixes.append(word) }
        return prefixes
    }

    /// Where Screenshot keeps the words it names captures with, in every
    /// language it ships.
    ///
    /// The localized word used to be asked of ScreenCaptureKit's bundle, whose
    /// table has no "Screenshot" key at all: the lookup handed the key back,
    /// which was already in the list, so on a Russian, German or Ukrainian
    /// Mac no still ever reached the Shelf (G-001). The words live in
    /// screencaptureui's table instead, which is what names the files.
    static let systemCaptureTable = URL(
        fileURLWithPath: "/System/Library/CoreServices/screencaptureui.app/Contents/Resources/Localizable.loctable"
    )

    /// Read once per launch: the table is a system file that changes only
    /// with macOS, and a capture scan runs on every Shelf open.
    static let systemCaptureWords = captureWords(inTable: systemCaptureTable)

    /// The "Screenshot" and "Screen Recording" words of every language in a
    /// `.loctable` — one plist keyed by language, each a table of strings.
    /// A table that is missing or unreadable yields nothing: the English
    /// words and the capture mark still work, so a macOS that moves the file
    /// degrades to what shipped before rather than to nothing.
    static func captureWords(inTable url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return [] }
        var words: [String] = []
        for language in table.keys.sorted() {
            // `LocProvenance` and anything else that is not a language's
            // strings is skipped by shape rather than by name.
            guard let strings = table[language] as? [String: Any] else { continue }
            for key in ["Screenshot", "Screen Recording"] {
                guard let word = strings[key] as? String, !word.isEmpty else { continue }
                // Dutch hyphenates its word for display with a soft hyphen,
                // which a filename need not carry, so both spellings count.
                for spelling in [word, word.replacingOccurrences(of: "\u{00AD}", with: "")]
                    where !words.contains(spelling) {
                    words.append(spelling)
                }
            }
        }
        return words
    }

    static func customCaptureName(preferencesFile: URL? = nil) -> String? {
        stringSetting("name", preferencesFile: preferencesFile)
    }

    /// Drops remembered names whose files are gone, so the set does not grow
    /// forever with what was trashed long ago.
    static func trimSeen(_ seen: inout Set<String>, folders: [URL], limit: Int = seenLimit) {
        // Forgetting starts with the trashed: a name with no file left will
        // never be met again. Same-name re-creation is the accepted edge:
        // Screenshot.app numbers same-second captures instead of reusing names.
        guard seen.count > limit else { return }
        var dated: [(name: String, date: Date)] = []
        for name in seen {
            let file = folders.lazy
                .map { $0.appendingPathComponent(name) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let file else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            dated.append((name, date))
        }
        // Still over: the oldest go, by the file's own date. This used to keep
        // `kept.prefix(limit)` of a Set, whose order changes with every
        // launch's hash seed, so which removed card came back was a dice roll
        // on each open (K-012). The name breaks a tie so the answer is the
        // same on every launch.
        dated.sort { ($0.date, $0.name) > ($1.date, $1.name) }
        seen = Set(dated.prefix(limit).map(\.name))
    }

    /// Where Screenshot.app saves captures: its configured location, or the
    /// Desktop, which is where the system saves by default.
    ///
    /// The preferences file is a parameter so the fallback can be tested
    /// without depending on the Mac running the tests: the test that pinned
    /// "Desktop" read the real `com.apple.screencapture.plist` and failed the
    /// moment this machine's Screenshot app was pointed somewhere else.
    static func captureFolder(preferencesFile: URL? = nil) -> URL {
        let location = preferencesFile.map(screencaptureLocation(preferencesFile:))
            ?? screencaptureLocation()
        if let location, !location.isEmpty {
            return URL(
                fileURLWithPath: (location as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The `location` Screenshot.app was configured with, if any. Reading
    /// another app's preferences file touches only the user's own Library —
    /// no prompt, no permission — and a missing or malformed file simply
    /// means the default.
    static func screencaptureLocation() -> String? {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first else { return nil }
        return screencaptureLocation(preferencesFile: library
            .appendingPathComponent("Preferences/com.apple.screencapture.plist"))
    }

    static func screencaptureLocation(preferencesFile: URL) -> String? {
        stringSetting("location", preferencesFile: preferencesFile)
    }

    /// One string out of Screenshot.app's own preferences.
    ///
    /// Reading another app's preferences file touches only the user's own
    /// Library — no prompt, no permission — and a missing or malformed file
    /// simply means the default.
    static func stringSetting(_ key: String, preferencesFile: URL? = nil) -> String? {
        let file = preferencesFile ?? FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("Preferences/com.apple.screencapture.plist")
        guard let file, let dict = NSDictionary(contentsOf: file) as? [String: Any] else {
            return nil
        }
        return dict[key] as? String
    }

    // MARK: - Where captures live

    /// Folders where captures have been sent, newest setting first.
    ///
    /// Every folder the save location has ever pointed at while Isla was
    /// running. Changing the location in Screenshot.app's own options used to
    /// orphan whatever was still sitting in the old one — the shelf simply
    /// stopped looking there, and those captures could never arrive.
    static let knownFoldersKey = "captures.folders"

    static func captureFolders(
        defaults: UserDefaults = .standard, preferencesFile: URL? = nil
    ) -> [URL] {
        // The Desktop arrives only through `captureFolder()`, as the system's
        // default when nothing is configured. It used to be appended to every
        // list, so a person whose captures go to ~/Pictures was asked for the
        // Desktop on the first Shelf open, for a folder Isla had no reason to
        // read, and it was rescanned on every open after (J-021).
        let current = captureFolder(preferencesFile: preferencesFile)
        var paths = [current.path]
        paths.append(contentsOf: defaults.stringArray(forKey: knownFoldersKey) ?? [])
        // Remembered before the duplicates are dropped, so the newest setting
        // stays at the head of the list it is written back as.
        var seenPaths: Set<String> = []
        let folders = paths.filter { seenPaths.insert($0).inserted }
        defaults.set(folders, forKey: knownFoldersKey)
        return folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Takes the folders a scan found missing out of the remembered list.
    ///
    /// The list only ever grew, so a capture folder that was deleted, or a
    /// disk that was retired, was probed on every Shelf open for good (J-021).
    /// Two kinds stay. The current folder: Screenshot.app may simply not have
    /// made it yet, and it is read from the preferences anyway. A folder
    /// under /Volumes: that is a disk that is not plugged in, not a folder
    /// that is gone, and captures on it should arrive when it is back.
    static func forget(
        _ missing: [URL], defaults: UserDefaults = .standard, current: URL? = nil
    ) {
        // Most opens find nothing missing, and then the preferences file is
        // not read a second time.
        guard !missing.isEmpty else { return }
        let current = current ?? captureFolder()
        let dropped = Set(missing.map(\.path))
            .subtracting([current.path])
            .filter { !$0.hasPrefix("/Volumes/") }
        guard !dropped.isEmpty, let known = defaults.stringArray(forKey: knownFoldersKey) else { return }
        let kept = known.filter { !dropped.contains($0) }
        if kept.count != known.count { defaults.set(kept, forKey: knownFoldersKey) }
    }
}

/// What the system records about a file it captured from the screen.
///
/// Screenshot.app marks every still and recording it writes with
/// `kMDItemIsScreenCapture`, kept as an extended attribute on the file itself.
/// That mark is the same whatever the system language or the custom capture
/// name, which is what a filename prefix is not: on a Russian Mac stills are
/// named "Снимок экрана …", and a prefix list that missed the word kept every
/// one of them off the Shelf (G-001). Read straight from the file rather than
/// through Spotlight: a Spotlight query answers asynchronously and finds
/// nothing at all on a volume that is not indexed.
enum CaptureMetadata {
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Whether the file carries the system's screen-capture mark. A missing
    /// attribute, an unreadable file or a value that is not a true boolean
    /// all mean no — never a throw, never a prompt beyond the one the folder
    /// listing that found the file already raised.
    static func hasScreenCaptureAttribute(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let size = getxattr(path, screenCaptureAttribute, nil, 0, 0, 0)
            // The value is a tiny binary plist; anything large is not ours.
            guard size > 0, size <= 4096 else { return false }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { buffer in
                getxattr(path, screenCaptureAttribute, buffer.baseAddress, size, 0, 0)
            }
            guard read == size else { return false }
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
            return (value as? NSNumber)?.boolValue ?? false
        }
    }
}
