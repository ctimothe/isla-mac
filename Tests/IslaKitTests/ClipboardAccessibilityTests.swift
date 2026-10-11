import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Clipboard tab as an assistive client finds it.
///
/// Before this, every row was the same "Copy Entry" button — twenty of them
/// read alike and none said what it would copy — and Remove and the reveal eye
/// appeared only under a hovering pointer, with no action anywhere else
/// (F-005). The covered and uncovered lists were indistinguishable to
/// VoiceOver. The empty tab was one glyph, read by its symbol's name, "Paste"
/// (F-036, M-08), and a copy was confirmed by a 12 pt glyph turning green and
/// nothing a screen reader could hear (H-016, M-02).
///
/// Every store here is isolated: a private defaults suite, a private named
/// pasteboard for the copies, and a recorder in place of the announcer, so a
/// run never touches the owner's settings, pasteboard or VoiceOver.
@MainActor
final class ClipboardAccessibilityTests: XCTestCase {
    private let size = CGSize(width: 560, height: 260)
    private let previews = ["third", "second", "first"]

    private var spoken: [String] = []
    private var savedSink: ((String) -> Void)?

    override func setUp() {
        super.setUp()
        spoken = []
        savedSink = Announcer.shared.sink
        Announcer.shared.sink = { [unowned self] in spoken.append($0) }
        Announcer.shared.forget()
    }

    override func tearDown() {
        if let savedSink { Announcer.shared.sink = savedSink }
        Announcer.shared.forget()
        super.tearDown()
    }

    /// Three entries, newest first, with the clipboard's cover set as asked.
    private func populated(covered: Bool) -> ProbeStores {
        let isolated = ProbeFixtures.isolatedStores()
        isolated.record([.text("first"), .text("second"), .text("third")], into: isolated.stores.clipboard)
        isolated.stores.privacy.setCovering(.clipboard, covered)
        return isolated
    }

    private func pane(_ isolated: ProbeStores, turnOnHistory: @escaping () -> Void = {}) -> ClipboardPane {
        ClipboardPane(
            clipboard: isolated.stores.clipboard,
            privacy: isolated.stores.privacy,
            historyDefaults: isolated.suite,
            turnOnHistory: turnOnHistory
        )
    }

    private func words(_ root: AXNode) -> [String] {
        root.all(role: "AXStaticText").map { $0.label.isEmpty ? $0.value : $0.label }
    }

    /// Each row is one button named by what it would copy, with Remove in the
    /// Actions rotor, and none of them is the old interchangeable "Copy Entry".
    func testRowsAreNamedByTheirTextAndOfferRemove() async {
        let isolated = populated(covered: false)
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard

        let root = await AXProbe.tree(of: pane(isolated), size: size)
        let rows = root.all(role: "AXButton").filter { previews.contains($0.label) }
        XCTAssertEqual(rows.map(\.label), previews, root.dump)
        XCTAssertTrue(root.all { $0.label == "Copy Entry" }.isEmpty, root.dump)
        for row in rows {
            XCTAssertTrue(row.actionNames.contains("AXPress"), root.dump)
            // Copy is the press; Show and Hide are offered only where there
            // is a cover to lift.
            XCTAssertEqual(row.customActions, ["Remove Entry"], root.dump)
            // One element per row: the preview is not read a second time as
            // loose text beside it.
            XCTAssertTrue(row.children.isEmpty, root.dump)
        }

        guard rows.count == 3 else { return }
        XCTAssertTrue(rows[1].perform(named: "Remove Entry"), root.dump)
        XCTAssertEqual(clipboard.items.map(\.preview), ["third", "first"])
        let after = await root.reread()
        XCTAssertEqual(after.all(role: "AXButton").filter { previews.contains($0.label) }.map(\.label),
                       ["third", "first"], after.dump)
    }

    /// A covered row says only that it is hidden, and Show — the same lift the
    /// eye gives a pointer — names it by its text.
    func testACoveredRowIsHiddenUntilRevealed() async {
        let isolated = populated(covered: true)
        defer { isolated.release() }

        let root = await AXProbe.tree(of: pane(isolated), size: size)
        let rows = root.all(role: "AXButton").filter { $0.label == "Hidden" }
        XCTAssertEqual(rows.count, 3, root.dump)
        // Nothing of the text leaks into any element while it is covered.
        XCTAssertTrue(root.all { node in previews.contains { node.label.contains($0) || node.value.contains($0) } }.isEmpty,
                      root.dump)
        for row in rows {
            // In the menu's order: the cover, then the destructive Remove last.
            XCTAssertEqual(row.customActions, ["Show", "Remove Entry"], root.dump)
        }

        guard rows.count == 3 else { return }
        XCTAssertTrue(rows[0].perform(named: "Show"), root.dump)
        let after = await root.reread()
        let labels = after.all(role: "AXButton").filter { $0.label == "third" || $0.label == "Hidden" }
        XCTAssertEqual(labels.map(\.label), ["third", "Hidden", "Hidden"], after.dump)
        XCTAssertEqual(labels.first?.customActions, ["Hide", "Remove Entry"], after.dump)
    }

    /// The empty tab says what goes in and what never does, and the glyph
    /// above it is drawing. With history off it says so, with a way to turn
    /// it back on where the person is looking.
    func testTheEmptyListSaysWhatGoesIn() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }

        let root = await AXProbe.tree(of: pane(isolated), size: size)
        XCTAssertTrue(words(root).contains("Nothing copied yet"), root.dump)
        XCTAssertTrue(words(root).contains("Text and files you copy appear here. Copies from password managers are skipped."),
                      root.dump)
        XCTAssertTrue(root.all { $0.label == "Paste" }.isEmpty, root.dump)
        XCTAssertTrue(root.all(role: "AXImage").isEmpty, root.dump)
        XCTAssertNil(root.first(label: "Turn On"), root.dump)

        isolated.suite.set(false, forKey: NotchViewModel.clipboardHistoryKey)
        var turnedOn = false
        let off = await AXProbe.tree(of: pane(isolated) { turnedOn = true }, size: size)
        XCTAssertTrue(words(off).contains("Clipboard history is off in Settings."), off.dump)
        XCTAssertFalse(words(off).contains("Nothing copied yet"), off.dump)
        let turnOn = off.all(role: "AXButton").filter { $0.label == "Turn On" || $0.title == "Turn On" }
        XCTAssertEqual(turnOn.count, 1, off.dump)
        XCTAssertTrue(turnOn.first?.press() ?? false, off.dump)
        XCTAssertTrue(turnedOn, "Turn On did not reach the history switch")
    }

    /// A copy is confirmed in words as well as a shape: the row is called
    /// "Copied" for the flash, and the announcer says it once.
    func testCopyingSaysCopied() async {
        let isolated = populated(covered: false)
        defer { isolated.release() }

        let root = await AXProbe.tree(of: pane(isolated), size: size)
        guard let first = root.all(role: "AXButton").first(where: { $0.label == "third" }) else {
            return XCTFail(root.dump)
        }
        XCTAssertTrue(first.press(), root.dump)
        XCTAssertEqual(isolated.pasteboard.string(forType: .string), "third")
        XCTAssertEqual(spoken, ["Copied"])

        let after = await root.reread()
        let copied = after.all(role: "AXButton").filter { $0.label == "Copied" }
        XCTAssertEqual(copied.count, 1, after.dump)
        // The other rows keep their names; only the pressed one confirms.
        XCTAssertEqual(after.all(role: "AXButton").filter { previews.contains($0.label) }.map(\.label),
                       ["second", "first"], after.dump)
    }
}
