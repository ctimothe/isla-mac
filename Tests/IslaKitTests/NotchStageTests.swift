import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The island's view stack (`NotchStage`, spec §19.12): what is under what, and
/// that the layers the outline is drawn on take no clicks, no drags and no
/// attention from assistive technology.
@MainActor
final class NotchStageTests: XCTestCase {
    private func stage() throws -> (stack: NotchStage.Stack, vm: NotchViewModel) {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let stack = NotchStage.make(viewModel: vm, windowSize: vm.geometry.windowSize)
        let window = NSWindow(contentRect: stack.root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = stack.root
        addTeardownBlock { @MainActor in window.contentView = nil }
        stack.root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (stack, vm)
    }

    func testTheViewsStandBackToFrontAsTheOutlineNeedsThem() throws {
        let (stack, _) = try stage()
        let views = stack.root.subviews
        XCTAssertEqual(views.count, 5)
        XCTAssertTrue(views[0] === stack.outline.backdrop, "the fill and its shadow under everything")
        XCTAssertTrue(views[1] === stack.hosting, "the island")
        XCTAssertTrue(views[2] === stack.bubble, "the Shelf's bubble, outside the island's mask")
        XCTAssertTrue(views[3] === stack.hudStrip, "the level indicator under the open panel, outside the mask")
        XCTAssertTrue(views[4] === stack.outline.overlay, "the line over the content")
        XCTAssertTrue(stack.root.islandHosting === stack.hosting, "the controller's geometry check asks for the island by name")
    }

    func testEveryViewCoversTheWholeWindow() throws {
        let (stack, vm) = try stage()
        for view in stack.root.subviews {
            XCTAssertEqual(view.frame, CGRect(origin: .zero, size: vm.geometry.windowSize), "\(type(of: view))")
            XCTAssertEqual(view.autoresizingMask, [.width, .height])
        }
    }

    func testTheIslandIsCutByTheOutlineOnceItHasBeenDrawn() throws {
        let (stack, _) = try stage()
        XCTAssertTrue(stack.hosting.layer?.mask === stack.outline.maskLayer)
        XCTAssertTrue(stack.outline.isShowing)
        XCTAssertFalse(stack.outline.backdrop.isHidden)
    }

    func testTheLayersTheOutlineIsDrawnOnTakeNoClicks() throws {
        let (stack, vm) = try stage()
        stack.root.activeRect = CGRect(origin: .zero, size: vm.geometry.windowSize)
        let centre = CGPoint(x: vm.geometry.windowSize.width / 2, y: vm.geometry.windowSize.height - 10)
        let hit = stack.root.hitTest(centre)
        XCTAssertFalse(hit === stack.outline.backdrop, "the fill is never what a click lands on")
        XCTAssertFalse(hit === stack.outline.overlay, "nor the line")
        XCTAssertNil(stack.outline.overlay.hitTest(centre))
    }

    /// The bubble's hosting view covers the window and sits above the island's;
    /// left alone it would take every click meant for the island.
    func testTheBubbleTakesOnlyClicksOnTheBubble() throws {
        let (stack, vm) = try stage()
        let window = vm.geometry.windowSize
        stack.root.activeRect = CGRect(origin: .zero, size: window)
        stack.root.bubbleRect = .zero
        let onTheIsland = CGPoint(x: window.width / 2, y: window.height - 12)
        XCTAssertNil(stack.bubble.hitTest(onTheIsland), "no bubble, no region")
        let hit = stack.root.hitTest(onTheIsland)
        XCTAssertFalse(hit === stack.bubble)

        let bubble = CGRect(x: window.width / 2 + 160, y: window.height - 38, width: 54, height: 38)
        stack.root.bubbleRect = bubble
        XCTAssertNil(stack.bubble.hitTest(CGPoint(x: bubble.minX - 30, y: bubble.midY)), "outside the bubble's own rect")
    }

    /// The capsule under the open panel is click-through: its hosting view
    /// covers the window above the island's and answers nothing, wherever the
    /// capsule is, and the panel's hit region never grows to include it.
    func testTheLevelCapsuleTakesNoClicksAndAddsNoHitRegion() throws {
        let (stack, vm) = try stage()
        let window = vm.geometry.windowSize
        vm.isOpen = true
        vm.hudStrip = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let body = vm.openBodySize
        stack.root.activeRect = CGRect(x: (window.width - body.width) / 2, y: window.height - body.height,
                                       width: body.width, height: body.height)
        let capsule = HUDStripLayout.frame(bodySize: body, bottomRadius: vm.openBottomRadius, windowSize: window)
        // AppKit's y runs up from the window's bottom.
        let underTheBody = CGPoint(x: capsule.midX, y: window.height - capsule.midY)
        XCTAssertNil(stack.hudStrip.hitTest(underTheBody), "its hosting view answers nothing")
        XCTAssertNil(stack.hudStrip.hitTest(CGPoint(x: window.width / 2, y: window.height - 10)))
        XCTAssertNil(stack.root.hitTest(underTheBody), "outside the active rect: the click goes to the app below")
        XCTAssertFalse(stack.root.activeRect.contains(underTheBody))
        XCTAssertFalse(stack.hudStrip.acceptsFirstResponder)
    }

    func testTheOutlineViewsAreNotForVoiceOver() throws {
        let (stack, _) = try stage()
        XCTAssertFalse(stack.outline.backdrop.isAccessibilityElement())
        XCTAssertFalse(stack.outline.overlay.isAccessibilityElement())
        XCTAssertTrue(stack.outline.backdrop.accessibilityChildren()?.isEmpty ?? true)
    }
}
