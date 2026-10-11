import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The probe every accessibility fix is tested through.
///
/// These run in the gate, not only in the visual lab: the lab's dump is gated
/// on ISLA_VISUAL_OUT and never read custom actions, so an accessibility
/// regression had no test that `./scripts/check` would ever run.
@MainActor
final class AccessibilityProbeTests: XCTestCase {
    /// Roles, labels, the standard press and a named action, all read the way
    /// an assistive client reads them, and the named action performed through
    /// the probe reaches the view's own handler.
    func testTheProbeReadsRolesLabelsAndNamedActions() async {
        var copied = false
        var fired = false
        let view = VStack {
            CopyButton { copied = true }
            Text(verbatim: "x").accessibilityAction(named: "Do It") { fired = true }
        }
        let root = await AXProbe.tree(of: view, size: CGSize(width: 200, height: 120))

        let copyButtons = root.all(role: "AXButton").filter { $0.label == "Copy" }
        XCTAssertEqual(copyButtons.count, 1, root.dump)
        let copy = copyButtons.first
        XCTAssertTrue(copy?.actionNames.contains("AXPress") ?? false, root.dump)
        XCTAssertTrue(copy?.enabled ?? false, root.dump)
        XCTAssertNotNil(root.first(label: "Copy"), root.dump)

        let named = root.all { $0.customActions == ["Do It"] }
        XCTAssertEqual(named.count, 1, root.dump)

        XCTAssertTrue(root.perform(named: "Do It"), root.dump)
        XCTAssertTrue(fired, "the named action did not reach its handler")

        XCTAssertTrue(copy?.press() ?? false, root.dump)
        XCTAssertTrue(copied, "pressing Copy did not reach the button's action")
    }

    /// The clipboard list, recorded first as the baseline the clipboard
    /// accessibility fix (ax/CB-01) inverted: every row was announced as the
    /// same "Copy Entry" button, so a VoiceOver user heard three identical
    /// buttons and nothing of what each one would copy. Now each row is named
    /// by its preview, and none by the old generic name. The full contract
    /// lives in `ClipboardAccessibilityTests`.
    func testTheProbeSeesTheClipboardRowsByName() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        isolated.record([.text("first"), .text("second"), .text("third")], into: clipboard)

        let pane = ClipboardPane(clipboard: clipboard, privacy: isolated.stores.privacy)
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 560, height: 260))

        XCTAssertTrue(root.all(role: "AXButton").filter { $0.label == "Copy Entry" }.isEmpty, root.dump)
        let rows = root.all(role: "AXButton").filter { ["first", "second", "third"].contains($0.label) }
        XCTAssertEqual(rows.map(\.label), ["third", "second", "first"], root.dump)
    }
}
