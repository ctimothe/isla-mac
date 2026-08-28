import SwiftUI
import XCTest
@testable import IslaKit

@MainActor
final class KaraokeTextTests: XCTestCase {

    /// The sweep is interpolated, not stepped.
    ///
    /// `TextRenderer` inherits `Animatable`, and mapping `animatableData` onto the
    /// fraction is what lets SwiftUI redraw between position ticks instead of
    /// jumping four times a second with them. That is the whole difference between
    /// "with the beat" and "lagging", and it is wiring rather than pixels, so it is
    /// asserted as wiring.
    func testTheRendererAnimatesOnTheFraction() {
        var renderer = KaraokeRenderer(fraction: 0.25, accent: .white, base: .gray)
        XCTAssertEqual(renderer.animatableData, 0.25, accuracy: 0.0001)
        renderer.animatableData = 0.75
        XCTAssertEqual(renderer.fraction, 0.75, accuracy: 0.0001)
    }

    /// A wrapped line fills in reading order: the top row completely, before the
    /// bottom row is touched at all.
    ///
    /// This is the assertion the renderer this replaced could not pass. A single
    /// rectangle mask over the whole text lights the left half of *every* row at
    /// once, so at half-swept a two-row line came out half-lit on both rows — the
    /// reading edge in two places, neither of them where the voice was.
    func testAWrappedLineFillsTheTopRowBeforeTheBottom() throws {
        let halfway = try lit(fraction: 0.5)
        XCTAssertGreaterThan(
            halfway.top, 0.75,
            "at half swept the top row should be essentially complete, was \(halfway.top)"
        )
        XCTAssertLessThan(
            halfway.bottom, 0.15,
            "the bottom row must be untouched while the top is still filling, was \(halfway.bottom)"
        )

        let none = try lit(fraction: 0)
        XCTAssertLessThan(none.top, 0.05)
        XCTAssertLessThan(none.bottom, 0.05)

        let all = try lit(fraction: 1)
        XCTAssertGreaterThan(all.top, 0.75)
        XCTAssertGreaterThan(all.bottom, 0.6)
    }

    // MARK: - Harness

    /// Renders a deliberately wrapping line with a pure-red sweep over pure-blue
    /// base, and reports the share of each row's ink that came out red.
    private func lit(fraction: Double) throws -> (top: Double, bottom: Double) {
        let view = KaraokeText(
            text: "the quick brown fox jumps over the lazy dog",
            fraction: fraction,
            accent: .red,
            font: .system(size: 15, weight: .bold),
            base: .blue,
            lineLimit: 2
        )
        .frame(width: 150, alignment: .leading)
        .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the line must render")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 20, "the text must have wrapped to two rows")

        func share(rows: Range<Int>) -> Double {
            var red = 0
            var blue = 0
            for y in rows {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                    let r = c.redComponent, b = c.blueComponent
                    guard r > 0.18 || b > 0.18 else { continue }
                    if r > b { red += 1 } else if b > r { blue += 1 }
                }
            }
            let ink = red + blue
            return ink == 0 ? 0 : Double(red) / Double(ink)
        }

        let mid = bitmap.pixelsHigh / 2
        return (share(rows: 0..<mid), share(rows: mid..<bitmap.pixelsHigh))
    }
}
