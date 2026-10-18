import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// A picture kept in the clipboard history (spec §9.1, §9.4): what goes back on
/// the pasteboard when the entry is copied, and a small thumbnail for the row
/// and the Images grid.
///
/// The bytes live in a file of the session, not in memory. The history used to
/// hold the pasteboard's original bytes for twelve pictures — up to 25 MB each,
/// 10 to 21 MB for an ordinary screenshot, a ceiling near 300 MB of `Data` —
/// and on the owner's Mac the footprint swung from 148 to 258 MB and peaked at
/// 521 MB within seconds of copying one 10 MB screenshot, with 41 MB of it
/// compressed by the system so that the next interaction paid to decompress it.
/// What stays resident now is the thumbnail, and the bytes of small pictures up
/// to a total budget (`ClipboardStore.imageResidentBudget`); the rest are read
/// back from the file, mapped, when the entry is pasted.
///
/// The files exist for the session only (`ClipImageSpool`): the Shelf's
/// screenshot vault is a separate, opt-in path with its own switch, and a
/// pinned image is not saved by Keep Pinned Items either.
struct ClipImage: Equatable {
    /// What is put back on the pasteboard, and where it is kept.
    let bytes: ClipImageBytes
    /// SHA-256 of the pasteboard's own bytes, computed once when the picture
    /// was read. It is what two pictures are compared by: `==` used to compare
    /// up to 25 MB of bytes with `memcmp` every time SwiftUI diffed the list.
    let digest: SHA256.Digest
    /// The type `data` is, as a pasteboard type (`public.png`, `public.tiff`,
    /// `public.jpeg`, …).
    let type: NSPasteboard.PasteboardType
    /// The original's size in pixels: what the row says ("1200 × 1200"),
    /// whether or not the kept bytes were scaled down from it.
    let pixelSize: CGSize
    /// 176 × 132 pixels — the 88 × 66 pt tile at 2×, cut to fill so a row's 20
    /// pt mark and the grid's tile are one image drawn at two sizes.
    let thumbnail: CGImage
    /// The app that was in front when the copy was made, for "1200 × 1200 ·
    /// Photos". A hint, never an authority: nil when it could not be told.
    let sourceApp: String?

    /// What is put back on the pasteboard: the pasteboard's own bytes when they
    /// fit in `byteLimit`, so a picture pasted back is the picture that was
    /// copied, colour profile and all — else a PNG no wider than
    /// `maximumPixels`. Empty when the file is gone; paste-back asks
    /// `pasteboardData` instead.
    var data: Data { bytes.data }

    /// The bytes to paste, or nil when they cannot be had any more (the file
    /// was removed under a session): the caller must not clear the pasteboard
    /// for nothing.
    var pasteboardData: Data? {
        let data = bytes.data
        return data.isEmpty ? nil : data
    }

    /// Compared by the picture, not by who copied it or by the thumbnail
    /// derived from it: copying the same picture twice is one entry, as copying
    /// the same words twice is. The digest, never the bytes.
    static func == (lhs: ClipImage, rhs: ClipImage) -> Bool {
        lhs.digest == rhs.digest && lhs.type == rhs.type
    }

    /// The digest `==` and the duplicate checks use. A hash of 20 MB takes a
    /// few milliseconds with the hardware SHA instructions, once, on the
    /// background queue.
    static func digest(of data: Data) -> SHA256.Digest {
        SHA256.hash(data: data)
    }

    // MARK: The numbers (spec §9.4)

    /// Most pictures a history holds; a thirteenth drops the oldest.
    static let maximumEntries = 12
    /// The original pasteboard bytes are kept up to this many.
    static let byteLimit = 25 * 1024 * 1024
    /// Past `byteLimit` the picture is kept as a PNG at most this wide or tall.
    static let maximumPixels = 2048
    /// A picture whose kept bytes are no larger than this also stays in memory
    /// (when it is in a file too), so pasting a small icon or a cropped
    /// screenshot back does not touch the disk.
    static let residentPictureLimit = 4 * 1024 * 1024
    /// All the resident picture bytes of a history together. 32 MB is what the
    /// history may hold in memory for its pictures however many it has:
    /// eight pictures at the per-picture limit, and far below the 300 MB the
    /// count and byte limits alone allowed. Past it the oldest pictures give
    /// up their resident bytes and are read from their files.
    static let residentBudget = 32 * 1024 * 1024
    /// Pixels, not points.
    static let thumbnailSize = CGSize(width: 176, height: 132)

    /// "1200 × 1200", as the boards write it.
    var dimensionsText: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    /// Builds the entry's picture from pasteboard bytes, or nil when the bytes
    /// are not a picture ImageIO can read.
    ///
    /// Heavy for a large picture — a downscale, a PNG encode, a file write —
    /// and made for a background queue: nothing here touches the main actor.
    /// The work runs in its own autorelease pool: a 20 MB decode leaves
    /// bitmap and `NSData` objects in the pool of a dispatch worker, which
    /// drains only when the worker goes idle, and they used to sit in the
    /// footprint until it did.
    ///
    /// - Parameters:
    ///   - byteLimit: injectable so a test can cross the 25 MB line with a few
    ///     kilobytes.
    ///   - spool: where the kept bytes are written. Nil keeps them in memory
    ///     only, which is what a test without a spool, and a disk that refuses
    ///     the write, get.
    ///   - digest: of `data`, when the caller has hashed it already.
    static func make(
        data: Data, type: NSPasteboard.PasteboardType, sourceApp: String?,
        byteLimit: Int = ClipImage.byteLimit, maximumPixels: Int = ClipImage.maximumPixels,
        spool: ClipImageSpool? = nil, residentLimit: Int = ClipImage.residentPictureLimit,
        digest: SHA256.Digest? = nil
    ) -> ClipImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { return nil }

            var kept = data
            var keptType = type
            if data.count > byteLimit {
                // Too big to hold twelve of: a PNG of the same picture, scaled so
                // its long side is `maximumPixels` (never enlarged).
                guard let scaled = scaledPNG(from: source, maximumPixels: maximumPixels) else { return nil }
                kept = scaled
                keptType = .png
            }
            guard let thumbnail = thumbnail(from: source) else { return nil }
            // File first, then the decision what stays in memory: a picture that
            // is on disk needs no resident copy beyond the small ones.
            let url = spool?.write(kept)
            let resident: Data? = url == nil || kept.count <= residentLimit ? kept : nil
            return ClipImage(
                bytes: ClipImageBytes(byteCount: kept.count, resident: resident, fileURL: url),
                digest: digest ?? ClipImage.digest(of: data), type: keptType,
                pixelSize: CGSize(width: width, height: height), thumbnail: thumbnail, sourceApp: sourceApp
            )
        }
    }

    /// The pixel size of the kept bytes, read back — what a test asserts the
    /// 2048 px rule against.
    var keptPixelSize: CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func scaledPNG(from source: CGImageSource, maximumPixels: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The picture cut to fill 176 × 132, centred — the way `scaledToFill`
    /// would draw it, done once so the list does not decode a megapixel image
    /// to draw twenty pixels of it.
    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        let box = thumbnailSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Enough to fill either dimension of the box before the crop.
            kCGImageSourceThumbnailMaxPixelSize: Int(max(box.width, box.height) * 2),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(
                data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let scale = max(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (box.width - drawn.width) / 2, y: (box.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        ))
        return context.makeImage()
    }
}


/// The kept bytes of one picture: in a file of the session, in memory, or both.
///
/// A class, so the copies of a `ClipImage` that SwiftUI passes around share one
/// file and one answer to "is this still resident". The file is deleted by
/// `discard()` when the entry leaves the history, and again by `deinit` as a
/// backstop for an entry that was built and never recorded.
final class ClipImageBytes: @unchecked Sendable {
    let byteCount: Int
    let fileURL: URL?
    private let lock = NSLock()
    private var resident: Data?

    init(byteCount: Int, resident: Data?, fileURL: URL?) {
        self.byteCount = byteCount
        self.resident = resident
        self.fileURL = fileURL
    }

    deinit { discard() }

    /// The resident bytes, else the file mapped read-only. A mapped file's
    /// pages are clean and backed by the file, so the system drops them under
    /// pressure instead of compressing or swapping them — the fault that
    /// holding 20 MB of heap `Data` per screenshot caused. Empty when neither
    /// exists.
    var data: Data {
        if let held = lock.withLock({ resident }) { return held }
        guard let fileURL, let mapped = try? Data(contentsOf: fileURL, options: .alwaysMapped) else { return Data() }
        return mapped
    }

    /// Bytes this picture holds in memory right now.
    var residentByteCount: Int { lock.withLock { resident?.count ?? 0 } }

    /// Lets go of the resident copy when the file has the picture. False for a
    /// memory-only picture, whose only copy is the resident one.
    @discardableResult
    func dropResident() -> Bool {
        guard fileURL != nil else { return false }
        lock.withLock { resident = nil }
        return true
    }

    /// Deletes the file. The resident bytes, if any, stay until the last
    /// reference goes, so an entry still on screen can be pasted once more.
    func discard() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The files behind the picture entries of one launch.
///
/// History is memory-only today, so these files must not outlive the session:
/// they live in a directory of their own under Isla's caches folder, named
/// with the owning process so that a launch can tell a crashed predecessor's
/// directory (swept) from a second running Isla's (left alone — a development
/// build beside the installed app is a normal state on this Mac). The
/// directory is 0700 and every file 0600, deleted when its entry goes, and the
/// whole directory when the app quits.
final class ClipImageSpool: @unchecked Sendable {
    static let directoryPrefix = "isla-clipboard-"

    /// The one the app uses; made lazily, so a session that never copies a
    /// picture creates no directory.
    static let session = ClipImageSpool()

    /// `~/Library/Caches/com.ctimothe.isla`, not the temporary directory:
    /// macOS clears files there that nobody has opened for a few days, and an
    /// Isla session runs for weeks, so an old entry's picture could vanish
    /// under it (R8c review, M3). Caches can still be purged when the disk is
    /// short, which `ClipboardStore.copy` answers by dropping the entry.
    static let defaultRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("com.ctimothe.isla", isDirectory: true)
    }()

    let root: URL
    let directory: URL

    /// - Parameter root: injectable so a test never writes the real caches
    ///   folder.
    init(root: URL = ClipImageSpool.defaultRoot, processID: Int32 = getpid(), id: UUID = UUID()) {
        self.root = root
        directory = root.appendingPathComponent(
            "\(Self.directoryPrefix)\(processID)-\(id.uuidString)", isDirectory: true
        )
    }

    /// Writes the bytes to a new file, or nil when the disk refuses.
    func write(_ data: Data) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch { return nil }
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return nil
        }
        return url
    }

    /// At quit: the directory and everything in it.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// At launch: removes the `isla-clipboard-*` directories whose process is
    /// gone — a crash or a force quit leaves them, since nothing runs at the end
    /// of those — and keeps this launch's own and any running instance's.
    /// A name that does not carry a process id is stale by definition.
    @discardableResult
    static func sweepStale(
        in root: URL = ClipImageSpool.defaultRoot, keeping: URL? = nil,
        isAlive: (Int32) -> Bool = ClipImageSpool.processIsAlive
    ) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(directoryPrefix) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if url.standardizedFileURL == keeping?.standardizedFileURL { continue }
            let rest = name.dropFirst(directoryPrefix.count)
            if let pid = rest.split(separator: "-", maxSplits: 1).first.flatMap({ Int32($0) }), isAlive(pid) { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
