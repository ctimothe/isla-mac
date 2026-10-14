import AppKit
import Combine
import ImageIO

/// Whether the wallpaper behind the island is dark (spec §3.3), which decides
/// whether the island draws its key line.
///
/// A black island disappears on a black wallpaper — the owner's Aerial measures
/// a mean of 8/255 behind the notch — and Apple's answer for the iPhone's island
/// is a thin stroke tinted to the content. It only helps where the island would
/// otherwise vanish; on a bright wallpaper the black edge is already the
/// strongest line on the screen, and a stroke round it is noise. So the stroke
/// is gated on this, and **on every wallpaper while Increase Contrast is on**
/// (`KeyLine.isShown`).
///
/// How, and why each step is the cheap one:
///
/// - `NSWorkspace.desktopImageURL(for:)` names the file, and the screen is
///   never captured, which would need Screen Recording and say something about
///   the person's other windows. **Naming the file is not permission to open
///   it.** A wallpaper that lives in Downloads, Desktop or Documents, in iCloud
///   Drive, on a removable or network volume, or inside another app's container
///   (the Photos and shuffle wallpapers) is behind a macOS privacy gate, and
///   opening one makes the system ask "Isla would like to access files in your
///   Downloads folder" with nothing on screen to say why — a surprise prompt
///   at launch, which the app's error contract forbids (review 2026-10-15). So
///   the URL is judged by its *string* first (`isReadableWithoutPrompt`): only
///   the system's own pictures (`/System/Library`, `/Library`) and the home
///   folder outside those protected places are ever opened, and anything else —
///   `/Volumes`, an unfamiliar root, a protected folder — answers nothing
///   **without a single file system call on it**: no open, no `stat`, no
///   modification date. The cost: a wallpaper that is gated, a folder, a
///   dynamic one the system composes, or a file Isla cannot read answers
///   nothing, and nothing is **not dark**: the key line is then absent, which
///   is a missing flourish, where a wrong answer would be a stroke on a light
///   desktop, and where a prompt would be a permission nobody asked for.
/// - `CGImageSourceCreateThumbnailAtIndex` decodes a thumbnail of at most 256
///   px, not the 6K original.
/// - The mean is taken over only the strip behind the island: the notch's
///   centre ± 310 pt across the top 60 pt of the screen, mapped through
///   aspect-fill, which is how a desktop picture is laid on the display. A
///   wallpaper dark at the bottom and bright at the top is a bright wallpaper
///   for this purpose.
/// - The answer is cached by URL and modification date, because the island
///   asks every time it unfolds.
///
/// "Luminance" here is the Rec. 709 weighting of the sRGB-*encoded* values —
/// luma — not of linear light. The spec's four measurements (Aerial 0.03, Pro
/// Black 0.09, Sonoma 0.36, Sky Blue 0.41) and its 0.20 line are in those
/// units: Aerial's "8/255" is 0.031 encoded and 0.002 linear. Computing it in
/// linear light would put Sonoma at about 0.1, under the line, and draw a key
/// line on a wallpaper the spec says is not dark.
enum WallpaperTone {
    /// What was found out. `unknown` is every failure, and behaves as `light`:
    /// no key line.
    enum Reading: Equatable {
        case dark, light, unknown
    }

    /// A wallpaper is dark below this mean luminance: Aerial and Pro Black
    /// under it, Sonoma and Sky Blue over.
    static let darkThreshold = 0.20
    /// The thumbnail's longest side, in pixels.
    static let thumbnailMaxPixel = 256
    /// The strip behind the island, in points: the notch's centre ± this
    /// across, the top `bandHeight` down. Wider than the widest island (the
    /// peek, 520) so the whole of it is judged.
    static let halfWidth: CGFloat = 310
    static let bandHeight: CGFloat = 60

    /// The decision, from a mean. Nil is the failure case.
    static func reading(forMeanLuminance luminance: Double?) -> Reading {
        guard let luminance else { return .unknown }
        return luminance < darkThreshold ? .dark : .light
    }

    // MARK: - May the file be opened at all

    /// Places under the home folder that macOS guards with a privacy prompt (or
    /// that hold another app's files), relative to home, lower-cased. Desktop,
    /// Documents and Downloads are the three TCC names; iCloud Drive is
    /// `Library/Mobile Documents` and the File Provider mounts (Dropbox, Drive,
    /// OneDrive, iCloud's newer home) are `Library/CloudStorage`; the two
    /// containers folders are other apps' data, Photos and wallpaper shuffles
    /// among them; the Photos library is a package whose originals are not
    /// Isla's to read; Movies and Music are guarded media folders.
    static let protectedHomeFolders: [String] = [
        "desktop", "documents", "downloads", "movies", "music",
        "library/mobile documents", "library/cloudstorage",
        "library/containers", "library/group containers",
        "pictures/photos library.photoslibrary",
    ]

    /// Roots whose pictures the system owns and any process may open without
    /// being asked: the shipped wallpapers and the downloaded Aerial assets.
    static let systemRoots: [String] = ["/system/library", "/library"]

    /// Whether the wallpaper at `url` may be opened without macOS asking the
    /// person for permission, decided on the URL's text alone — it never
    /// touches the file system (see the type's comment). Anything that is not a
    /// plain file URL, or that cannot be placed under a known-safe root, is no.
    ///
    /// Compared lexically and case-insensitively (the default volume is
    /// case-insensitive, and `Downloads` is `downloads` to it), after `.` and
    /// `..` are folded away, so `~/Pictures/../Downloads/x.png` is judged as
    /// the Downloads file it is. Symlinks are deliberately not resolved: that
    /// would be a file system call on the very path being judged.
    static func isReadableWithoutPrompt(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        guard url.isFileURL, let path = normalized(url.path), !path.isEmpty else { return false }
        func isInside(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if systemRoots.contains(where: isInside) { return true }
        guard let homePath = normalized(home), homePath.count > 1, isInside(homePath) else { return false }
        let relative = path.dropFirst(homePath.count).drop(while: { $0 == "/" })
        guard !relative.isEmpty else { return false }
        return !protectedHomeFolders.contains { folder in
            relative == folder || relative.hasPrefix(folder + "/")
        }
    }

    /// An absolute path with `.` and `..` folded away and the case lowered, or
    /// nil for one that is not absolute or climbs out of the root.
    private static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.lowercased().split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: - Where to look

    /// The strip behind the island, in screen points with the origin at the
    /// screen's top-left. `notchCenterX` is relative to the screen's left edge.
    static func islandRegion(screenSize: CGSize, notchCenterX: CGFloat) -> CGRect {
        let strip = CGRect(x: notchCenterX - halfWidth, y: 0, width: 2 * halfWidth, height: bandHeight)
        return strip.intersection(CGRect(origin: .zero, size: screenSize))
    }

    /// A screen region in the picture's own pixels, for a picture laid on the
    /// screen aspect-fill: scaled until it covers the screen, centred, and the
    /// overflow cropped.
    static func imageRegion(for screenRegion: CGRect, screenSize: CGSize, imageSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0, imageSize.width > 0, imageSize.height > 0
        else { return .null }
        let scale = max(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
        let offsetX = (screenSize.width - imageSize.width * scale) / 2
        let offsetY = (screenSize.height - imageSize.height * scale) / 2
        let mapped = CGRect(
            x: (screenRegion.minX - offsetX) / scale,
            y: (screenRegion.minY - offsetY) / scale,
            width: screenRegion.width / scale,
            height: screenRegion.height / scale
        )
        return mapped.intersection(CGRect(origin: .zero, size: imageSize))
    }

    // MARK: - Measuring

    /// The mean luma of the part of `image` inside `region` (pixels, origin
    /// top-left), 0...1. Nil for an empty region.
    static func meanLuminance(of image: CGImage, in region: CGRect) -> Double? {
        let rect = region.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                bytesPerRow: cropped.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let count = cropped.width * cropped.height
        let pixels = data.bindMemory(to: UInt8.self, capacity: count * 4)
        var total = 0.0
        for index in 0..<count {
            total += 0.2126 * Double(pixels[index * 4])
                + 0.7152 * Double(pixels[index * 4 + 1])
                + 0.0722 * Double(pixels[index * 4 + 2])
        }
        return total / Double(count) / 255
    }

    /// A thumbnail of at most `thumbnailMaxPixel` px, or nil for anything that
    /// is not an image Isla can read — a folder, a missing file, a corrupt one.
    static func thumbnail(at url: URL) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    private struct CacheKey: Hashable {
        let url: URL
        let modified: Date?
        let x, y, width, height: Int
    }

    private static let cache = LuminanceCache()

    /// Thread-safe, because the model reads it from a background task and a
    /// test reads it from the main thread. A handful of entries: one wallpaper
    /// per display, a region each.
    private final class LuminanceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CacheKey: Double?] = [:]

        func value(for key: CacheKey) -> Double?? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ value: Double?, for key: CacheKey) {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= 16 { entries.removeAll() }
            entries[key] = value
        }
    }

    /// The mean luma behind the island on the wallpaper at `url`, cached by
    /// URL and modification date; nil when anything about it fails.
    ///
    /// A *failure* is cached too — a folder is a folder until its date moves —
    /// so a wallpaper the island cannot read costs one attempt, not one per
    /// unfold.
    ///
    /// `mayRead` is asked first and alone: a no is nil with no file system call
    /// of any kind on `url` — not the modification date for the cache key, not
    /// the open — so a wallpaper behind a privacy gate costs the person
    /// nothing, not even a prompt. `thumbnail` is how the picture is read;
    /// both are parameters so a test can prove a gated file is never reached
    /// and can describe a fixture in a temporary folder, which the real gate
    /// would rightly refuse.
    static func meanLuminance(
        ofWallpaperAt url: URL, screenSize: CGSize, notchCenterX: CGFloat,
        mayRead: (URL) -> Bool = { isReadableWithoutPrompt($0) },
        thumbnail read: (URL) -> CGImage? = { thumbnail(at: $0) }
    ) -> Double? {
        guard mayRead(url) else { return nil }
        let screenRegion = islandRegion(screenSize: screenSize, notchCenterX: notchCenterX)
        // Asked of the file system, not of `url.resourceValues`: a `URL` caches
        // the values it has been asked for, so a long-lived URL answered with
        // the date it first saw and a replaced wallpaper kept its old tone.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = CacheKey(
            url: url, modified: modified,
            x: Int(screenRegion.minX.rounded()), y: Int(screenRegion.minY.rounded()),
            width: Int(screenRegion.width.rounded()), height: Int(screenRegion.height.rounded())
        )
        if let known = cache.value(for: key) { return known }
        var luminance: Double?
        if let thumbnail = read(url) {
            let region = imageRegion(
                for: screenRegion, screenSize: screenSize,
                imageSize: CGSize(width: thumbnail.width, height: thumbnail.height)
            )
            luminance = meanLuminance(of: thumbnail, in: region)
        }
        cache.store(luminance, for: key)
        return luminance
    }

    static func reading(
        ofWallpaperAt url: URL?, screenSize: CGSize, notchCenterX: CGFloat,
        mayRead: (URL) -> Bool = { isReadableWithoutPrompt($0) },
        thumbnail read: (URL) -> CGImage? = { thumbnail(at: $0) }
    ) -> Reading {
        guard let url else { return .unknown }
        return reading(forMeanLuminance: meanLuminance(
            ofWallpaperAt: url, screenSize: screenSize, notchCenterX: notchCenterX,
            mayRead: mayRead, thumbnail: read
        ))
    }
}

/// The wallpaper's tone for the island's screen, kept current.
///
/// Recomputed on the four things that can change what is behind the island: a
/// different Space (each can wear its own picture), a change of display
/// parameters (the notch may have moved or another display arrived), the Mac
/// waking (a wallpaper that rotates or follows the appearance has moved on),
/// and the island unfolding — the caller's `refresh()`, free when the cache
/// already knows the file. The work is done off the main actor; a stale answer
/// for a screen that has since changed never lands.
@MainActor
final class WallpaperToneModel: ObservableObject {
    @Published private(set) var reading: WallpaperTone.Reading = .unknown

    /// How the island's screen and notch are found, and how a screen's picture
    /// is named — both replaceable, so a test can describe a Mac that has no
    /// wallpaper, or a dark one, without owning one.
    private let target: @MainActor () -> (screen: NSScreen, notchCenterX: CGFloat)?
    private let wallpaperURL: @MainActor (NSScreen) -> URL?
    /// Whether a picture may be opened at all (`WallpaperTone.isReadableWithoutPrompt`);
    /// replaceable so a test's fixture in a temporary folder can be read.
    private let mayRead: @Sendable (URL) -> Bool
    private var generation = 0
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(
        target: @escaping @MainActor () -> (screen: NSScreen, notchCenterX: CGFloat)?,
        wallpaperURL: @escaping @MainActor (NSScreen) -> URL? = { NSWorkspace.shared.desktopImageURL(for: $0) },
        mayRead: @escaping @Sendable (URL) -> Bool = { WallpaperTone.isReadableWithoutPrompt($0) }
    ) {
        self.target = target
        self.wallpaperURL = wallpaperURL
        self.mayRead = mayRead
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    /// Starts watching the system for changes that move what is behind the
    /// island. Separate from `init` so a model built in a test listens to
    /// nothing.
    func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (center, NSApplication.didChangeScreenParametersNotification),
        ]
        for (source, name) in names {
            let token = source.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append((source, token))
        }
    }

    /// Looks again. A cache hit settles on the next turn of the run loop.
    func refresh() {
        generation += 1
        let mine = generation
        guard let found = target() else {
            reading = .unknown
            return
        }
        let url = wallpaperURL(found.screen)
        let size = found.screen.frame.size
        let centre = found.notchCenterX - found.screen.frame.minX
        let mayRead = mayRead
        Task { [weak self] in
            let answer = await Task.detached(priority: .utility) {
                WallpaperTone.reading(ofWallpaperAt: url, screenSize: size, notchCenterX: centre, mayRead: mayRead)
            }.value
            guard let self, self.generation == mine, self.reading != answer else { return }
            self.reading = answer
        }
    }
}
