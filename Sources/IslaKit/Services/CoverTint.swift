import AppKit
import SwiftUI

/// The one colour a cover lends the compact island (spec §3.4): the equalizer
/// draws in it while music plays, and the key line round a music island or
/// panel is it at half strength.
///
/// Chosen as "the most saturated of the cover's bright colours, lifted to at
/// least 0.65 HSB brightness so it reads on black, falling back to white 0.82
/// when the cover is greyscale or missing". Three things that rule is written
/// to avoid, each one a way another app's equalizer goes wrong on a black
/// island:
///
/// - *the average of the cover* — a red-and-blue sleeve averages to a brown
///   that is on neither of them, and a busy one to grey;
/// - *the dominant colour* — most covers are mostly their own background, which
///   on this island means a near-black bar that cannot be seen;
/// - *a dark saturated colour left as it is* — a deep navy at 0.3 brightness
///   on black is invisible, so it keeps its hue and saturation and is lifted.
///
/// There is no existing extraction to reuse: the lock card's "lit by the song's
/// own cover" blurs the picture itself under a wash (`LockCardLegibility`
/// measures only how *bright* it is, as a grey) and never reads a colour. This
/// file reuses what it does share — the downsample-into-a-small-bitmap
/// approach and a cache keyed by the image itself — so there is still one
/// place a cover is read for the island and one tint per track.
struct CoverTint: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    /// White 0.82: what a greyscale or missing cover gives, light enough to
    /// read on black and quiet enough not to be mistaken for a colour.
    static let fallback = CoverTint(red: 0.82, green: 0.82, blue: 0.82)

    /// The edge of the downsample (spec §3.4: 24 × 24). 576 pixels is far
    /// finer than a 24 pt cover on screen and cheap enough that a track change
    /// costs nothing off the main actor.
    static let sampleSide = 24

    /// A pixel is one of the cover's *bright* colours at or above this HSB
    /// brightness. Under it, a colour would be lifted from something the
    /// cover barely shows — a shadow's blue, not its sleeve's.
    static let minimumBrightness = 0.35
    /// Under this saturation a pixel is grey for our purposes: a warm-white
    /// paper or a cool-grey photograph is not a colour to draw the bars in.
    static let minimumSaturation = 0.20
    /// The floor the chosen colour is lifted to (spec §3.4).
    static let liftedBrightness = 0.65

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    // MARK: - Choosing

    /// The tint of a cover as a bitmap. Nil — no cover, or one that cannot be
    /// drawn — is the fallback, never a crash and never a stale colour.
    static func tint(of image: CGImage?) -> CoverTint {
        guard let image, let pixels = downsample(image) else { return .fallback }
        return tint(fromRGBA: pixels)
    }

    /// The pure half: premultiplied RGBA bytes, four per pixel. Public to the
    /// module so the choice is tested on pixels a test wrote, not on whatever a
    /// decoder makes of a fixture.
    static func tint(fromRGBA pixels: [UInt8]) -> CoverTint {
        var best: (hue: Double, saturation: Double, brightness: Double)?
        for index in stride(from: 0, to: pixels.count - 3, by: 4) {
            let hsb = hsb(
                red: Double(pixels[index]) / 255,
                green: Double(pixels[index + 1]) / 255,
                blue: Double(pixels[index + 2]) / 255
            )
            guard hsb.brightness >= minimumBrightness, hsb.saturation >= minimumSaturation else { continue }
            // The most saturated; of equals, the brighter — the pixel that will
            // read better on black.
            if let current = best,
               hsb.saturation < current.saturation
                || (hsb.saturation == current.saturation && hsb.brightness <= current.brightness) {
                continue
            }
            best = hsb
        }
        guard let chosen = best else { return .fallback }
        let rgb = rgb(
            hue: chosen.hue, saturation: chosen.saturation,
            brightness: max(chosen.brightness, liftedBrightness)
        )
        return CoverTint(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func downsample(_ image: CGImage) -> [UInt8]? {
        let side = sampleSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        return Array(UnsafeBufferPointer(start: bytes, count: side * side * 4))
    }

    // MARK: - HSB

    static func hsb(red: Double, green: Double, blue: Double)
        -> (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low
        guard high > 0 else { return (0, 0, 0) }
        let saturation = delta / high
        guard delta > 0 else { return (0, saturation, high) }
        var hue: Double
        switch high {
        case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, saturation, high)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double)
        -> (red: Double, green: Double, blue: Double) {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6
        let fraction = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }

    // MARK: - Once per artwork, off the main actor

    /// One reading per artwork. The cover changes once a track and the island
    /// redraws far more often, so the answer is cached against the image
    /// itself — the same key `LockCardLegibility` caches its brightness
    /// under, for the same reason: an `ObjectIdentifier` could be inherited by
    /// a new image allocated at a freed one's address, and the new cover would
    /// read the old one's colour. Eight covers is more than the island ever
    /// holds at once.
    private static let cache: NSCache<NSImage, Box> = {
        let cache = NSCache<NSImage, Box>()
        cache.countLimit = 8
        return cache
    }()

    private final class Box {
        let tint: CoverTint
        init(_ tint: CoverTint) { self.tint = tint }
    }

    /// An answer already in hand, for the redraw that must not wait: the cached
    /// reading, the fallback for no cover, nil for one still to be read.
    static func cachedTint(for image: NSImage?) -> CoverTint? {
        guard let image else { return .fallback }
        return cache.object(forKey: image)?.tint
    }

    /// Reads the cover on a background executor and caches the answer. Never
    /// on the main actor: decoding and drawing a cover is not work the
    /// island's frame should wait for.
    static func resolve(_ image: NSImage?) async -> CoverTint {
        guard let image else { return .fallback }
        if let known = cache.object(forKey: image) { return known.tint }
        let handoff = ImageHandoff(image: image)
        let tint = await Task.detached(priority: .utility) { () -> CoverTint in
            var proposed = CGRect(origin: .zero, size: handoff.image.size)
            let cgImage = handoff.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            return CoverTint.tint(of: cgImage)
        }.value
        cache.setObject(Box(tint), forKey: image)
        return tint
    }

    /// `NSImage` is not `Sendable`, and a cover handed to one reader for one
    /// read, never touched elsewhere meanwhile, is the case the escape hatch is
    /// for.
    private struct ImageHandoff: @unchecked Sendable {
        let image: NSImage
    }
}
