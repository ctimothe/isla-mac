import AppKit
import Combine
import XCTest
@testable import IslaKit

/// What the Clipboard tab shows of the history (redesign spec §9.2, §9.3): the
/// kind filter, the search, the hairline under the pins — and the rules that tie
/// the search field to the keyboard.
@MainActor
final class ClipboardBrowseTests: XCTestCase {
    private func text(_ string: String, pinned: Bool = false) -> ClipItem {
        ClipItem(payload: .text(string), date: Date(timeIntervalSince1970: 1_792_065_600), isPinned: pinned)
    }

    private func image(_ seed: Int, pinned: Bool = false) throws -> ClipItem {
        let image = try XCTUnwrap(ClipImage.make(data: ClipboardPinsTests.png(width: 30 + seed, height: 20), type: .png, sourceApp: "Photos"))
        return ClipItem(payload: .image(image), date: Date(timeIntervalSince1970: 1_792_065_600), isPinned: pinned)
    }

    private func sample() throws -> [ClipItem] {
        [
            text("Meet at the north entrance"),                   // text
            text("#FF453A"),                                      // colour
            text("let answer = try await translator.translate()"),// code
            text("https://developer.apple.com/design"),           // link
            try image(1),
            ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/Q3 Report.pdf")), date: .distantPast),
            ClipItem(payload: .files([URL(fileURLWithPath: "/tmp/a.key"), URL(fileURLWithPath: "/tmp/b.key")]), date: .distantPast),
        ]
    }

    private func previews(_ listing: ClipboardBrowser.Listing) -> [String] { listing.items.map(\.preview) }

    // MARK: Filter

    func testEachFilterListsItsKinds() throws {
        let items = try sample()
        func kinds(_ filter: ClipFilter) -> [ClipKind] {
            ClipboardBrowser.listing(of: items, filter: filter, query: "", searching: false).items.map(\.kind)
        }
        XCTAssertEqual(kinds(.all).count, 7)
        XCTAssertEqual(kinds(.text), [.text, .colour, .code], "colour and code are Text")
        XCTAssertEqual(kinds(.links), [.link])
        XCTAssertEqual(kinds(.images), [.image])
        XCTAssertEqual(kinds(.files), [.file, .files])
    }

    func testPinnedEntriesLeadEveryFilterAboveAHairline() throws {
        let items = [text("one"), text("two", pinned: true), text("three"), text("four", pinned: true)]
        let all = ClipboardBrowser.listing(of: items, filter: .all, query: "", searching: false)
        XCTAssertEqual(previews(all), ["two", "four", "one", "three"])
        XCTAssertEqual(all.separatorAfter, 1, "after the last pinned row")

        let none = ClipboardBrowser.listing(of: [text("a"), text("b")], filter: .all, query: "", searching: false)
        XCTAssertNil(none.separatorAfter, "no pins, no hairline")
        let only = ClipboardBrowser.listing(of: [text("a", pinned: true)], filter: .all, query: "", searching: false)
        XCTAssertNil(only.separatorAfter, "nothing below the pins to separate from")

        // The hairline follows the filter: it is drawn in the filtered list too.
        let mixed = [text("note", pinned: true), text("#FFF", pinned: true), text("https://x.com"), text("plain")]
        let texts = ClipboardBrowser.listing(of: mixed, filter: .text, query: "", searching: false)
        XCTAssertEqual(previews(texts), ["note", "#FFF", "plain"])
        XCTAssertEqual(texts.separatorAfter, 1)
    }

    // MARK: Search

    func testASearchFindsEntriesOfAnyKindWhateverTheFilterWas() throws {
        let items = try sample()
        let found = ClipboardBrowser.listing(of: items, filter: .images, query: "north", searching: true)
        XCTAssertEqual(previews(found), ["Meet at the north entrance"], "the filter is not on screen while searching")
        XCTAssertTrue(found.isSearch)

        let byName = ClipboardBrowser.listing(of: items, filter: .all, query: "report", searching: true)
        XCTAssertEqual(byName.items.map(\.kind), [.file])
        let picture = ClipboardBrowser.listing(of: items, filter: .all, query: "photos", searching: true)
        XCTAssertEqual(picture.items.map(\.kind), [.image], "a picture is found by where it came from")
        let none = ClipboardBrowser.listing(of: items, filter: .all, query: "quarterly", searching: true)
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertTrue(none.isSearch, "an empty result is a search with no results, not an empty history")
    }

    func testTheFieldOpenWithNothingTypedShowsTheWholeList() throws {
        let items = try sample()
        let open = ClipboardBrowser.listing(of: items, filter: .links, query: "", searching: true)
        XCTAssertEqual(open.items.count, 7)
        XCTAssertFalse(open.isSearch)
        let blank = ClipboardBrowser.listing(of: items, filter: .links, query: "   ", searching: true)
        XCTAssertEqual(blank.items.count, 7)
        // A closed field ignores a stale query.
        let closed = ClipboardBrowser.listing(of: items, filter: .links, query: "north", searching: false)
        XCTAssertEqual(closed.items.count, 1)
    }

    func testResultsKeepThePinsFirst() {
        let items = [text("north gate"), text("north star", pinned: true), text("south")]
        let found = ClipboardBrowser.listing(of: items, filter: .all, query: "north", searching: true)
        XCTAssertEqual(previews(found), ["north star", "north gate"])
        XCTAssertEqual(found.separatorAfter, 0)
    }

    func testClosingTheFieldForgetsTheQuery() {
        let browser = ClipboardBrowser()
        browser.filter = .links
        browser.beginSearch()
        browser.query = "north"
        XCTAssertTrue(browser.isSearching)
        browser.endSearch()
        XCTAssertFalse(browser.isSearching)
        XCTAssertEqual(browser.query, "")
        XCTAssertEqual(browser.filter, .links, "the segment the person chose is still chosen")
    }
}

// MARK: - The keyboard (spec §9.3)

/// "The panel becomes key while the search field is focused, the way it does for
/// Translate, and gives it back when the field closes" — and when the tab
/// changes, and when the panel closes.
@MainActor
final class ClipboardSearchKeyboardTests: XCTestCase {
    private func rig() throws -> (NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        return (vm, isolated)
    }

    func testOnlyTranslateAndAnOpenClipboardSearchWantTheKeyboard() {
        for tab in NotchViewModel.Tab.allCases {
            for searching in [false, true] {
                let wants = NotchViewModel.tabWantsKeyboard(tab: tab, clipboardSearching: searching)
                XCTAssertEqual(wants, tab == .translate || (tab == .clipboard && searching), "\(tab) \(searching)")
            }
        }
        XCTAssertFalse(NotchViewModel.Tab.clipboard.needsKeyboard, "arriving never takes the keyboard")
    }

    func testOpeningTheFieldTakesTheKeyboardAndClosingGivesItBack() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .clipboard
        XCTAssertFalse(vm.wantsKeyboard, "the tab alone asks for nothing")

        vm.openClipboardSearch()
        XCTAssertTrue(vm.clipboardBrowser.isSearching)
        XCTAssertTrue(vm.wantsKeyboard)

        vm.clipboardBrowser.query = "north"
        vm.closeClipboardSearch()
        XCTAssertFalse(vm.clipboardBrowser.isSearching)
        XCTAssertEqual(vm.clipboardBrowser.query, "")
        XCTAssertFalse(vm.wantsKeyboard)
    }

    func testTheFieldOpensOnlyOnTheClipboardAndNeverOverTheLock() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .shelf
        vm.openClipboardSearch()
        XCTAssertFalse(vm.clipboardBrowser.isSearching)
        XCTAssertFalse(vm.wantsKeyboard)

        vm.tab = .clipboard
        vm.isLockedPresentation = true
        vm.openClipboardSearch()
        XCTAssertFalse(vm.clipboardBrowser.isSearching, "typing on the lock screen belongs to the lock screen")
        XCTAssertFalse(vm.wantsKeyboard)
    }

    func testChangingTabsEndsTheSearchAndGivesTheKeyboardBack() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        for destination in [NotchViewModel.Tab.media, .shelf, .settings] {
            vm.tab = .clipboard
            vm.openClipboardSearch()
            vm.clipboardBrowser.query = "x"
            vm.tab = destination
            XCTAssertFalse(vm.clipboardBrowser.isSearching, "\(destination)")
            XCTAssertEqual(vm.clipboardBrowser.query, "")
            XCTAssertFalse(vm.wantsKeyboard, "\(destination)")
        }
        // To Translate the keyboard stays asked for: Translate's own claim.
        vm.tab = .clipboard
        vm.openClipboardSearch()
        vm.select(.translate)
        XCTAssertFalse(vm.clipboardBrowser.isSearching)
        XCTAssertTrue(vm.wantsKeyboard)
    }

    func testChoosingTheClipboardTabAgainKeepsTheFieldAndItsKeyboard() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .clipboard
        vm.openClipboardSearch()
        vm.select(.clipboard)
        XCTAssertTrue(vm.clipboardBrowser.isSearching)
        XCTAssertTrue(vm.wantsKeyboard)
    }

    func testThePanelFoldingEndsTheSearch() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .clipboard
        vm.isOpen = true
        vm.openClipboardSearch()
        vm.clipboardBrowser.query = "north"
        vm.isOpen = false
        XCTAssertFalse(vm.clipboardBrowser.isSearching)
        XCTAssertEqual(vm.clipboardBrowser.query, "")
        XCTAssertFalse(vm.wantsKeyboard)
    }

    func testClosingNoSearchLeavesTranslatesKeyboardAlone() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.select(.translate)
        XCTAssertTrue(vm.wantsKeyboard)
        vm.closeClipboardSearch()
        XCTAssertTrue(vm.wantsKeyboard, "there was no search to close")
        vm.isOpen = true
        vm.isOpen = false
        // The panel folding does not touch what the controller already gives back.
        XCTAssertTrue(vm.clipboardBrowser.isSearching == false)
    }

    func testEscapeClosesTheSearchBeforeItClosesThePanel() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .clipboard
        vm.isOpen = true
        vm.openClipboardSearch()
        XCTAssertTrue(vm.consumeEscape(), "the first Escape is the field's")
        XCTAssertFalse(vm.clipboardBrowser.isSearching)
        XCTAssertFalse(vm.wantsKeyboard)
        XCTAssertTrue(vm.isOpen, "and the panel is still open")
        XCTAssertFalse(vm.consumeEscape(), "the second finds nothing to cancel, so the panel folds")
    }

    func testAnArmedQuestionTakesEscapeBeforeTheSearchDoes() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .clipboard
        vm.openClipboardSearch()
        let ask = ClipboardClearConfirmation()
        ask.ask(count: 3)
        XCTAssertTrue(vm.consumeEscape())
        XCTAssertFalse(ask.isAsking, "the question is answered first")
        XCTAssertTrue(vm.clipboardBrowser.isSearching)
        XCTAssertTrue(vm.consumeEscape())
        XCTAssertFalse(vm.clipboardBrowser.isSearching)
    }

    /// With the field key, plain Escape arrives at the panel's own `sendEvent`
    /// and never at the transient hot key: the hot key is held only while the
    /// panel is not key, which is what `wantsKeyboard` says.
    func testTheTransientEscapeKeyStaysDownWhileTheFieldHoldsTheKeyboard() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .clipboard
        vm.isPinnedOpen = true
        XCTAssertTrue(NotchViewModel.claimsEscape(
            pinned: vm.isPinnedOpen, panelHasKeyboard: vm.wantsKeyboard, appIsActive: false, locked: false
        ), "a pinned panel that is not key holds Escape")
        vm.openClipboardSearch()
        XCTAssertFalse(NotchViewModel.claimsEscape(
            pinned: vm.isPinnedOpen, panelHasKeyboard: vm.wantsKeyboard, appIsActive: false, locked: false
        ), "with the field key, Escape is the panel's, and the field closes first")
    }

    /// Delete edits the search text: the Shelf's hot key claims only on the
    /// Shelf, and a key panel offers Delete to the Shelf's handler, which
    /// declines on every other tab.
    func testDeleteIsNeverTheShelfsWhileTheFieldIsOpen() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.tab = .clipboard
        vm.openClipboardSearch()
        // The claim reads "on the Shelf" from the tab, as the controller does.
        XCTAssertFalse(NotchViewModel.claimsDelete(
            panelOpen: true, onShelf: vm.tab == .shelf, pointerOnShelf: true,
            hasSelection: true, appIsActive: false, locked: false
        ))
        // And with the Shelf's selection standing, the panel would still let
        // Delete through to the field.
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        var removed = 0
        panel.removeKeyHandled = { [vm] in
            guard vm.tab == .shelf else { return false }
            removed += 1
            return true
        }
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51
        ))
        panel.sendEvent(press)
        XCTAssertEqual(removed, 0)
    }

    func testThePanelOnlyCanBecomeKeyWhileAskedAndGivesItBack() {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        panel.acceptsKeyboard = true
        XCTAssertTrue(panel.canBecomeKey)
        panel.acceptsKeyboard = false
        XCTAssertFalse(panel.canBecomeKey, "the keyboard claim is what makes the panel key, and only that")
    }

    func testTheKeyClaimFollowsTheViewModelIntoThePanel() throws {
        // The controller's one sink, `vm.$wantsKeyboard` into `panel.acceptsKeyboard`,
        // is the same for Translate and for the search field: replayed here.
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        let sink = vm.$wantsKeyboard.removeDuplicates().sink { panel.acceptsKeyboard = $0 }
        defer { sink.cancel() }

        vm.tab = .clipboard
        XCTAssertFalse(panel.canBecomeKey)
        vm.openClipboardSearch()
        XCTAssertTrue(panel.canBecomeKey)
        vm.closeClipboardSearch()
        XCTAssertFalse(panel.canBecomeKey, "closed: given back")
        vm.openClipboardSearch()
        vm.tab = .media
        XCTAssertFalse(panel.canBecomeKey, "tab change: given back")
        vm.tab = .clipboard
        vm.isOpen = true
        vm.openClipboardSearch()
        vm.isOpen = false
        XCTAssertFalse(panel.canBecomeKey, "panel closed: given back")
    }
}
