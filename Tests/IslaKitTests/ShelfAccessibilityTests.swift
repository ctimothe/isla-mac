import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Shelf as an assistive client finds it.
///
/// Before this, a card was not an element at all: its name and its age
/// floated loose in the pane and interleaved across cards ("Just now" read
/// beside the wrong file), the selection mark was a separate 13x13 image, and
/// select, open and drag lived in an AppKit overlay with no accessibility.
/// A VoiceOver user could not use the Shelf. The empty Shelf was one glyph,
/// spoken "Download Multiple".
///
/// Nothing here opens a file, shows Quick Look, starts AirDrop or writes the
/// general pasteboard: only Select and Remove are performed, on an isolated
/// store over files in a temporary folder.
@MainActor
final class ShelfAccessibilityTests: XCTestCase {
    private let paneSize = CGSize(width: 560, height: 150)

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

        let root = await AXProbe.tree(of: ShelfPane(shelf: shelf, isTargeted: false), size: paneSize)
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

    /// The empty Shelf says what it is for and how much it holds, and the
    /// glyph above that is decoration.
    func testTheEmptyShelfSaysWhatToDo() async {
        let fixture = Fixture(files: [])
        defer { fixture.release() }

        let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: paneSize)
        let texts = root.all(role: "AXStaticText")
        let words = texts.map { $0.label.isEmpty ? $0.value : $0.label }
        XCTAssertTrue(words.contains("Drop files here to keep them"), root.dump)
        XCTAssertTrue(words.contains { $0.contains("Holds \(ShelfStore.limit).") }, root.dump)
        XCTAssertTrue(root.all { $0.label == "Download Multiple" }.isEmpty, root.dump)
        XCTAssertTrue(root.all(role: "AXImage").isEmpty, root.dump)
    }

    /// Deselect sits beside the destructive Clear, so it must not be a 13 pt
    /// sliver: the target is at least the panel's minimum hit size.
    func testDeselectIsBigEnough() async {
        let fixture = Fixture(files: ["alpha.txt"])
        defer { fixture.release() }
        fixture.shelf.select(fixture.shelf.items[0], modifiers: [])

        let root = await AXProbe.tree(of: ShelfPane(shelf: fixture.shelf, isTargeted: false), size: paneSize)
        guard let deselect = root.all(role: "AXButton").first(where: { $0.label == "Deselect" || $0.title == "Deselect" }),
              let frame = deselect.frame else {
            return XCTFail(root.dump)
        }
        XCTAssertGreaterThanOrEqual(frame.width, 24, root.dump)
        XCTAssertGreaterThanOrEqual(frame.height, 20, "\(frame)\n\(root.dump)")
    }
}
