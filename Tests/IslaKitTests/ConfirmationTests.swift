import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The panel's two-press confirmations and its Copy button (F-014, M-06).
///
/// Arming used to be silent: the word changed colour and nothing else, so a
/// VoiceOver user pressed Clear, heard nothing, and three seconds later the
/// arming had lapsed before they could find the button again. Escape closed
/// the whole panel instead of taking the question back, and the caption word
/// was a 27x13 target beside Deselect. Copy kept saying "Copy" after it had
/// copied.
@MainActor
final class ConfirmationTests: XCTestCase {
    private var spoken: [String] = []
    private var savedSink: ((String) -> Void)?

    override func setUp() {
        super.setUp()
        spoken = []
        let announcer = Announcer.shared
        savedSink = announcer.sink
        announcer.sink = { [unowned self] in spoken.append($0) }
        announcer.forget()
        _ = ArmedConfirmations.shared.disarmAll()
    }

    override func tearDown() {
        if let savedSink { Announcer.shared.sink = savedSink }
        Announcer.shared.forget()
        _ = ArmedConfirmations.shared.disarmAll()
        super.tearDown()
    }

    /// On macOS Escape means cancel, so the nearest cancellable thing goes
    /// first: an armed Clear is taken back, and only the next Escape — with
    /// nothing left armed — is left for the panel to fold on.
    func testEscapeDisarmsBeforeItCloses() throws {
        let probe = ProbeFixtures.isolatedStores()
        defer { probe.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: probe.stores)
        vm.open(.clipboard)

        var disarmed = 0
        ArmedConfirmations.shared.register { disarmed += 1 }

        XCTAssertTrue(vm.consumeEscape(), "an armed confirmation takes the Escape before the panel does")
        XCTAssertEqual(disarmed, 1)
        XCTAssertFalse(vm.consumeEscape(), "nothing is armed any more, so the panel folds")
        XCTAssertEqual(disarmed, 1, "a disarm runs once")
    }

    /// A withdrawn confirmation — the pane went away, or it was confirmed —
    /// cannot claim an Escape it no longer has anything to cancel for.
    func testAWithdrawnConfirmationClaimsNothing() {
        var disarmed = false
        let token = ArmedConfirmations.shared.register { disarmed = true }
        ArmedConfirmations.shared.withdraw(token)
        XCTAssertFalse(ArmedConfirmations.shared.disarmAll())
        XCTAssertFalse(disarmed)
    }

    func testArmingIsAnnouncedAndLastsLongerUnderVoiceOver() async {
        XCTAssertEqual(ArmedConfirmations.armedDuration(voiceOver: false), 3)
        XCTAssertEqual(ArmedConfirmations.armedDuration(voiceOver: true), 8)

        var cleared = 0
        let root = await AXProbe.tree(
            of: ConfirmTextButton(title: "Clear", armedTitle: "Clear Everything") { cleared += 1 },
            size: CGSize(width: 200, height: 60)
        )
        guard let clear = root.all(role: "AXButton").first(where: { $0.label == "Clear" }) else {
            return XCTFail(root.dump)
        }
        XCTAssertTrue(clear.press())
        let armed = await root.reread()
        XCTAssertEqual(spoken, ["Clear Everything. Press again to confirm."], armed.dump)
        XCTAssertEqual(cleared, 0, "the first press only asks")
        XCTAssertNotNil(armed.all(role: "AXButton").first { $0.label == "Clear Everything" }, armed.dump)

        // Escape takes the question back, and the button says Clear again.
        XCTAssertTrue(ArmedConfirmations.shared.disarmAll())
        let calm = await root.reread()
        XCTAssertNotNil(calm.all(role: "AXButton").first { $0.label == "Clear" }, calm.dump)
        XCTAssertEqual(cleared, 0, "a disarm never acts")
    }

    /// The whole two-press life of Clear without a pointer on it: the first
    /// press asks and speaks, the second acts, and an unanswered question
    /// lapses by itself after 3 s (8 s under VoiceOver, which this test cannot
    /// switch on — the allowance itself is held above). A pointer resting on the
    /// word holds the red until 3 s after it leaves (`ConfirmationArming.hover`),
    /// and a hover cannot be delivered to a window that is never ordered in, so
    /// that half stays a hardware check.
    func testAnUnansweredClearLapsesAfterThreeSecondsAndASecondPressActs() async throws {
        try XCTSkipIf(NSWorkspace.shared.isVoiceOverEnabled, "VoiceOver is on: the allowance is 8 s, not 3")
        var cleared = 0
        let root = await AXProbe.tree(
            of: ConfirmTextButton(title: "Clear", armedTitle: "Clear Everything") { cleared += 1 },
            size: CGSize(width: 200, height: 60)
        )
        func button(_ label: String, in tree: AXNode) throws -> AXNode {
            try XCTUnwrap(tree.all(role: "AXButton").first { $0.label == label }, tree.dump)
        }

        // Asked, then answered: the second press acts, once, and the word is
        // back to Clear.
        XCTAssertTrue(try button("Clear", in: root).press())
        let armed = await root.reread()
        XCTAssertNotNil(try? button("Clear Everything", in: armed), armed.dump)
        XCTAssertTrue(try button("Clear Everything", in: armed).press())
        let answered = await root.reread()
        XCTAssertEqual(cleared, 1, "the second press acts")
        XCTAssertNotNil(try? button("Clear", in: answered), answered.dump)

        // Asked, then left alone: still red a second later, back by 3 s.
        XCTAssertTrue(try button("Clear", in: answered).press())
        let waiting = await root.reread(settle: 1.0)
        XCTAssertNotNil(try? button("Clear Everything", in: waiting), "still asking after a second\n\(waiting.dump)")
        let lapsed = await root.reread(settle: 2.4)
        XCTAssertNotNil(try? button("Clear", in: lapsed), "lapsed by itself\n\(lapsed.dump)")
        XCTAssertEqual(cleared, 1, "a lapse never acts")
        XCTAssertFalse(ArmedConfirmations.shared.disarmAll(), "and it left nothing registered for Escape to take")
    }

    /// The caption word alone measured 27x13 in the lab dump, beside
    /// Deselect: a near miss armed Clear or hit the row underneath.
    func testCaptionButtonsAreBigEnough() async {
        let root = await AXProbe.tree(
            of: ConfirmTextButton(title: "Clear", armedTitle: "Clear Everything") {},
            size: CGSize(width: 200, height: 60)
        )
        guard let clear = root.all(role: "AXButton").first(where: { $0.label == "Clear" }),
              let frame = clear.frame else {
            return XCTFail(root.dump)
        }
        XCTAssertGreaterThanOrEqual(frame.width, Theme.minimumHitSize.width, "\(frame)\n\(root.dump)")
        XCTAssertGreaterThanOrEqual(frame.height, Theme.minimumHitSize.height, "\(frame)\n\(root.dump)")
    }

    func testCopyButtonSaysCopied() async {
        var copies = 0
        let root = await AXProbe.tree(of: CopyButton { copies += 1 }, size: CGSize(width: 80, height: 40))
        guard let copy = root.all(role: "AXButton").first(where: { $0.label == "Copy" }) else {
            return XCTFail(root.dump)
        }
        XCTAssertTrue(copy.press())
        let after = await root.reread()
        XCTAssertEqual(copies, 1)
        XCTAssertNotNil(after.all(role: "AXButton").first { $0.label == "Copied" }, after.dump)
        XCTAssertEqual(spoken, ["Copied"])
    }

    /// Translate's button names what it copies (KB-02).
    func testCopyButtonTakesATitle() async {
        let root = await AXProbe.tree(
            of: CopyButton(title: "Copy Translation") {}, size: CGSize(width: 80, height: 40)
        )
        XCTAssertNotNil(root.all(role: "AXButton").first { $0.label == "Copy Translation" }, root.dump)
    }
}
