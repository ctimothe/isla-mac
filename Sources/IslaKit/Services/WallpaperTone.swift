import AppKit
import ImageIO

/// How bright the desktop picture is behind a part of the screen.
///
/// Only the lock card asks — its Automatic material picks an opacity from the
/// wallpaper behind it (`LockCardToneModel`, `cardRegion`; spec §19.2). The
/// island used to ask too, to draw a key line only on a dark wallpaper; its
/// stroke is now drawn on every wallpaper, so nothing else watches the desktop.
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
///   nothing, and nothing is the card's default material, which is a missing
///   refinement, where a prompt would be a permission nobody asked for.
/// - `CGImageSourceCreateThumbnailAtIndex` decodes a thumbnail of at most 256
///   px, not the 6K original.
/// - The mean is taken over only the region asked about, mapped through
///   aspect-fill, which is how a desktop picture is laid on the display. A
///   wallpaper dark at the bottom and bright at the top is a bright wallpaper
///   for a region at the top.
/// - The answer is cached by URL, modification date and region, because the
///   card asks every time it shows.
///
/// "Luminance" here is the Rec. 709 weighting of the sRGB-*encoded* values —
/// luma — not of linear light. The spec's four measurements (Aerial 0.03, Pro
/// Black 0.09, Sonoma 0.36, Sky Blue 0.41) and its 0.20 line are in those
/// units: Aerial's "8/255" is 0.031 encoded and 0.002 linear. Computing it in
/// linear light would put Sonoma at about 0.1 and push the card's opacity
/// ramp the wrong way.
enum WallpaperTone {
    /// The thumbnail's longest side, in pixels.
    static let thumbnailMaxPixel = 256

    // MARK: - May the file be opened at all

    /// Places under the home folder that macOS guards with a privacy prompt (or
    /// that hold another app's files), relative to home, lower-cased. Desktop,
    /// Documents and Downloads are the three TCC names; iCloud Drive is
    /// `Library/Mobile Documents` and the File Provider mounts (Dropbox, Drive,
    /// OneDrive, iCloud's newer home) are `Library/CloudStorage`; the two
    /// containers folders are other apps' data, Photos and wallpaper shuffles
    /// among them; a Photos library (any package ending in `.photoslibrary`, wherever under
    /// home it sits — `isReadableWithoutPrompt` checks every path component, not
    /// one fixed name; review 2026-10-15) is a package whose originals are not
    /// Isla's to read; Movies and Music are guarded media folders.
    static let protectedHomeFolders: [String] = [
        "desktop", "documents", "downloads", "movies", "music",
        "library/mobile documents", "library/cloudstorage",
        "library/containers", "library/group containers",
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
        if relative.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) { return false }
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

    /// The part of the screen behind the lock card, in screen points with the
    /// origin at the screen's top-left (redesign 2026-10-15, spec §7.2). The card
    /// is centred on the display both ways (`LockCardWindow.frame`), and the
    /// largest thing that stands there is the card, so the banner — which hangs
    /// from the card's top edge — is judged against the same region: a banner
    /// that read one wallpaper and a card another would change material in the
    /// middle of a click.
    static func cardRegion(screenSize: CGSize, cardSize: CGSize) -> CGRect {
        let card = CGRect(
            x: ((screenSize.width - cardSize.width) / 2).rounded(),
            y: ((screenSize.height - cardSize.height) / 2).rounded(),
            width: cardSize.width, height: cardSize.height
        )
        return card.intersection(CGRect(origin: .zero, size: screenSize))
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

    /// The mean luma behind a region of the screen on the wallpaper at `url`,
    /// cached by URL, modification date and region; nil when anything about it
    /// fails. A *failure* is cached too — a folder is a folder until its date
    /// moves — so a wallpaper the card cannot read costs one attempt, not one
    /// per showing.
    ///
    /// **The privacy gate is the first thing asked, whatever the region**: a
    /// wallpaper in Downloads, in iCloud Drive or on a removable volume
    /// answers nil without a file system call, however many surfaces have a
    /// reason to want its brightness. `mayRead` is asked first and alone: a no
    /// is nil with no file system call of any kind on `url` — not the
    /// modification date for the cache key, not the open. `thumbnail` is how
    /// the picture is read; both are parameters so a test can prove a gated
    /// file is never reached and can describe a fixture in a temporary folder,
    /// which the real gate would rightly refuse.
    static func meanLuminance(
        ofWallpaperAt url: URL, screenSize: CGSize, region screenRegion: CGRect,
        mayRead: (URL) -> Bool = { isReadableWithoutPrompt($0) },
        thumbnail read: (URL) -> CGImage? = { thumbnail(at: $0) }
    ) -> Double? {
        guard mayRead(url) else { return nil }
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
}
