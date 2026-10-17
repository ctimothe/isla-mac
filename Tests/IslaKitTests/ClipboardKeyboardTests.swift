import AppKit
import XCTest
@testable import IslaKit

/// Clipboard summoned takes the keyboard (spec §19.8): typing searches, ↑ ↓
/// select, Return copies the selection and closes, Escape clears the search
/// and then closes. The arrows and Return reach the view model from the panel
/// (`NotchPanel.listKey`, `NotchViewModel.consumeListKey`), ahead of the
/// search field, which would otherwise take ↑ ↓ as caret moves.
///
/// Every test copies onto the probe's private pasteboard, never the general
/// one the owner is using.
@MainActor
final class ClipboardKeyboardTests: XCTestCase {
    private var isolated: ProbeStores!
    private var vm: NotchViewModel!

    override func setUp() async throws {
        isolated = ProbeFixtures.isolatedStores()
        vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
    }

    override func tearDown() async throws {
        vm = nil
        isolated.release()
        isolated = nil
    }

    /// Three entries, newest first: "third", "second", "first".
    private func fill() {
        let now = Date()
        for (offset, text) in ["first", "second", "third"].enumerated() {
            vm.clipboard.record(ClipItem(payload: .text(text), date: now.addingTimeInterval(Double(offset))))
        }
    }

    private var selectedText: String? {
        let listing = ClipboardBrowser.listing(
            of: vm.clipboard.items, filter: vm.clipboardBrowser.filter, query: vm.clipboardBrowser.query,
            isHidden: { _ in false }
        )
        guard let index = ClipboardBrowser.selectedIndex(in: listing, selection: vm.clipboardBrowser.selection),
              case .text(let text) = listing.items[index].payload else { return nil }
        return text
    }

    // MARK: The panel's keys

    /// ↑ 126, ↓ 125, Return 36 and Enter 76 — bare. With a modifier they are
    /// the field's: ⇧↓ extends a selection, ⌘↑ goes to the start.
    func testThePanelRoutesOnlyTheBareListKeys() {
        XCTAssertEqual(NotchPanel.listKey(keyCode: 126, flags: []), .up)
        XCTAssertEqual(NotchPanel.listKey(keyCode: 125, flags: []), .down)
        XCTAssertEqual(NotchPanel.listKey(keyCode: 36, flags: []), .enter)
        XCTAssertEqual(NotchPanel.listKey(keyCode: 76, flags: []), .enter)
        // Function and numeric-pad flags ride on the arrows by themselves.
        XCTAssertEqual(NotchPanel.listKey(keyCode: 125, flags: [.function, .numericPad]), .down)
        for flag: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
            XCTAssertNil(NotchPanel.listKey(keyCode: 125, flags: flag), "\(flag)")
            XCTAssertNil(NotchPanel.listKey(keyCode: 36, flags: flag), "\(flag)")
        }
        XCTAssertNil(NotchPanel.listKey(keyCode: 0, flags: []), "A is typed into the search")
        XCTAssertNil(NotchPanel.listKey(keyCode: 123, flags: []), "← moves the caret")
    }

    /// Only the two surfaces with a field ask for the keyboard; the panel can
    /// become key for nothing else.
    func testOnlyClipboardAndTranslateTakeTheKeyboard() {
        XCTAssertEqual(NotchViewModel.Surface.allCases.filter(\.takesKeyboard), [.clipboard, .translate])
    }

    func testOpeningClipboardAsksForTheKeyboard() {
        vm.open(.settings)
        XCTAssertFalse(vm.wantsKeyboard)
        vm.open(.clipboard)
        XCTAssertTrue(vm.wantsKeyboard)
        vm.open(.settings)
        XCTAssertFalse(vm.wantsKeyboard, "leaving a surface that types gives the keyboard back")
    }

    /// Over the lock no surface takes the keyboard: typing on the lock screen
    /// belongs to the lock screen, and the panel is lifted above the shield.
    func testNothingTakesTheKeyboardOverTheLock() {
        vm.isLockedPresentation = true
        for surface in [NotchViewModel.Surface.clipboard, .translate] {
            vm.open(surface)
            XCTAssertFalse(vm.wantsKeyboard, "\(surface)")
            vm.choose(surface)
            XCTAssertFalse(vm.wantsKeyboard, "\(surface), chosen")
        }
        vm.isLockedPresentation = false
        vm.open(.clipboard)
        XCTAssertTrue(vm.wantsKeyboard, "unlocked, Clipboard asks again")
    }

    // MARK: Selection

    /// The first row is selected before any key; ↓ and ↑ walk the list and
    /// stop at either end rather than wrapping.
    func testTheArrowsWalkTheListAndStopAtTheEnds() {
        fill()
        vm.open(.clipboard)
        XCTAssertEqual(selectedText, "third")
        XCTAssertEqual(vm.consumeListKey(.up), .handled)
        XCTAssertEqual(selectedText, "third", "↑ on the first row stays")
        XCTAssertEqual(vm.consumeListKey(.down), .handled)
        XCTAssertEqual(selectedText, "second")
        XCTAssertEqual(vm.consumeListKey(.down), .handled)
        XCTAssertEqual(vm.consumeListKey(.down), .handled)
        XCTAssertEqual(selectedText, "first", "↓ on the last row stays")
    }

    /// The selection moves through what the list shows: a search narrows it.
    func testTheArrowsFollowTheSearch() {
        fill()
        vm.open(.clipboard)
        vm.clipboardBrowser.query = "ir"
        XCTAssertEqual(selectedText, "third")
        XCTAssertEqual(vm.consumeListKey(.down), .handled)
        XCTAssertEqual(selectedText, "first", "second does not match and is not stepped on")
    }

    /// Return copies the selected row — onto the probe's pasteboard — and
    /// closes the panel.
    func testReturnCopiesTheSelectionAndCloses() {
        fill()
        vm.open(.clipboard)
        XCTAssertEqual(vm.consumeListKey(.down), .handled)
        XCTAssertEqual(vm.consumeListKey(.enter), .handledAndClose)
        XCTAssertEqual(isolated.pasteboard.string(forType: .string), "second")
    }

    /// Return on an empty history is taken — it is not a newline for the
    /// search — but copies nothing and keeps the panel.
    func testReturnOnAnEmptyListCopiesNothing() {
        vm.open(.clipboard)
        let before = isolated.pasteboard.changeCount
        XCTAssertEqual(vm.consumeListKey(.enter), .handled)
        XCTAssertEqual(isolated.pasteboard.changeCount, before)
    }

    /// Every other surface lets the keys through: Translate's field moves its
    /// caret with them, and the rest have nothing to select.
    func testOtherSurfacesLetTheKeysThrough() {
        fill()
        for surface in [NotchViewModel.Surface.translate, .settings, .tray, .player] {
            vm.open(surface)
            for key in [NotchPanel.ListKey.up, .down, .enter] {
                XCTAssertEqual(vm.consumeListKey(key), .ignored, "\(surface) took \(key)")
            }
        }
    }

    /// Escape clears the search first and keeps the surface; with nothing in
    /// the field it is the panel's again.
    func testEscapeClearsTheSearchBeforeItCloses() {
        fill()
        vm.open(.clipboard)
        vm.clipboardBrowser.query = "sec"
        XCTAssertTrue(vm.consumeEscape(), "the first Escape belongs to the search")
        XCTAssertEqual(vm.clipboardBrowser.query, "")
        XCTAssertEqual(vm.surface, .clipboard)
        XCTAssertFalse(vm.consumeEscape(), "the second closes the panel")
    }

    /// The Images grid draws no selection (§19.8 draws it on rows), so the
    /// keys are not the grid's: ↑ ↓ moved a selection nobody could see, and
    /// Return copied a picture nobody chose and closed (R8 review F5). A
    /// search shows rows again, and the keys come back with them.
    func testTheImagesGridLetsTheListKeysThrough() throws {
        let image = try XCTUnwrap(ClipImage.make(
            data: ClipboardPinsTests.png(width: 40, height: 30, noise: false), type: .png, sourceApp: nil
        ))
        vm.clipboard.record(ClipItem(payload: .image(image), date: Date()))
        vm.open(.clipboard)
        vm.clipboardBrowser.filter = .images
        let before = isolated.pasteboard.changeCount
        for key in [NotchPanel.ListKey.up, .down, .enter] {
            XCTAssertEqual(vm.consumeListKey(key), .ignored, "the grid took \(key)")
        }
        XCTAssertEqual(isolated.pasteboard.changeCount, before, "nothing was copied")
    }

    /// Return while the Clear All question stands copies nothing and keeps
    /// the panel: the question is answered by its own buttons or by Escape.
    func testReturnLeavesAStandingQuestionAlone() {
        fill()
        vm.open(.clipboard)
        vm.clipboardClear.ask(count: 3)
        defer { vm.clipboardClear.cancel() }
        let before = isolated.pasteboard.changeCount
        XCTAssertEqual(vm.consumeListKey(.enter), .handled)
        XCTAssertEqual(isolated.pasteboard.changeCount, before)
        XCTAssertTrue(vm.clipboardClear.isAsking, "the question still stands")
    }

    /// Only Clipboard's own question holds Return. One armed anywhere else —
    /// a Settings row lapsing behind the panel — is not Clipboard's to answer
    /// and must not silence the key (R-10).
    func testAnotherQuestionDoesNotHoldReturn() {
        fill()
        vm.open(.clipboard)
        let elsewhere = ArmedConfirmations.shared.register {}
        defer { ArmedConfirmations.shared.withdraw(elsewhere) }
        XCTAssertEqual(vm.consumeListKey(.enter), .handledAndClose)
        XCTAssertEqual(isolated.pasteboard.string(forType: .string), "third")
    }

    /// Leaving Clipboard puts its question away, as leaving the tray does the
    /// tray's: the bar is not waiting on the next visit.
    func testLeavingClipboardPutsItsQuestionAway() {
        fill()
        vm.open(.clipboard)
        vm.clipboardClear.ask(count: 3)
        vm.open(.settings)
        XCTAssertFalse(vm.clipboardClear.isAsking)
    }
}
