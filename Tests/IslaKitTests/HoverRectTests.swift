import XCTest
@testable import IslaKit

/// What lights is what the pointer is actually on.
@MainActor
final class HoverRectTests: XCTestCase {

    /// The open target is padded so a near miss still opens the panel. The
    /// appearance must not be: driven from the padded rect, the island lit up
    /// while the cursor was visibly beside it.
    func testTheHoverRectIsTighterThanTheOpenTarget() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let width: CGFloat = 300

        let island = geometry.collapsedIslandRect(for: width)
        let target = geometry.collapsedHoverRect(for: width)

        XCTAssertEqual(island.width, width, "the drawn island is exactly its width")
        XCTAssertGreaterThan(target.width, island.width, "the open target is forgiving")
        XCTAssertTrue(target.insetBy(dx: -1, dy: -1).contains(island),
                      "and it contains the island rather than sitting beside it")
    }

    /// A point just outside the island but inside the padded target must open
    /// the panel and light nothing — that gap is the whole bug.
    func testAPointBesideTheIslandIsNotHovering() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current())
        let width: CGFloat = 300
        let island = geometry.collapsedIslandRect(for: width)
        let target = geometry.collapsedHoverRect(for: width)

        let beside = CGPoint(x: island.maxX + 3, y: island.midY)
        XCTAssertFalse(island.contains(beside), "not on the island")
        XCTAssertTrue(target.contains(beside), "but still close enough to open it")
    }

    /// The rect that keeps an open panel open contains the whole clickable
    /// island, at every width the island can take.
    ///
    /// This is why a click no longer pins the panel open
    /// (`NotchViewModel.clickOpened`): a click delivered by the mouse leaves the
    /// pointer inside the rect the watcher closes on, so the pin can buy the
    /// panel nothing and did nothing but refuse the walk-away. Should the two
    /// ever come apart — a pill allowed to outgrow the body it opens into is how
    /// — a click could land outside the close rect and the panel would fold
    /// under the very pointer that opened it, so the containment is asserted
    /// rather than assumed.
    func testTheOpenPanelsCloseRectContainsTheWholeClickableIsland() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let hold = geometry.hoverRect(for: geometry.expandedSize)

        // Every width the collapsed pill is ever cut to: bare notch, playing,
        // and the widest a sneak peek can reach. Taken from the same source the
        // panel takes them from, so the cap is the real cap.
        let playing = CompactMediaActivity.playing
        let widths = [
            geometry.notchSize.width,
            playing.bodySize(notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width).width,
            playing.bodySize(
                notchSize: geometry.notchSize,
                peeking: true,
                bodyWidth: geometry.expandedSize.width
            ).width,
            geometry.expandedSize.width,
        ]

        for width in widths {
            // The drawn pill plus its shoulders — what `applyActiveRect` makes
            // clickable while collapsed, which is where a click can land.
            let clickable = geometry.collapsedIslandRect(for: width)
                .insetBy(dx: -Theme.collapsedTopRadius, dy: 0)
            XCTAssertTrue(
                hold.contains(clickable),
                "at \(width)pt a click on the island lands outside the rect that would hold the panel open"
            )
        }
    }

    /// Native beats taste (owner decision 24): every Mac app shows an I-beam
    /// over a text field, and the panel pinned the arrow over the whole active
    /// rect, the Translate editor included. The panel is never key, so the
    /// shape comes from the view's tracking areas, and this is their rule.
    func testTheCursorIsAnIBeamOverTheEditorOnly() {
        let active = CGRect(x: 100, y: 50, width: 400, height: 200)
        let editor = CGRect(x: 120, y: 70, width: 150, height: 120)

        XCTAssertEqual(
            NotchRootView.cursor(at: CGPoint(x: 150, y: 100), active: active, text: [editor]),
            .iBeam,
            "over the editor"
        )
        XCTAssertEqual(
            NotchRootView.cursor(at: CGPoint(x: 400, y: 100), active: active, text: [editor]),
            .arrow,
            "inside the panel, outside the editor"
        )
        XCTAssertNil(
            NotchRootView.cursor(at: CGPoint(x: 10, y: 10), active: active, text: [editor]),
            "outside the panel is not ours to claim"
        )
        XCTAssertNil(
            NotchRootView.cursor(at: CGPoint(x: 150, y: 100), active: .zero, text: [editor]),
            "a collapsed panel claims nothing, whatever the editor last reported"
        )
    }

    /// The editor's frame arrives in the hosting view's space, top-left
    /// origin; the root view is bottom-left, like `activeRect`.
    func testTheEditorFrameIsFlippedIntoTheRootViewsSpace() {
        let flipped = NotchRootView.textRect(fromTopLeft: CGRect(x: 20, y: 30, width: 100, height: 40), windowHeight: 400)
        XCTAssertEqual(flipped, CGRect(x: 20, y: 330, width: 100, height: 40))
        XCTAssertEqual(NotchRootView.textRect(fromTopLeft: .zero, windowHeight: 400), .zero, "no editor, no rect")
    }
}
