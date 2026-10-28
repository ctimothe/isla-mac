import AppKit
import XCTest
@testable import IslaKit

/// Keeping off a built-in display that has Apple's own island (announced
/// 2026-10-28), or that the person switched Isla off on. Isla's synthetic
/// island used to be drawn at the top centre of any display macOS reported no
/// notch for — on top of Apple's.
@MainActor
final class NativeIslandTests: XCTestCase {
    typealias Facts = NotchGeometry.ScreenFacts

    private func facts(notch: Bool = false, remembered: Bool = false, builtIn: Bool = false) -> Facts {
        Facts(reportsNotch: notch, rememberedNotch: remembered, isBuiltIn: builtIn)
    }

    private func pick(_ screens: [Facts], avoiding: Bool) -> String {
        guard let chosen = NotchGeometry.pick(screens, avoidingBuiltIn: avoiding) else { return "nil" }
        return "\(chosen.index),\(chosen.stepsAside)"
    }

    // MARK: - Which display

    func testNoScreensPickNothing() {
        XCTAssertEqual(pick([], avoiding: false), "nil")
        XCTAssertEqual(pick([], avoiding: true), "nil")
    }

    func testOneNotchedBuiltInDisplayIsChosenAndOnlyStepsAsideWhenAvoiding() {
        let screens = [facts(notch: true, builtIn: true)]
        XCTAssertEqual(pick(screens, avoiding: false), "0,false")
        XCTAssertEqual(pick(screens, avoiding: true), "0,true", "still chosen: the panel needs a display, and draws nothing on it")
    }

    func testAvoidingMovesToTheExternalDisplayAndDoesNotStepAside() {
        let screens = [facts(notch: true, builtIn: true), facts()]
        XCTAssertEqual(pick(screens, avoiding: true), "1,false")
    }

    func testNotAvoidingKeepsTodaysChoiceOfTheNotchedBuiltInDisplay() {
        XCTAssertEqual(pick([facts(notch: true, builtIn: true), facts()], avoiding: false), "0,false")
        XCTAssertEqual(pick([facts(), facts(notch: true, builtIn: true)], avoiding: false), "1,false")
    }

    func testTodaysOrderIsReportedThenRememberedThenFirst() {
        // Reported beats remembered, whatever the order.
        XCTAssertEqual(pick([facts(remembered: true), facts(notch: true)], avoiding: false), "1,false")
        // A glitched reading on a remembered display still counts as notched.
        XCTAssertEqual(pick([facts(), facts(remembered: true)], avoiding: false), "1,false")
        // Nothing notched, nothing remembered: the first.
        XCTAssertEqual(pick([facts(), facts()], avoiding: false), "0,false")
    }

    func testTwoExternalDisplaysKeepTheSameOrderWhileAvoiding() {
        let reported = [facts(builtIn: true), facts(), facts(notch: true), facts(remembered: true)]
        XCTAssertEqual(pick(reported, avoiding: true), "2,false", "the first that reports a notch")
        let remembered = [facts(notch: true, builtIn: true), facts(), facts(remembered: true)]
        XCTAssertEqual(pick(remembered, avoiding: true), "2,false", "else the first remembered")
        let plain = [facts(notch: true, builtIn: true), facts(), facts()]
        XCTAssertEqual(pick(plain, avoiding: true), "1,false", "else the first")
    }

    func testAvoidingWithNoBuiltInDisplayAtAllDoesNotStepAside() {
        XCTAssertEqual(pick([facts(), facts()], avoiding: true), "0,false", "a closed laptop driving only external displays")
    }

    // MARK: - The switch

    func testAStoredChoiceWinsAndOtherwiseOnlyAMacWithAppleIslandAvoids() {
        XCTAssertFalse(NativeIsland.avoidsBuiltIn(stored: true, nativeIsland: true), "shown on purpose")
        XCTAssertTrue(NativeIsland.avoidsBuiltIn(stored: false, nativeIsland: false), "hidden on purpose")
        XCTAssertTrue(NativeIsland.avoidsBuiltIn(stored: nil, nativeIsland: true))
        XCTAssertFalse(NativeIsland.avoidsBuiltIn(stored: nil, nativeIsland: false))
    }

    func testNoModelIsNamedUntilAppleNamesThem() {
        XCTAssertTrue(NativeIsland.models.isEmpty)
        XCTAssertFalse(NativeIsland.onThisMac)
    }

    // MARK: - What it changes

    func testSteppingAsideRebuildsThePanel() throws {
        let shown = try LabGeometry.make(physical: true)
        var aside = shown
        aside.stepsAside = true
        XCTAssertTrue(shown.matches(shown))
        XCTAssertFalse(shown.matches(aside))
        XCTAssertFalse(aside.matches(shown))
        XCTAssertTrue(aside.matches(aside))
    }

    func testAMomentIsQuietWhileTheIslandStandsAside() {
        XCTAssertTrue(NotchController.momentsQuiet(
            fullScreenFrontmost: false, displayMirrored: false, soleExternalDisplay: false, stepsAside: true
        ))
        XCTAssertFalse(NotchController.momentsQuiet(
            fullScreenFrontmost: false, displayMirrored: false, soleExternalDisplay: false, stepsAside: false
        ))
    }

    /// The shut island takes no click and lights on no hover while it stands
    /// aside, and the same controller gives every region back when it opens.
    func testAShutIslandThatStandsAsideCutsNoRegionAndAnOpenOneDoes() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        var geometry = try LabGeometry.make(physical: true)
        geometry.stepsAside = true
        let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)

        controller.refreshCollapsedRects()
        XCTAssertEqual(root.activeRect, .zero)
        XCTAssertEqual(root.dropRect, .zero)
        XCTAssertEqual(root.bubbleRect, .zero)
        XCTAssertEqual(controller.pointer.interactiveRect, .zero)
        XCTAssertEqual(controller.pointer.hoverRect, .zero)
        XCTAssertEqual(controller.pointer.openRect, .zero)
        XCTAssertEqual(controller.pointer.bubbleRect, .zero)
        XCTAssertEqual(controller.pointer.shelfRect, .zero)
        XCTAssertTrue(root.refusesDrops, "an empty drop rect must not read as \"accept anywhere\"")

        vm.isOpen = true
        controller.refreshOpenRects(animated: false)
        XCTAssertFalse(root.refusesDrops)
        XCTAssertFalse(root.activeRect.isEmpty, "opened by a hot key or the menu, the panel is clickable")
        XCTAssertFalse(controller.pointer.interactiveRect.isEmpty)
        XCTAssertFalse(controller.pointer.openRect.isEmpty)
    }

    func testAShutIslandThatIsShownKeepsItsRegions() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)

        controller.refreshCollapsedRects()
        XCTAssertFalse(root.activeRect.isEmpty)
        XCTAssertFalse(controller.pointer.interactiveRect.isEmpty)
        XCTAssertFalse(controller.pointer.hoverRect.isEmpty)
        XCTAssertFalse(controller.pointer.openRect.isEmpty)
    }

    /// Whatever the screens are, not avoiding is the geometry every Mac had.
    func testNotAvoidingNeverStepsAside() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(avoidingBuiltIn: false), "a test host always has a screen")
        XCTAssertFalse(geometry.stepsAside)
    }

    // MARK: - The row

    func testTheRowSitsAfterPanelWidthOnALaptopAndNowhereElse() {
        var laptop = SettingsContext()
        laptop.hasBattery = true
        let rows = SettingsTable.rows(for: .general, context: laptop)
        let width = rows.firstIndex(of: .panelWidth)
        XCTAssertNotNil(width)
        XCTAssertEqual(rows.firstIndex(of: .showOnBuiltInDisplay), width.map { $0 + 1 })

        var desk = SettingsContext()
        desk.hasBattery = false
        XCTAssertFalse(SettingsTable.rows(for: .general, context: desk).contains(.showOnBuiltInDisplay))
    }

    func testTheRowIsOneSwitchOnTheDisplayKey() {
        XCTAssertEqual(SettingsRowID.showOnBuiltInDisplay.kind, .toggle)
        XCTAssertEqual(SettingsRowID.showOnBuiltInDisplay.key, "showOnBuiltInDisplay")
        XCTAssertEqual(SettingsRowID.showOnBuiltInDisplay.key, NativeIsland.showOnBuiltInKey)
        XCTAssertEqual(SettingsRowID.showOnBuiltInDisplay.defaultValue, .on)
        XCTAssertEqual(SettingsRowID.showOnBuiltInDisplay.title, "Show on Built-in Display")
        XCTAssertEqual(SettingsRowID.showOnBuiltInDisplay.icon, "laptopcomputer")
    }
}
