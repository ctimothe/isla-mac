import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Translate tab as an assistive client finds it, and how big its
/// controls are to a pointer.
///
/// Before this, the source field was an unnamed text area (F-030); each
/// language menu was found twice, once as its title and once as a 7x4-point
/// chevron of its own (H-021); the swap was an 18x14 target and the language
/// row 14 points tall, at the very top edge of the screen (F-014).
///
/// Every store is isolated (`ProbeFixtures`): a private defaults suite, a
/// translator whose capabilities are answered by the test, so nothing is
/// downloaded, nothing reaches the network and the owner's language choice is
/// never read or written.
@MainActor
final class TranslatePaneAccessibilityTests: XCTestCase {
    /// The pane at the default 560-point panel.
    private let size = CGSize(width: 488, height: 154)

    private func pane(_ isolated: ProbeStores) -> some View {
        TranslatePane(
            translator: isolated.stores.translator,
            privacy: isolated.stores.privacy,
            wantsKeyboard: .constant(false)
        )
        .background(Color.black)
    }

    /// One menu per language, each a row tall enough to land; a swap that is
    /// a target and not a glyph; and a field that says what it is for.
    func testOneMenuPerLanguageAndATappableSwap() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }

        let root = await AXProbe.tree(of: pane(isolated), size: size)
        let menus = root.all(role: "AXMenuButton")
        for name in ["Translate From", "Translate To"] {
            let found = menus.filter { $0.label == name || $0.title == name }
            XCTAssertEqual(found.count, 1, "\(name) is announced \(found.count) times\n\(root.dump)")
            if let frame = found.first?.frame {
                XCTAssertGreaterThanOrEqual(frame.height, 20, "\(name) is \(frame.height) points tall\n\(root.dump)")
            } else {
                XCTFail("\(name) has no frame\n\(root.dump)")
            }
        }

        let swap = root.first(label: "Swap Languages")
        XCTAssertNotNil(swap, root.dump)
        if let frame = swap?.frame {
            XCTAssertGreaterThanOrEqual(frame.width, 24, "swap is \(frame.size)\n\(root.dump)")
            XCTAssertGreaterThanOrEqual(frame.height, 20, "swap is \(frame.size)\n\(root.dump)")
        }

        let fields = root.all(role: "AXTextArea")
        XCTAssertEqual(fields.count, 1, root.dump)
        XCTAssertTrue(
            fields.contains { $0.label == "Text to translate" || $0.title == "Text to translate" },
            root.dump
        )
        // The placeholder is drawn, not read: VoiceOver has the field's label
        // and would otherwise hear the same invitation twice.
        XCTAssertNil(root.first(label: "Type or paste text"), root.dump)
    }

    /// A pair this Mac cannot translate offers a button, at least a target in
    /// size, and the message says the text would leave the Mac and for where.
    func testRemediesAreButtonsAndSayTheTextLeaves() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let translator = isolated.stores.translator
        // Nothing on device, the switch off: Uzbek is online-only.
        translator.capabilitiesOverride = { _ in Translator.Capabilities() }
        translator.choose(target: .uzbek)
        translator.input = "Where is the station?"
        await translator.translate()
        XCTAssertEqual(translator.remedies, [.turnOnOnline])
        XCTAssertTrue(translator.failure?.contains("MyMemory") ?? false, translator.failure ?? "no failure")

        let root = await AXProbe.tree(of: pane(isolated), size: size)
        let offer = root.all(role: "AXButton").first { $0.label == "Turn On Translate Online" || $0.title == "Turn On Translate Online" }
        XCTAssertNotNil(offer, root.dump)
        if let frame = offer?.frame {
            XCTAssertGreaterThanOrEqual(frame.width, 24, root.dump)
            XCTAssertGreaterThanOrEqual(frame.height, 20, root.dump)
        }
    }

    /// The placeholder belongs to an empty field only; under the cover there
    /// is text, so the dust is what shows.
    func testThePlaceholderShowsOnlyOverAnEmptyField() {
        XCTAssertTrue(TranslatePane.showsPlaceholder(input: "", covered: false))
        XCTAssertFalse(TranslatePane.showsPlaceholder(input: "a", covered: false))
        XCTAssertFalse(TranslatePane.showsPlaceholder(input: "a", covered: true))
    }
}
