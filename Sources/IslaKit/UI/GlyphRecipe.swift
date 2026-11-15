import CoreGraphics
import Foundation

/// One element of a Hugeicons drawing, on its 24 unit grid.
///
/// The free set draws with `path`, `circle`, `ellipse` and `rect`; every other
/// attribute (its own stroke, fill and width) is dropped, because islandcn's
/// renderer overrides all of them with the part's own.
enum GlyphElement {
    case path(String, evenOdd: Bool = false)
    case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)
    case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat = 0)

    var cgPath: CGPath {
        switch self {
        case .path(let d, _):
            guard let path = SVGPath.parse(d) else {
                assertionFailure("Unreadable Hugeicons path: \(d)")
                return CGMutablePath()
            }
            return path
        case .circle(let cx, let cy, let r):
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
        case .ellipse(let cx, let cy, let rx, let ry):
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case .rect(let x, let y, let width, let height, let rx):
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let radius = min(rx, width / 2, height / 2)
            return radius > 0
                ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: rect, transform: nil)
        }
    }

    var fillRule: CGPathFillRule {
        if case .path(_, true) = self { return .evenOdd }
        return .winding
    }

    /// islandcn's test (`glyphs.tsx` `isClosed`): every shape but a path is
    /// closed, and a path only when its data ends in Z. A closed shape cuts a
    /// hole; an open mark cuts only along its stroke.
    var isClosed: Bool {
        guard case .path(let d, _) = self else { return true }
        guard let last = d.trimmingCharacters(in: .whitespaces).last else { return false }
        return last == "Z" || last == "z"
    }
}

/// How one element of a drawing renders, as islandcn's `GlyphPart` says:
/// - `line`: an outline at the island weight.
/// - `fill`: solid, with no stroke added, so its edge is the icon's own path.
/// - `heavy`: solid and outlined at the island weight, for a solid element whose
///   path also carries an open mark (the stopwatch's side button).
/// - `cut`: not drawn, but cut out of the solid elements: a closed shape as a
///   hole, an open mark as a gap the island weight wide.
/// - `gap`: drawn as an outline, with a gap cut around it in the solid elements.
/// - `inlay`: solid, set into the solid elements with a gap around it, as a
///   car's wheels are.
enum GlyphPart {
    case line, fill, heavy, cut, gap, inlay
}

/// Where a layer sits on the 24 unit grid (islandcn's `GlyphPlacement`).
/// Outlines keep the glyph's weight however it is scaled or stretched.
struct GlyphPlacement {
    /// Where the icon's grid centre (12, 12) lands.
    var at = CGPoint(x: 12, y: 12)
    var scale: CGFloat = 1
    /// Clockwise turn in degrees about that centre.
    var turn: CGFloat = 0
    var mirror = false
    /// Stretches its height only, by this factor.
    var stretch: CGFloat = 1

    static let identity = GlyphPlacement()

    /// SVG's `translate(x y) scale(sx, scale·stretch) rotate(turn) translate(-12 -12)`,
    /// applied to a point right to left. The stretch lands after the turn, in
    /// the grid's own vertical, as it does in islandcn.
    var transform: CGAffineTransform {
        let sx = scale * (mirror ? -1 : 1)
        // SVG's rotate(θ) turns clockwise on a y-down grid, which is the same
        // matrix as CGAffineTransform(rotationAngle: θ) applied to y-down points.
        let toOrigin = CGAffineTransform(translationX: -12, y: -12)
        let turned = CGAffineTransform(rotationAngle: turn * .pi / 180)
        let scaled = CGAffineTransform(scaleX: sx, y: scale * stretch)
        let placed = CGAffineTransform(translationX: at.x, y: at.y)
        return toOrigin.concatenating(turned).concatenating(scaled).concatenating(placed)
    }
}

/// One Hugeicons icon, or some of its elements, in a glyph.
struct GlyphLayer {
    var icon: [GlyphElement]
    /// Parts by element index; an element past the end draws as `line`.
    var parts: [GlyphPart]
    var place: GlyphPlacement

    init(_ icon: [GlyphElement], parts: [GlyphPart], place: GlyphPlacement = .identity) {
        self.icon = icon
        self.parts = parts
        self.place = place
    }

    init(_ icon: [GlyphElement], _ part: GlyphPart = .line, place: GlyphPlacement = .identity) {
        self.init(icon, parts: Array(repeating: part, count: icon.count), place: place)
    }

    func part(at index: Int) -> GlyphPart { index < parts.count ? parts[index] : .line }
}

/// How a glyph draws its Hugeicons icon, and any more layers on top of it: a
/// port of islandcn's `glyphFrom` (`components/islandcn/glyphs.tsx`, commit
/// 0011a41) from SVG to Core Graphics.
///
/// islandcn draws three passes into an SVG — solids under a mask of every cut,
/// then outlines, then inlays. Here the passes become regions and the glyph one
/// filled path: `(solids − cuts) ∪ outlines ∪ inlays`. One path draws the same
/// ink, takes any `foregroundStyle`, and has no seam where an outline crosses a
/// solid, which two blended SVG passes do at their antialiased edges.
struct GlyphRecipe {
    var layers: [GlyphLayer]
    /// The window onto the 24 unit grid the box shows. A smaller window draws
    /// the ink larger, for controls drawn to measured sizes.
    var view: CGRect

    static let grid: CGFloat = 24
    static let fullView = CGRect(x: 0, y: 0, width: grid, height: grid)

    init(layers: [GlyphLayer], view: CGRect = GlyphRecipe.fullView) {
        self.layers = layers
        self.view = view
    }

    /// islandcn's `glyphFrom(name, icon, { parts, place, layers, view })`.
    init(
        _ icon: [GlyphElement], _ part: GlyphPart = .line, place: GlyphPlacement = .identity,
        layers: [GlyphLayer] = [], view: CGRect = GlyphRecipe.fullView
    ) {
        self.init(layers: [GlyphLayer(icon, part, place: place)] + layers, view: view)
    }

    init(
        _ icon: [GlyphElement], parts: [GlyphPart], place: GlyphPlacement = .identity,
        layers: [GlyphLayer] = [], view: CGRect = GlyphRecipe.fullView
    ) {
        self.init(layers: [GlyphLayer(icon, parts: parts, place: place)] + layers, view: view)
    }

    /// The outline weight in grid units at a box of `size` points: 2 units at
    /// islandcn's 22 pt compact glyph, a little heavier small and lighter
    /// large, as type is (`strokeAt`). Rounded to hundredths as JavaScript's
    /// `Math.round` does, so the weights match islandcn's to the digit.
    static func stroke(atBox size: CGFloat) -> CGFloat {
        jsRound2(2 * pow(22 / size, 0.35))
    }

    /// islandcn's `centredView`: a square window centred on the grid that draws
    /// `inkUnits` of ink at `share` of the box.
    static func centredView(ink inkUnits: CGFloat, share: CGFloat) -> CGRect {
        let side = jsRound2(inkUnits / share)
        let start = jsRound2(grid / 2 - side / 2)
        return CGRect(x: start, y: start, width: side, height: side)
    }

    /// `Math.round(x * 100) / 100`: halves round up, toward +∞.
    static func jsRound2(_ value: CGFloat) -> CGFloat {
        (value * 100 + 0.5).rounded(.down) / 100
    }

    /// The glyph's ink as one path in a `size` × `size` box, y down.
    func path(size: CGFloat) -> CGPath {
        let line = Self.stroke(atBox: size * Self.grid / view.width)

        var solids: [CGPath] = []
        var cuts: [CGPath] = []
        var outlines: [CGPath] = []
        var inlays: [CGPath] = []

        func stroked(_ path: CGPath, _ width: CGFloat) -> CGPath {
            path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }

        for layer in layers {
            let transform = layer.place.transform
            for (index, element) in layer.icon.enumerated() {
                var placed = transform
                // Every width below is in grid units after the layer's own
                // transform: islandcn divides a scaled layer's widths back out
                // and draws a stretched one's in screen space, which both come
                // to the same grid width once the layer is placed.
                guard let path = element.cgPath.copy(using: &placed) else { continue }
                // Its own fill rule settled once, so every region after this
                // can be combined under one rule.
                let filled = { path.normalized(using: element.fillRule) }
                switch layer.part(at: index) {
                case .line:
                    outlines.append(stroked(path, line))
                case .fill:
                    solids.append(filled())
                case .heavy:
                    solids.append(filled().union(stroked(path, line)))
                case .cut:
                    cuts.append(element.isClosed ? filled() : stroked(path, line))
                case .gap:
                    cuts.append(stroked(path, line * 3))
                    outlines.append(stroked(path, line))
                case .inlay:
                    cuts.append(stroked(path, line * 2))
                    inlays.append(filled())
                }
            }
        }

        func union(_ paths: [CGPath]) -> CGPath? {
            guard var result = paths.first else { return nil }
            for path in paths.dropFirst() { result = result.union(path) }
            return result
        }

        var ink: CGPath? = union(solids)
        if let solid = ink, let holes = union(cuts) { ink = solid.subtracting(holes) }
        for extra in [union(outlines), union(inlays)].compactMap({ $0 }) {
            ink = ink.map { $0.union(extra) } ?? extra
        }
        guard let ink else { return CGMutablePath() }

        let unit = size / view.width
        var toBox = CGAffineTransform(translationX: -view.minX, y: -view.minY)
            .concatenating(CGAffineTransform(scaleX: unit, y: unit))
        return ink.copy(using: &toBox) ?? ink
    }
}
