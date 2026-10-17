import AppKit
import Carbon.HIToolbox
import XCTest
@testable import IslaKit

/// The island's right-click menu (spec §19.9): what it lists, the keys it
/// shows, where it opens, and that it shakes instead over the lock.
@MainActor
final class IslandMenuTests: XCTestCase {
    private let bindings: [HotKeyAction: HotKeyBinding] = Dictionary(
        uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultBinding) }
    )

    func testTheRowsAreTheBoardsInItsOrder() {
        let items = IslandMenu.items(bindings: bindings, songPlaying: true)
        XCTAssertEqual(
            items.map(\.kind),
            [.clipboard, .translateClipboard, .shelf, .lyrics, .separator, .settings, .quit]
        )
        XCTAssertEqual(
            items.filter { $0.kind != .separator }.map(\.title),
            ["Clipboard", "Translate Clipboard", "Shelf", "Lyrics", "Settings…", "Quit Isla"].map { localized($0) }
        )
    }

    /// The keys are the hot keys' current bindings; Shelf, Settings… and Quit
    /// show none (the menu claims no key of its own).
    func testTheShownKeysAreTheCurrentBindings() {
        let items = IslandMenu.items(bindings: bindings, songPlaying: true)
        func shown(_ kind: IslandMenuItem.Kind) -> HotKeyBinding? { items.first { $0.kind == kind }?.shown }
        XCTAssertEqual(shown(.translateClipboard), HotKeyAction.translateClipboard.defaultBinding)
        XCTAssertEqual(shown(.lyrics), HotKeyAction.showLyrics.defaultBinding)
        XCTAssertNil(shown(.shelf))
        XCTAssertNil(shown(.settings))
        XCTAssertNil(shown(.quit))

        // A key moved in Settings moves here; a cleared one shows nothing.
        var moved = bindings
        moved[.showLyrics] = HotKeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: HotKeyBinding.defaultModifiers)
        moved[.translateClipboard] = nil
        let after = IslandMenu.items(bindings: moved, songPlaying: true)
        XCTAssertEqual(after.first { $0.kind == .lyrics }?.shown?.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertNil(after.first { $0.kind == .translateClipboard }?.shown)
    }

    func testLyricsIsEnabledOnlyWhileASongPlays() {
        let silent = IslandMenu.items(bindings: bindings, songPlaying: false)
        XCTAssertEqual(silent.filter { !$0.isEnabled }.map(\.kind), [.lyrics])
        XCTAssertTrue(IslandMenu.items(bindings: bindings, songPlaying: true).allSatisfy(\.isEnabled))
    }

    func testAKeyEquivalentIsTheLetterAndItsModifiers() throws {
        let shown = try XCTUnwrap(IslandMenu.keyEquivalent(for: HotKeyAction.showLyrics.defaultBinding))
        // The letter the ASCII-capable layout prints there, as Settings shows
        // it — L on QWERTY — lower case, or AppKit reads Shift into it.
        XCTAssertEqual(shown.key, HotKeyBinding.keyName(UInt32(kVK_ANSI_L)).lowercased())
        XCTAssertEqual(shown.modifiers, [.control, .option, .command])

        let f5 = try XCTUnwrap(IslandMenu.keyEquivalent(
            for: HotKeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey))
        ))
        XCTAssertEqual(f5.key, String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        XCTAssertEqual(f5.modifiers, [.shift, .command])
    }

    /// The menu AppKit draws matches the rows, and a row runs its kind.
    func testTheMenuMatchesTheRowsAndRunsThem() throws {
        let items = IslandMenu.items(bindings: bindings, songPlaying: false)
        var ran: [IslandMenuItem.Kind] = []
        let menu = IslandMenu.menu(items) { ran.append($0) }

        XCTAssertEqual(menu.items.count, items.count)
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
        XCTAssertFalse(menu.autoenablesItems)
        let lyrics = menu.items[3]
        XCTAssertEqual(lyrics.title, localized("Lyrics"))
        XCTAssertFalse(lyrics.isEnabled)
        XCTAssertEqual(lyrics.keyEquivalent, HotKeyBinding.keyName(UInt32(kVK_ANSI_L)).lowercased())
        XCTAssertEqual(lyrics.keyEquivalentModifierMask, [.control, .option, .command])
        XCTAssertEqual(menu.items[2].keyEquivalent, "", "Shelf has no key")

        // Through each row's own target and action, which is what AppKit
        // sends: `performActionForItem` routes through `NSApp`, which a test
        // process does not have.
        for index in [0, 6] {
            let row = menu.items[index]
            let target = try XCTUnwrap(row.target as? NSObject, "a row keeps its target alive: \(row.title)")
            let action = try XCTUnwrap(row.action)
            target.perform(action, with: row)
        }
        XCTAssertEqual(ran, [.clipboard, .quit])
    }

    // MARK: - What reaches it

    /// A right-click, or a click with Control and nothing else held — which
    /// macOS means as a right-click — and no other press.
    func testARightClickOrAControlClickIsSecondary() {
        XCTAssertTrue(NotchPanel.isSecondaryClick(type: .rightMouseDown, flags: []))
        XCTAssertTrue(NotchPanel.isSecondaryClick(type: .leftMouseDown, flags: .control))
        XCTAssertTrue(NotchPanel.isSecondaryClick(type: .leftMouseDown, flags: [.control, .capsLock]))
        XCTAssertFalse(NotchPanel.isSecondaryClick(type: .leftMouseDown, flags: []), "a click opens the island")
        XCTAssertFalse(NotchPanel.isSecondaryClick(type: .leftMouseDown, flags: [.control, .command]))
        XCTAssertFalse(NotchPanel.isSecondaryClick(type: .rightMouseUp, flags: []))
        XCTAssertFalse(NotchPanel.isSecondaryClick(type: .keyDown, flags: .control))
    }

    /// The panel asks the seam with the click's point, before anything
    /// under it hears of the press; taken, the press is not latched, since
    /// the menu's own loop takes the release.
    func testThePanelAsksBeforeTheClickReachesAnything() throws {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        var asked: [NSPoint] = []
        panel.secondaryClickHandled = { asked.append($0); return true }
        for (type, flags) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()), (.leftMouseDown, .control)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 40, y: 60), modifierFlags: flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            panel.sendEvent(event)
        }
        XCTAssertEqual(asked, [NSPoint(x: 40, y: 60), NSPoint(x: 40, y: 60)])
        XCTAssertFalse(panel.isPressLatched, "a press the menu took is never latched")
    }

    // MARK: - Where it opens

    private let island = CGRect(x: 400, y: 562, width: 300, height: 40)
    private let bubble = CGRect(x: 716, y: 562, width: 58, height: 40)
    private let openBody = CGRect(x: 320, y: 300, width: 560, height: 302)

    private func click(
        _ point: CGPoint, active: CGRect, isOpen: Bool, isLocked: Bool = false
    ) -> IslandMenu.SecondaryClick {
        IslandMenu.secondaryClick(
            at: point, active: active, bubble: isOpen ? .zero : bubble,
            isOpen: isOpen, isLocked: isLocked, headerHeight: 38
        )
    }

    func testTheClosedIslandAndItsBubbleOpenTheMenu() {
        XCTAssertEqual(click(CGPoint(x: 410, y: 580), active: island, isOpen: false), .menu)
        XCTAssertEqual(click(CGPoint(x: 690, y: 580), active: island, isOpen: false), .menu)
        XCTAssertEqual(click(CGPoint(x: 740, y: 580), active: island, isOpen: false), .menu, "the bubble")
        XCTAssertEqual(
            click(CGPoint(x: 708, y: 580), active: island, isOpen: false), .passThrough,
            "the gap between them is the menu bar's"
        )
    }

    func testAnOpenSurfaceOpensTheMenuFromItsHeaderRowOnly() {
        XCTAssertEqual(click(CGPoint(x: 330, y: 590), active: openBody, isOpen: true), .menu)
        XCTAssertEqual(click(CGPoint(x: 870, y: 566), active: openBody, isOpen: true), .menu)
        XCTAssertEqual(
            click(CGPoint(x: 600, y: 562), active: openBody, isOpen: true), .passThrough,
            "below the row the click is the surface's: a row's own menu, a tile's Open With"
        )
        XCTAssertEqual(click(CGPoint(x: 600, y: 400), active: openBody, isOpen: true), .passThrough)
        XCTAssertEqual(click(CGPoint(x: 200, y: 590), active: openBody, isOpen: true), .passThrough)
    }

    /// Over the lock the island never offers the menu — Settings… and Quit
    /// would act over the password field — and answers with its shake, as a
    /// click does (LockedIslandIsInertTests holds the shake itself).
    func testOverTheLockARightClickShakesAndOpensNoMenu() {
        XCTAssertEqual(click(CGPoint(x: 410, y: 580), active: island, isOpen: false, isLocked: true), .shake)
        XCTAssertEqual(click(CGPoint(x: 740, y: 580), active: island, isOpen: false, isLocked: true), .shake)
        XCTAssertEqual(click(CGPoint(x: 200, y: 580), active: island, isOpen: false, isLocked: true), .passThrough)
    }
}
