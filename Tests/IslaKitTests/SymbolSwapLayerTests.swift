import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// A glyph swap never draws through RenderBox (B9, 2026-10-29).
///
/// The gear turning into Settings' X was a `.symbolEffect(.replace)`, and
/// SwiftUI draws that effect into an `RBDrawingLayer`. Every frame of it, the
/// layer's display waited in `-[CAContext waitForCommitId:]` for the render
/// server to finish the frame before, so the main thread sat blocked through
/// the effect while the panel swapped its pane. The hitch lab put the cost at
/// 27 missed frames of 125 on player to Settings with lyrics live, against 4
/// with the plain scale and fade `symbolSwap` uses now. This holds the
/// mechanism rather than the timing: a swap's layers, every frame of it, and
/// not one of them RenderBox's.
@MainActor
final class SymbolSwapLayerTests: XCTestCase {
    private final class Flag: ObservableObject {
        @Published var on = false
    }

    private struct Glyph: View {
        @ObservedObject var flag: Flag
        var reduceMotion = false

        var body: some View {
            // The gear's own glyph and size (`HeaderToolButton`).
            Image(systemName: flag.on ? "xmark" : "gearshape")
                .font(HeaderIcon.font)
                .foregroundStyle(flag.on ? Color.white : Theme.secondary)
                .symbolSwap(value: flag.on, reduceMotion: reduceMotion)
                .frame(width: SurfaceHeaderLayout.toolSide, height: SurfaceHeaderLayout.toolSide)
        }
    }

    private static func classes(under layer: CALayer, into names: inout Set<String>) {
        names.insert(NSStringFromClass(type(of: layer)))
        for sublayer in layer.sublayers ?? [] { classes(under: sublayer, into: &names) }
    }

    /// Flips the glyph both ways in plain transactions, as the player's stream
    /// and the pane swap flip theirs, and returns every layer class seen
    /// through both swaps, read each frame.
    private func layersThroughSwaps(reduceMotion: Bool) async throws -> Set<String> {
        let flag = Flag()
        let side = SurfaceHeaderLayout.toolSide
        let host = AXProbe.present(Glyph(flag: flag, reduceMotion: reduceMotion), size: CGSize(width: side, height: side))
        host.hosting.wantsLayer = true
        // Composited, so SwiftUI commits the swap the way it does on screen;
        // far off every display and never key.
        host.window.orderFrontRegardless()
        defer { host.window.orderOut(nil) }
        await AXProbe.wait(0.1)
        let root = try XCTUnwrap(host.hosting.layer, "the hosting view has no layer")

        var seen: Set<String> = []
        for on in [true, false] {
            flag.on = on
            // Theme.contentAnimation is 0.16 s; read past its end.
            for _ in 0..<16 {
                await AXProbe.wait(0.016)
                Self.classes(under: root, into: &seen)
            }
        }
        return seen
    }

    func testTheGearsSwapDrawsNoRenderBoxLayer() async throws {
        let seen = try await layersThroughSwaps(reduceMotion: false)
        let renderBox = seen.filter { $0.contains("RBDrawingLayer") || $0.contains("RBSurface") || $0.hasSuffix("RBLayer") }
        XCTAssertTrue(renderBox.isEmpty, "a glyph swap drew through RenderBox: \(renderBox.sorted())")
        XCTAssertGreaterThan(seen.count, 1, "no layers were read: the test saw nothing to judge")
    }

    func testUnderReduceMotionToo() async throws {
        let seen = try await layersThroughSwaps(reduceMotion: true)
        let renderBox = seen.filter { $0.contains("RBDrawingLayer") || $0.contains("RBSurface") || $0.hasSuffix("RBLayer") }
        XCTAssertTrue(renderBox.isEmpty, "a glyph swap drew through RenderBox: \(renderBox.sorted())")
    }
}
