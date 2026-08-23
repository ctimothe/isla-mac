import AppKit
import SwiftUI
import XCTest
@testable import DynamicIslandKit

/// What the notch panel draws while the shield is up.
///
/// The pill is the only thing left in that window now that the card has one of
/// its own, and it has to stay pinned to the top of it — the panel is anchored
/// to the notch, so the top of the window *is* the cutout. When the card left,
/// it took with it the one view that made the locked stack fill the window, and
/// a stack that hugs a 32 pt pill gets centred in 444 pt instead: the island
/// floating two hundred points down the lock screen, over the clock.
@MainActor
final class LockedShellLayoutTests: XCTestCase {
    func testTheLockedShellFillsThePanelSoThePillStaysAtTheNotch() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current(), "the test host has a screen")
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
        vm.isLockedPresentation = true

        let panel = geometry.windowSize
        let host = NSHostingController(rootView: NotchContentView(vm: vm))
        let wanted = host.sizeThatFits(in: panel)

        XCTAssertEqual(
            wanted.height, panel.height, accuracy: 1,
            "the locked shell must take the whole panel: anything shorter is centred, "
                + "which puts the island below the notch it is pretending to be"
        )
        XCTAssertEqual(wanted.width, panel.width, accuracy: 1)
    }

    /// The same for the ordinary shell, which had the property all along and
    /// must keep it.
    func testTheUnlockedShellFillsThePanelToo() throws {
        let geometry = try XCTUnwrap(NotchGeometry.current())
        let vm = NotchViewModel(geometry: geometry, stores: NotchStores())

        let panel = geometry.windowSize
        let host = NSHostingController(rootView: NotchContentView(vm: vm))
        let wanted = host.sizeThatFits(in: panel)

        XCTAssertEqual(wanted.height, panel.height, accuracy: 1)
        XCTAssertEqual(wanted.width, panel.width, accuracy: 1)
    }
}
