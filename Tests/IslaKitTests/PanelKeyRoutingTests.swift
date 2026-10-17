import AppKit
import XCTest
@testable import IslaKit

/// The editing keys the panel dispatches itself, since an `.accessory` app
/// has no Edit menu to carry them (F-039, G-006, H-018).
///
/// They were matched by US key code with an exact modifier test. On a German
/// keyboard the key labelled Z is key code 16, so ⌘Z did nothing and ⌘Y
/// undid; on AZERTY ⌘A did not select all; with Caps Lock latched, every one
/// of them failed the exact-flags test and fell through to nothing; and after
/// ⌃⌥⌘T no key copied the translation, because ⇧⌘C copied the source like
/// ⌘C.
///
/// Every event here is one the panel handles itself. One that fell through
/// to `super` would reach no responder and beep on whatever Mac runs the
/// suite.
@MainActor
final class PanelKeyRoutingTests: XCTestCase {
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

    private func command(
        keyCode: UInt16,
        _ characters: String,
        ignoring: String? = nil,
        flags: NSEvent.ModifierFlags = .command
    ) -> NotchPanel.EditingCommand? {
        NotchPanel.editingCommand(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            flags: flags
        )
    }

    /// German QWERTZ: the key labelled Z sits where US has Y (key code 16),
    /// and the key at US Z's position (6) prints "y". The label wins.
    func testQWERTZFollowsTheLabelNotThePosition() {
        XCTAssertEqual(command(keyCode: 16, "z"), .undo)
        XCTAssertNil(command(keyCode: 6, "y"), "the key labelled Y is not undo, wherever it sits")
        XCTAssertEqual(command(keyCode: 16, "Z", flags: [.command, .shift]), .redo)
    }

    /// French AZERTY: A is where US has Q (key code 12).
    func testAZERTYSelectsAllFromTheKeyLabelledA() {
        XCTAssertEqual(command(keyCode: 12, "a"), .selectAll)
        XCTAssertNil(command(keyCode: 0, "q"), "US A's position prints Q here")
    }

    /// A Cyrillic layout prints "с" (U+0441) for the C key: no Latin letter
    /// anywhere in the event, so the physical key decides, as it always did.
    func testCyrillicFallsBackToThePhysicalKey() {
        XCTAssertEqual(command(keyCode: 8, "\u{0441}"), .copy)
        XCTAssertEqual(command(keyCode: 9, "\u{043C}"), .paste)
        XCTAssertEqual(command(keyCode: 6, "\u{044F}"), .undo)
        XCTAssertEqual(command(keyCode: 0, "\u{0444}"), .selectAll)
        XCTAssertEqual(command(keyCode: 7, "\u{0447}"), .cut)
    }

    /// Caps Lock is not a modifier anyone pressed for this. It used to fail
    /// the exact-flags test, so latched Caps Lock disabled every editing key.
    func testCapsLockDoesNotDisableTheEditingKeys() {
        XCTAssertEqual(command(keyCode: 9, "v", flags: [.command, .capsLock]), .paste)
        XCTAssertEqual(command(keyCode: 9, "V", flags: [.command, .capsLock]), .paste)
        XCTAssertEqual(command(keyCode: 8, "\u{0421}", flags: [.command, .capsLock]), .copy)
        XCTAssertEqual(command(keyCode: 8, "c", flags: [.command, .capsLock, .numericPad, .function]), .copy)
    }

    /// Dvorak – QWERTY ⌘ switches to QWERTY while ⌘ is held, so `characters`
    /// says "c" where the unmodified layout would say "j". What ⌘ produces is
    /// what the person meant.
    func testDvorakQWERTYCommandHonoursTheCommandLayout() {
        XCTAssertEqual(command(keyCode: 8, "c", ignoring: "j"), .copy)
    }

    /// ⇧⌘C is the translation; ⌘C stays the selection in the source.
    func testShiftCommandCCopiesTheTranslation() {
        XCTAssertEqual(command(keyCode: 8, "C", flags: [.command, .shift]), .copyTranslation)
        XCTAssertEqual(command(keyCode: 8, "c", flags: [.command, .shift, .capsLock]), .copyTranslation)
        XCTAssertEqual(command(keyCode: 8, "\u{0421}", flags: [.command, .shift]), .copyTranslation)
        XCTAssertEqual(command(keyCode: 8, "c"), .copy)
    }

    /// Option, Control and a missing ⌘ belong to somebody else.
    func testOtherModifiersAreNotEditingKeys() {
        XCTAssertNil(command(keyCode: 8, "ç", ignoring: "c", flags: [.command, .option]))
        XCTAssertNil(command(keyCode: 8, "c", flags: [.command, .control]))
        XCTAssertNil(command(keyCode: 8, "c", flags: []))
        XCTAssertNil(command(keyCode: 8, "C", flags: .shift))
        XCTAssertNil(command(keyCode: 1, "s"), "⌘S is not an editing key")
        XCTAssertNil(command(keyCode: 1, ""), "a dead key that printed nothing and is not on the table")
    }

    // MARK: - Real events through the panel

    private static func key(
        _ characters: String,
        ignoring: String? = nil,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = .command,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// The real `NSEvent` reads the same as its parts.
    func testARealEventReadsAsItsParts() throws {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        XCTAssertEqual(NotchPanel.editingCommand(for: try Self.key("z", keyCode: 16, in: panel)), .undo)
        XCTAssertEqual(
            NotchPanel.editingCommand(for: try Self.key("v", keyCode: 9, flags: [.command, .capsLock], in: panel)),
            .paste
        )
        XCTAssertEqual(
            NotchPanel.editingCommand(for: try Self.key("C", keyCode: 8, flags: [.command, .shift], in: panel)),
            .copyTranslation
        )
        XCTAssertNil(NotchPanel.editingCommand(for: try Self.key("y", keyCode: 6, in: panel)))
    }

    /// QWERTZ ⌘Z reaches the field's undo, and Caps Lock ⌘V its paste.
    func testTheEditingKeysReachTheFirstResponder() throws {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        let field = RecordingResponder(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        panel.contentView = field
        XCTAssertTrue(panel.makeFirstResponder(field))

        panel.sendEvent(try Self.key("z", keyCode: 16, in: panel))
        panel.sendEvent(try Self.key("v", keyCode: 9, flags: [.command, .capsLock], in: panel))
        panel.sendEvent(try Self.key("a", keyCode: 12, in: panel))
        XCTAssertEqual(field.performed, ["undo:", "paste:", "selectAll:"])
    }

    /// ⇧⌘C goes to the translation first, and only when there is none to
    /// copy does it fall back to what ⌘C does.
    func testShiftCommandCAsksForTheTranslationBeforeTheSelection() throws {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        let field = RecordingResponder(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        panel.contentView = field
        XCTAssertTrue(panel.makeFirstResponder(field))

        var asked = 0
        var copied = true
        panel.onCopyTranslation = {
            asked += 1
            return copied
        }
        panel.sendEvent(try Self.key("C", keyCode: 8, flags: [.command, .shift], in: panel))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(field.performed, [], "the translation was copied, so the source's selection was not")

        copied = false
        panel.sendEvent(try Self.key("C", keyCode: 8, flags: [.command, .shift], in: panel))
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(field.performed, ["copy:"], "nothing to translate-copy, so it copies like ⌘C")

        panel.sendEvent(try Self.key("c", keyCode: 8, in: panel))
        XCTAssertEqual(asked, 2, "⌘C never asks for the translation")
        XCTAssertEqual(field.performed, ["copy:", "copy:"])
    }

    // MARK: - The view model's half

    /// ⇧⌘C copies the answer on screen and says so; anywhere else, or with no
    /// answer to the text in the field, it leaves the key to ⌘C's meaning.
    func testCopyTranslationCopiesOnlyACurrentAnswerOnTranslate() throws {
        let probe = ProbeFixtures.isolatedStores()
        defer { probe.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: probe.stores)
        let translator = probe.stores.translator
        translator.pasteboard = probe.pasteboard
        probe.pasteboard.clearContents()

        vm.open(.translate)
        XCTAssertFalse(vm.copyTranslationIfShowing(), "no answer yet")

        translator.input = "Good morning"
        translator.received("Доброе утро", for: "Good morning", by: .intelligence)
        vm.open(.clipboard)
        XCTAssertFalse(vm.copyTranslationIfShowing(), "the translation is not what is on screen")
        XCTAssertNil(probe.pasteboard.string(forType: .string))

        vm.open(.translate)
        XCTAssertTrue(vm.copyTranslationIfShowing())
        XCTAssertEqual(probe.pasteboard.string(forType: .string), "Доброе утро")
        XCTAssertEqual(spoken.last, "Copied")
        XCTAssertEqual(translator.outputCopies, 1, "the Copy button ticks for a copy it did not make")

        // Mid-edit the answer is the previous text's (K-004): the button is
        // disabled, and the key does what the disabled button does — nothing
        // — rather than quietly copying the source in its place.
        translator.input = "Good morning, everyone"
        probe.pasteboard.clearContents()
        XCTAssertTrue(vm.copyTranslationIfShowing())
        XCTAssertNil(probe.pasteboard.string(forType: .string))
        XCTAssertEqual(translator.outputCopies, 1)
    }
}

/// A first responder that records the editing actions it receives.
private final class RecordingResponder: NSView {
    var performed: [String] = []
    override var acceptsFirstResponder: Bool { true }
    @objc func undo(_ sender: Any?) { performed.append("undo:") }
    @objc func redo(_ sender: Any?) { performed.append("redo:") }
    @objc func copy(_ sender: Any?) { performed.append("copy:") }
    @objc func cut(_ sender: Any?) { performed.append("cut:") }
    @objc func paste(_ sender: Any?) { performed.append("paste:") }
    @objc override func selectAll(_ sender: Any?) { performed.append("selectAll:") }
}
