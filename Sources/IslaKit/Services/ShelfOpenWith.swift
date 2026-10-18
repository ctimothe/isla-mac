import AppKit

/// The applications a file can be opened with, for the Shelf's Open With
/// submenu (spec §8.2) — Finder's list: the file's default application first,
/// then the rest by name.
///
/// Asked when the menu is built, never when a tile is drawn: Launch Services'
/// answer for one file is a few milliseconds and the Shelf draws sixty tiles on
/// every change.
enum ShelfOpenWith {
    struct App: Identifiable, Equatable {
        let url: URL
        let name: String
        var id: URL { url }
    }

    /// The most the submenu lists. A file a dozen editors claim is no
    /// shorter to choose from for a thirteenth, and a menu taller than the
    /// screen's notch-side half is not usable from a panel hanging at the top.
    static let limit = 12

    /// `default` first, then `all` in name order, each application once.
    /// Pure, so the order is a test and not a look at a menu.
    static func ordered(default defaultApp: URL?, all: [URL], name: (URL) -> String, limit: Int = limit) -> [App] {
        var seen = Set<URL>()
        var apps: [App] = []
        func add(_ url: URL) {
            let key = url.standardizedFileURL
            guard seen.insert(key).inserted else { return }
            apps.append(App(url: url, name: name(url)))
        }
        if let defaultApp { add(defaultApp) }
        let rest = all.sorted {
            name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
        }
        rest.forEach(add)
        return Array(apps.prefix(limit))
    }

    static func apps(for file: URL, workspace: NSWorkspace = .shared) -> [App] {
        ordered(
            default: workspace.urlForApplication(toOpen: file),
            all: workspace.urlsForApplications(toOpen: file),
            name: { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        )
    }

    /// The icon at menu size. A copy: the workspace hands out a shared image,
    /// and resizing that one would resize it for Finder's callers in this
    /// process too.
    static func icon(for app: App) -> NSImage {
        let icon = (NSWorkspace.shared.icon(forFile: app.url.path).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @MainActor
    static func open(_ file: URL, with app: App) {
        NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
