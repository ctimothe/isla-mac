import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The island as an assistive client finds it: always one button called
/// "Isla", shut or open, playing or not, locked or not.
///
/// With nothing playing the only element that could open the panel was
/// hidden, so the resting island's tree held nothing but the hosting view and
/// VoiceOver had nothing to find (H-001). Once something opened the panel
/// pinned, nothing in it would close it again: the header strip was a bare tap
/// gesture and the body answered no Escape (G-015). The rail that once sat
/// loose beside the pane's controls went with the tabs (§19.11): the open
/// surface is one named group under the island.
@MainActor
final class IslandAccessibilityTests: XCTestCase {
    /// The lab's pill window: the panel's full width, two notches deep.
    static let pillProbe = CGSize(width: VisualLab.windowSize.width, height: 84)

    private func makeVM(_ isolated: ProbeStores, physical: Bool = true) throws -> NotchViewModel {
        NotchViewModel(geometry: try LabGeometry.make(physical: physical), stores: isolated.stores)
    }

    private func islands(in root: AXNode) -> [AXNode] {
        root.all { $0.role == "AXButton" && $0.label == ProductIdentity.displayName }
    }

    // MARK: - Resting

    func testTheRestingIslandIsOneButtonCalledIsla() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = try makeVM(isolated)
        var clicks = 0
        vm.onIslandClick = { clicks += 1 }

        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: Self.pillProbe)

        let found = islands(in: root)
        XCTAssertEqual(found.count, 1, root.dump)
        let island = try XCTUnwrap(found.first, root.dump)
        XCTAssertEqual(island.value, "Nothing is playing.", root.dump)
        XCTAssertEqual(island.help, "Opens the panel", root.dump)

        // The island's own frame, at the notch: not the whole window, and not
        // a strip floating somewhere the finger on the trackpad cannot find.
        let frame = try XCTUnwrap(island.frame, root.dump)
        XCTAssertEqual(frame.height, LabGeometry.physicalNotch.height, accuracy: 0.5, root.dump)
        XCTAssertLessThanOrEqual(frame.width, LabGeometry.physicalNotch.width + 2 * Theme.collapsedTopRadius, root.dump)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.5, root.dump)
        XCTAssertEqual(frame.midX, Self.pillProbe.width / 2, accuracy: 1, root.dump)

        XCTAssertTrue(island.press(), root.dump)
        XCTAssertEqual(clicks, 1, "pressing the resting island did not open the panel")
    }

    /// A playing pill and a charger moment are the same one element, with a
    /// different value — not a second element swapped in for the first.
    func testThePlayingAndAmbientIslandAreTheSameButtonWithADifferentValue() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(), on: isolated.stores.media)
        let vm = try makeVM(isolated)

        let playing = await AXProbe.tree(of: NotchContentView(vm: vm), size: Self.pillProbe)
        let found = islands(in: playing)
        XCTAssertEqual(found.count, 1, playing.dump)
        let island = try XCTUnwrap(found.first, playing.dump)
        XCTAssertFalse(vm.compactAccessibilityLabel.isEmpty)
        XCTAssertEqual(island.value, vm.compactAccessibilityLabel, playing.dump)
        // The drawn pill, at notch height — this element's frame used to be
        // the whole 700 × 84 window.
        let frame = try XCTUnwrap(island.frame, playing.dump)
        XCTAssertEqual(frame.height, LabGeometry.physicalNotch.height, accuracy: 0.5, playing.dump)
        XCTAssertLessThanOrEqual(frame.width, vm.bodySize.width + 2 * Theme.collapsedTopRadius, playing.dump)

        vm.ambient = .charging(level: 80, isCharging: true)
        let charging = await playing.reread()
        let moments = islands(in: charging)
        XCTAssertEqual(moments.count, 1, charging.dump)
        XCTAssertEqual(moments.first?.value, AmbientActivity.charging(level: 80, isCharging: true).accessibilityLabel,
                       charging.dump)
    }

    /// R8d-H7, in the order VoiceOver walks it (spec §19.12): the island first,
    /// as "Isla", then — with a file kept on the Shelf while Music holds the
    /// island — the Shelf's bubble beside it, as a button of its own with the
    /// Shelf activity's label, and pressing it opens the Shelf. The bubble's
    /// glyph and count are one element, not two more to swipe through, and the
    /// Core Animation layer views that draw the island's shape (backdrop and
    /// overlay, `IslandOutlineHost`) are not elements at all.
    ///
    /// The bubble is drawn here by the shell itself (no outline host is
    /// handed in); in the app it is the same view in a hosting view of its own
    /// that sits above the island's, and "above" is the order VoiceOver reads.
    func testTheIslandReadsAsIslaThenTheShelfBubbleAndNoLayerIsAnnounced() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let shelf = isolated.stores.shelf
        shelf.requestThumbnail = { _, done in done(nil) }
        shelf.makeBookmark = { _ in nil }
        let urls = (0..<3).map { isolated.temp.appendingPathComponent("kept-\($0).txt") }
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
        shelf.add(urls)
        await LabFixtures.play(LabFixtures.Track(), on: isolated.stores.media)
        let vm = try makeVM(isolated)
        var bubbleClicks = 0
        vm.onBubbleClick = { bubbleClicks += 1 }
        XCTAssertEqual(vm.bubbleCount, 3, "the fixture: Music holds the island, three files wait beside it")

        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: Self.pillProbe)
        let nodes = root.flattened
        let island = try XCTUnwrap(nodes.firstIndex { $0.role == "AXButton" && $0.label == ProductIdentity.displayName }, root.dump)
        let bubbleLabel = IslandBubble.label(count: 3)
        let bubble = try XCTUnwrap(nodes.firstIndex { $0.role == "AXButton" && $0.label == bubbleLabel }, root.dump)
        XCTAssertLessThan(island, bubble, "the island first, then the bubble\n\(root.dump)")
        XCTAssertEqual(islands(in: root).count, 1, "one Isla\n\(root.dump)")
        XCTAssertEqual(nodes.filter { $0.label == bubbleLabel }.count, 1, "the bubble is one element\n\(root.dump)")
        XCTAssertEqual(bubbleLabel, "Shelf, 3 items")

        // Its glyph and its count are not announced a second time.
        let strays = nodes.filter { node in
            node.role != "AXButton" && (node.label == "3" || node.value == "3" || node.label.contains("tray"))
        }
        XCTAssertTrue(strays.isEmpty, "the bubble's content is hidden from VoiceOver\n\(root.dump)")

        // Pressing it is a click on the bubble: the Shelf opens.
        XCTAssertTrue(nodes[bubble].press(), root.dump)
        XCTAssertEqual(bubbleClicks, 1)

        // The shell's own tree holds exactly those two buttons and nothing
        // unnamed beside them (the layer views draw; they are not elements).
        XCTAssertTrue(AccessibilitySweepTests.unnamedControls(in: root).isEmpty, root.dump)
        let buttons = root.all(role: "AXButton").map(\.label)
        XCTAssertEqual(Set(buttons), [ProductIdentity.displayName, bubbleLabel], "\(buttons)\n\(root.dump)")
    }

    // MARK: - Open

    func testTheOpenPanelClosesFromItsHeaderAndFromCancel() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = try makeVM(isolated)
        vm.isOpen = true
        vm.surface = .clipboard
        var clicks = 0
        vm.onIslandClick = { clicks += 1 }

        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)

        // The header: the island, now saying it closes.
        let found = islands(in: root)
        XCTAssertEqual(found.count, 1, root.dump)
        let header = try XCTUnwrap(found.first, root.dump)
        XCTAssertEqual(header.help, "Closes the panel", root.dump)
        XCTAssertEqual(header.value, NotchViewModel.Surface.clipboard.title, root.dump)
        // The strip at the top, at notch depth — not the whole panel.
        let headerFrame = try XCTUnwrap(header.frame, root.dump)
        XCTAssertEqual(headerFrame.minY, 0, accuracy: 0.5, root.dump)
        XCTAssertEqual(headerFrame.height, LabGeometry.physicalNotch.height, accuracy: 0.5, root.dump)
        XCTAssertTrue(header.press(), root.dump)
        XCTAssertEqual(clicks, 1, "pressing the open header did not close the panel")

        // No rail: nothing of the tabs is left to find (§19.11).
        XCTAssertNil(root.first(label: "Tabs"), root.dump)

        // The surface: a group named for it, answering Cancel by closing.
        let panes = root.all { $0.role == "AXGroup" && $0.label == NotchViewModel.Surface.clipboard.title }
        XCTAssertEqual(panes.count, 1, root.dump)
        let pane = try XCTUnwrap(panes.first, root.dump)
        XCTAssertTrue(pane.actionNames.contains("AXCancel"), pane.dump)
        XCTAssertTrue(pane.cancel(), pane.dump)
        XCTAssertEqual(clicks, 2, "Cancel on the open pane did not close the panel")
    }

    /// The welcome is not a tab, so its group says what it is instead.
    func testTheWelcomePaneIsAGroupCalledWelcome() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = try makeVM(isolated)
        vm.isOpen = true
        vm.isShowingWelcome = true

        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)

        XCTAssertEqual(root.all { $0.role == "AXGroup" && $0.label == "Welcome" }.count, 1, root.dump)
        XCTAssertEqual(islands(in: root).count, 1, root.dump)
    }

    // MARK: - Locked

    func testTheLockedIslandWithNothingPlayingIsStillIslaAndRefuses() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = try makeVM(isolated)
        vm.isLockedPresentation = true
        var clicks = 0
        vm.onIslandClick = { clicks += 1 }

        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: Self.pillProbe)

        let found = islands(in: root)
        XCTAssertEqual(found.count, 1, root.dump)
        let island = try XCTUnwrap(found.first, root.dump)
        XCTAssertEqual(island.value, "Nothing is playing.", root.dump)
        let frame = try XCTUnwrap(island.frame, root.dump)
        XCTAssertEqual(frame.height, LabGeometry.physicalNotch.height, accuracy: 0.5, root.dump)
        XCTAssertLessThanOrEqual(frame.width, LabGeometry.physicalNotch.width + 2 * Theme.collapsedTopRadius, root.dump)
        XCTAssertEqual(frame.midX, Self.pillProbe.width / 2, accuracy: 1, root.dump)

        XCTAssertTrue(island.press(), root.dump)
        XCTAssertEqual(vm.lockedHoverNudges, 1, "the locked island did not refuse")
        XCTAssertEqual(clicks, 0, "the locked island opened")
    }
}

extension IslandAccessibilityTests {
    /// While the banner or the card holds the song the island has no wings
    /// (redesign 2026-10-15, spec §3.7): it is the resting notch — an element
    /// the notch's own height, no wider than the notch grown for a hover — and
    /// still Isla, still refusing a click with the shake.
    func testTheLockedIslandWhileTheBannerHoldsTheSongHasNoWingsAndStillRefuses() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(), on: isolated.stores.media)
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        vm.isLockedPresentation = true
        var clicks = 0
        vm.onIslandClick = { clicks += 1 }

        XCTAssertTrue(vm.compactMediaActivity.isVisible, "the song is playing: unlocked, this island would have wings")
        XCTAssertTrue(vm.lockSurfacePresentsSong)
        XCTAssertFalse(vm.lockedIslandShowsWings, "one surface per activity")

        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: Self.pillProbe)
        let found = root.all { $0.role == "AXButton" && $0.label == ProductIdentity.displayName }
        XCTAssertEqual(found.count, 1, root.dump)
        let island = try XCTUnwrap(found.first, root.dump)
        let frame = try XCTUnwrap(island.frame, root.dump)
        XCTAssertEqual(frame.height, LabGeometry.physicalNotch.height, accuracy: 0.5, root.dump)
        // The notch and its hover growth (shoulders and 8 pt each side), never
        // the wings: those are `vm.bodySize.width`, a third as wide again.
        XCTAssertEqual(frame.width, vm.lockedIslandSize.width, accuracy: 1, root.dump)
        XCTAssertLessThanOrEqual(
            frame.width,
            LabGeometry.physicalNotch.width + 2 * (Theme.collapsedTopRadius + NotchMetrics.hoverNudgeWidth) + 0.5,
            root.dump
        )
        XCTAssertLessThan(frame.width, vm.bodySize.width, "the wings' width is not what answers")
        XCTAssertEqual(frame.midX, Self.pillProbe.width / 2, accuracy: 1, root.dump)

        XCTAssertTrue(island.press(), root.dump)
        XCTAssertEqual(vm.lockedHoverNudges, 1, "the locked island did not refuse")
        XCTAssertEqual(clicks, 0, "the locked island opened")
    }
}

extension AXNode {
    /// Performs the element's standard cancel, as VoiceOver's VO-Escape and
    /// Switch Control's Escape do.
    @discardableResult
    func cancel() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformCancel")
        guard element.responds(to: selector) else { return false }
        typealias Perform = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Perform.self)(element, selector)
    }
}
