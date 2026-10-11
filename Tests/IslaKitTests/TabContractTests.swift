import AppKit
import XCTest
@testable import IslaKit

/// The rail has two configurations, and this suite holds both (Prompter spec
/// 5.1). With the Prompter's switch off, the default, the island has exactly
/// the five tabs the 2026-08-22 withdrawal left; with it on there is a sixth,
/// `prompter`, after Translate. Everything the rail, the Welcome legend and the
/// icon height read comes from `visibleTabs(prompterEnabled:)`, so the two
/// configurations are asserted once, here.
@MainActor
final class TabContractTests: XCTestCase {
    private typealias Tab = NotchViewModel.Tab

    // MARK: - The visible set

    func testWithTheSwitchOffTheRailIsTheFiveTabsInOrder() {
        XCTAssertEqual(
            Tab.visibleTabs(prompterEnabled: false),
            [.media, .shelf, .clipboard, .translate, .settings]
        )
    }

    func testWithTheSwitchOnPrompterIsASixthTabAfterTranslate() {
        XCTAssertEqual(
            Tab.visibleTabs(prompterEnabled: true),
            [.media, .shelf, .clipboard, .translate, .prompter, .settings]
        )
        // Settings stays last, below the gap: it is not somewhere to land on
        // the way to a track, and a sixth tab does not change that.
        XCTAssertEqual(Tab.visibleTabs(prompterEnabled: true).last, .settings)
    }

    /// The rail draws the content run and then a footer, from the same list:
    /// the split is a property of the tab, not a second list to keep in step.
    func testTheRailSplitsTheSameListIntoARunAndAFooter() {
        for enabled in [false, true] {
            let all = Tab.visibleTabs(prompterEnabled: enabled)
            let split = Tab.railGroups(prompterEnabled: enabled)
            XCTAssertEqual(split.content + split.footer, all)
            XCTAssertEqual(split.footer, [.settings])
        }
    }

    func testOnlyTranslateAndPrompterTakeTheKeyboard() {
        XCTAssertEqual(Tab.allCases.filter(\.needsKeyboard), [.translate, .prompter])
        XCTAssertTrue(Tab.prompter.needsKeyboard)
    }

    /// Snippets, Calendar, Notes and the Teleprompter were dropped from the
    /// product deliberately, not hidden. The Prompter is a new, optional
    /// feature rather than the old Teleprompter coming back, so in the default
    /// configuration the absence is still total: no tab, no privacy section.
    func testDroppedFeaturesAreAbsentEntirelyInTheDefaultConfiguration() {
        XCTAssertEqual(
            Tab.visibleTabs(prompterEnabled: false).map(\.rawValue).sorted(),
            ["clipboard", "media", "settings", "shelf", "translate"]
        )
        XCTAssertEqual(
            PrivacyMode.Section.shown(prompterEnabled: false).map(\.rawValue).sorted(),
            ["clipboard", "translate"]
        )
    }

    /// Nothing that was removed has come back under another name, in either
    /// configuration. (`teleprompter` is the old tab's name; the new feature
    /// is the Prompter.)
    func testRemovedFeaturesStayRemovedInBothConfigurations() {
        let removed: Set<String> = ["notes", "snippets", "calendar", "teleprompter"]
        for enabled in [false, true] {
            let names = Set(Tab.visibleTabs(prompterEnabled: enabled).map(\.rawValue))
            XCTAssertTrue(names.isDisjoint(with: removed), "\(names)")
        }
        XCTAssertTrue(Set(Tab.allCases.map(\.rawValue)).isDisjoint(with: removed))
        XCTAssertTrue(Set(PrivacyMode.Section.allCases.map(\.rawValue)).isDisjoint(with: removed))
    }

    /// With the switch off no prompter symbol or label is reachable from the
    /// rail: not as a tab, not as a glyph, not as a title.
    func testNothingOfThePrompterIsReachableFromTheRailWhileOff() {
        let visible = Tab.visibleTabs(prompterEnabled: false)
        XCTAssertFalse(visible.contains(.prompter))
        XCTAssertFalse(visible.map(\.symbol).contains(Tab.prompter.symbol))
        XCTAssertFalse(visible.map(\.title).contains(Tab.prompter.title))
        XCTAssertFalse(PrivacyMode.Section.shown(prompterEnabled: false).contains(.prompter))
    }

    // MARK: - Glyphs

    /// Every rail glyph resolves — a name macOS does not know draws nothing at
    /// all — and none of the four retired on 2026-09-21 comes back. Music
    /// keeps the system's plain note by the owner's choice; with the other four
    /// changed, the rail as a whole is no longer the upstream project's. The
    /// Prompter's glyph is held to the same rules in the configuration that
    /// shows it.
    func testTheRailGlyphsResolveAndAreTheIslandsOwn() {
        for tab in Tab.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil),
                            "\(tab.symbol) does not resolve")
            XCTAssertFalse(Tab.retiredSymbols.contains(tab.symbol),
                           "\(tab) is wearing a retired glyph again: \(tab.symbol)")
        }
        XCTAssertEqual(Set(Tab.allCases.map(\.symbol)).count, Tab.allCases.count, "two tabs share a glyph")
        XCTAssertFalse(Tab.retiredSymbols.contains(SettingsIcon.clipboard))
        XCTAssertFalse(Tab.retiredSymbols.contains(SettingsIcon.translate))
    }

    // MARK: - The privacy section

    func testPrivacySectionsListBothConfigurations() {
        XCTAssertEqual(PrivacyMode.Section.shown(prompterEnabled: false), [.clipboard, .translate])
        XCTAssertEqual(PrivacyMode.Section.shown(prompterEnabled: true), [.clipboard, .translate, .prompter])
        XCTAssertEqual(
            PrivacyMode.Section.allCases.map(\.rawValue).sorted(),
            ["clipboard", "prompter", "translate"]
        )
    }

    // MARK: - The switch turning off under a selected tab

    /// The spec is silent on where a selected `prompter` tab goes when its
    /// switch turns off; the switch lives in Settings, so that is where the
    /// person was most likely heading from, and it is the one tab that is
    /// never absent. Pinned here so a change is deliberate.
    func testASelectedPrompterTabFallsBackToSettingsWhenTheSwitchTurnsOff() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores, prompterEnabled: true)
        vm.select(.prompter)
        XCTAssertEqual(vm.tab, .prompter)
        XCTAssertTrue(vm.wantsKeyboard, "arriving on the prompter hands it the keyboard")

        vm.setPrompterEnabled(false)
        XCTAssertEqual(vm.tab, .settings)
        XCTAssertFalse(vm.wantsKeyboard, "leaving the tab gives the keyboard back")
        XCTAssertFalse(vm.prompterEnabled)
    }

    func testTurningTheSwitchOffElsewhereLeavesTheSelectionAlone() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores, prompterEnabled: true)
        vm.select(.clipboard)
        vm.setPrompterEnabled(false)
        XCTAssertEqual(vm.tab, .clipboard)
    }

    /// Turning it on shows the tab and does not select it (spec 4).
    func testTurningTheSwitchOnDoesNotSelectTheTab() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        XCTAssertFalse(vm.prompterEnabled, "off by default")
        vm.select(.shelf)
        vm.setPrompterEnabled(true)
        XCTAssertTrue(vm.prompterEnabled)
        XCTAssertEqual(vm.tab, .shelf)
    }

    /// A tab that is not on the rail cannot be selected by any route.
    func testAnAbsentPrompterTabCannotBeSelected() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.select(.prompter)
        XCTAssertEqual(vm.tab, .media)
        vm.chooseTab(.prompter)
        XCTAssertEqual(vm.tab, .media)
        XCTAssertFalse(vm.wantsKeyboard)
    }

    // MARK: - What is actually drawn

    /// The rendered rail, read the way VoiceOver reads it: five buttons and no
    /// Prompter with the switch off; six, the Prompter after Translate, with
    /// it on. The control half proves the probe can see the sixth button.
    func testTheDrawnRailFollowsTheSwitch() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.isOpen = true
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)

        let off = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)
        let offRail = try XCTUnwrap(off.first(label: "Tabs"), off.dump)
        XCTAssertEqual(offRail.all(role: "AXButton").map(\.label),
                       Tab.visibleTabs(prompterEnabled: false).map(\.title), offRail.dump)
        XCTAssertFalse(off.dump.contains(Tab.prompter.title), off.dump)

        vm.setPrompterEnabled(true)
        let on = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)
        let onRail = try XCTUnwrap(on.first(label: "Tabs"), on.dump)
        XCTAssertEqual(onRail.all(role: "AXButton").map(\.label),
                       Tab.visibleTabs(prompterEnabled: true).map(\.title), onRail.dump)
    }
}
