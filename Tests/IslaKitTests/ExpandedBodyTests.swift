import SwiftUI
import XCTest
@testable import IslaKit

/// What the open body's size follows (spec §19.6–§19.8): one size per surface,
/// the hover and close rects the controller cuts from `openBodySize`, and what
/// must *not* change it: closing the panel. It replaces the tall body (spec §6)
/// — which tab asked for 400, Expand and Collapse, the rail's foot and the bottom
/// radius that went with 400 — all withdrawn by §19.11: a surface has the size
/// it is drawn for, and nothing asks for another.
@MainActor
final class ExpandedBodyTests: XCTestCase {
    private func model() throws -> NotchViewModel {
        NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
    }

    /// A model with a song playing, which is what gives the stage anything to
    /// be: with nothing on, the stage is the empty player whatever was asked
    /// (`NotchViewModel.presented`).
    private func playingModel() async throws -> (NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        await LabFixtures.play(LabFixtures.Track(elapsed: 9), on: isolated.stores.media)
        return (NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores), isolated)
    }

    // MARK: - openBodySize

    /// Every surface starts at the size it is drawn for, whichever was open
    /// before: nothing is remembered per surface, so there is nothing to
    /// collapse. The summoned surfaces run the panel's width; the player, the
    /// tray and Tools their own.
    func testEverySurfaceOpensAtItsOneSize() async throws {
        let (vm, isolated) = try await playingModel()
        defer { isolated.release() }
        let notch = vm.geometry.notchSize
        let width = vm.geometry.expandedSize.width
        let heights: [NotchViewModel.Surface: CGFloat] = [
            .player: 198, .stage: 400, .tray: 158, .tools: 204, .clipboard: 300, .translate: 268, .settings: 400,
        ]
        for surface in NotchViewModel.Surface.reachable + NotchViewModel.Surface.reachable.reversed() {
            vm.open(surface)
            XCTAssertEqual(vm.presented, surface, "a song is playing: nothing is substituted")
            XCTAssertEqual(
                vm.openBodySize.height, heights[surface]! - SurfaceLayout.referenceNotchHeight + notch.height,
                accuracy: 0.001, "\(surface): the board's height, moved with the notch"
            )
            XCTAssertEqual(
                vm.openBodySize, SurfaceLayout.bodySize(for: surface, bodyWidth: width, notch: notch), "\(surface)"
            )
        }
        vm.open(.stage)
        XCTAssertEqual(vm.openBodySize.width, vm.geometry.expandedSize.width, "the width is the setting's")
        vm.open(.tools)
        XCTAssertEqual(vm.openBodySize.width, 480, "Tools is 480 whatever the setting says")
    }

    /// §19.8: Settings is 400 at every width the body can be (480…620): the
    /// height is not a function of the width at all, the drawn body while open
    /// is that height, and the form's scrolling area fits inside it at each width
    /// — above the body's 14 pt of bottom padding — so nothing of a section is
    /// drawn past the shape that is meant to hold it.
    func testSettingsIsFourHundredAtEveryWidth() throws {
        let suiteName = "com.ctimothe.isla.settingswidth.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores(), defaults: suite)
        vm.open(.settings)
        vm.isOpen = true
        let body = vm.openBodySize.height - vm.geometry.notchSize.height
        XCTAssertEqual(body, 400 - 38, accuracy: 0.001, "the content is 362 under the header row on any notch")
        XCTAssertEqual(vm.bodySize, vm.openBodySize)
        XCTAssertEqual(SettingsLayout.bodyHeight, 400)
        for width: CGFloat in [480, 500, 539, 540, 560, 620] {
            let form = SettingsLayout.formFrame(bodyWidth: width)
            XCTAssertLessThanOrEqual(form.maxY, 400 - SettingsLayout.bottomInset, "width \(width)")
            XCTAssertEqual(SettingsLayout.bottomInset, 14)
            XCTAssertLessThanOrEqual(form.maxX, width - 14, "width \(width): inside the body's right padding")
            XCTAssertEqual(SurfaceLayout.bodySize(for: .settings, bodyWidth: width, notch: vm.geometry.notchSize).height,
                           vm.openBodySize.height, "the height is not a function of the width")
        }
    }

    /// ⌃⌥⌘L on a silent Mac: the stage was asked for and there is no song, so
    /// what is drawn is the empty player — 198 tall, not 400 for nothing, with no
    /// lyric tools over it. The choice is kept: a song arriving puts the stage up.
    func testTheStageNeedsASongToBeOn() async throws {
        let vm = try model()
        vm.openStage()
        XCTAssertNil(vm.media.track)
        XCTAssertTrue(vm.isShowingLyrics, "asked for")
        XCTAssertEqual(vm.presented, .player)
        let notch = vm.geometry.notchSize
        XCTAssertEqual(
            vm.openBodySize, SurfaceLayout.bodySize(for: .player, bodyWidth: vm.geometry.expandedSize.width, notch: notch)
        )
        XCTAssertEqual(vm.openBodySize.height, 198 - 38 + notch.height, accuracy: 0.001)
        XCTAssertEqual(vm.openTopRadius, 34)
        XCTAssertEqual(vm.openBottomRadius, 44)
    }

    // MARK: - What must not change it

    /// "Escape and a pointer leaving close the panel as today; they do not
    /// change what it opens onto."
    func testClosingThePanelKeepsTheSurfaceAndItsSize() throws {
        let vm = try model()
        vm.open(.settings)
        vm.isOpen = true
        let size = vm.openBodySize
        vm.isOpen = false
        XCTAssertEqual(vm.surface, .settings)
        XCTAssertEqual(vm.openBodySize, size, "the next open is as it was left")
        vm.isOpen = true
        XCTAssertEqual(vm.bodySize, size, "and the drawn body is that size")
    }

    // MARK: - Everything derived from the size follows it

    /// The rects the controller cuts: the hover rect — which is also the close
    /// area and the open rect while the panel is up — and the content rect the
    /// active rect is made of, for Clipboard (300) and Settings (400), which run
    /// the same width. The window is cut once for 620 × 444 and never resized, so
    /// the taller body fits inside it.
    func testTheRectsFollowTheBodyHeight() throws {
        let vm = try model()
        let geometry = vm.geometry
        vm.open(.clipboard)
        let shorter = vm.openBodySize
        vm.open(.settings)
        let taller = vm.openBodySize
        let difference = taller.height - shorter.height
        XCTAssertEqual(difference, 100, accuracy: 0.001)
        XCTAssertEqual(taller.width, shorter.width)

        XCTAssertEqual(geometry.hoverRect(for: taller).height - geometry.hoverRect(for: shorter).height, difference, accuracy: 0.001)
        XCTAssertEqual(
            geometry.hoverRect(for: taller).minY, geometry.hoverRect(for: shorter).minY - difference, accuracy: 0.001,
            "the area grows down from the top edge, which stays where it is"
        )
        XCTAssertEqual(geometry.hoverRect(for: taller).width, geometry.hoverRect(for: shorter).width)
        XCTAssertEqual(geometry.contentRect(for: taller).height, taller.height)
        XCTAssertEqual(geometry.contentRect(for: taller).maxY, geometry.contentRect(for: shorter).maxY, "hung from the same top")
        XCTAssertLessThanOrEqual(
            geometry.contentRect(for: taller).height, geometry.windowSize.height,
            "the window is never resized: it is already cut for the tallest surface"
        )
        XCTAssertLessThanOrEqual(geometry.contentRect(for: taller).minY, geometry.contentRect(for: shorter).minY)
        XCTAssertEqual(geometry.windowSize, NotchMetrics.maximumWindow)
    }

    /// The same value feeds the drawn body, so the shape, the clip and the rects
    /// can never disagree about the height.
    func testTheDrawnBodyIsTheOpenBodyWhileOpen() throws {
        let vm = try model()
        vm.open(.translate)
        vm.isOpen = true
        XCTAssertEqual(vm.bodySize, vm.openBodySize)
        XCTAssertEqual(vm.bodySize.height, 268 - 38 + vm.geometry.notchSize.height, accuracy: 0.001)
    }

    /// The drop surface is drawn over whatever is chosen, at its own size
    /// (176), and the rects follow it for the length of the drag.
    func testTheDropSurfaceHasItsOwnSizeWhileADragIsOver() throws {
        let vm = try model()
        vm.open(.clipboard)
        let clipboard = vm.openBodySize
        vm.isDropTargeted = true
        XCTAssertEqual(vm.openBodySize.height, 176 - 38 + vm.geometry.notchSize.height, accuracy: 0.001)
        XCTAssertEqual(vm.bodySize, vm.openBodySize)
        XCTAssertEqual(vm.openTopRadius, 24)
        XCTAssertEqual(vm.openBottomRadius, 34)
        vm.isDropTargeted = false
        XCTAssertEqual(vm.openBodySize, clipboard, "and gives the surface underneath back")
    }
}
