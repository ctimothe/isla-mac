import Foundation
import UniformTypeIdentifiers

/// Screen recordings the system saved to disk, picked up with no copy step.
///
/// Screenshot.app writes captures to a folder — its configured location, or
/// the Desktop by default — and nothing about a finished recording reaches
/// the pasteboard, so the clipboard path never sees it. The shelf scans that
/// folder when it opens and imports what finished since the feature first ran.
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
        in folder: URL, since: Date, seen: Set<String>
    ) -> (urls: [URL], seen: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], seen) }
        var seen = seen
        var fresh: [(url: URL, date: Date)] = []
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .movie) else { continue }
            guard !seen.contains(url.lastPathComponent) else { continue }
            seen.insert(url.lastPathComponent)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard date > since else { continue }
            fresh.append((url, date))
        }
        // Newest names go first out of the cap: the set remembers what to
        // skip, and forgetting starts with the trashed — a name with no file
        // left will never be met again, while anything still on disk is simply
        // re-met on the next open. Same-name re-creation is the accepted edge:
        // Screenshot.app numbers same-second captures instead of reusing names.
        if seen.count > seenLimit {
            let kept = seen.filter { name in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
            }
            seen = kept.count > seenLimit ? Set(kept.prefix(seenLimit)) : kept
        }
        fresh.sort { $0.date < $1.date }
        return (fresh.map(\.url), seen)
    }

    /// Where Screenshot.app saves captures: its configured location, or the
    /// Desktop, which is where the system saves by default.
    static func captureFolder() -> URL {
        if let location = screencaptureLocation(), !location.isEmpty {
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
        guard let dict = NSDictionary(contentsOf: preferencesFile) as? [String: Any] else {
            return nil
        }
        return dict["location"] as? String
    }
}
