import AppKit
import XCTest
@testable import IslaKit

/// The ⋯ on every page and the stage (2026-10-25): which rows each surface's
/// menu lists, that none repeats a header button, that Settings… ends every
/// one, and that ⌘, is shown only where the key opens Settings.
@MainActor
final class HeaderMoreMenuTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    override func setUp() {
        super.setUp()
        LabLocalization.use("en")
    }

    override func tearDown() {
        LabLocalization.use("en")
        super.tearDown()
    }

    private func titles(_ surface: Surface, song: Bool = true, clearable: Bool = true, key: Bool = false) -> [String] {
        HeaderMoreMenu.items(for: surface, hasSong: song, clipboardClearable: clearable, panelIsKey: key)
            .map { $0.kind == .separator ? "—" : $0.title }
    }

    func testEachSurfacesRows() {
        XCTAssertEqual(titles(.player), ["Lyrics", "—", "Settings…"])
        XCTAssertEqual(titles(.stage), ["Hide Lyrics", "Lyrics Settings…", "—", "Settings…"])
        XCTAssertEqual(titles(.clipboard), ["Clear History…", "—", "Settings…"])
        XCTAssertEqual(titles(.tray), ["Settings…"], "Remove All stays a button beside the ⋯")
        XCTAssertEqual(titles(.translate), ["Settings…"], "History stays a button beside the ⋯")
        for surface in [Surface.settings, .drop, .welcome] {
            XCTAssertEqual(titles(surface), [], "\(surface) has no ⋯")
        }
        for surface in Surface.allCases {
            XCTAssertEqual(titles(surface).isEmpty, surface.headerCorner != .more, "\(surface)")
        }

        LabLocalization.use("ru")
        XCTAssertEqual(titles(.stage), ["Скрыть текст", "Настройки текста…", "—", "Настройки…"], "ru")
        XCTAssertEqual(localized("More"), "Ещё")
    }

    func testWhatIsEnabled() {
        let noSong = HeaderMoreMenu.items(for: .player, hasSong: false, clipboardClearable: true, panelIsKey: false)
        XCTAssertEqual(noSong.first { $0.kind == .lyrics }?.isEnabled, false, "Lyrics wants a song, as the island's menu")
        let empty = HeaderMoreMenu.items(for: .clipboard, hasSong: true, clipboardClearable: false, panelIsKey: false)
        XCTAssertEqual(empty.first { $0.kind == .clearClipboardHistory }?.isEnabled, false, "nothing to clear")
        for surface in Surface.allCases {
            for item in HeaderMoreMenu.items(for: surface, hasSong: false, clipboardClearable: false, panelIsKey: false)
            where item.kind == .settings {
                XCTAssertTrue(item.isEnabled, "Settings… is always there, \(surface)")
            }
        }
    }

    /// ⌘, opens Settings only while the panel is key (`settingsKeyHandled`);
    /// anywhere else it is the front app's, and the row does not promise it.
    func testTheSettingsKeyIsShownOnlyWhereItWorks() {
        for surface in Surface.allCases where surface.headerCorner == .more {
            let off = HeaderMoreMenu.items(for: surface, hasSong: true, clipboardClearable: true, panelIsKey: false)
            let on = HeaderMoreMenu.items(for: surface, hasSong: true, clipboardClearable: true, panelIsKey: true)
            XCTAssertEqual(off.last?.kind, .settings)
            XCTAssertFalse(off.last?.showsSettingsKey ?? true, "\(surface), panel not key")
            XCTAssertTrue(on.last?.showsSettingsKey ?? false, "\(surface), panel key")
            XCTAssertEqual(on.filter(\.showsSettingsKey).count, 1, "only Settings… shows a key")
        }
        XCTAssertTrue(NotchPanel.isSettingsKey(keyCode: 43, characters: ",", flags: .command), "the key the row shows")
    }

    func testTheNativeMenuCarriesTheRows() {
        var chosen: [HeaderMenuItem.Kind] = []
        let items = HeaderMoreMenu.items(for: .stage, hasSong: true, clipboardClearable: true, panelIsKey: true)
        let menu = HeaderMoreMenu.menu(items) { chosen.append($0) }
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, false, true, false])
        XCTAssertEqual(menu.items.map(\.title), ["Hide Lyrics", "Lyrics Settings…", "", "Settings…"])
        let settings = menu.items[3]
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items[0].keyEquivalent, "")
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem {
            menu.performActionForItem(at: index)
            _ = item
        }
        XCTAssertEqual(chosen, [.hideLyrics, .lyricsSettings, .settings])

        let unkeyed = HeaderMoreMenu.menu(
            HeaderMoreMenu.items(for: .player, hasSong: true, clipboardClearable: true, panelIsKey: false)
        ) { _ in }
        XCTAssertEqual(unkeyed.items.last?.keyEquivalent, "", "no ⌘, where the key does nothing")
    }

    /// Clear History… asks the pane's own question; nothing goes until it is
    /// answered.
    func testClearHistoryAsksFirst() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.open(.clipboard)
        XCTAssertEqual(
            vm.moreMenuItems(panelIsKey: false).first { $0.kind == .clearClipboardHistory }?.isEnabled, false,
            "an empty history has nothing to clear"
        )
        vm.performMoreMenu(.clearClipboardHistory)
        XCTAssertFalse(vm.clipboardClear.isAsking, "and asks nothing")

        vm.clipboard.record(ClipItem(payload: .text("one"), date: Date()))
        vm.clipboard.record(ClipItem(payload: .text("two"), date: Date()))
        XCTAssertEqual(vm.moreMenuItems(panelIsKey: false).first { $0.kind == .clearClipboardHistory }?.isEnabled, true)
        vm.performMoreMenu(.clearClipboardHistory)
        XCTAssertTrue(vm.clipboardClear.isAsking, "the pane's own question")
        XCTAssertEqual(vm.clipboardClear.count, 2)
        XCTAssertEqual(vm.clipboard.items.count, 2, "nothing removed until it is answered")
        XCTAssertEqual(
            vm.moreMenuItems(panelIsKey: false).first { $0.kind == .clearClipboardHistory }?.isEnabled, false,
            "not asked twice"
        )
        vm.clipboardClear.cancel()
    }
}
