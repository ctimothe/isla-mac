import XCTest
@testable import IslaKit

/// A panel the keyboard opened can be ended from the keyboard.
///
/// ⌃⌥⌘I, Show Isla, ⌃⌥⌘L and the island's accessibility action all pin the
/// panel open with the pointer elsewhere, and the panel is not key outside
/// Translate — so Escape went to the app underneath and ⌘-Tab left the panel
/// standing over the menu bar (F-004). A pinned panel now holds Escape through
/// a transient hot key and ends when another app comes to the front. The
/// registration and the observer need a window server; the rules they consult
/// are pure and are held here.
@MainActor
final class PinnedKeyboardTests: XCTestCase {

    /// Only a pinned panel holds Escape, and only while nothing else in this
    /// app is entitled to it: the panel's own `sendEvent` already reads Escape
    /// while the panel is key (and must keep doing so, for input-method
    /// composition and Translate's clear-the-field), a window this app was
    /// activated for — Quick Look, AirDrop, About — answers Escape itself, and
    /// nothing is claimed over the lock screen's password field.
    func testOnlyAPinnedPanelWithoutTheKeyboardClaimsEscape() {
        XCTAssertTrue(
            NotchViewModel.claimsEscape(pinned: true, panelHasKeyboard: false, appIsActive: false, locked: false),
            "⌃⌥⌘I on Music: Escape must reach the panel"
        )
        XCTAssertFalse(
            NotchViewModel.claimsEscape(pinned: false, panelHasKeyboard: false, appIsActive: false, locked: false),
            "an unpinned panel is the pointer's, and every app keeps its own Escape"
        )
        XCTAssertFalse(
            NotchViewModel.claimsEscape(pinned: true, panelHasKeyboard: true, appIsActive: false, locked: false),
            "a key panel reads Escape in sendEvent; a hot key would steal it from an input method"
        )
        XCTAssertFalse(
            NotchViewModel.claimsEscape(pinned: true, panelHasKeyboard: false, appIsActive: true, locked: false),
            "Quick Look or AirDrop activated the app, and their own window answers Escape"
        )
        for pinned in [false, true] {
            for keyboard in [false, true] {
                for active in [false, true] {
                    XCTAssertFalse(
                        NotchViewModel.claimsEscape(
                            pinned: pinned, panelHasKeyboard: keyboard, appIsActive: active, locked: true
                        ),
                        "nothing is claimed over the shield (pinned \(pinned), keyboard \(keyboard), active \(active))"
                    )
                }
            }
        }
    }

    /// The pointer taking a pinned panel back gives Escape back with the pin:
    /// the claim is read from `isPinnedOpen`, which `pointerArrived()` clears.
    func testThePointerArrivingGivesEscapeBack() throws {
        let vm = try makeViewModel()
        vm.isPinnedOpen = true
        XCTAssertTrue(claims(vm))
        vm.pointerArrived()
        XCTAssertFalse(vm.isPinnedOpen)
        XCTAssertFalse(claims(vm), "a panel handed back to the pointer holds nothing")
    }

    /// ⌘-Tab is the keyboard's click in another app, and it ends a pin the
    /// same way. This app coming to the front is not another app: Quick Look
    /// and AirDrop activate it from inside a pinned panel.
    func testSwitchingToAnotherAppEndsAPin() throws {
        let vm = try makeViewModel()
        vm.isPinnedOpen = true
        XCTAssertTrue(vm.appActivated(ownPID: 1, activatedPID: 2))
        XCTAssertFalse(vm.appActivated(ownPID: 1, activatedPID: 1))
        vm.isPinnedOpen = false
        XCTAssertFalse(
            vm.appActivated(ownPID: 1, activatedPID: 2),
            "an unpinned panel is the pointer's to close, not the activation's"
        )
    }

    private func claims(_ vm: NotchViewModel) -> Bool {
        NotchViewModel.claimsEscape(
            pinned: vm.isPinnedOpen,
            panelHasKeyboard: vm.wantsKeyboard,
            appIsActive: false,
            locked: vm.isLockedPresentation
        )
    }

    /// Stores rooted in a temporary directory, so building a view model never
    /// reads or migrates the lyric files in the person's Application Support.
    private func makeViewModel() throws -> NotchViewModel {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinnedKeyboardTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return NotchViewModel(geometry: geometry, stores: NotchStores(localLyricsDirectory: root))
    }
}
