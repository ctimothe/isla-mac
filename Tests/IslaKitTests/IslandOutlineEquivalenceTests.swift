import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import IslaKit

/// The outline on layers and the outline in SwiftUI are one picture (spec
/// §19.12). The layers replaced three SwiftUI shapes — the black fill with its
/// shadow, the 2 pt line — and nothing about how the island looks was meant to
/// change, so each state the island has is drawn both ways onto transparent
/// bitmaps and compared pixel by pixel: where the black is, how strong the
/// shadow is under it, and where the line lies.
///
/// What cannot be compared here is the content between the two (the mask is
/// held geometrically by `IslandOutlineHostTests`).
@MainActor
final class IslandOutlineEquivalenceTests: XCTestCase {
    private let window = CGSize(width: 700, height: 340)
    private let scale: CGFloat = 2

    private struct Case {
        var name: String
        var state: OutlineState
    }

    private func state(
        _ width: Double, _ height: Double, _ top: Double, _ bottom: Double,
        fill: Color = .black, stroke: Color = Color.white.opacity(0.14), strokeShown: Bool = true
    ) -> OutlineState {
        OutlineState(
            width: width, height: height, topRadius: top, bottomRadius: bottom,
            fill: OutlineColor(fill),
            stroke: OutlineColor(stroke).scalingAlpha(by: strokeShown ? 1 : 0),
            strokeWidth: Double(Theme.islandStrokeWidth),
            shadowOpacity: IslandStroke.castsShadow(height: CGFloat(height)) ? Theme.islandShadowOpacity : 0
        )
    }

    private var cases: [Case] {
        [
            Case(name: "resting notch, nothing drawn", state: state(185, 31, 0, 12.67, strokeShown: false)),
            Case(name: "compact activity", state: state(300, 38, 8.67, 12.67)),
            Case(name: "charging, green line", state: state(
                365, 38, 8.67, 12.67, stroke: Theme.chargingGreen.opacity(Theme.islandStrokeTintOpacity))),
            Case(name: "hovered compact island", state: state(300, 38, 8.67, 12.67, fill: Theme.islandHover)),
            Case(name: "the peek", state: state(330, 50, 8.67, 16)),
            Case(name: "headphones alert", state: state(410, 95, 20, 38)),
            Case(name: "player", state: state(628, 198, 34, 44)),
            Case(name: "shelf tray", state: state(628, 260, 24, 34)),
            Case(name: "settings", state: state(628, 400, 34, 44)),
        ]
    }

    // MARK: Rendering

    private struct Bitmap {
        var width: Int
        var height: Int
        /// Premultiplied RGBA, rows from the top.
        var pixels: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(pixels[(y * width + x) * 4 + $0]) } }
    }

    private func bitmap(of image: CGImage) -> Bitmap {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A bitmap context keeps its first row in memory first: the image's top.
        return Bitmap(width: w, height: h, pixels: data)
    }

    /// The SwiftUI outline: what `NotchContentView` drew before the layers,
    /// composed the way the screen composes it — through the hosting view's own
    /// layers, whose shadow is a layer's. (`ImageRenderer` draws SwiftUI's
    /// shadow with Core Graphics instead, which falls off differently and is
    /// not what anyone sees.)
    private func swiftUI(_ state: OutlineState) -> Bitmap {
        let shape = state.shape
        let size = CGSize(width: shape.width, height: shape.height)
        let view = ZStack(alignment: .top) {
            NotchShape(topRadius: CGFloat(shape.topRadius), bottomRadius: CGFloat(shape.bottomRadius))
                .fill(Color(nsColor: NSColor(
                    srgbRed: CGFloat(state.fill.red), green: CGFloat(state.fill.green),
                    blue: CGFloat(state.fill.blue), alpha: CGFloat(state.fill.alpha))))
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(state.shadowOpacity), radius: Theme.islandShadowRadius)
            IslandStrokeShape(topRadius: CGFloat(shape.topRadius), bottomRadius: CGFloat(shape.bottomRadius))
                .stroke(
                    Color(nsColor: NSColor(
                        srgbRed: CGFloat(state.stroke.red), green: CGFloat(state.stroke.green),
                        blue: CGFloat(state.stroke.blue), alpha: CGFloat(state.stroke.alpha))),
                    lineWidth: CGFloat(state.strokeWidth))
                .frame(width: size.width, height: size.height)
        }
        .frame(width: window.width, height: window.height, alignment: .top)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: window)
        let host = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let context = CGContext(
            data: nil, width: Int(window.width * scale), height: Int(window.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        // The hosting view's layers are laid out from the top.
        context.translateBy(x: 0, y: window.height)
        context.scaleBy(x: 1, y: -1)
        hosting.layer?.render(in: context)
        host.contentView = nil
        return bitmap(of: context.makeImage()!)
    }

    /// The outline on layers: the host's two layer views, drawn under and over
    /// nothing, with the CPU renderer.
    private func layers(_ state: OutlineState) -> Bitmap {
        let host = IslandOutlineHost(windowSize: window)
        host.apply(state, curve: .instant)
        let context = CGContext(
            data: nil, width: Int(window.width * scale), height: Int(window.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        host.backdrop.layer?.render(in: context)
        host.overlay.layer?.render(in: context)
        return bitmap(of: context.makeImage()!)
    }

    // MARK: Comparison

    private struct Difference {
        var worst = 0
        var over = 0
        var total = 0
        var coverageA = 0.0
        var coverageB = 0.0
    }

    private func compare(_ a: Bitmap, _ b: Bitmap, tolerance: Int) -> Difference {
        var result = Difference()
        for index in stride(from: 0, to: a.pixels.count, by: 4) {
            var worst = 0
            for channel in 0..<4 { worst = max(worst, abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel]))) }
            result.worst = max(result.worst, worst)
            if worst > tolerance { result.over += 1 }
            result.total += 1
            result.coverageA += Double(a.pixels[index + 3]) / 255
            result.coverageB += Double(b.pixels[index + 3]) / 255
        }
        return result
    }

    func testEveryStateOfTheOutlineIsOnePictureOnLayersAndInSwiftUI() {
        for c in cases {
            let reference = swiftUI(c.state)
            let drawn = layers(c.state)
            XCTAssertEqual(reference.width, drawn.width)
            let difference = compare(reference, drawn, tolerance: 16)
            let fraction = Double(difference.over) / Double(difference.total)
            // Anti-aliasing along the curves differs by a shade between the two
            // rasterisers; anything past a sliver of the pixels is a different
            // outline.
            XCTAssertLessThan(fraction, 0.0015, "\(c.name): \(difference.over) of \(difference.total) pixels differ by more than 16/255 (worst \(difference.worst))")
            XCTAssertEqual(
                difference.coverageA, difference.coverageB, accuracy: max(8, difference.coverageA * 0.01),
                "\(c.name): the same amount of ink")
        }
    }

    /// The shadow is the part of this a layer renders its own way. Under the
    /// player, the profile of its alpha going down from the foot of the shape
    /// is the SwiftUI shadow's to within a few parts in 255 at every row.
    func testTheShadowFallsOffAsSwiftUIsDid() {
        let player = state(628, 198, 34, 44)
        let reference = swiftUI(player)
        let drawn = layers(player)
        let column = reference.width / 2
        let foot = Int(player.height * Double(scale))
        var worst = 0
        var total = 0.0
        for row in foot..<min(reference.height, foot + Int(40 * scale)) {
            let a = reference.pixel(column, row)[3]
            let b = drawn.pixel(column, row)[3]
            worst = max(worst, abs(a - b))
            total += Double(abs(a - b))
        }
        XCTAssertLessThanOrEqual(worst, 6, "alpha of the shadow below the player, row by row")
        XCTAssertLessThan(total / Double(40 * scale), 2.5, "and on average")
        XCTAssertGreaterThan(drawn.pixel(column, foot + 2)[3], 8, "there is a shadow")
    }

    func testACompactActivityCastsNoShadowOnEitherSide() {
        let compact = state(300, 38, 8.67, 12.67)
        let reference = swiftUI(compact)
        let drawn = layers(compact)
        let column = reference.width / 2
        let foot = Int(38 * scale)
        for row in (foot + 2)..<(foot + 20) {
            XCTAssertEqual(reference.pixel(column, row)[3], 0, "SwiftUI draws none")
            XCTAssertEqual(drawn.pixel(column, row)[3], 0, "nor do the layers")
        }
    }

    /// The content is cut by the outline on real pixels: a real hosting view
    /// whose SwiftUI content fills the whole window in red, under the layers,
    /// with the outline applied. Red shows inside the island and nowhere else —
    /// not in the corners the rounded bottom takes away, not beside the body
    /// under the shoulders — and the mask stands the right way up on a flipped
    /// hosting layer.
    func testTheContentIsCutByTheOutlineOnRealPixels() {
        let host = IslandOutlineHost(windowSize: window)
        let hosting = NSHostingView(rootView: Color.red.frame(width: window.width, height: window.height))
        hosting.frame = CGRect(origin: .zero, size: window)
        host.attach(content: hosting)
        let root = NSView(frame: hosting.frame)
        root.wantsLayer = true
        for view in [host.backdrop, hosting, host.overlay] { root.addSubview(view) }
        let panel = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.contentView = root
        defer { panel.contentView = nil }
        let island = state(628, 198, 34, 44)
        host.apply(island, curve: .instant)
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let context = CGContext(
            data: nil, width: Int(window.width * scale), height: Int(window.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        root.layer?.render(in: context)
        let picture = bitmap(of: context.makeImage()!)

        func red(_ x: Double, _ y: Double) -> Int { picture.pixel(Int(x * Double(scale)), Int(y * Double(scale)))[0] }
        let left = (Double(window.width) - 628) / 2
        let bottom = 198.0
        XCTAssertGreaterThan(red(left + 314, 100), 200, "the content shows in the middle of the island")
        XCTAssertGreaterThan(red(left + 314, bottom - 3), 200, "and down to its foot")
        XCTAssertLessThan(red(left + 314, bottom + 6), 40, "not below the foot")
        // The bottom corner takes away a corner of the body's square.
        XCTAssertLessThan(red(left + 34 + 3, bottom - 3), 40, "nothing in the rounded bottom corner")
        XCTAssertGreaterThan(red(left + 34 + 44, bottom - 3), 200, "but the foot is there once the corner is past")
        // Beside the body, under the shoulder, is outside; the shoulder's own flare is inside.
        XCTAssertLessThan(red(left + 6, 80), 40, "nothing beside the body")
        XCTAssertGreaterThan(red(left + 20, 2), 200, "the shoulder's flare, right of its concave curve, is the island's")
        XCTAssertLessThan(red(left + 3, 2), 40, "and left of the curve is not")
    }

    func testTheLineIsNeverDrawnAlongTheTopEdge() {
        let player = state(628, 198, 34, 44, stroke: Color.white)
        let drawn = layers(player)
        // Row 0 is the display's top edge: the fill reaches it, the line does
        // not run along it. The fill is black, so a white line there would be
        // the only light pixels in the row between the shoulders.
        let middle = drawn.width / 2
        XCTAssertEqual(drawn.pixel(middle, 0)[0], 0, "no white along the top")
        XCTAssertEqual(drawn.pixel(middle, 0)[3], 255, "black, to the edge")
        // And it is drawn on the sides: just inside and just outside the left side.
        let sideX = Int((Double(window.width) - 628) / 2 + 34) * Int(scale)
        XCTAssertGreaterThan(drawn.pixel(sideX, Int(100 * scale))[0], 100, "the white line on the left side")
    }
}
