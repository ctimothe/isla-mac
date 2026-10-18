import AppKit
import SwiftUI

/// Something a change can be partway between, by a progress that may leave
/// 0…1 (the island's spring does, by 3 %).
protocol OutlineMixable: Equatable {
    func mixed(to other: Self, _ progress: Double) -> Self
}

/// An sRGB colour with its alpha, as plain numbers: what the outline's layers
/// are given and what a change between two of them mixes.
struct OutlineColor: OutlineMixable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let clear = OutlineColor(red: 0, green: 0, blue: 0, alpha: 0)
    static let black = OutlineColor(red: 0, green: 0, blue: 0, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(resolved.redComponent), green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent), alpha: Double(resolved.alphaComponent)
        )
    }

    /// The same colour, `factor` as present: how a stroke that is not shown
    /// is the stroke with no alpha, and fades in as it.
    func scalingAlpha(by factor: Double) -> OutlineColor {
        OutlineColor(red: red, green: green, blue: blue, alpha: alpha * factor)
    }

    /// Between two colours, never outside the gamut: a spring that overshoots
    /// must not push a channel past 1.
    func mixed(to other: OutlineColor, _ progress: Double) -> OutlineColor {
        func mix(_ a: Double, _ b: Double) -> Double { min(1, max(0, a + (b - a) * progress)) }
        return OutlineColor(
            red: mix(red, other.red), green: mix(green, other.green),
            blue: mix(blue, other.blue), alpha: mix(alpha, other.alpha)
        )
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// A number between 0 and 1 — the shadow's opacity.
struct OutlineOpacity: OutlineMixable {
    var value: Double

    func mixed(to other: OutlineOpacity, _ progress: Double) -> OutlineOpacity {
        OutlineOpacity(value: min(1, max(0, value + (other.value - value) * progress)))
    }
}

/// The outline's silhouette: the four numbers a change of size moves.
struct OutlineShape: OutlineMixable {
    /// The shape's own width and height, shoulders included (`shapeSize`).
    var width: Double
    var height: Double
    var topRadius: Double
    var bottomRadius: Double

    /// The numbers in points, for the velocity a spring carries from one
    /// change into the next.
    var numbers: [Double] { [width, height, topRadius, bottomRadius] }

    /// Not held inside any range: the island's spring overshoots by design,
    /// and the shape that results is the shape a SwiftUI animation of the same
    /// numbers draws.
    func mixed(to other: OutlineShape, _ progress: Double) -> OutlineShape {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        return OutlineShape(
            width: mix(width, other.width), height: mix(height, other.height),
            topRadius: mix(topRadius, other.topRadius), bottomRadius: mix(bottomRadius, other.bottomRadius)
        )
    }
}

/// Everything the island's outline is at one moment: the shape, what it is
/// filled with, the line round it and the shadow under it. The SwiftUI shell
/// decides it (`NotchContentView.outlineState`, from the same properties that
/// drew the outline before) and `IslandOutlineHost` draws it.
///
/// Four parts, because SwiftUI animates each value that changes on its own:
/// the pointer arriving while the island opens changes the fill, and must not
/// restart the open's spring on the shape. The host keeps one change in
/// flight per part.
struct OutlineState: Equatable {
    var shape: OutlineShape
    var fill: OutlineColor
    /// The line's colour with whether it is shown folded into its alpha — a
    /// stroke that is hidden is a stroke with none.
    var stroke: OutlineColor
    var strokeWidth: Double
    /// The shadow's opacity (0 or `Theme.islandShadowOpacity`; its radius is
    /// the constant `Theme.islandShadowRadius`).
    var shadow: OutlineOpacity

    init(
        width: Double, height: Double, topRadius: Double, bottomRadius: Double,
        fill: OutlineColor, stroke: OutlineColor, strokeWidth: Double, shadowOpacity: Double
    ) {
        shape = OutlineShape(width: width, height: height, topRadius: topRadius, bottomRadius: bottomRadius)
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        shadow = OutlineOpacity(value: shadowOpacity)
    }

    var width: Double { shape.width }
    var height: Double { shape.height }
    var topRadius: Double { shape.topRadius }
    var bottomRadius: Double { shape.bottomRadius }
    var shadowOpacity: Double { shadow.value }

    /// Between two states, every part by the same progress.
    func mixed(to other: OutlineState, _ progress: Double) -> OutlineState {
        var mixed = other
        mixed.shape = shape.mixed(to: other.shape, progress)
        mixed.fill = fill.mixed(to: other.fill, progress)
        mixed.stroke = stroke.mixed(to: other.stroke, progress)
        mixed.shadow = shadow.mixed(to: other.shadow, progress)
        return mixed
    }
}

/// The outline's paths, in the coordinates of a layer as big as the window:
/// the shape centred in it and hung from its top edge, which is the display's.
///
/// The corners come from `NotchShape` — the path §19.2 pins and
/// `IslandOutlineTests` holds — and nowhere else, so the layers can only ever
/// draw the shape the SwiftUI outline drew.
enum OutlinePaths {
    /// Where the shape is in a window: centred, top flush. In top-left
    /// coordinates, y down — the way SwiftUI places it.
    static func rect(of shape: OutlineShape, in window: CGSize) -> CGRect {
        CGRect(x: (window.width - shape.width) / 2, y: 0, width: shape.width, height: shape.height)
    }

    /// The filled shape, closed along the top edge: the fill, the shadow's
    /// silhouette and the mask that cuts the content.
    static func fill(_ shape: OutlineShape, in window: CGSize, flipped: Bool) -> CGPath {
        placed(notch(shape).path(in: rect(of: shape, in: window)), in: window, flipped: flipped)
    }

    /// The whole window less the island: even-odd, so the island's own area is
    /// the hole. The mask of what lies beside the island (the Shelf's bubble),
    /// which is thereby kept off the island's area on every frame the render
    /// server draws, whatever the main thread is doing about the bubble.
    static func outside(_ shape: OutlineShape, in window: CGSize, flipped: Bool) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: window))
        path.addPath(fill(shape, in: window, flipped: flipped))
        return path
    }

    /// The same outline left open along the top edge, which the stroke draws as
    /// it is: a line there would be a seam against the bezel.
    static func stroke(_ shape: OutlineShape, in window: CGSize, flipped: Bool) -> CGPath {
        placed(notch(shape).openPath(in: rect(of: shape, in: window)), in: window, flipped: flipped)
    }

    static func fill(_ state: OutlineState, in window: CGSize, flipped: Bool) -> CGPath {
        fill(state.shape, in: window, flipped: flipped)
    }

    static func stroke(_ state: OutlineState, in window: CGSize, flipped: Bool) -> CGPath {
        stroke(state.shape, in: window, flipped: flipped)
    }

    static func outside(_ state: OutlineState, in window: CGSize, flipped: Bool) -> CGPath {
        outside(state.shape, in: window, flipped: flipped)
    }

    private static func notch(_ shape: OutlineShape) -> NotchShape {
        NotchShape(topRadius: CGFloat(shape.topRadius), bottomRadius: CGFloat(shape.bottomRadius))
    }

    /// Layers in a view that is not flipped have their origin at the bottom
    /// left, and a view that is flipped (SwiftUI's hosting view is) at the top
    /// left. The path is built top-left; this stands it on whichever.
    private static func placed(_ path: Path, in window: CGSize, flipped: Bool) -> CGPath {
        guard !flipped else { return path.cgPath }
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: window.height)
        return path.cgPath.copy(using: &transform) ?? path.cgPath
    }
}
