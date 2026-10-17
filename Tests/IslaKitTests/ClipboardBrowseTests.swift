import AppKit
import Combine
import XCTest
@testable import IslaKit

/// What Clipboard shows of the history (spec §9.2, §9.3, §19.8): the kind filter,
/// the search, the hairline under the pins — and the rules that tie the search
/// field to the keyboard. The field is always on the surface now (§19.8), so the
/// listing has no "searching" state to be in: a query narrows the filter's list,
/// and an empty one leaves it whole.
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
            ClipboardBrowser.listing(of: items, filter: filter, query: "").items.map(\.kind)
        }
        XCTAssertEqual(kinds(.all).count, 7)
        XCTAssertEqual(kinds(.text), [.text, .colour, .code], "colour and code are Text")
        XCTAssertEqual(kinds(.links), [.link])
        XCTAssertEqual(kinds(.images), [.image])
        XCTAssertEqual(kinds(.files), [.file, .files])
        // The surface offers four of them (§19.8): files show under All.
        XCTAssertEqual(ClipboardBrowser.filters, [.all, .text, .links, .images])
        XCTAssertTrue(kinds(.all).contains(.file) && kinds(.all).contains(.files))
    }

    func testPinnedEntriesLeadEveryFilterAboveAHairline() throws {
        let items = [text("one"), text("two", pinned: true), text("three"), text("four", pinned: true)]
        let all = ClipboardBrowser.listing(of: items, filter: .all, query: "")
        XCTAssertEqual(previews(all), ["two", "four", "one", "three"])
        XCTAssertEqual(all.separatorAfter, 1, "after the last pinned row")

        let none = ClipboardBrowser.listing(of: [text("a"), text("b")], filter: .all, query: "")
        XCTAssertNil(none.separatorAfter, "no pins, no hairline")
        let only = ClipboardBrowser.listing(of: [text("a", pinned: true)], filter: .all, query: "")
        XCTAssertNil(only.separatorAfter, "nothing below the pins to separate from")

        // The hairline follows the filter: it is drawn in the filtered list too.
        let mixed = [text("note", pinned: true), text("#FFF", pinned: true), text("https://x.com"), text("plain")]
        let texts = ClipboardBrowser.listing(of: mixed, filter: .text, query: "")
        XCTAssertEqual(previews(texts), ["note", "#FFF", "plain"])
        XCTAssertEqual(texts.separatorAfter, 1)
    }

    // MARK: Search

    /// The filter and the search sit side by side (§19.8), so a search finds
    /// what is plainly in the list the two describe together: it narrows within
    /// the kind chosen, and All is the whole history.
    func testASearchNarrowsWithinTheFilter() throws {
        let items = try sample()
        let found = ClipboardBrowser.listing(of: items, filter: .all, query: "north")
        XCTAssertEqual(previews(found), ["Meet at the north entrance"])
        XCTAssertTrue(found.isSearch)
        XCTAssertEqual(previews(ClipboardBrowser.listing(of: items, filter: .text, query: "north")), ["Meet at the north entrance"])
        let otherKind = ClipboardBrowser.listing(of: items, filter: .images, query: "north")
        XCTAssertTrue(otherKind.items.isEmpty, "the filter is on screen while searching, and Images has no north")
        XCTAssertTrue(otherKind.isSearch)

        let byName = ClipboardBrowser.listing(of: items, filter: .all, query: "report")
        XCTAssertEqual(byName.items.map(\.kind), [.file])
        let picture = ClipboardBrowser.listing(of: items, filter: .all, query: "photos")
        XCTAssertEqual(picture.items.map(\.kind), [.image], "a picture is found by where it came from")
        let none = ClipboardBrowser.listing(of: items, filter: .all, query: "quarterly")
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertTrue(none.isSearch, "an empty result is a search with no results, not an empty history")
    }

    /// Nothing typed is not a search: the filter's own list, whole. A stale
    /// query is the model's to clear (`clearQuery`), not the listing's to ignore.
    func testNothingTypedShowsTheFiltersWholeList() throws {
        let items = try sample()
        let empty = ClipboardBrowser.listing(of: items, filter: .links, query: "")
        XCTAssertEqual(empty.items.count, 1)
        XCTAssertFalse(empty.isSearch)
        let blank = ClipboardBrowser.listing(of: items, filter: .links, query: "   ")
        XCTAssertEqual(blank.items.count, 1)
        XCTAssertFalse(blank.isSearch, "spaces are not a search")
        XCTAssertEqual(ClipboardBrowser.listing(of: items, filter: .all, query: "").items.count, 7)
    }

    /// Review 2026-10-15: while the Clipboard is covered, a search that listed the
    /// rows containing a word was a way to read the rows. Hidden rows are matched
    /// on their kind's name alone; a row the person has revealed is matched on
    /// what it says.
    func testASearchNeverMatchesTheContentOfARowThePrivacyCoverHides() {
        let secret = text("hunter2 is my password")
        let other = text("south gate")
        let link = text("https://secret.example.com/path")
        let items = [secret, other, link]
        let hideAll: (ClipItem) -> Bool = { _ in true }
        let byContent = ClipboardBrowser.listing(of: items, filter: .all, query: "hunter2", isHidden: hideAll)
        XCTAssertTrue(byContent.items.isEmpty, "no match on content, and so no tell")
        XCTAssertTrue(byContent.isSearch)
        let secretWord = ClipboardBrowser.listing(of: items, filter: .all, query: "secret", isHidden: hideAll)
        XCTAssertTrue(secretWord.items.isEmpty)
        let byKind = ClipboardBrowser.listing(of: items, filter: .all, query: "links", isHidden: hideAll)
        XCTAssertEqual(byKind.items.map(\.id), [link.id], "a kind's name is what the mark says anyway")

        let revealedOnly = ClipboardBrowser.listing(
            of: items, filter: .all, query: "hunter2", isHidden: { $0.id != secret.id }
        )
        XCTAssertEqual(revealedOnly.items.map(\.id), [secret.id], "a revealed row matches on its content")
        let uncovered = ClipboardBrowser.listing(of: items, filter: .all, query: "hunter2")
        XCTAssertEqual(uncovered.items.map(\.id), [secret.id], "with no cover, as before")
    }

    func testResultsKeepThePinsFirst() {
        let items = [text("north gate"), text("north star", pinned: true), text("south")]
        let found = ClipboardBrowser.listing(of: items, filter: .all, query: "north")
        XCTAssertEqual(previews(found), ["north star", "north gate"])
        XCTAssertEqual(found.separatorAfter, 0)
    }

    func testClearingTheQueryForgetsItAndKeepsTheFilter() {
        let browser = ClipboardBrowser()
        browser.filter = .links
        browser.query = "north"
        browser.selection = UUID()
        browser.clearQuery()
        XCTAssertEqual(browser.query, "")
        XCTAssertNil(browser.selection, "the arrows start again from the top")
        XCTAssertEqual(browser.filter, .links, "the segment the person chose is still chosen")
    }

    // MARK: The arrow keys (spec §19.8)

    /// A new query is a new list: the arrows start again from its top. The
    /// selection stops at either end rather than wrapping, and a selected row
    /// that left the listing falls back to the first.
    func testTheSelectionStartsOverWithANewQueryAndStopsAtTheEnds() {
        let items = [text("one"), text("two"), text("three")]
        let listing = ClipboardBrowser.listing(of: items, filter: .all, query: "")
        XCTAssertEqual(ClipboardBrowser.selectedIndex(in: listing, selection: nil), 0)
        let second = ClipboardBrowser.moved(1, in: listing, selection: nil)
        XCTAssertEqual(second, listing.items[1].id)
        let last = ClipboardBrowser.moved(1, in: listing, selection: listing.items[2].id)
        XCTAssertEqual(last, listing.items[2].id, "↓ stops at the last row")
        let first = ClipboardBrowser.moved(-1, in: listing, selection: nil)
        XCTAssertEqual(first, listing.items[0].id, "↑ stops at the first")
        XCTAssertEqual(ClipboardBrowser.selectedIndex(in: listing, selection: UUID()), 0, "a row no longer listed: the first")
        let empty = ClipboardBrowser.listing(of: [], filter: .all, query: "")
        XCTAssertNil(ClipboardBrowser.selectedIndex(in: empty, selection: nil))
        XCTAssertNil(ClipboardBrowser.moved(1, in: empty, selection: nil))

        let browser = ClipboardBrowser()
        browser.selection = listing.items[2].id
        browser.query = "t"
        XCTAssertNil(browser.selection, "a new query is a new list")
    }
}

// MARK: - The keyboard (spec §19.8)

/// "Summoned, Clipboard takes the keyboard as Translate does" — the panel becomes
/// key when the surface opens, and gives it back when the surface changes (the
/// controller gives it back when the panel closes). The search field is always
/// on the surface, so there is no field to open and close.
@MainActor
final class ClipboardSearchKeyboardTests: XCTestCase {
    private func rig() throws -> (NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        return (vm, isolated)
    }

    func testOnlyTranslateAndClipboardTakeTheKeyboardWhenTheyOpen() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        for surface in NotchViewModel.Surface.reachable {
            vm.open(.tools)
            XCTAssertFalse(vm.wantsKeyboard)
            vm.open(surface)
            XCTAssertEqual(vm.wantsKeyboard, surface == .translate || surface == .clipboard, "\(surface)")
            XCTAssertEqual(vm.wantsKeyboard, surface.takesKeyboard, "\(surface)")
        }
        // Assigning the surface is not a road in: only `open` and `choose`
        // ask for the keyboard, so a surface restored without one (a rebuild,
        // a test) does not grab it.
        vm.open(.tools)
        vm.surface = .clipboard
        XCTAssertFalse(vm.wantsKeyboard, "choosing a surface by assignment alone asks for nothing: only a road in does")
    }

    func testOpeningClipboardTakesTheKeyboardAndLeavingGivesItBack() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.open(.tools)
        XCTAssertFalse(vm.wantsKeyboard, "Tools asks for nothing")

        vm.open(.clipboard)
        XCTAssertTrue(vm.wantsKeyboard)

        vm.clipboardBrowser.query = "north"
        vm.open(.tools)
        XCTAssertEqual(vm.clipboardBrowser.query, "")
        XCTAssertFalse(vm.wantsKeyboard)
    }

    func testChangingSurfaceEndsTheSearchAndGivesTheKeyboardBack() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        for destination in [NotchViewModel.Surface.player, .tray, .settings, .tools] {
            vm.open(.clipboard)
            vm.clipboardBrowser.query = "x"
            vm.open(destination)
            XCTAssertEqual(vm.clipboardBrowser.query, "", "\(destination)")
            XCTAssertFalse(vm.wantsKeyboard, "\(destination)")
        }
        // To Translate the keyboard stays asked for: Translate's own claim.
        vm.open(.clipboard)
        vm.clipboardBrowser.query = "x"
        vm.open(.translate)
        XCTAssertEqual(vm.clipboardBrowser.query, "")
        XCTAssertTrue(vm.wantsKeyboard)
    }

    func testChoosingClipboardAgainKeepsTheQueryAndItsKeyboard() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.open(.clipboard)
        vm.clipboardBrowser.query = "north"
        vm.open(.clipboard)
        XCTAssertEqual(vm.clipboardBrowser.query, "north")
        XCTAssertTrue(vm.wantsKeyboard)
    }

    func testThePanelFoldingEndsTheSearch() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.open(.clipboard)
        vm.isOpen = true
        vm.clipboardBrowser.query = "north"
        vm.clipboardBrowser.filter = .links
        vm.isOpen = false
        XCTAssertEqual(vm.clipboardBrowser.query, "", "a half-remembered query would hide most of the next visit's list")
        XCTAssertEqual(vm.clipboardBrowser.filter, .links, "the segment the person chose is kept")
    }

    func testEscapeClearsTheSearchBeforeItClosesThePanel() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.open(.clipboard)
        vm.isOpen = true
        XCTAssertFalse(vm.consumeEscape(), "nothing typed: Escape closes the panel at once")
        vm.clipboardBrowser.query = "north"
        XCTAssertTrue(vm.consumeEscape(), "the first Escape is the field's")
        XCTAssertEqual(vm.clipboardBrowser.query, "")
        XCTAssertTrue(vm.isOpen, "and the panel is still open")
        XCTAssertFalse(vm.consumeEscape(), "the second finds nothing to cancel, so the panel folds")
    }

    func testAnArmedQuestionTakesEscapeBeforeTheSearchDoes() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.open(.clipboard)
        vm.clipboardBrowser.query = "north"
        let ask = ClipboardClearConfirmation()
        ask.ask(count: 3)
        XCTAssertTrue(vm.consumeEscape())
        XCTAssertFalse(ask.isAsking, "the question is answered first")
        XCTAssertEqual(vm.clipboardBrowser.query, "north")
        XCTAssertTrue(vm.consumeEscape())
        XCTAssertEqual(vm.clipboardBrowser.query, "")
    }

    /// With the field key, plain Escape arrives at the panel's own `sendEvent`
    /// and never at the transient hot key: the hot key is held only while the
    /// panel is not key, which is what `wantsKeyboard` says.
    func testTheTransientEscapeKeyStaysDownWhileTheFieldHoldsTheKeyboard() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.surface = .clipboard
        vm.isPinnedOpen = true
        XCTAssertTrue(NotchViewModel.claimsEscape(
            pinned: vm.isPinnedOpen, panelHasKeyboard: vm.wantsKeyboard, appIsActive: false, locked: false
        ), "a pinned panel that is not key holds Escape")
        vm.open(.clipboard)
        XCTAssertFalse(NotchViewModel.claimsEscape(
            pinned: vm.isPinnedOpen, panelHasKeyboard: vm.wantsKeyboard, appIsActive: false, locked: false
        ), "with the field key, Escape is the panel's, and the field clears first")
    }

    /// Delete edits the search text: the Shelf's hot key claims only on the
    /// tray, and a key panel offers Delete to the Shelf's handler, which
    /// declines on every other surface.
    func testDeleteIsNeverTheShelfsWhileTheFieldHasTheKeyboard() throws {
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        vm.open(.clipboard)
        // The claim reads "on the tray" from the surface, as the controller does.
        XCTAssertFalse(NotchViewModel.claimsDelete(
            panelOpen: true, onShelf: vm.surface == .tray, pointerOnShelf: true,
            hasSelection: true, appIsActive: false, locked: false
        ))
        // And with the Shelf's selection standing, the panel would still let
        // Delete through to the field.
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        var removed = 0
        panel.removeKeyHandled = { [vm] in
            guard vm.surface == .tray else { return false }
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
        // is the same for Translate and for Clipboard's field: replayed here.
        let (vm, isolated) = try rig()
        defer { isolated.release() }
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        let sink = vm.$wantsKeyboard.removeDuplicates().sink { panel.acceptsKeyboard = $0 }
        defer { sink.cancel() }

        vm.open(.tools)
        XCTAssertFalse(panel.canBecomeKey)
        vm.open(.clipboard)
        XCTAssertTrue(panel.canBecomeKey)
        vm.open(.tools)
        XCTAssertFalse(panel.canBecomeKey, "surface change: given back")
        vm.open(.clipboard)
        vm.open(.player)
        XCTAssertFalse(panel.canBecomeKey, "surface change: given back")
    }
}
