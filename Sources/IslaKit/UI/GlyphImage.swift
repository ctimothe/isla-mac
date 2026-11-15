import AppKit
import SwiftUI

/// How a glyph fills the space it is given.
enum GlyphFit {
    /// The glyph's whole 24 unit box fills the square, as islandcn's `Glyph`
    /// draws at a size: ink keeps the drawing's own margin.
    case box
    /// The ink's bounds fit the space, as a resizable SF Symbol's do. Every
    /// frame the app measured around an SF Symbol keeps its ink this way.
    case ink
}

/// An `IslandGlyph` as a view. It fills with the foreground style, like text.
///
/// Three ways in, matching the three ways SF Symbols were drawn here:
/// - `GlyphImage(.music)` takes the space offered and fits its ink to it, for
///   what was `Image(systemName:).resizable().scaledToFit()`;
/// - `GlyphImage(.music, size: 22)` is islandcn's `Glyph size={22}`;
/// - `GlyphImage(.music, pointSize: 13)` stands where a symbol set in a 13 pt
///   font stood (`symbolBox(pointSize:)`).
struct GlyphImage: View {
    let glyph: IslandGlyph
    private let fit: GlyphFit
    private let side: CGFloat?

    init(_ glyph: IslandGlyph, fit: GlyphFit = .ink) {
        self.glyph = glyph
        self.fit = fit
        self.side = nil
    }

    init(_ glyph: IslandGlyph, size: CGFloat) {
        self.glyph = glyph
        self.fit = .box
        self.side = size
    }

    init(_ glyph: IslandGlyph, pointSize: CGFloat) {
        self.init(glyph, size: IslandGlyph.symbolBox(pointSize: pointSize))
    }

    var body: some View {
        // Decorative, as an unlabelled image is: every control that draws one
        // names itself (`accessibilityLabel`), and the glyph must not add its
        // drawing's name to that.
        if let side {
            drawing
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            drawing
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var drawing: some View {
        if let product = glyph.appleProductImage {
            // Apple's drawing of an Apple product, tinted like every glyph. In
            // a box it keeps a Hugeicons drawing's margin (2 of 24 units a side).
            let inset = side.map { fit == .box ? $0 / 12 : 0 } ?? 0
            Image(nsImage: product)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(inset)
        } else {
            GlyphShape(glyph: glyph, fit: fit)
        }
    }
}

/// The glyph's ink as a shape, cut from the rect it is given.
struct GlyphShape: Shape {
    var glyph: IslandGlyph
    var fit: GlyphFit = .ink

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        return Path(GlyphCache.shared.placed(glyph, fit: fit, in: rect))
    }
}

extension IslandGlyph {
    /// The box a glyph gets where an SF Symbol was set in a `pointSize` font.
    /// A symbol's ink is about its point size tall; a Hugeicons drawing's ink
    /// spans 20 of its 24 units, so the box is 1.2 times the point size.
    static func symbolBox(pointSize: CGFloat) -> CGFloat {
        (pointSize * 1.2 * 2).rounded() / 2
    }

    /// The glyph's ink in a `size` box, y down, at the island weight for that size.
    func path(size: CGFloat) -> CGPath {
        GlyphCache.shared.path(self, size: size)
    }

    /// Apple's own drawing of this Apple product, or nil when it is not one
    /// (`isAppleProduct`) or this macOS predates its symbol. The only place
    /// Isla asks for an SF Symbol: `IslandGlyphTests` holds it to that.
    var appleProductImage: NSImage? {
        guard isAppleProduct else { return nil }
        return GlyphCache.shared.product(self) { NSImage(systemSymbolName: rawValue, accessibilityDescription: nil) }
    }

    /// A template image of the glyph, for an `NSMenuItem` or for a glyph set
    /// inside a run of text, where only an image can go. Template, so the menu
    /// or the text tints it.
    func nsImage(size: CGFloat) -> NSImage {
        if let product = appleProductImage {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                product.draw(in: Self.fitted(product.size, in: rect.insetBy(dx: size / 12, dy: size / 12)))
                return true
            }
            image.isTemplate = true
            return image
        }
        let path = self.path(size: size)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The glyph's ink alone, cropped to its bounds and `inkHeight` tall, as a
    /// template image.
    func nsImage(inkHeight: CGFloat) -> NSImage {
        // The weight follows the box, so the box is found from the ink's
        // share of it, then the ink drawn at that box and cropped.
        let probe = path(size: GlyphRecipe.grid).boundingBoxOfPath
        guard probe.height > 0 else { return nsImage(size: inkHeight) }
        let ink = path(size: GlyphRecipe.grid * inkHeight / probe.height)
        let bounds = ink.boundingBoxOfPath
        let scale = inkHeight / bounds.height
        var place = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let placed = ink.copy(using: &place) ?? ink
        let size = NSSize(width: bounds.width * scale, height: inkHeight)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(placed)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// `size` scaled to fit `rect` and centred in it.
    static func fitted(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// A glyph inside a run of text: `Text(glyph.textImage(pointSize: 13))`.
    /// An image in text sits on the baseline, and one taller than the font's
    /// ascent (about 0.95 of the point size) grows the line, which moved every
    /// lyric row measured by its type. Its ink alone, 0.85 of the point size
    /// tall, stays inside the line as an SF Symbol did.
    func textImage(pointSize: CGFloat) -> Image {
        Image(nsImage: nsImage(inkHeight: pointSize * 0.85)).renderingMode(.template)
    }
}

/// Glyph paths, made once per glyph and size. Boolean path operations are the
/// expensive part of drawing a glyph; a body pass that redrew the transport
/// row would otherwise run them for every button on every frame.
final class GlyphCache: @unchecked Sendable {
    static let shared = GlyphCache()

    private struct Key: Hashable {
        let glyph: IslandGlyph
        /// Hundredths of a point: sizes closer than that draw the same pixels.
        let size: Int
    }

    private let lock = NSLock()
    private var paths: [Key: CGPath] = [:]
    /// Apple's product drawings, looked up once: the answer cannot change
    /// while the app runs, and a symbol lookup is not free in a body pass.
    private var products: [IslandGlyph: NSImage?] = [:]
    /// A frame that animates its size asks for a new size every frame; past
    /// this many the cache starts over rather than growing without end.
    private let limit = 1024

    func path(_ glyph: IslandGlyph, size: CGFloat) -> CGPath {
        let key = Key(glyph: glyph, size: Int((size * 100).rounded()))
        lock.lock()
        if let cached = paths[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let made = glyph.recipe.path(size: CGFloat(key.size) / 100)
        lock.lock()
        if paths.count >= limit { paths.removeAll(keepingCapacity: true) }
        paths[key] = made
        lock.unlock()
        return made
    }

    func product(_ glyph: IslandGlyph, lookUp: () -> NSImage?) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let known = products[glyph] { return known }
        let found = lookUp()
        products[glyph] = .some(found)
        return found
    }

    /// The glyph placed in `rect` by `fit`.
    func placed(_ glyph: IslandGlyph, fit: GlyphFit, in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        switch fit {
        case .box:
            var move = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            let box = path(glyph, size: side)
            return box.copy(using: &move) ?? box
        case .ink:
            // The weight follows the box the ink is drawn at, so the box is
            // found first from the ink at the rect's size, then the ink drawn
            // at that box and fitted exactly.
            let first = path(glyph, size: side).boundingBoxOfPath
            guard first.width > 0, first.height > 0 else { return CGMutablePath() }
            let box = side * min(rect.width / first.width, rect.height / first.height)
            let ink = path(glyph, size: box)
            let bounds = ink.boundingBoxOfPath
            guard bounds.width > 0, bounds.height > 0 else { return CGMutablePath() }
            let scale = min(rect.width / bounds.width, rect.height / bounds.height)
            var place = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
            return ink.copy(using: &place) ?? ink
        }
    }
}
