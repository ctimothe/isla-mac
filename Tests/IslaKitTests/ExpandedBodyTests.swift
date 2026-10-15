import SwiftUI
import XCTest
@testable import IslaKit

/// The tall body (spec §6): which tab asks for 400, what follows the height —
/// the hover and close rects the controller cuts from `openBodySize`, the
/// rail's foot, the bottom radius — and what must *not* change it: closing the
/// panel, changing tabs.
@MainActor
final class ExpandedBodyTests: XCTestCase {
    private func model() throws -> NotchViewModel {
        NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
    }

    /// A model with a song playing, which is what gives the lyric page anything
    /// to be: with nothing on, the Music tab is the empty player whatever was
    /// asked (`NotchViewModel.showsLyricPage`).
    private func playingModel() async throws -> (NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        await LabFixtures.play(LabFixtures.Track(elapsed: 9), on: isolated.stores.media)
        return (NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores), isolated)
    }

    // MARK: - openBodySize

    /// Redesign 2026-10-15, spec §10: Settings is the one tab that opens tall
    /// without being asked — 400, where R1 held it at 208 and left the comment
    /// that R4 owned its height. Every other tab starts collapsed.
    func testEveryTabOpensStandardUntilItIsExpanded() throws {
        let vm = try model()
        for tab in NotchViewModel.Tab.allCases {
            vm.select(tab)
            XCTAssertEqual(vm.openBodySize.height, tab == .settings ? 400 : 208,
                           "\(tab) starts collapsed: a relaunch does (Settings is always tall)")
            XCTAssertEqual(vm.openBodySize.width, vm.geometry.expandedSize.width, "the width is the setting's")
        }
        XCTAssertTrue(vm.expandedTabs.isEmpty)
    }

    func testAnExpandedTabIsFourHundredTall() throws {
        let vm = try model()
        vm.setExpanded(true, for: .shelf)
        vm.select(.shelf)
        XCTAssertEqual(vm.openBodySize.height, 400)
        XCTAssertEqual(vm.openBodySize.height, NotchMetrics.tallestBody.height)
        XCTAssertTrue(vm.isCurrentTabExpanded)
        vm.setExpanded(false, for: .shelf)
        XCTAssertEqual(vm.openBodySize.height, 208, "Collapse puts it back")
        XCTAssertFalse(vm.isCurrentTabExpanded)
    }

    /// For Music, expanded is the tall *lyric page*: the player never expands.
    func testTheMusicTabIsTallOnlyOnTheLyricPage() async throws {
        let (vm, isolated) = try await playingModel()
        defer { isolated.release() }
        vm.select(.media)
        vm.setExpanded(true, for: .media)
        XCTAssertEqual(vm.musicPage, .player, "the player is not the page that expands")
        XCTAssertEqual(vm.openBodySize.height, 208)

        vm.isShowingLyrics = true
        XCTAssertEqual(vm.musicPage, .tall)
        XCTAssertEqual(vm.openBodySize.height, 400)

        vm.setExpanded(false, for: .media)
        XCTAssertEqual(vm.musicPage, .column)
        XCTAssertEqual(vm.openBodySize.height, 208, "the column is the standard body")

        vm.isShowingLyrics = false
        XCTAssertEqual(vm.musicPage, .player)
    }

    /// R4 made Settings always tall (spec §10): 400 at every width, whatever
    /// `expandedTabs` holds, and nothing can put it elsewhere — no Expand button
    /// reaches it, so a stray insert changes nothing and a stray call is refused.
    func testSettingsIsAlwaysFourHundredTall() throws {
        let vm = try model()
        vm.select(.settings)
        XCTAssertEqual(vm.openBodySize.height, 400)
        vm.setExpanded(true, for: .settings)
        XCTAssertFalse(vm.expandedTabs.contains(.settings), "no Expand button reaches Settings, so nothing remembers it")
        vm.setExpanded(false, for: .settings)
        XCTAssertEqual(vm.openBodySize.height, 400, "and Collapse cannot fold it")
        vm.expandedTabs.insert(.settings)
        XCTAssertEqual(vm.openBodySize.height, 400, "Settings does not read expandedTabs")
        vm.expandedTabs = []
        for expanded: Set<NotchViewModel.Tab> in [[], [.settings], [.shelf, .clipboard, .translate, .media]] {
            XCTAssertEqual(
                NotchViewModel.openBodyHeight(tab: .settings, showingLyrics: false, expandedTabs: expanded), 400
            )
            XCTAssertEqual(
                NotchViewModel.openBodyHeight(tab: .settings, showingLyrics: true, expandedTabs: expanded), 400
            )
        }
        XCTAssertTrue(vm.isCurrentTabExpanded, "400 is the tall body, with its 26 pt bottom radius")
        XCTAssertEqual(SettingsLayout.bodyHeight, NotchMetrics.tallestBody.height)
    }

    /// 400 at every width the body can be (480…620): the height is not a function
    /// of the width at all (`openBodyHeight` takes none), the drawn body while open
    /// is that height, and the form's scrolling area fits inside it at each width —
    /// above the body's 14 pt of bottom padding — so nothing of a section is drawn
    /// past the shape that is meant to hold it.
    func testSettingsIsFourHundredAtEveryWidth() throws {
        let suiteName = "com.ctimothe.isla.settingswidth.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores(), defaults: suite)
        vm.select(.settings)
        vm.isOpen = true
        XCTAssertEqual(vm.openBodySize.height, 400)
        XCTAssertEqual(vm.bodySize.height, 400)
        for width: CGFloat in [480, 500, 539, 540, 560, 620] {
            let form = SettingsLayout.formFrame(bodyWidth: width)
            XCTAssertLessThanOrEqual(form.maxY, 400 - NotchGeometry.bodyBottomPadding, "width \(width)")
            XCTAssertLessThanOrEqual(form.maxX, width - PlayerLayout.bodyInset, "width \(width): inside the body's right padding")
        }
    }

    /// ⌃⌥⌘L on a silent Mac: the page was asked for and there is no song, so the
    /// tab is the empty player — 208 tall, with no lyric tools over it.
    func testTheLyricPageNeedsASongToBeOn() throws {
        let vm = try model()
        vm.select(.media)
        vm.isShowingLyrics = true
        vm.setExpanded(true, for: .media)
        XCTAssertNil(vm.media.track)
        XCTAssertFalse(vm.showsLyricPage)
        XCTAssertEqual(vm.musicPage, .player)
        XCTAssertEqual(vm.openBodySize.height, 208)
    }

    // MARK: - What must not collapse it

    /// "A tab change keeps each tab's own expansion."
    func testATabChangeKeepsEachTabsOwnExpansion() throws {
        let vm = try model()
        vm.setExpanded(true, for: .shelf)
        vm.setExpanded(true, for: .clipboard)
        vm.select(.shelf)
        XCTAssertEqual(vm.openBodySize.height, 400)
        vm.select(.translate)
        XCTAssertEqual(vm.openBodySize.height, 208, "Translate was never expanded")
        vm.select(.clipboard)
        XCTAssertEqual(vm.openBodySize.height, 400, "Clipboard kept its own")
        vm.select(.shelf)
        XCTAssertEqual(vm.openBodySize.height, 400, "and Shelf its own, through the visit elsewhere")
        XCTAssertEqual(vm.expandedTabs, [.shelf, .clipboard])
    }

    /// "Escape and a pointer leaving close the panel as today; they do not
    /// collapse it."
    func testClosingThePanelDoesNotCollapseIt() throws {
        let vm = try model()
        vm.setExpanded(true, for: .shelf)
        vm.select(.shelf)
        vm.isOpen = true
        vm.isOpen = false
        XCTAssertEqual(vm.expandedTabs, [.shelf])
        XCTAssertEqual(vm.openBodySize.height, 400, "the next open is as it was left")
        vm.isOpen = true
        XCTAssertEqual(vm.bodySize.height, 400, "and the drawn body is that height")
    }

    func testLeavingMusicStillFoldsTheLyricPageButNotTheTallMemory() async throws {
        let (vm, isolated) = try await playingModel()
        defer { isolated.release() }
        vm.select(.media)
        vm.isShowingLyrics = true
        vm.setExpanded(true, for: .media)
        vm.select(.shelf)
        XCTAssertFalse(vm.isShowingLyrics, "the page belongs to the Music tab (LyricRoutesTests)")
        XCTAssertTrue(vm.expandedTabs.contains(.media), "but the tall state persists per session (spec §5.1)")
        vm.select(.media)
        XCTAssertEqual(vm.musicPage, .player, "back on the player…")
        vm.isShowingLyrics = true
        XCTAssertEqual(vm.musicPage, .tall, "…and the Lyrics button opens onto where the person left it")
    }

    // MARK: - Everything derived from the size follows it

    /// The rects the controller cuts: the hover rect — which is also the close
    /// area and the open rect while the panel is up — and the content rect the
    /// active rect is made of, at 208 and at 400. The window is cut once for
    /// 620 × 400 and never resized, so the taller body fits inside it.
    func testTheRectsFollowTheBodyHeight() throws {
        let vm = try model()
        let geometry = vm.geometry
        vm.select(.shelf)
        let standard = vm.openBodySize
        vm.setExpanded(true, for: .shelf)
        let tall = vm.openBodySize

        XCTAssertEqual(tall.height - standard.height, 192)
        XCTAssertEqual(geometry.hoverRect(for: tall).height - geometry.hoverRect(for: standard).height, 192)
        XCTAssertEqual(
            geometry.hoverRect(for: tall).minY, geometry.hoverRect(for: standard).minY - 192,
            "the area grows down from the top edge, which stays where it is"
        )
        XCTAssertEqual(geometry.hoverRect(for: tall).width, geometry.hoverRect(for: standard).width)
        XCTAssertEqual(geometry.contentRect(for: tall).height, 400)
        XCTAssertEqual(geometry.contentRect(for: tall).maxY, geometry.contentRect(for: standard).maxY, "hung from the same top")
        XCTAssertLessThanOrEqual(
            geometry.contentRect(for: tall).height, geometry.windowSize.height,
            "the window is never resized: it is already cut for the tall body"
        )
        XCTAssertLessThanOrEqual(geometry.contentRect(for: tall).minY, geometry.contentRect(for: standard).minY)
        XCTAssertEqual(geometry.windowSize, NotchMetrics.maximumWindow)
    }

    /// The same value feeds the drawn body, so the shape, the clip and the rects
    /// can never disagree about the height.
    func testTheDrawnBodyIsTheOpenBodyWhileOpen() throws {
        let vm = try model()
        vm.setExpanded(true, for: .translate)
        vm.select(.translate)
        vm.isOpen = true
        XCTAssertEqual(vm.bodySize, vm.openBodySize)
        XCTAssertEqual(vm.bodySize.height, 400)
    }

    /// Settings rides the foot at `h − 39`: the body's height less the rail's
    /// 14 pt of padding and its own icon; the four top items hang from the header
    /// and never move.
    func testTheRailsFootRidesTheBodyAndItsTopItemsStayPut() throws {
        let geometry = try LabGeometry.make()
        let standard = geometry.contentHeight(forBodyHeight: 208)
        let tall = geometry.contentHeight(forBodyHeight: 400)
        XCTAssertEqual(standard, geometry.standardContentHeight)
        XCTAssertEqual(tall - standard, 192, "the rail's column grows by exactly what the body does")
        XCTAssertEqual(
            geometry.notchSize.height + tall + NotchGeometry.bodyBottomPadding, 400,
            "its foot ends 14 pt above the body's"
        )
        // The icons' own height is a function of the standard column alone, so
        // the top four are the same size and in the same places on both bodies.
        XCTAssertEqual(geometry.railIconHeight, min(24, ((standard - 4 * NotchGeometry.railSpacing) / 5).rounded(.down)))
    }

    // MARK: - The Expand button

    func testExpandAndCollapseNameThemselvesForTheirState() {
        XCTAssertEqual(ExpandCollapseButton.label(isExpanded: false), "Expand")
        XCTAssertEqual(ExpandCollapseButton.label(isExpanded: true), "Collapse")
        XCTAssertEqual(ExpandCollapseButton.symbol(isExpanded: false), "rectangle.expand.vertical")
        XCTAssertEqual(ExpandCollapseButton.symbol(isExpanded: true), "rectangle.compress.vertical")
    }

    /// The button is drawn from a binding alone, 22 × 22, and reachable by name —
    /// the contract the other three tabs will use it by.
    func testTheButtonIsOneTwentyTwoPointTargetNamedForItsState() async throws {
        final class Box { var expanded = false }
        let box = Box()
        let binding = Binding(get: { box.expanded }, set: { box.expanded = $0 })
        let root = await AXProbe.tree(of: ExpandCollapseButton(isExpanded: binding), size: CGSize(width: 40, height: 40))
        let button = try XCTUnwrap(root.first(label: "Expand"), root.dump)
        XCTAssertEqual(try XCTUnwrap(button.frame).width, 22, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(button.frame).height, 22, accuracy: 1)
        XCTAssertTrue(button.press(), root.dump)
        XCTAssertTrue(box.expanded, "pressing writes the binding")
    }
}
