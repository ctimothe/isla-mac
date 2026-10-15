import AppKit
import Foundation
import SwiftUI

/// The real icon and the real name of an app the person has installed.
///
/// Settings used to draw its own Spotify disc — a green circle with three arcs —
/// and it read as a fake beside everything else on a Mac. The owner wants the
/// real marks of Spotify, Apple Music, Deezer, Yandex Music, Telegram and
/// whatever else people play music in. The rule that keeps the repository free
/// of a brand's artwork does not move: **no brand asset ever travels in Isla's
/// bundle or its source.** The icons come from the person's own copy of each
/// app, at runtime, through LaunchServices — an app they have not installed has
/// no icon here, and the caller draws a fallback (or nothing).
///
/// Two questions are asked of the system and both are slow enough to matter:
/// where an app lives (`urlForApplication(withBundleIdentifier:)` is an IPC to
/// LaunchServices) and what its icon is (`icon(forFile:)` composes an image
/// from the bundle). Neither may run inside a SwiftUI `body` on every render,
/// so each answer is kept per bundle identifier — including "not installed",
/// which is the common answer for the dozen players this Mac has never heard
/// of. `refresh()` drops the lot; the panel calls it once as it opens
/// (`NotchViewModel.isOpen`), because apps are installed and removed while
/// Isla runs and a cache that never forgot would show the Yandex Music a person
/// deleted last week. Not from a view's `onAppear`: that runs after the first
/// render has already filled the cache, so clearing there made every opening
/// ask LaunchServices twice, mid-animation.
///
/// The three lookups are injected so a test never depends on what is installed
/// on the machine that runs it.
@MainActor
final class AppIcons: ObservableObject {
    static let shared = AppIcons()

    /// One installed app.
    struct Installed {
        let bundleID: String
        let url: URL
        /// The name the person sees in the Finder, in their language
        /// («Яндекс Музыка»), except for the two apps `preferredNames` names.
        let name: String
        let icon: NSImage
    }

    /// The system's three answers. Defaults ask LaunchServices and the file
    /// system; a test passes its own.
    struct Lookups {
        var applicationURL: (String) -> URL?
        var icon: (URL) -> NSImage
        var displayName: (URL) -> String

        static let system = Lookups(
            applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            icon: { NSWorkspace.shared.icon(forFile: $0.path) },
            displayName: { AppIcons.cleaned(FileManager.default.displayName(atPath: $0.path)) }
        )
    }

    /// Apple Music is «Music» on disk — and «Музыка» on a Russian Mac — while
    /// every other line of Isla (the Automation rows, the Open buttons, the
    /// empty player) says Apple Music. Two names for one app on one screen is
    /// worse than a name the Finder does not use.
    static let preferredNames: [String: String] =
        Dictionary(uniqueKeysWithValues: PlayerApp.allCases.map { ($0.bundleID, $0.displayName) })

    /// A Finder name with its `.app` stripped: `displayName(atPath:)` keeps the
    /// extension for a person who shows all of them, and «Spotify.app» in a row
    /// of players is a file name, not a name.
    nonisolated static func cleaned(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private let lookups: Lookups
    /// `nil` inside is "asked, not installed": asking again would cost the same
    /// IPC for the same answer.
    private var cache: [String: Installed?] = [:]

    /// Counts `refresh()`. Views that draw an icon observe this object, so a
    /// refresh that finds a newly installed app redraws them; it is not read.
    @Published private(set) var generation = 0

    init(lookups: Lookups = .system) {
        self.lookups = lookups
    }

    /// The app, or nil when it is not installed. Asks the system once per
    /// bundle identifier between refreshes.
    func app(_ bundleID: String) -> Installed? {
        if let cached = cache[bundleID] { return cached }
        let resolved: Installed?
        if let url = lookups.applicationURL(bundleID) {
            resolved = Installed(
                bundleID: bundleID,
                url: url,
                name: Self.preferredNames[bundleID] ?? lookups.displayName(url),
                icon: lookups.icon(url)
            )
        } else {
            resolved = nil
        }
        cache[bundleID] = .some(resolved)
        return resolved
    }

    /// The icon alone, for the views that draw one.
    func icon(_ bundleID: String) -> NSImage? { app(bundleID)?.icon }

    /// The installed ones among `bundleIDs`, in the order given.
    func installed<S: Sequence>(_ bundleIDs: S) -> [Installed] where S.Element == String {
        bundleIDs.compactMap(app)
    }

    /// Forgets every answer. Cheap to call: nothing is asked until a view next
    /// needs an icon, and only for the apps it draws.
    func refresh() {
        cache.removeAll()
        generation += 1
    }

    // MARK: - Which players, in what order

    /// Every installed app Isla knows plays music or songs: the dedicated
    /// players and the ones that play songs and films (`MediaSourcePolicy`),
    /// ordered by `order`. Settings › Music › Players on This Mac.
    func installedPlayers() -> [Installed] {
        Self.order(installed(MediaSourcePolicy.listedPlayers))
    }

    /// The installed songs-only players — no podcast app, no Telegram — ordered
    /// by `order`. What the empty Music tab offers to open.
    func installedMusicApps() -> [Installed] {
        Self.order(installed(MediaSourcePolicy.songApps))
    }

    /// Apple Music, then Spotify, then the rest by the name the person sees.
    ///
    /// The two lead because they are the two Isla can drive (shuffle, repeat,
    /// the heart): everything else is a window onto what it reports. The rest
    /// are sorted the way the Finder sorts (`localizedStandardCompare`) so
    /// «Яндекс Музыка» sits among Cyrillic names, not after "Z"; two apps with
    /// the same name — both Telegram builds are «Telegram» on a Mac that has
    /// them both — keep a stable order by bundle identifier.
    static func order(_ apps: [Installed]) -> [Installed] {
        let lead = MediaSourcePolicy.leadingApps
        func rank(_ app: Installed) -> Int { lead.firstIndex(of: app.bundleID) ?? lead.count }
        return apps.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.bundleID < b.bundleID
            }
        }
    }
}

extension AppIcons.Installed: Equatable {
    /// By what is shown and where it lives; the image is the system's to
    /// recompose and says nothing the URL does not.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.url == rhs.url && lhs.name == rhs.name
    }
}

/// An app's real icon, optically matched to Isla's rounded-square tiles.
///
/// A macOS app icon is not its own bounds. The Big Sur grid puts an 824 pt
/// squircle in the middle of a 1024 pt canvas and leaves the rest transparent
/// for the drop shadow, so an app icon drawn into an 18 pt frame shows a 14.6 pt
/// squircle — which is why the real icons looked smaller than the 18 pt
/// SF-symbol tiles beside them in Settings, and why the About row's Isla icon
/// did too. The image is drawn at `side × 1024 / 824` in a `side × side` frame
/// and not clipped, so the squircle fills the frame exactly and the icon's own
/// shadow spills into the margin where it belongs.
struct AppIconImage: View {
    let image: NSImage
    var side: CGFloat

    var body: some View {
        let drawn = side * Theme.appIconOpticalScale
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: drawn, height: drawn)
            // The layout box is the tile's, not the canvas's: the neighbours
            // are placed by `side`, and the overflow is transparent padding.
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// An installed app's icon, looked up through the cache and redrawn when a
/// refresh changes the answer; `fallback` when the app is not installed.
struct InstalledAppIcon<Fallback: View>: View {
    let bundleID: String
    var side: CGFloat
    /// `.shared` in the app; a test passes its own so the sidebar it renders
    /// never asks the runner's LaunchServices.
    @ObservedObject var icons: AppIcons = .shared
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        if let image = icons.icon(bundleID) {
            AppIconImage(image: image, side: side)
        } else {
            fallback().frame(width: side, height: side)
        }
    }
}
