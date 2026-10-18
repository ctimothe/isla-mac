import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The tray as an assistive client finds it.
///
/// Before this, a card was not an element at all: its name and its age
/// floated loose in the pane and interleaved across cards ("Just now" read
/// beside the wrong file), the selection mark was a separate 13x13 image, and
/// select, open and drag lived in an AppKit overlay with no accessibility.
/// A VoiceOver user could not use the Shelf. The empty Shelf was one glyph,
/// spoken "Download Multiple". The tray (spec §19.7) keeps every one of those
/// rules on its tiles; the selection bar it once held is gone (§19.11).
///
/// Nothing here opens a file, shows Quick Look, starts AirDrop or writes the
/// general pasteboard: only Select and Remove are performed, on an isolated
/// store over files in a temporary folder.
@MainActor
final class ShelfAccessibilityTests: XCTestCase {
    /// The tray's content at the panel's default width: 560 wide and 262 under
    /// the 38 pt header row (`ShelfLayout.viewport`), the pane's own default.
    private let paneSize = ShelfLayout.viewport(bodyWidth: 560).size

    private func tray(_ shelf: ShelfStore, clear: ShelfClearConfirmation = ShelfClearConfirmation()) -> ShelfPane {
        ShelfPane(shelf: shelf, clear: clear)
    }

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let folder: URL
        let shelf: ShelfStore

        @MainActor
        init(files: [String]) {
            suiteName = "ShelfAccessibilityTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("isla-shelf-ax-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            shelf = ShelfStore(defaults: defaults)
            // No QuickLook and no bookmarks: the card's preview is beside the
            // point here, and the store must not reach past the folder.
            shelf.requestThumbnail = { _, done in done(nil) }
            shelf.makeBookmark = { _ in nil }
            let urls = files.map { folder.appendingPathComponent($0) }
            for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
            if !urls.isEmpty { shelf.add(urls) }
        }

        func release() {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeSuite(named: suiteName)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static let cardActions = ["Select", "Quick Look", "AirDrop", "Copy", "Show in Finder", "Remove from Shelf"]

    /// Each card is one button named by its file, with its age as the value
    /// and the context menu's actions under VoiceOver's Actions rotor; Select
    /// marks it selected in both the value and the trait, and Remove takes it
    /// off the Shelf.
    func testEachCardIsOneButtonWithItsActions() async {
        let fixture = Fixture(files: ["alpha.txt", "beta.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        XCTAssertEqual(shelf.items.count, 2)

        let root = await AXProbe.tree(of: tray(shelf), size: paneSize)
        let names = Set(["alpha.txt", "beta.txt"])
        let cards = root.all(role: "AXButton").filter { names.contains($0.label) }
        XCTAssertEqual(cards.count, 2, root.dump)
        XCTAssertEqual(Set(cards.map(\.label)), names, root.dump)
        for card in cards {
            XCTAssertTrue(card.value.contains(localized("Just now")), root.dump)
            XCTAssertEqual(card.customActions, Self.cardActions, root.dump)
            XCTAssertTrue(card.actionNames.contains("AXPress"), root.dump)
            XCTAssertFalse(card.selected, root.dump)
            // The card swallows its own parts: the name and the age are not
            // read again as loose text beside it.
            XCTAssertTrue(card.children.isEmpty, root.dump)
        }
        XCTAssertTrue(root.all(role: "AXStaticText").filter { names.contains($0.label) || names.contains($0.value) }.isEmpty,
                      root.dump)

        guard let alpha = cards.first(where: { $0.label == "alpha.txt" }),
              let alphaItem = shelf.items.first(where: { $0.name == "alpha.txt" }) else {
            return XCTFail(root.dump)
        }
        XCTAssertTrue(alpha.perform(named: "Select"), root.dump)
        XCTAssertTrue(shelf.isSelected(alphaItem))

        let after = await alpha.reread()
        guard let selected = after.all(role: "AXButton").first(where: { $0.label == "alpha.txt" }) else {
            return XCTFail(after.dump)
        }
        XCTAssertTrue(selected.selected, after.dump)
        XCTAssertTrue(selected.value.contains(localized("Selected")), after.dump)
        XCTAssertEqual(selected.customActions.first, "Deselect", after.dump)
        // The selection mark is part of the card now, not an image beside it.
        XCTAssertTrue(after.all(role: "AXImage").isEmpty, after.dump)

        XCTAssertTrue(selected.perform(named: "Remove from Shelf"), after.dump)
        XCTAssertEqual(shelf.items.map(\.name), ["beta.txt"])
        let last = await after.reread()
        XCTAssertEqual(last.all(role: "AXButton").filter { names.contains($0.label) }.count, 1, last.dump)
    }

    /// The empty tray says what the Shelf is for in one line, and there is
    /// no glyph or limit to read: the line is the whole state (§19.7).
    func testTheEmptyShelfSaysWhatToDo() async {
        let fixture = Fixture(files: [])
        defer { fixture.release() }

        let root = await AXProbe.tree(of: tray(fixture.shelf), size: paneSize)
        let texts = root.all(role: "AXStaticText")
        let words = texts.map { $0.label.isEmpty ? $0.value : $0.label }
        XCTAssertEqual(words, ["Drag files to the notch to keep them here."], root.dump)
        XCTAssertTrue(root.all { $0.label == "Download Multiple" }.isEmpty, root.dump)
        XCTAssertTrue(root.all(role: "AXImage").isEmpty, root.dump)
        XCTAssertTrue(root.all(role: "AXButton").isEmpty, "nothing to press on an empty tray\n\(root.dump)")
    }

    private func words(_ root: AXNode) -> [String] {
        root.all(role: "AXStaticText").map { $0.label.isEmpty ? $0.value : $0.label }
    }

    /// A drag over the island presents the drop surface (spec §19.7) instead of
    /// the tray: two targets name what letting go does — the same words empty or
    /// populated, since they are a surface of their own, not a state of the
    /// tray — and the one under the pointer is lit, which is colour and no
    /// words. They are drawing, not controls.
    func testTheDropSurfaceNamesBothTargets() async {
        let bodyWidth = 560.0
        let size = CGSize(width: bodyWidth, height: SurfaceLayout.dropHeight - 38)
        for target in [ShelfDropTarget.keep, .airDrop] {
            let root = await AXProbe.tree(of: ShelfDropSurface(bodyWidth: bodyWidth, dropTarget: target), size: size)
            XCTAssertEqual(
                Set(words(root)),
                ["Keep on Shelf", "Release to add to the Shelf", "AirDrop", "Send to a nearby device"],
                "lit \(target)\n\(root.dump)"
            )
            // Glyphs are drawing, as the empty tray's line is.
            XCTAssertTrue(root.all(role: "AXImage").isEmpty, root.dump)
            XCTAssertTrue(root.all(role: "AXButton").isEmpty, "the surface takes no clicks: the drop is the window's\n\(root.dump)")
        }
    }

    /// Remove All asks first, in place of the row (spec §19.7): the sentence says
    /// how many, Cancel keeps everything, and Remove All is the one that acts.
    /// Both answers are the panel's push buttons, at least its minimum hit size.
    func testRemoveAllAsksInPlaceWithTwoNamedAnswers() async {
        let fixture = Fixture(files: ["alpha.txt", "beta.txt"])
        defer { fixture.release() }
        let ask = ShelfClearConfirmation()
        ask.ask(count: 2)
        defer { ask.cancel() }

        let root = await AXProbe.tree(of: tray(fixture.shelf, clear: ask), size: paneSize)
        XCTAssertTrue(words(root).contains("Remove all 2 items? Files are untouched."), root.dump)
        let cancel = root.all(role: "AXButton").first { $0.label == "Cancel" || $0.title == "Cancel" }
        let remove = root.all(role: "AXButton").first { $0.label == "Remove All" || $0.title == "Remove All" }
        XCTAssertNotNil(cancel, root.dump)
        XCTAssertNotNil(remove, root.dump)
        XCTAssertTrue(root.all(role: "AXButton").filter { ["alpha.txt", "beta.txt"].contains($0.label) }.isEmpty,
                      "the question stands in place of the row\n\(root.dump)")
        for button in [cancel, remove].compactMap({ $0 }) {
            let frame = button.frame ?? .zero
            XCTAssertGreaterThanOrEqual(frame.height, 20, "\(frame)\n\(root.dump)")
        }

        XCTAssertTrue(cancel?.press() ?? false, root.dump)
        XCTAssertEqual(fixture.shelf.items.count, 2, "Cancel keeps everything")
        XCTAssertFalse(ask.isAsking)

        ask.ask(count: 2)
        let again = await AXProbe.tree(of: tray(fixture.shelf, clear: ask), size: paneSize)
        let yes = again.all(role: "AXButton").first { $0.label == "Remove All" || $0.title == "Remove All" }
        XCTAssertTrue(yes?.press() ?? false, again.dump)
        XCTAssertTrue(fixture.shelf.items.isEmpty)
        XCTAssertFalse(ask.isAsking)
    }
}
