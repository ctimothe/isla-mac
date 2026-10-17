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

    // MARK: ⌃Tab and ⌃⇧Tab (spec §19.16)

    private func openOnAHandTurnedClock() {
        vm.pageTravel.clock = ManualPageClock()
        vm.isOpen = true
    }

    /// While the panel has the keyboard, ⌃Tab and ⌃⇧Tab turn the page as
    /// they move between tabs in Safari, and the keyboard goes with them —
    /// onto the Shelf and Music too, which have no field: given back there,
    /// the next ⌃⇧Tab would go to the app in front and switch its tabs.
    func testControlTabTurnsThePageAndKeepsTheKeyboard() {
        openOnAHandTurnedClock()
        vm.open(.clipboard)
        XCTAssertTrue(vm.turnPageByKey(1, reduceMotion: false))
        XCTAssertEqual(vm.surface, .translate)
        XCTAssertTrue(vm.wantsKeyboard)
        XCTAssertTrue(vm.turnPageByKey(-1, reduceMotion: false))
        XCTAssertTrue(vm.turnPageByKey(-1, reduceMotion: false))
        XCTAssertEqual(vm.surface, .tray)
        XCTAssertTrue(vm.wantsKeyboard, "the Shelf keeps it, so the next ⌃⇧Tab still reaches the panel")
        XCTAssertTrue(vm.turnPageByKey(-1, reduceMotion: true))
        XCTAssertEqual(vm.surface, .player)
        XCTAssertTrue(vm.wantsKeyboard, "under Reduce Motion too")
    }

    /// Past either end the press is swallowed and nothing turns: the pages do
    /// not wrap, and ⌃Tab let through to a field would move its caret to a
    /// key view nobody can see.
    func testControlTabStopsAtTheEnds() {
        openOnAHandTurnedClock()
        vm.open(.translate)
        XCTAssertTrue(vm.turnPageByKey(1, reduceMotion: false))
        XCTAssertEqual(vm.surface, .translate)
        XCTAssertNil(vm.pageTravel.leg)
    }

    /// Without the keyboard ⌃Tab is not the island's to take — the panel is
    /// not key then and never sees it, but the model holds the rule too — and
    /// in Settings or over the lock it is left for whatever else wants it, a
    /// shortcut being recorded among them.
    func testControlTabNeedsTheKeyboardAndAPage() {
        openOnAHandTurnedClock()
        vm.turnPage(to: .tray)
        XCTAssertFalse(vm.wantsKeyboard)
        XCTAssertFalse(vm.turnPageByKey(1, reduceMotion: false))
        XCTAssertEqual(vm.surface, .tray)

        vm.open(.settings)
        vm.wantsKeyboard = true // a shortcut being recorded
        XCTAssertFalse(vm.turnPageByKey(1, reduceMotion: false))
        XCTAssertEqual(vm.surface, .settings)

        vm.open(.clipboard)
        vm.isLockedPresentation = true
        XCTAssertFalse(vm.turnPageByKey(1, reduceMotion: false))
        XCTAssertEqual(vm.surface, .clipboard)
    }

    /// The page last shown can be Clipboard or Translate, and the island
    /// landing there is not a summons: the pointer arriving and a click on the
    /// bare notch open it without the keyboard. With `open(_:)` on those roads
    /// a hover onto the notch, Open on Hover off, opened Clipboard holding the
    /// keyboard of the app being typed in (R8b review F1).
    func testLandingOnTheLastPageNeverTakesTheKeyboard() {
        for page in [NotchViewModel.Surface.clipboard, .translate] {
            vm.open(page)
            vm.isOpen = false
            vm.wantsKeyboard = false // Escape
            XCTAssertEqual(vm.openTarget, page, "the bare notch opens the page last shown")
            vm.pointerArrived()
            XCTAssertEqual(vm.surface, page)
            XCTAssertFalse(vm.wantsKeyboard, "\(page): the pointer arriving")
            vm.clickOpened(pointerIsOnPanel: { _ in true })
            XCTAssertFalse(vm.wantsKeyboard, "\(page): a click on the bare notch")
        }
    }

    /// Only a press into the field asks for the keyboard (§19.16): Clipboard's
    /// search field, Translate's source card. A row pressed to copy it, a dot,
    /// the gear, Swap or the translation is a way somewhere or an action, not a
    /// request to type. Excluding the header and the dots alone left every
    /// other press asking, so a row copied on a Clipboard the bare notch
    /// opened made the panel key on mouse-down, and a pinned panel kept it: a
    /// ⌘V meant for the app underneath landed in the search field (R8b review
    /// F2, re-review R2). That also covers the gear's last point below a
    /// 24 pt header strip (re-review R5).
    func testOnlyAPressIntoTheFieldAsksForTheKeyboard() {
        vm.isOpen = true
        vm.turnPage(to: .clipboard)
        let body = vm.openBodySize
        let header = vm.geometry.notchSize.height
        func press(_ x: CGFloat, _ y: CGFloat) -> Bool { vm.pressClaimsKeyboard(atBodyPoint: CGPoint(x: x, y: y)) }
        for centre in PageDotsLayout.centres(bodySize: body) {
            XCTAssertFalse(press(centre.x, centre.y), "a dot")
        }
        let gear = SurfaceHeaderLayout.gear(bodyWidth: body.width, notchHeight: header)
        XCTAssertFalse(press(gear.midX, gear.midY), "the gear")
        XCTAssertFalse(press(gear.midX, gear.maxY - 0.5), "the gear's last point")
        // The field is placed in the content, which starts under the header.
        let field = ClipboardHeader.searchField.offsetBy(dx: 0, dy: header)
        XCTAssertTrue(press(field.midX, field.midY), "the search field")
        XCTAssertFalse(press(body.width / 2, body.height / 2), "a row, pressed to copy it")

        vm.turnPage(to: .translate)
        let width = vm.openBodySize.width
        let card = TranslateLayout.sourceCard(bodyWidth: width).offsetBy(dx: 0, dy: header)
        XCTAssertTrue(press(card.midX, card.midY), "the source card")
        let result = TranslateLayout.resultCard(bodyWidth: width).offsetBy(dx: 0, dy: header)
        XCTAssertFalse(press(result.midX, result.midY), "the translation")
        let swap = TranslateLayout.pairBar(bodyWidth: width).swap.offsetBy(dx: 0, dy: header)
        XCTAssertFalse(press(swap.midX, swap.midY), "Swap")
        vm.translateShowsHistory = true
        XCTAssertFalse(press(card.midX, card.midY), "the History list replaces the card")
        vm.translateShowsHistory = false

        vm.turnPage(to: .tray)
        XCTAssertFalse(press(body.width / 2, body.height / 2), "the Shelf types nothing")
        vm.turnPage(to: .translate)
        vm.isLockedPresentation = true
        XCTAssertFalse(press(card.midX, card.midY), "never over the lock")
    }

    /// While the pages move, a press finds the field where it is drawn: the
    /// dots ride the moving outline and the field slides in with its page.
    /// Measured on the reach, a dot pressed on the way onto Clipboard asked
    /// (R8b re-review R1); refused for the whole leg, a click into a field
    /// that already looked still, in the settle's last few hundred
    /// milliseconds, was lost (re-review N1).
    func testAPressFindsTheFieldWhereItIsDrawn() throws {
        let clock = ManualPageClock()
        vm.pageTravel.clock = clock
        vm.isOpen = true
        vm.turnPage(to: .tray)
        vm.travel(to: .clipboard, reduceMotion: false)
        clock.advance(0.08)
        let leg = try XCTUnwrap(vm.travellingLeg)
        let drawn = vm.drawnOpenBodySize
        for centre in PageDotsLayout.centres(bodySize: drawn) {
            let inRegion = CGPoint(x: centre.x + (vm.openBodySize.width - drawn.width) / 2, y: centre.y)
            XCTAssertFalse(vm.pressClaimsKeyboard(atBodyPoint: inRegion), "a dot on the moving outline")
        }
        let field = ClipboardHeader.searchField.offsetBy(dx: 0, dy: vm.geometry.notchSize.height)
        let atRest = CGPoint(x: field.midX, y: field.midY)
        XCTAssertFalse(vm.pressClaimsKeyboard(atBodyPoint: atRest), "where the field will be, while it is far off")
        let index = try XCTUnwrap(leg.strip.pages.firstIndex(of: .clipboard))
        let paneX = leg.strip.x(ofPage: index, at: leg.position, outlineWidth: drawn.width)
        let onScreen = CGPoint(x: (vm.openBodySize.width - drawn.width) / 2 + paneX + field.midX, y: field.midY)
        XCTAssertTrue(vm.pressClaimsKeyboard(atBodyPoint: onScreen), "the field where it is drawn")

        for _ in 0..<600 where abs((vm.travellingLeg?.position ?? 2) - 2) > 0.01 { clock.advance(1.0 / 120) }
        XCTAssertNotNil(vm.travellingLeg, "the settle's tail")
        XCTAssertTrue(vm.pressClaimsKeyboard(atBodyPoint: atRest), "a field that looks still takes the click")
        for _ in 0..<600 where clock.isRunning { clock.advance(1.0 / 120) }
        XCTAssertTrue(vm.pressClaimsKeyboard(atBodyPoint: atRest), "at rest")
    }

    /// A dot's target is 20 pt tall, taller than the band under the pages:
    /// on the way onto Translate its source card slides under the top of the
    /// row, and a press there, on the row, asked for the keyboard — which
    /// stayed when the dot was Translate's own (R8b re-review P1).
    func testNoPartOfADotAsksForTheKeyboardOnTheWay() throws {
        let clock = ManualPageClock()
        vm.pageTravel.clock = clock
        vm.isOpen = true
        vm.turnPage(to: .tray)
        vm.travel(to: .translate, reduceMotion: false)
        while (vm.travellingLeg?.position ?? 1) < 0.65 { clock.advance(1.0 / 120) }
        let leg = try XCTUnwrap(vm.travellingLeg)
        let drawn = vm.drawnOpenBodySize
        let margin = (vm.openBodySize.width - drawn.width) / 2
        let index = try XCTUnwrap(leg.strip.pages.firstIndex(of: .translate))
        let paneX = leg.strip.x(ofPage: index, at: leg.position, outlineWidth: drawn.width)
        let card = try XCTUnwrap(vm.fieldFrame(of: .translate)).offsetBy(dx: paneX, dy: 0)
        let tops = PageDotsLayout.hitFrames(bodySize: drawn).map { CGPoint(x: $0.midX, y: $0.minY + 1) }
        let overCard = tops.filter { card.contains($0) }
        XCTAssertFalse(overCard.isEmpty, "the card is under the row's top")
        for top in overCard {
            XCTAssertFalse(vm.pressClaimsKeyboard(atBodyPoint: CGPoint(x: top.x + margin, y: top.y)), "a dot's top")
        }
    }

    /// The press as the panel hands it over, in window coordinates, read into
    /// the body by the controller: a y read the wrong way up or an x off the
    /// body's left edge would put the field somewhere else, and no other test
    /// drives the conversion (R8b review F10).
    func testAPressIsReadFromTheWindowIntoTheBody() {
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        vm.isOpen = true
        vm.turnPage(to: .clipboard)
        let body = vm.openBodySize
        let content = vm.geometry.contentRect(for: body)
        func window(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: content.minX + x, y: content.maxY - y) }
        let field = ClipboardHeader.searchField.offsetBy(dx: 0, dy: vm.geometry.notchSize.height)
        controller.pressed(atWindowPoint: window(body.width / 2, body.height / 2))
        XCTAssertFalse(vm.wantsKeyboard, "a row")
        controller.pressed(atWindowPoint: window(field.midX, field.midY))
        XCTAssertTrue(vm.wantsKeyboard, "the search field")
    }

    /// A swipe or a dot after ⌃Tab gives the keyboard back, as it does from
    /// a page the keyboard summoned: the pointer is driving now.
    func testADotAfterControlTabGivesTheKeyboardBack() {
        openOnAHandTurnedClock()
        vm.open(.clipboard)
        XCTAssertTrue(vm.turnPageByKey(-1, reduceMotion: false))
        XCTAssertTrue(vm.wantsKeyboard)
        vm.travel(to: .player, reduceMotion: false)
        XCTAssertFalse(vm.wantsKeyboard)
    }
}
