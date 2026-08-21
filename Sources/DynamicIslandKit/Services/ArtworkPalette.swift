import AppKit
import CoreImage

/// The colors a cover actually carries, for tinting whatever presents it.
///
/// Flat surfaces read as flat because nothing in them answers the artwork.
/// Every rich now-playing player derives its ambience from the cover — a
/// blurred fill, a tinted progress bar, a glow — and all of those start from
/// the same two numbers: a dominant color worth tinting with, and whether it
/// is vivid enough to trust (a grey cover tints nothing).
struct ArtworkPalette: Equatable {
    let dominant: NSColor

    /// Vivid enough to drive a tint; below this the UI should fall back to
    /// its neutral styling rather than tint everything grey-brown.
    let isVivid: Bool

    /// Downsamples to a small grid and averages the vivid cells, so one
    /// bright motif on a dark cover wins over the darkness around it.
    /// CoreImage does the scaling; the walk is 64 pixels, not a million.
    /// One context for the life of the process.
    ///
    /// `CIContext` is expensive to build — it compiles and caches its pipeline
    /// — and Apple documents it as an object to reuse. Building a fresh one
    /// per artwork meant paying that on every track change.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func extract(from image: NSImage) -> ArtworkPalette? {
        // Straight from the decoded bitmap where there is one. The old path
        // asked for `tiffRepresentation`, which re-encodes the whole cover
        // uncompressed — tens of megabytes of transient allocation for a
        // high-resolution cover — purely to get to an 8×8 downsample.
        let source: CIImage
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            source = CIImage(cgImage: cgImage)
        } else if let tiff = image.tiffRepresentation, let fallback = CIImage(data: tiff) {
            source = fallback
        } else {
            return nil
        }

        let side = 8
        let context = Self.context
        let scale = CGFloat(side) / max(source.extent.width, source.extent.height)
        let scaled = source.transformed(by: .init(scaleX: scale, y: scale))
        // Rendered into a stated format rather than whatever the source
        // happened to carry: the loop below indexes bytes as R, G, B, and an
        // image that arrived as BGRA or 16-bit would have been read as a
        // different colour entirely.
        guard let cg = context.createCGImage(
            scaled,
            from: scaled.extent,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) else { return nil }

        guard let data = cg.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = cg.bytesPerRow
        let bytesPerPixel = max(cg.bitsPerPixel / 8, 1)

        var bestScore: Double = -1
        var best: (r: Double, g: Double, b: Double) = (0.5, 0.5, 0.5)
        var sum: (r: Double, g: Double, b: Double) = (0, 0, 0)
        var count = 0.0

        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < data.count else { continue }
                let r = Double(data[offset]) / 255
                let g = Double(data[offset + 1]) / 255
                let b = Double(data[offset + 2]) / 255
                sum = (r: sum.r + r, g: sum.g + g, b: sum.b + b)
                count += 1
                let mx = max(r, g, b), mn = min(r, g, b)
                let saturation = mx == 0 ? 0 : (mx - mn) / mx
                // Vivid and reasonably bright beats vivid-but-black.
                let score = saturation * (0.35 + 0.65 * mx)
                if score > bestScore {
                    bestScore = score
                    best = (r, g, b)
                }
            }
        }
        guard count > 0 else { return nil }

        let vivid = bestScore > 0.25
        let pick = vivid ? best : (r: sum.r / count, g: sum.g / count, b: sum.b / count)
        return ArtworkPalette(
            dominant: NSColor(red: pick.r, green: pick.g, blue: pick.b, alpha: 1),
            isVivid: vivid
        )
    }
}
