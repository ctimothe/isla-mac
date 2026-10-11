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
/// gesture and the body answered no Escape (G-015). And the rail's five
/// buttons sat loose beside the pane's controls, so reading by position
/// interleaved "Translate From" between Music and Shelf.
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

    // MARK: - Open

    func testTheOpenPanelClosesFromItsHeaderAndFromCancel() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = try makeVM(isolated)
        vm.isOpen = true
        vm.tab = .clipboard
        var clicks = 0
        vm.onIslandClick = { clicks += 1 }

        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)

        // The header: the island, now saying it closes.
        let found = islands(in: root)
        XCTAssertEqual(found.count, 1, root.dump)
        let header = try XCTUnwrap(found.first, root.dump)
        XCTAssertEqual(header.help, "Closes the panel", root.dump)
        XCTAssertEqual(header.value, NotchViewModel.Tab.clipboard.title, root.dump)
        // The strip at the top, at notch depth — not the whole panel.
        let headerFrame = try XCTUnwrap(header.frame, root.dump)
        XCTAssertEqual(headerFrame.minY, 0, accuracy: 0.5, root.dump)
        XCTAssertEqual(headerFrame.height, LabGeometry.physicalNotch.height, accuracy: 0.5, root.dump)
        XCTAssertTrue(header.press(), root.dump)
        XCTAssertEqual(clicks, 1, "pressing the open header did not close the panel")

        // The rail: five buttons together, and nothing of the pane among them.
        let rails = root.all { $0.role == "AXGroup" && $0.label == "Tabs" }
        XCTAssertEqual(rails.count, 1, root.dump)
        let rail = try XCTUnwrap(rails.first, root.dump)
        let inside = Array(rail.flattened.dropFirst())
        XCTAssertEqual(inside.filter { $0.role == "AXButton" }.count, 5, rail.dump)
        XCTAssertEqual(
            Set(inside.map(\.label)),
            Set((NotchViewModel.Tab.contentTabs + NotchViewModel.Tab.utilityTabs).map(\.title)),
            rail.dump
        )

        // The pane: a group named for the tab, answering Cancel by closing.
        let panes = root.all { $0.role == "AXGroup" && $0.label == NotchViewModel.Tab.clipboard.title }
        XCTAssertEqual(panes.count, 1, root.dump)
        let pane = try XCTUnwrap(panes.first, root.dump)
        XCTAssertFalse(rail.flattened.contains { $0.element === pane.element }, root.dump)
        XCTAssertTrue(pane.actionNames.contains("AXCancel"), pane.dump)
        XCTAssertTrue(pane.cancel(), pane.dump)
        XCTAssertEqual(clicks, 2, "Cancel on the open pane did not close the panel")
        // And from the rail, where VoiceOver's cursor is as likely to be.
        XCTAssertTrue(rail.actionNames.contains("AXCancel"), rail.dump)
        XCTAssertTrue(rail.cancel(), rail.dump)
        XCTAssertEqual(clicks, 3, "Cancel on the rail did not close the panel")
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
