import XCTest
@testable import IslaKit

/// Where the compact island is, in the coordinate space the click arrives in.
///
/// `NotchRootView.activeRect` decides what reaches the panel at all, and it was
/// always right. One layer below it, SwiftUI's gesture then decided whether the
/// click had landed *on the island* — and it compared the click against a rect
/// at the window's own origin while the gesture reports coordinates in the whole
/// 700 pt window and the island is centred in it. The overlap between the two is
/// the island's left edge: on a 185 pt notch with a track playing, the left 34 %
/// opened the panel and the right 66 % did nothing, and with nothing playing the
/// island was not clickable anywhere.
///
/// Hover never hit this, because hovering goes through `PointerWatcher` instead,
/// which is why it survived a release.
@MainActor
final class CompactGestureRectTests: XCTestCase {

    private func geometry() throws -> NotchGeometry {
        let onscreen = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        return NotchGeometry(
            screen: onscreen.screen,
            notchSize: CGSize(width: 185, height: 32),
            notchCenterX: onscreen.screen.frame.midX,
            isPhysical: true
        )
    }

    func testTheGestureRectIsCentredInTheWindowLikeTheIslandIs() throws {
        let geometry = try geometry()
        let body = CGSize(width: 289, height: 32)   // a 185 pt notch, playing
        let rect = geometry.compactGestureRect(for: body, topRadius: Theme.collapsedTopRadius)

        XCTAssertEqual(rect.midX, geometry.windowSize.width / 2, accuracy: 0.001,
                       "the island is centred, so the rect that tests a click on it must be too")
        XCTAssertEqual(rect.width, body.width + 2 * Theme.collapsedTopRadius, accuracy: 0.001,
                       "the drawn width, shoulders included")
    }

    /// The bug in the form the user reported it: the right half answered nothing.
    func testBothEdgesOfTheDrawnIslandAreInside() throws {
        let geometry = try geometry()
        for width in [CGFloat(185), 289, 485] {
            let body = CGSize(width: width, height: 32)
            let rect = geometry.compactGestureRect(for: body, topRadius: Theme.collapsedTopRadius)
            let y = rect.midY

            XCTAssertTrue(rect.contains(CGPoint(x: rect.minX + 0.5, y: y)),
                          "the leading shoulder at \(width)pt")
            XCTAssertTrue(rect.contains(CGPoint(x: rect.maxX - 0.5, y: y)),
                          "the trailing shoulder at \(width)pt — this is the half that was dead")
        }
    }

    /// It has to agree with the layer above it, or a click can pass `activeRect`
    /// and then be thrown away by the gesture — which is exactly what happened.
    func testItAgreesWithTheRectTheWindowUsesToAcceptTheClick() throws {
        let geometry = try geometry()
        let body = CGSize(width: 289, height: 32)
        let slack = Theme.collapsedTopRadius

        let appKit = geometry.contentRect(for: body).insetBy(dx: -slack, dy: 0)
        let swiftUI = geometry.compactGestureRect(for: body, topRadius: slack)

        XCTAssertEqual(swiftUI.minX, appKit.minX, accuracy: 0.001)
        XCTAssertEqual(swiftUI.width, appKit.width, accuracy: 0.001)
    }

    /// SwiftUI measures down from the top; `contentRect` measures up from the
    /// bottom. The island is pinned to the top edge, so its gesture rect starts
    /// at y = 0 rather than at the window's height minus its own.
    func testItIsMeasuredFromTheTopEdgeNotTheBottom() throws {
        let geometry = try geometry()
        let rect = geometry.compactGestureRect(for: CGSize(width: 289, height: 32),
                                               topRadius: Theme.collapsedTopRadius)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.height, 32, accuracy: 0.001)
    }
}
