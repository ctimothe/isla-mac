import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A picture kept in the clipboard history (spec §9.1, §9.4): what goes back on
/// the pasteboard when the entry is copied, and a small thumbnail for the row
/// and the Images grid.
///
/// Memory only. Nothing here is ever written to disk — the Shelf's screenshot
/// vault is a separate, opt-in path with its own switch — and a pinned image is
/// not saved by Keep Pinned Items either.
struct ClipImage: Equatable {
    /// What is put back on the pasteboard: the pasteboard's own bytes when they
    /// fit in `byteLimit`, so a picture pasted back is the picture that was
    /// copied, colour profile and all — else a PNG no wider than
    /// `maximumPixels`.
    let data: Data
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

    /// Compared by the picture, not by who copied it or by the thumbnail
    /// derived from it: copying the same picture twice is one entry, as copying
    /// the same words twice is.
    static func == (lhs: ClipImage, rhs: ClipImage) -> Bool {
        lhs.data.count == rhs.data.count && lhs.type == rhs.type && lhs.data == rhs.data
    }

    // MARK: The numbers (spec §9.4)

    /// Most pictures a history holds; a thirteenth drops the oldest.
    static let maximumEntries = 12
    /// The original pasteboard bytes are kept up to this many.
    static let byteLimit = 25 * 1024 * 1024
    /// Past `byteLimit` the picture is kept as a PNG at most this wide or tall.
    static let maximumPixels = 2048
    /// Pixels, not points.
    static let thumbnailSize = CGSize(width: 176, height: 132)

    /// "1200 × 1200", as the boards write it.
    var dimensionsText: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    /// Builds the entry's picture from pasteboard bytes, or nil when the bytes
    /// are not a picture ImageIO can read.
    ///
    /// Heavy for a large picture — a downscale and a PNG encode — and made for
    /// a background queue: nothing here touches the main actor.
    ///
    /// - Parameter byteLimit: injectable so a test can cross the 25 MB line
    ///   with a few kilobytes.
    static func make(
        data: Data, type: NSPasteboard.PasteboardType, sourceApp: String?,
        byteLimit: Int = ClipImage.byteLimit, maximumPixels: Int = ClipImage.maximumPixels
    ) -> ClipImage? {
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
        return ClipImage(
            data: kept, type: keptType, pixelSize: CGSize(width: width, height: height),
            thumbnail: thumbnail, sourceApp: sourceApp
        )
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
