import SwiftUI
import XCTest
@testable import IslaKit

/// Settings mounts its content once the old pane has gone (redesign spec
/// §19.3, amended 2026-10-18, and §19.12).
///
/// The form and the sidebar are the heaviest tree any surface builds; mounted
/// in the frame the swap begins, they landed on the same frame as the island's
/// own first move and the old pane's leaving, and that frame was the morph's
/// costliest (20-23 ms of main-thread CPU against a 8.3 ms slot at 120 Hz, the
/// hitch lab's `worstFrameCPUMs`). The new pane is transparent until the old
/// one has finished leaving (`Theme.swapIn` is delayed by
/// `Theme.swapOutDuration`), so building it then costs a frame nobody can see.
/// These hold that the content is not there before the delay and is there
/// after it, that the pane drawn on its own (the layout tests, the visual lab)
/// still has it at once, and that the shell asks for the delay on every road
/// into Settings.
@MainActor
final class SettingsStagedMountTests: XCTestCase {
    private let paneSize = SettingsFixture.paneSize()

    private func hasForm(_ root: AXNode) -> Bool {
        root.first(label: SettingsRowID.launchAtLogin.title) != nil
    }

    override func tearDown() async throws {
        SystemAppearance.shared.resetForTests()
    }

    private func hasSidebar(_ root: AXNode) -> Bool {
        root.first(label: SettingsSection.lockScreen.title) != nil
    }

    /// The tree once SwiftUI has stopped changing it: two readings in a row
    /// that agree.
    ///
    /// The shell tests below used to read at once and take a form there as
    /// proof it came with the island. The delay they guard is
    /// `Theme.swapOutDuration`, 80 ms, and on a Mac at load 50 to 160
    /// (2026-10-29) one reading takes longer than that, so it never could tell
    /// the two apart; and SwiftUI updates its accessibility tree
    /// asynchronously, so it caught the header before the page and failed
    /// three runs in five on code nobody had touched. Whether an arrival waits
    /// is decided by `arrivedOverAnOpenSurface` alone (the one `mountsAfter:`
    /// in the shell, pinned above), so the tests assert that flag at the moment
    /// the island opens and read the tree only for what it ends up showing.
    private func settledTree(_ host: AXProbe.Host) async -> AXNode {
        var root = await AXProbe.read(host, settle: 0.05)
        for _ in 0..<40 {
            let next = await AXProbe.read(host, settle: 0.05)
            if next.dump == root.dump { return next }
            root = next
        }
        return root
    }

    // MARK: - The pane on its own

    func testTheContentIsNotThereBeforeTheDelay() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let pane = SettingsFixture.pane(isolated, section: .general, mountsAfter: 30)
        // A pane that has built nothing has no tree to read: a marker beside
        // it keeps the probe's "came back empty" check meaning what it says.
        let beside = ZStack(alignment: .bottom) { pane; Text("probe marker") }
        let root = await AXProbe.tree(of: beside, size: paneSize, settle: 0.25)
        XCTAssertTrue(root.dump.contains("probe marker"), root.dump)
        XCTAssertFalse(hasForm(root), "the form is built after the delay, not with the pane\n\(root.dump)")
        XCTAssertFalse(hasSidebar(root), "nor the sidebar\n\(root.dump)")
    }

    func testTheContentIsThereOnceTheDelayHasPassed() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let pane = SettingsFixture.pane(isolated, section: .general, mountsAfter: 0.03)
        let root = await AXProbe.tree(of: pane, size: paneSize, settle: 0.4)
        XCTAssertTrue(hasForm(root), root.dump)
        XCTAssertTrue(hasSidebar(root), root.dump)
    }

    /// Off by default, and off is the pane the layout tests and the visual lab
    /// draw: no waiting, the first reading already has everything.
    func testWithoutStagingTheContentIsThereAtOnce() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let pane = SettingsFixture.pane(isolated, section: .general)
        let root = await AXProbe.tree(of: pane, size: paneSize, settle: 0)
        XCTAssertTrue(hasForm(root), root.dump)
        XCTAssertTrue(hasSidebar(root), root.dump)
    }

    func testTheDefaultIsNoStaging() {
        XCTAssertEqual(SettingsPane.defaultMountDelay, 0)
    }

    // MARK: - The shell

    /// The delay the shell asks for is the leaving pane's whole duration, at
    /// which the arriving one has not yet begun to show — and only for a swap.
    func testTheShellStagesASwapByTheLeavingPanesDuration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/IslaKit/UI/NotchContentView.swift"), encoding: .utf8)
        XCTAssertTrue(shell.contains("mountsAfter: vm.arrivedOverAnOpenSurface ? Theme.swapOutDuration : 0"),
                      "pane(for: .settings) names Theme.swapOutDuration, not a number of its own")
    }

    /// Which arrival is a swap is the model's to say, and it says it for as
    /// long as the pane lives: a surface that changes in an island that is
    /// open is one; whatever is on screen when the island opens is not.
    func testTheModelSaysWhichArrivalsAreSwaps() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)

        vm.surface = .settings
        XCTAssertFalse(vm.arrivedOverAnOpenSurface, "chosen while shut, as the controller does before it opens")
        vm.isOpen = true
        XCTAssertFalse(vm.arrivedOverAnOpenSurface, "and opening with it brings it along")
        vm.surface = .player
        XCTAssertTrue(vm.arrivedOverAnOpenSurface, "a change inside an open island is a swap")
        vm.surface = .player
        XCTAssertTrue(vm.arrivedOverAnOpenSurface, "choosing what is already there changes nothing")
        vm.surface = .settings
        XCTAssertTrue(vm.arrivedOverAnOpenSurface)
        vm.isOpen = false
        vm.isOpen = true
        XCTAssertFalse(vm.arrivedOverAnOpenSurface, "reopening onto the same surface is an opening, not a swap")
    }

    private func shell(
        _ isolated: ProbeStores, reduceMotion: Bool
    ) throws -> (vm: NotchViewModel, host: AXProbe.Host) {
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        SystemAppearance.shared.overrideForTests(reduceMotion: reduceMotion)
        let host = AXProbe.present(NotchContentView(vm: vm), size: size)
        return (vm, host)
    }

    /// From the player in an open island: the swap. That it waits is the
    /// flag's to say, as for the other shell tests here: the one `mountsAfter:`
    /// is pinned above, and the pane's own wait by the tests of the pane on
    /// its own. This one still took an "early" reading at settle 0 and failed
    /// on the CI runner on 2026-11-04 (Reduce Motion on, the form already
    /// there), because one reading there outlasts the 80 ms it was racing.
    func testSettingsOpenedFromThePlayerArrivesAfterTheOldPaneHasGone() async throws {
        for reduceMotion in [false, true] {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let (vm, host) = try shell(isolated, reduceMotion: reduceMotion)
            vm.isOpen = true
            vm.surface = .player
            _ = await AXProbe.read(host, settle: 0.1)

            withAnimation(Theme.island(reduceMotion: reduceMotion)) { vm.open(.settings) }
            XCTAssertTrue(vm.arrivedOverAnOpenSurface,
                          "reduceMotion \(reduceMotion): a swap, so the pane waits Theme.swapOutDuration")
            let late = await settledTree(host)
            XCTAssertTrue(hasForm(late), "reduceMotion \(reduceMotion): there once the old pane has gone\n\(late.dump)")
            XCTAssertTrue(hasSidebar(late), late.dump)
        }
    }

    /// Straight onto Settings from the shut island (the Open Settings road,
    /// the service, a shortcut) the content comes in on the island's own
    /// `Theme.paneIn`, which is already 35 % opaque 0.08 s in: waiting for it
    /// would show a blank pane and then a form arriving late. It is built with
    /// the island, as it always was.
    func testSettingsOpenedFromClosedIsBuiltWithTheIsland() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let (vm, host) = try shell(isolated, reduceMotion: false)
        _ = await AXProbe.read(host, settle: 0.1)

        vm.surface = .settings
        withAnimation(Theme.island(reduceMotion: false)) { vm.isOpen = true }
        XCTAssertFalse(vm.arrivedOverAnOpenSurface, "an opening is not a swap, so the pane asks for no delay")
        let root = await settledTree(host)
        XCTAssertTrue(hasForm(root), root.dump)
    }

    /// The swap's flag must not outlive the visit: Settings reached by the
    /// gear, the island shut, and opened again onto Settings is an opening.
    func testSettingsReopenedAfterASwapIsBuiltWithTheIsland() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let (vm, host) = try shell(isolated, reduceMotion: false)
        vm.isOpen = true
        vm.surface = .player
        _ = await AXProbe.read(host, settle: 0.1)
        withAnimation(Theme.island(reduceMotion: false)) { vm.open(.settings) }
        _ = await AXProbe.read(host, settle: Theme.swapOutDuration + 0.3)

        vm.isOpen = false
        _ = await AXProbe.read(host, settle: 0.4)
        withAnimation(Theme.island(reduceMotion: false)) { vm.isOpen = true }
        XCTAssertFalse(vm.arrivedOverAnOpenSurface, "a reopening is an opening, not a swap")
        let root = await settledTree(host)
        XCTAssertTrue(hasForm(root), root.dump)
    }

    /// Other surfaces are not delayed: only the heavy one asks, and the
    /// shell asks in one place.
    func testNoOtherSurfaceWaits() async throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shellSource = try String(
            contentsOf: sources.appendingPathComponent("Sources/IslaKit/UI/NotchContentView.swift"), encoding: .utf8)
        XCTAssertEqual(shellSource.components(separatedBy: "mountsAfter:").count - 1, 1,
                       "only pane(for: .settings) passes a mount delay")

        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let (vm, host) = try shell(isolated, reduceMotion: false)
        vm.isOpen = true
        vm.surface = .clipboard
        let root = await settledTree(host)
        XCTAssertNotNil(
            root.all { $0.role == "AXGroup" && $0.label == NotchViewModel.Surface.clipboard.title }.first, root.dump)
    }
}
