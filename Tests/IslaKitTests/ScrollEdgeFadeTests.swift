import SwiftUI
import XCTest
@testable import IslaKit

/// The scroll-edge fade (H-017): a list fades only at an edge that has more
/// content beyond it. The Clipboard list cut its fifth row square against
/// Clear, and the Shelf strip at its cap clipped its last card with no cue,
/// so both looked cropped rather than scrollable.
final class ScrollEdgeFadeTests: XCTestCase {

    /// At rest at the top of a long list only the bottom is clipped; at the
    /// end only the top; a list that fits is clipped nowhere, so its first
    /// and last rows are never dimmed.
    func testOnlyClippedEdgesFade() {
        XCTAssertEqual(ScrollEdgeFade.edges(offset: 0, content: 300, container: 162), [.bottom])
        XCTAssertEqual(ScrollEdgeFade.edges(offset: 138, content: 300, container: 162), [.top])
        XCTAssertEqual(ScrollEdgeFade.edges(offset: 0, content: 100, container: 162), [])
        XCTAssertEqual(ScrollEdgeFade.edges(offset: 60, content: 300, container: 162), [.top, .bottom])
    }

    /// The horizontal Shelf strip names its ends leading and trailing, so
    /// the mask is drawn along the right axis.
    func testAHorizontalStripFadesItsLeadingAndTrailingEnds() {
        XCTAssertEqual(
            ScrollEdgeFade.edges(offset: 0, content: 900, container: 480, axis: .horizontal), [.trailing]
        )
        XCTAssertEqual(
            ScrollEdgeFade.edges(offset: 420, content: 900, container: 480, axis: .horizontal), [.leading]
        )
    }

    /// The elastic bounce past either end, and sub-point layout rounding,
    /// must not flash a fade on a list that is not clipped.
    func testOverscrollAndRoundingDoNotFade() {
        XCTAssertEqual(ScrollEdgeFade.edges(offset: -12, content: 300, container: 162), [.bottom])
        XCTAssertEqual(ScrollEdgeFade.edges(offset: 150, content: 300, container: 162), [.top])
        XCTAssertEqual(ScrollEdgeFade.edges(offset: 0.3, content: 162.4, container: 162), [])
    }

    /// The fade ends at the clip: opaque down to 10 pt before the bottom of
    /// a 150 pt viewport, transparent at exactly its edge. The top, not
    /// clipped, stays opaque from the first point.
    func testTheFadeReachesTheClip() {
        let stops = ScrollEdgeFade.stops(viewport: 150, fade: 10, edges: [.bottom])
        XCTAssertEqual(stops.map(\.location), [0, 10.0 / 150, 140.0 / 150, 1])
        XCTAssertEqual(stops.map(\.color), [.black, .black, .black, .clear])
    }

    func testAStartEdgeFadesFromTransparent() {
        let stops = ScrollEdgeFade.stops(viewport: 150, fade: 10, edges: [.leading])
        XCTAssertEqual(stops.map(\.color), [.clear, .black, .black, .black])
    }

    /// A viewport shorter than two ramps still draws a valid gradient: the
    /// ramps meet in the middle instead of crossing.
    func testATinyViewportKeepsItsStopsInOrder() {
        let stops = ScrollEdgeFade.stops(viewport: 12, fade: 10, edges: [.top, .bottom])
        let locations = stops.map(\.location)
        XCTAssertEqual(locations, locations.sorted())
        XCTAssertEqual(locations.first, 0)
        XCTAssertEqual(locations.last, 1)
        XCTAssertTrue(ScrollEdgeFade.stops(viewport: 0, fade: 10, edges: [.bottom]).allSatisfy {
            $0.location.isFinite
        })
    }

    /// The modifier rests on SwiftUI reporting the geometry once at first
    /// layout, before anyone scrolls: the case H-017 is about is a list at
    /// rest with its fifth row cut. Were the first report to wait for a
    /// scroll, the fade would be missing exactly there. Hosted in a window
    /// that is never ordered in.
    @MainActor
    func testAListAtRestReportsItsClippedEdgeBeforeAnyScroll() async {
        final class Reports { var values: [Edge.Set] = [] }
        let reports = Reports()
        let list = ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<10) { row in Text(verbatim: "\(row)").frame(height: 30) }
            }
        }
        .onScrollGeometryChange(for: Edge.Set.self) { geometry in
            ScrollEdgeFade.edges(
                offset: geometry.visibleRect.minY, content: geometry.contentSize.height,
                container: geometry.visibleRect.height
            )
        } action: { _, edges in
            reports.values.append(edges)
        }
        let size = CGSize(width: 200, height: 162)
        let window = NSWindow(
            contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: list.frame(width: size.width, height: size.height))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(reports.values.last, [.bottom])
    }

    func testTheFadeIsTenPoints() {
        XCTAssertEqual(Theme.scrollFadeLength, 10)
    }

    /// Source contract: both lists that H-017 caught clipping wear the fade.
    func testEveryListFades() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/IslaKit/UI")
        for file in ["ClipboardPane.swift", "ShelfPane.swift"] {
            let source = try String(contentsOf: ui.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains(".scrollEdgeFade("), "\(file) must apply .scrollEdgeFade(")
        }
    }
}
