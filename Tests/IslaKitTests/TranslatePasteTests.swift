import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Paste button (redesign 2026-10-15, spec §11): enabled only when the
/// pasteboard offers text, decided from its types alone, with the contents read
/// when the button is pressed and not one moment before.
///
/// Reading a pasteboard's contents is what raises macOS's "Paste from Other
/// Apps" alert (`checklist.md` §"Pasteboard privacy", 2026-10-11), and an alert
/// at the mere opening of a tab is exactly what that section was written to
/// prevent. The pasteboard here is private and its text is supplied lazily by a
/// provider that counts every request for the bytes — which, on a real
/// pasteboard, is a content read.
@MainActor
final class TranslatePasteTests: XCTestCase {
    private func offer(_ text: String, on board: NSPasteboard) -> CountingTextProvider {
        let provider = CountingTextProvider(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        board.writeObjects([item])
        return provider
    }

    func testAnEmptyPasteboardOffersNoText() {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.pasteboard.clearContents()
        XCTAssertFalse(rig.translator.pasteboardOffersText)
    }

    func testAPictureIsNotText() {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        XCTAssertFalse(rig.translator.pasteboardOffersText)
    }

    /// The whole rule: text is offered, nothing was read to find out, and the
    /// press reads it once.
    func testPasteIsEnabledByTypesAndReadsNothingUntilPressed() {
        let rig = TranslateRig()
        defer { rig.release() }
        let provider = offer("Where is the station?", on: rig.pasteboard)

        XCTAssertTrue(rig.translator.pasteboardOffersText, "enabled")
        XCTAssertTrue(rig.translator.pasteboardOffersText, "asked again, as the pane does every second")
        XCTAssertEqual(provider.calls, 0, "the type list alone decided it: no content read")

        let prepared = rig.translator.textFromPasteboard()
        XCTAssertEqual(prepared.text, "Where is the station?")
        XCTAssertEqual(provider.calls, 1, "the press is the one read")
    }

    /// Opening the tab — building the pane and walking it — reads nothing, and
    /// shows Paste enabled; with the field filled, it is gone.
    func testOpeningTheTabReadsNothingAndShowsPasteEnabled() async {
        let rig = TranslateRig()
        defer { rig.release() }
        let provider = offer("secret copied elsewhere", on: rig.pasteboard)

        let pane = TranslatePane(translator: rig.translator, privacy: rig.privacy, wantsKeyboard: .constant(false))
            .background(Color.black)
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
        let paste = root.first(label: "Paste")
        XCTAssertNotNil(paste, root.dump)
        XCTAssertTrue(paste?.enabled ?? false, root.dump)
        XCTAssertEqual(provider.calls, 0, "no read from opening the tab\n\(root.dump)")

        rig.translator.input = "Hello"
        let filled = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
        XCTAssertNil(filled.first(label: "Paste"), "Paste belongs to an empty card\n\(filled.dump)")
        XCTAssertEqual(provider.calls, 0)
    }

    func testPasteIsDisabledWithNoTextOnThePasteboard() async {
        let rig = TranslateRig()
        defer { rig.release() }
        rig.pasteboard.clearContents()
        let pane = TranslatePane(translator: rig.translator, privacy: rig.privacy, wantsKeyboard: .constant(false))
            .background(Color.black)
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
        let paste = root.first(label: "Paste")
        XCTAssertNotNil(paste, root.dump)
        XCTAssertFalse(paste?.enabled ?? true, root.dump)
    }

    /// The press itself: through the same preparation the hot key uses (trimmed,
    /// capped, noticed), here from the real button's accessibility press.
    func testPressingPasteFillsTheFieldAndReadsOnce() async {
        let rig = TranslateRig()
        defer { rig.release() }
        let provider = offer("  Good morning  ", on: rig.pasteboard)
        let pane = TranslatePane(translator: rig.translator, privacy: rig.privacy, wantsKeyboard: .constant(false))
            .background(Color.black)
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
        XCTAssertEqual(provider.calls, 0)
        XCTAssertTrue(root.first(label: "Paste")?.press() ?? false, root.dump)
        XCTAssertEqual(rig.translator.input, "Good morning")
        XCTAssertEqual(provider.calls, 1)
    }
}
