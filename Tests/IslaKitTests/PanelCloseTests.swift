import Foundation
import SwiftUI
import XCTest
@testable import IslaKit

/// Closing mirrors opening: the body leaves before the shape comes for it
/// (H-012, H-028).
///
/// The open has always had a rule — the panel has height before the body has
/// alpha — and the close only pretended to. The body left on an ease-in 0.12 s,
/// a curve that starts at zero speed, while the shape started its 0.34 s spring
/// in the same frame. The shape eats the 14 pt bottom padding in about 25 ms
/// and then the clip is into the rail and the time label, which at that moment
/// were still 0.93 opaque: the visual lab's keyframes-close t033–t050 show both
/// cut while bright. A close read as a blind dropping, not as the open run
/// backwards.
///
/// The model here is read from the shipped `Animation` values rather than
/// restated, the way the visual lab reads them, so a retune of either curve
/// is measured against the clip it has to beat.
@MainActor
final class PanelCloseTests: XCTestCase {

    /// The shape's travel on a close: the standard body folding into the
    /// physical notch it grew out of.
    private var shapeTravel: Double {
        Double(NotchMetrics.standardBodyHeight - LabGeometry.physicalNotch.height)
    }

    private func parsed(_ animation: Animation, _ name: String) throws -> LabCurve {
        try XCTUnwrap(LabCurve.parse(animation, name: name, usedFor: "", source: ""),
                      "cannot read \(name): \(animation)")
    }

    /// When the clip has travelled the bottom padding — the first point at
    /// which it touches anything drawn — the body is under a third opaque.
    /// Today's ease-in with no shape delay leaves it at 0.93 there.
    func testTheBodyIsMostlyGoneBeforeTheClipReachesIt() throws {
        let shape = try parsed(Theme.close(reduceMotion: false), "close")
        let body = try parsed(Theme.paneOut, "pane-out")

        // The curves that ship are the ones the constants name.
        XCTAssertEqual(shape.kind, .spring)
        XCTAssertEqual(shape.response, Theme.islandResponse, accuracy: 1e-9, "the outline's spring (spec §19.3)")
        XCTAssertEqual(shape.damping, Theme.islandDamping, accuracy: 1e-9)
        XCTAssertEqual(shape.delay, Theme.closeShapeDelay, accuracy: 1e-9)
        XCTAssertEqual(body.kind, .bezier)
        XCTAssertEqual(body.duration, Theme.paneOutDuration, accuracy: 1e-9)
        XCTAssertEqual(body.delay, 0, "the fade is the response to the click; it must not wait")

        // The first instant the clip reaches drawn content, from the spring's
        // own closed form, after the shape's delay.
        let reach = Theme.closeShapeDelay + Theme.springRiseTime(
            response: Theme.islandResponse, damping: Theme.islandDamping,
            level: Double(NotchGeometry.bodyBottomPadding) / shapeTravel
        )
        let opacity = 1 - body.sample(reach).value
        XCTAssertLessThanOrEqual(opacity, 0.30, String(
            format: "body still %.2f opaque when the clip reaches it at %.0f ms", opacity, reach * 1000))
    }

    /// An exit that ends at peak speed yanks the text out rather than letting
    /// it go (H-028); the tab swap rides the same curve. Ease-out starts at its
    /// fastest, so the fade answers the click in the first frame.
    ///
    /// Read from the coefficients, not the name: SwiftUI describes a timing
    /// curve only as its cubic solver, so a check for the word "easeIn" in the
    /// description passed against the very ease-in it was meant to catch.
    func testTheExitStartsFast() throws {
        let described = String(describing: Theme.paneOut)
        let body = try parsed(Theme.paneOut, "pane-out")
        // Speed in its first instant, in progress per duration. Read by
        // sampling rather than as cy / cx, which is 0 / 0 for the system
        // ease-out (both control points' first coordinates are 0). Linear is
        // 1; ease-in starts at 0; ease-out at about 1.7.
        let opening = body.sample(body.duration * 1e-4).velocity * body.duration
        XCTAssertGreaterThan(opening, 1.5, "the exit must start faster than linear: \(described)")
    }

    /// Reduce Motion asks for the change without the travel, and a delay is
    /// choreography, which it also did not ask for: the reduced close is the
    /// reduced open, straight away.
    func testReduceMotionClosesWithoutTheDelay() {
        let reduced = String(describing: Theme.close(reduceMotion: true))
        XCTAssertFalse(reduced.contains("DelayAnimation"), reduced)
        XCTAssertEqual(reduced, String(describing: Theme.open(reduceMotion: true)))
    }

    /// The open is the same spring the close is, so the two still mirror.
    func testTheOpenIsTheNamedResponse() throws {
        let open = try parsed(Theme.open(reduceMotion: false), "open")
        XCTAssertEqual(open.response, Theme.islandResponse, accuracy: 1e-9)
        XCTAssertEqual(open.damping, Theme.islandDamping, accuracy: 1e-9)
        XCTAssertEqual(open.delay, 0, "an open must never wait")
    }

    /// The hit area shrinks `collapseRectShrinkDelay` after the close starts.
    /// The delay moved the shape's settle later by `closeShapeDelay`, and a
    /// rect that shrank before the panel was gone would let clicks through a
    /// panel still on screen.
    ///
    /// The outline's spring overshoots, and on a close it overshoots *inward*:
    /// once it has crossed its end the shape is smaller than what it is going
    /// to, so inside the rect cut for that, and its swing back out is under a
    /// tenth of a percent. Its first crossing is the moment that matters.
    func testTheHitAreaOutlastsTheDelayedClose() {
        let settle = Theme.closeShapeDelay
            + Theme.springRiseTime(response: Theme.islandResponse, damping: Theme.islandDamping, level: 1)
        XCTAssertGreaterThanOrEqual(NotchMetrics.collapseRectShrinkDelay, settle)
    }

    /// Both ways a panel is closed by hand ride the close curve: the
    /// controller's `withAnimation` and the shell's own `.animation(value:
    /// isOpen)`. Either one left on the open spring would start the shape
    /// with the fade and put the slice back. Read from the source because the
    /// curve a transaction carries cannot be observed from outside a render.
    func testBothClosePathsRideTheCloseCurve() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/Notch/NotchController.swift"), encoding: .utf8)
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/NotchContentView.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("withAnimation(Theme.close(reduceMotion: SystemAppearance.shared.reduceMotion)) { vm.isOpen = false }"))
        XCTAssertTrue(shell.contains(".animation(isOpen ? Theme.open(reduceMotion: reduceMotion) : Theme.close(reduceMotion: reduceMotion), value: isOpen)"))
    }
}
