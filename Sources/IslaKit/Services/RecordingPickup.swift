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
/// has to match the capture *prefix* as well, because a capture folder is very
/// often the Desktop, and a folder full of somebody's working files must not
/// be swept onto the shelf wholesale.
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
    /// Filenames already met, offered or not — so a removed card stays
    /// removed instead of returning on every open.
    static let seenKey = "recordings.seen"
    /// How many remembered filenames are kept. The set exists so a removed
    /// card stays removed: without it every open would re-import what was
    /// just thrown away, and without the cap a heavy recorder grows defaults
    /// forever with names of files long trashed.
    static let seenLimit = 1000

    /// Movies in `folder` that finished after `since` and were never offered,
    /// oldest first — the shelf inserts each at the front, so ascending lands
    /// them in the order they were recorded. Everything met is folded into
    /// the returned set, including what is not offered, so an old recording
    /// is settled once rather than reconsidered on every open.
    static func fresh(
        in folders: [URL], since: Date, seen: Set<String>, prefixes: [String] = capturePrefixes()
    ) -> (urls: [URL], dates: [URL: Date], seen: Set<String>) {
        var seen = seen
        var fresh: [(url: URL, date: Date)] = []
        // Every folder captures have been sent to, not only the current one: a
        // person who changes the save location mid-session would otherwise lose
        // everything already sitting in the old one.
        for folder in folders {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            collect(contents, since: since, prefixes: prefixes, seen: &seen, into: &fresh)
        }
        trimSeen(&seen, folders: folders)
        fresh.sort { $0.date < $1.date }
        // The dates travel with the files: a capture is found when the shelf
        // opens, and it belongs where it was taken, not where it was found.
        let dates = Dictionary(fresh.map { ($0.url, $0.date) }, uniquingKeysWith: { first, _ in first })
        return (fresh.map(\.url), dates, seen)
    }

    /// One folder's worth, folded into the running answer.
    private static func collect(
        _ urls: [URL], since: Date, prefixes: [String],
        seen: inout Set<String>, into fresh: inout [(url: URL, date: Date)]
    ) {
        for url in urls {
            guard isCapture(url, prefixes: prefixes) else { continue }
            guard !seen.contains(url.lastPathComponent) else { continue }
            seen.insert(url.lastPathComponent)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard date > since else { continue }
            fresh.append((url, date))
        }
    }

    /// Whether this file is something the screen-capture tool wrote.
    ///
    /// A movie in a capture folder is taken on its type: Screenshot is
    /// effectively the only thing that puts one there, and a recording renamed
    /// by hand should still arrive. A still must also carry the capture prefix,
    /// because the capture folder is so often the Desktop — without that rule,
    /// opening the shelf once would sweep up every picture somebody keeps
    /// there.
    static func isCapture(_ url: URL, prefixes: [String] = capturePrefixes()) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        if type.conforms(to: .movie) { return true }
        guard type.conforms(to: .image) else { return false }
        let name = url.lastPathComponent
        return prefixes.contains { !$0.isEmpty && name.hasPrefix($0) }
    }

    /// What a capture is called here.
    ///
    /// `com.apple.screencapture name` holds a custom prefix when one is set,
    /// and the system's own is localized — so the running system's word is
    /// asked for first, with the English defaults kept as well for a Mac whose
    /// language changed after the captures were taken.
    static func capturePrefixes(customName: String? = customCaptureName()) -> [String] {
        var prefixes = ["Screenshot", "Screen Recording"]
        if let customName, !customName.isEmpty { prefixes.insert(customName, at: 0) }
        let localized = Bundle(identifier: "com.apple.ScreenCaptureKit")?
            .localizedString(forKey: "Screenshot", value: nil, table: nil)
        if let localized, !localized.isEmpty { prefixes.append(localized) }
        return prefixes
    }

    static func customCaptureName(preferencesFile: URL? = nil) -> String? {
        stringSetting("name", preferencesFile: preferencesFile)
    }

    /// Drops remembered names whose files are gone, so the set does not grow
    /// forever with what was trashed long ago.
    private static func trimSeen(_ seen: inout Set<String>, folders: [URL]) {
        // Newest names go first out of the cap: the set remembers what to
        // skip, and forgetting starts with the trashed — a name with no file
        // left will never be met again, while anything still on disk is simply
        // re-met on the next open. Same-name re-creation is the accepted edge:
        // Screenshot.app numbers same-second captures instead of reusing names.
        guard seen.count > seenLimit else { return }
        let kept = seen.filter { name in
            folders.contains { folder in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
            }
        }
        seen = kept.count > seenLimit ? Set(kept.prefix(seenLimit)) : kept
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
    /// running, plus the Desktop, which is where the system saves when nothing
    /// is configured. Changing the location in Screenshot.app's own options
    /// used to orphan whatever was still sitting in the old one — the shelf
    /// simply stopped looking there, and those captures could never arrive.
    static let knownFoldersKey = "captures.folders"

    static func captureFolders(defaults: UserDefaults = .standard) -> [URL] {
        let current = captureFolder()
        var paths = [current.path]
        paths.append(contentsOf: defaults.stringArray(forKey: knownFoldersKey) ?? [])
        paths.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true).path
        )
        // Remembered before the duplicates are dropped, so the newest setting
        // stays at the head of the list it is written back as.
        var seenPaths: Set<String> = []
        let folders = paths.filter { seenPaths.insert($0).inserted }
        defaults.set(folders, forKey: knownFoldersKey)
        return folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
