import AppKit

/// How dark the lock card dims its cover, worked out from how bright the cover
/// is — so white type holds over a pale one without a dark one losing its light.
///
/// The card is lit from behind by the song's own cover, blurred, under a black
/// wash. The wash was a fixed 0.34, and its comment said that was enough for
/// "the palest" cover. It was not: a near-white cover under 0.34 is a 0.66
/// grey, on which the artist line measured 1.76:1 and the elapsed time and the
/// lyric status 1.59:1 (F-003). The obvious repair — one heavy wash for every
/// cover — would have put out the light on every dark cover, which is the whole
/// look the owner asked for on 2026-09-21. So the wash is the old value until a
/// cover is bright enough to need more, and from there exactly as much more as
/// the dimmest label on the card needs to clear WCAG AA.
///
/// The model is a flat grey: the cover is blurred at 44pt past any detail, so
/// what sits behind a label is close to one tone, and the cover is measured at
/// its bright end so that tone is never underestimated. Layers are composited
/// source-over in gamma space, which is how SwiftUI draws `Color.black.opacity`
/// over an image and white type over both. The 1.3 saturation on the blurred
/// cover is left out: it moves chroma far more than luminance. The bottom
/// gradient is left out too — it only ever darkens, and the artist line sits at
/// the top where it does not reach.
enum LockCardLegibility {
    /// The AA ratio for body text. The card's smallest labels are 11–13pt, well
    /// under the 18pt where the looser 3:1 would apply.
    static let minimumContrast = 4.5

    /// The wash each style had before it was solved for, kept as the floor: a
    /// cover dark enough to hold at these values is drawn exactly as it was.
    /// Increase Contrast keeps its heavier 0.56 in every style, and Transparent
    /// keeps its lighter 0.2 because the card's own opacity already lets the
    /// wallpaper through.
    static func washFloor(style: NotchViewModel.LockCardStyle, increaseContrast: Bool) -> Double {
        if increaseContrast { return 0.56 }
        return style == .clear ? 0.2 : 0.34
    }

    /// The black wash over the blurred cover: the floor, or the least opacity
    /// above it at which `Theme.cardTertiary` — the dimmest type on the card —
    /// clears `minimumContrast` over what the cover becomes underneath it.
    ///
    /// In Transparent this answers for the part of the card the cover lights.
    /// The 38% of wallpaper that also shows through is behind the login shield,
    /// where no window is given a backdrop to read, so it cannot be measured;
    /// `checklist.md` records that divergence. Solid draws no cover and never
    /// asks.
    static func washOpacity(
        coverLuma: Double,
        style: NotchViewModel.LockCardStyle,
        increaseContrast: Bool
    ) -> Double {
        let floor = washFloor(style: style, increaseContrast: increaseContrast)
        let text = Theme.cardTertiaryOpacity(increaseContrast: increaseContrast)
        let luma = min(max(coverLuma, 0), 1)
        func holds(_ wash: Double) -> Bool {
            contrast(textOpacity: text, overGrey: luma * (1 - wash)) >= minimumContrast
        }
        if holds(floor) { return floor }
        // Contrast only rises as the wash darkens the grey, so bisection finds
        // the edge. Thirty halvings put it within 1e-9 of the true value, and
        // `high` is always on the side that holds — the answer never rounds
        // into a ratio a hair under the line.
        var low = floor
        var high = 1.0
        for _ in 0..<30 {
            let middle = (low + high) / 2
            if holds(middle) { high = middle } else { low = middle }
        }
        return high
    }

    /// The grey a label actually sits on: the cover, dimmed by its wash. An
    /// sRGB-encoded value in 0...1.
    static func backdrop(
        coverLuma: Double,
        style: NotchViewModel.LockCardStyle,
        increaseContrast: Bool
    ) -> Double {
        let luma = min(max(coverLuma, 0), 1)
        return luma * (1 - washOpacity(coverLuma: luma, style: style, increaseContrast: increaseContrast))
    }

    /// WCAG contrast of white at `textOpacity` laid over an sRGB grey.
    static func contrast(textOpacity: Double, overGrey grey: Double) -> Double {
        let composite = textOpacity + (1 - textOpacity) * grey
        return (relativeLuminance(composite) + 0.05) / (relativeLuminance(grey) + 0.05)
    }

    // MARK: - Measuring the cover

    /// One reading per artwork. The card redraws on every tick of the clock and
    /// the artwork changes once a track, so the measurement is cached against
    /// the image itself — not its `ObjectIdentifier`, which a new image
    /// allocated at a freed one's address would inherit, reading the old
    /// cover's brightness for the new one. Holding the image as the key keeps
    /// a few covers alive; four is more than one lock ever shows.
    private static let cache: NSCache<NSImage, NSNumber> = {
        let cache = NSCache<NSImage, NSNumber>()
        cache.countLimit = 4
        return cache
    }()

    /// How bright the cover is where it is brightest, as an sRGB grey in 0...1.
    ///
    /// The cover is drawn down to 8×8 — the 44pt blur leaves no finer detail
    /// behind the type than that — and the 90th percentile of relative
    /// luminance is taken rather than the mean. A cover half white and half
    /// black averages to a mid grey, and then the half of the card the white
    /// lands on gets a wash solved for a grey it is not.
    ///
    /// A cover that cannot be read is taken as white: the heavier wash costs a
    /// dark cover some of its light, and the lighter one costs every label.
    static func coverLuma(of image: NSImage) -> Double {
        if let known = cache.object(forKey: image) { return known.doubleValue }
        let luma = measure(image)
        cache.setObject(NSNumber(value: luma), forKey: image)
        return luma
    }

    private static func measure(_ image: NSImage) -> Double {
        let side = 8
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return 1 }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var luminances: [Double] = []
        luminances.reserveCapacity(side * side)
        for index in 0..<(side * side) {
            let red = linear(Double(pixels[index * 4]) / 255)
            let green = linear(Double(pixels[index * 4 + 1]) / 255)
            let blue = linear(Double(pixels[index * 4 + 2]) / 255)
            luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }
        luminances.sort()
        let percentile = luminances[Int((Double(luminances.count - 1) * 0.9).rounded())]
        return encoded(percentile)
    }

    // MARK: - sRGB

    private static func relativeLuminance(_ grey: Double) -> Double { linear(grey) }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
}
