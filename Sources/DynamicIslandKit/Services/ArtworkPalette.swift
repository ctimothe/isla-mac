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
    static func extract(from image: NSImage) -> ArtworkPalette? {
        guard let tiff = image.tiffRepresentation,
              let source = CIImage(data: tiff) else { return nil }

        let side = 8
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let scale = CGFloat(side) / max(source.extent.width, source.extent.height)
        let scaled = source.transformed(by: .init(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }

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
